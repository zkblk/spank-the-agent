// spank-the-agent: slap your MacBook, your AI agent obeys.
//
// Detects physical impacts via the Apple Silicon accelerometer (IOKit HID),
// always plays a whip crack, optionally plays WC3 peon responses,
// and — when --agent is enabled — automatically presses Enter to confirm
// whatever your AI overlord was nervously asking permission for.
//
// Inspired by spank (github.com/taigrr/spank). Requires sudo.
package main

import "C"

import (
	"bufio"
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/rand"
	"os"
	"os/exec"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/charmbracelet/fang"
	"github.com/gopxl/beep/v2"
	"github.com/gopxl/beep/v2/effects"
	"github.com/gopxl/beep/v2/mp3"
	"github.com/gopxl/beep/v2/speaker"
	"github.com/spf13/cobra"
	"github.com/taigrr/apple-silicon-accelerometer/detector"
	"github.com/taigrr/apple-silicon-accelerometer/sensor"
	"github.com/taigrr/apple-silicon-accelerometer/shm"
)

var version = "dev"

//go:embed audio/whip/*.mp3
var whipAudio embed.FS

//go:embed audio/warcraft/*.mp3
var warcraftAudio embed.FS

//go:embed audio/pain/*.mp3
var painAudio embed.FS

//go:embed audio/sexy/*.mp3
var sexyAudio embed.FS

//go:embed audio/halo/*.mp3
var haloAudio embed.FS

var (
	sexyMode      bool
	sexyAlso      bool
	haloMode      bool
	warcraftMode  bool
	customPath    string
	customFiles   []string
	fastMode      bool
	minAmplitude  float64
	cooldownMs    int
	stdioMode     bool
	volumeScaling bool
	paused        bool
	pausedMu      sync.RWMutex
	speedRatio    float64
	agentMode     bool
	multiSlap     int
)

const multiSlapWindow = 600 * time.Millisecond

var sensorReady = make(chan struct{})
var sensorErr = make(chan error, 1)

type playMode int

const (
	modeRandom      playMode = iota
	modeEscalation
)

const (
	decayHalfLife             = 30.0
	defaultMinAmplitude       = 0.20
	defaultCooldownMs         = 750
	defaultSpeedRatio         = 1.0
	defaultSensorPollInterval = 10 * time.Millisecond
	defaultMaxSampleBatch     = 200
	sensorStartupDelay        = 100 * time.Millisecond
)

type runtimeTuning struct {
	minAmplitude float64
	cooldown     time.Duration
	pollInterval time.Duration
	maxBatch     int
}

func defaultTuning() runtimeTuning {
	return runtimeTuning{
		minAmplitude: defaultMinAmplitude,
		cooldown:     time.Duration(defaultCooldownMs) * time.Millisecond,
		pollInterval: defaultSensorPollInterval,
		maxBatch:     defaultMaxSampleBatch,
	}
}

func applyFastOverlay(base runtimeTuning) runtimeTuning {
	base.pollInterval = 4 * time.Millisecond
	base.cooldown = 350 * time.Millisecond
	if base.minAmplitude > 0.18 {
		base.minAmplitude = 0.18
	}
	if base.maxBatch < 320 {
		base.maxBatch = 320
	}
	return base
}

type soundPack struct {
	name   string
	fs     embed.FS
	dir    string
	mode   playMode
	files  []string
	custom bool
}

func (sp *soundPack) loadFiles() error {
	if sp.custom {
		entries, err := os.ReadDir(sp.dir)
		if err != nil {
			return err
		}
		sp.files = make([]string, 0, len(entries))
		for _, entry := range entries {
			if !entry.IsDir() {
				sp.files = append(sp.files, sp.dir+"/"+entry.Name())
			}
		}
	} else {
		entries, err := sp.fs.ReadDir(sp.dir)
		if err != nil {
			return err
		}
		sp.files = make([]string, 0, len(entries))
		for _, entry := range entries {
			if !entry.IsDir() {
				sp.files = append(sp.files, sp.dir+"/"+entry.Name())
			}
		}
	}
	sort.Strings(sp.files)
	if len(sp.files) == 0 {
		return fmt.Errorf("no audio files found in %s", sp.dir)
	}
	return nil
}

type slapTracker struct {
	mu       sync.Mutex
	score    float64
	lastTime time.Time
	total    int
	halfLife float64
	scale    float64
	pack     *soundPack
}

func newSlapTracker(pack *soundPack, cooldown time.Duration) *slapTracker {
	cooldownSec := cooldown.Seconds()
	ssMax := 1.0 / (1.0 - math.Pow(0.5, cooldownSec/decayHalfLife))
	scale := (ssMax - 1) / math.Log(float64(len(pack.files)+1))
	return &slapTracker{
		halfLife: decayHalfLife,
		scale:    scale,
		pack:     pack,
	}
}

func (st *slapTracker) record(now time.Time) (int, float64) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if !st.lastTime.IsZero() {
		elapsed := now.Sub(st.lastTime).Seconds()
		st.score *= math.Pow(0.5, elapsed/st.halfLife)
	}
	st.score += 1.0
	st.lastTime = now
	st.total++
	return st.total, st.score
}

func (st *slapTracker) getFile(score float64) string {
	if st.pack.mode == modeRandom {
		return st.pack.files[rand.Intn(len(st.pack.files))]
	}
	maxIdx := len(st.pack.files) - 1
	idx := min(int(float64(len(st.pack.files))*(1.0-math.Exp(-(score-1)/st.scale))), maxIdx)
	return st.pack.files[idx]
}

func main() {
	cmd := &cobra.Command{
		Use:   "spank-the-agent",
		Short: "Slap your MacBook. Your AI agent obeys.",
		Long: `spank-the-agent reads the Apple Silicon accelerometer via IOKit HID.

Every slap plays a whip crack. Add --warcraft and your AI's "yes" comes
with a WC3 peon response. Add --agent and it also auto-presses Enter —
no more clicking through AI permission prompts like a peasant.

Requires sudo (for IOKit HID access to the accelerometer).
Agent mode also requires Accessibility permission (one-time dialog).`,
		Version: version,
		RunE: func(cmd *cobra.Command, args []string) error {
			tuning := defaultTuning()
			if fastMode {
				tuning = applyFastOverlay(tuning)
			}
			if cmd.Flags().Changed("min-amplitude") {
				tuning.minAmplitude = minAmplitude
			}
			if cmd.Flags().Changed("cooldown") {
				tuning.cooldown = time.Duration(cooldownMs) * time.Millisecond
			}
			return run(cmd.Context(), tuning)
		},
		SilenceUsage: true,
	}

	cmd.Flags().BoolVar(&agentMode, "agent", false, "Auto-press Enter on each slap (confirms AI permission prompts)")
	cmd.Flags().IntVar(&multiSlap, "multi-slap", 2, "Require N consecutive slaps within 1.5s to trigger (default 2)")
	cmd.Flags().BoolVar(&warcraftMode, "warcraft", false, "Play WC3 peon response after the whip crack")
	cmd.Flags().BoolVarP(&sexyMode, "sexy", "s", false, "Enable sexy mode (replaces whip with sexy sounds)")
	cmd.Flags().BoolVar(&sexyAlso, "sexy-also", false, "Play whip first, then moan after (both sounds together)")
	cmd.Flags().BoolVarP(&haloMode, "halo", "H", false, "Enable halo mode (replaces whip with Halo death sounds)")
	cmd.Flags().StringVarP(&customPath, "custom", "c", "", "Path to custom MP3 directory (replaces whip)")
	cmd.Flags().StringSliceVar(&customFiles, "custom-files", nil, "Comma-separated custom MP3 files (replaces whip)")
	cmd.Flags().BoolVar(&fastMode, "fast", false, "Faster detection: 4ms polling, 350ms cooldown")
	cmd.Flags().Float64Var(&minAmplitude, "min-amplitude", defaultMinAmplitude, "Detection threshold (0.0–1.0, lower = more sensitive)")
	cmd.Flags().IntVar(&cooldownMs, "cooldown", defaultCooldownMs, "Cooldown between responses (ms)")
	cmd.Flags().BoolVar(&stdioMode, "stdio", false, "JSON output + stdin commands (for integrations)")
	cmd.Flags().BoolVar(&volumeScaling, "volume-scaling", false, "Harder hits = louder sound")
	cmd.Flags().Float64Var(&speedRatio, "speed", defaultSpeedRatio, "Playback speed multiplier (0.5–2.0)")

	if err := fang.Execute(context.Background(), cmd); err != nil {
		os.Exit(1)
	}
}

func run(ctx context.Context, tuning runtimeTuning) error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("spank-the-agent requires root — run with: sudo spank-the-agent")
	}

	modeCount := 0
	if sexyMode && !sexyAlso {
		modeCount++
	}
	if haloMode {
		modeCount++
	}
	if customPath != "" || len(customFiles) > 0 {
		modeCount++
	}
	if modeCount > 1 {
		return fmt.Errorf("--sexy, --halo, and --custom are mutually exclusive")
	}
	if tuning.minAmplitude < 0 || tuning.minAmplitude > 1 {
		return fmt.Errorf("--min-amplitude must be between 0.0 and 1.0")
	}
	if tuning.cooldown <= 0 {
		return fmt.Errorf("--cooldown must be greater than 0")
	}

	// Primary sound pack (whip by default)
	var primary *soundPack
	switch {
	case len(customFiles) > 0:
		for _, f := range customFiles {
			if !strings.HasSuffix(strings.ToLower(f), ".mp3") {
				return fmt.Errorf("custom file must be MP3: %s", f)
			}
			if _, err := os.Stat(f); err != nil {
				return fmt.Errorf("custom file not found: %s", f)
			}
		}
		primary = &soundPack{name: "custom", mode: modeRandom, custom: true, files: customFiles}
	case customPath != "":
		primary = &soundPack{name: "custom", dir: customPath, mode: modeRandom, custom: true}
	case sexyMode && !sexyAlso:
		primary = &soundPack{name: "sexy", fs: sexyAudio, dir: "audio/sexy", mode: modeEscalation}
	case haloMode:
		primary = &soundPack{name: "halo", fs: haloAudio, dir: "audio/halo", mode: modeRandom}
	default:
		primary = &soundPack{name: "whip", fs: whipAudio, dir: "audio/whip", mode: modeRandom}
	}
	if len(primary.files) == 0 {
		if err := primary.loadFiles(); err != nil {
			return fmt.Errorf("loading %s audio: %w", primary.name, err)
		}
	}

	// Extra sexy pack — plays after whip when --sexy-also is set (both modes together)
	var sexyExtra *soundPack
	if sexyAlso {
		sexyExtra = &soundPack{name: "sexy", fs: sexyAudio, dir: "audio/sexy", mode: modeEscalation}
		if err := sexyExtra.loadFiles(); err != nil {
			return fmt.Errorf("loading sexy audio: %w", err)
		}
	}

	// Secondary sound pack (WC3 peon — optional)
	var warcraft *soundPack
	if warcraftMode {
		warcraft = &soundPack{name: "warcraft", fs: warcraftAudio, dir: "audio/warcraft", mode: modeRandom}
		if err := warcraft.loadFiles(); err != nil {
			return fmt.Errorf("loading warcraft audio: %w", err)
		}
	}

	if agentMode {
		fmt.Println("⚡ Agent mode — slap to confirm.")
		fmt.Println("   Need Accessibility: System Preferences → Privacy & Security → Accessibility")
	}
	if warcraftMode {
		fmt.Println("⚔️  Warcraft mode — Yes, me lord.")
	}

	ctx, cancel := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	accelRing, err := shm.CreateRing(shm.NameAccel)
	if err != nil {
		return fmt.Errorf("creating accel shm: %w", err)
	}
	defer accelRing.Close()
	defer accelRing.Unlink()

	go func() {
		close(sensorReady)
		if err := sensor.Run(sensor.Config{
			AccelRing: accelRing,
			Restarts:  0,
		}); err != nil {
			sensorErr <- err
		}
	}()

	select {
	case <-sensorReady:
	case err := <-sensorErr:
		return fmt.Errorf("sensor worker failed: %w", err)
	case <-ctx.Done():
		return nil
	}

	time.Sleep(sensorStartupDelay)
	return listenForSlaps(ctx, primary, warcraft, sexyExtra, accelRing, tuning)
}

func listenForSlaps(ctx context.Context, primary *soundPack, warcraft *soundPack, sexyExtra *soundPack, accelRing *shm.RingBuffer, tuning runtimeTuning) error {
	tracker := newSlapTracker(primary, tuning.cooldown)
	speakerInit := false
	det := detector.New()
	var lastAccelTotal uint64
	var lastEventTime time.Time
	var lastYell time.Time
	var pendingSlaps []time.Time // for multi-slap detection

	if stdioMode {
		go readStdinCommands()
	}

	presetLabel := "default"
	if fastMode {
		presetLabel = "fast"
	}
	extras := ""
	if warcraftMode {
		extras += " +warcraft"
	}
	if agentMode {
		extras += " +agent"
	}
	fmt.Printf("spank-the-agent: %s mode, %s tuning%s — ctrl+c to quit\n", primary.name, presetLabel, extras)
	if stdioMode {
		fmt.Println(`{"status":"ready"}`)
	}

	ticker := time.NewTicker(tuning.pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			fmt.Println("\nthe agent is free. goodbye.")
			return nil
		case err := <-sensorErr:
			return fmt.Errorf("sensor worker failed: %w", err)
		case <-ticker.C:
		}

		pausedMu.RLock()
		isPaused := paused
		pausedMu.RUnlock()
		if isPaused {
			continue
		}

		now := time.Now()
		tNow := float64(now.UnixNano()) / 1e9

		samples, newTotal := accelRing.ReadNew(lastAccelTotal, shm.AccelScale)
		lastAccelTotal = newTotal
		if len(samples) > tuning.maxBatch {
			samples = samples[len(samples)-tuning.maxBatch:]
		}

		nSamples := len(samples)
		for idx, sample := range samples {
			tSample := tNow - float64(nSamples-idx-1)/float64(det.FS)
			det.Process(sample.X, sample.Y, sample.Z, tSample)
		}

		if len(det.Events) == 0 {
			continue
		}

		ev := det.Events[len(det.Events)-1]
		if ev.Time.Equal(lastEventTime) {
			continue
		}
		lastEventTime = ev.Time

		if ev.Amplitude < minAmplitude {
			continue
		}

		// Multi-slap: accumulate hits, fire only when N arrive within window.
		// During cooldown we skip entirely so the window always starts fresh.
		if time.Since(lastYell) <= time.Duration(cooldownMs)*time.Millisecond {
			continue
		}

		n := multiSlap
		if n < 1 {
			n = 1
		}
		if n > 1 {
			pendingSlaps = append(pendingSlaps, now)
			// trim entries older than the window
			cutoff := now.Add(-multiSlapWindow)
			i := 0
			for i < len(pendingSlaps) && pendingSlaps[i].Before(cutoff) {
				i++
			}
			pendingSlaps = pendingSlaps[i:]
			if len(pendingSlaps) < n {
				if !stdioMode {
					fmt.Printf("slap %d/%d — keep going!\n", len(pendingSlaps), n)
				}
				continue
			}
			// Got enough — fire and reset
			pendingSlaps = pendingSlaps[:0]
		}

		lastYell = now
		num, score := tracker.record(now)
		file := tracker.getFile(score)

		if stdioMode {
			event := map[string]interface{}{
				"timestamp":    now.Format(time.RFC3339Nano),
				"slapNumber":   num,
				"amplitude":    ev.Amplitude,
				"severity":     string(ev.Severity),
				"file":         file,
				"agentMode":    agentMode,
				"warcraftMode": warcraftMode,
			}
			if data, err := json.Marshal(event); err == nil {
				fmt.Println(string(data))
			}
		} else {
			tags := ""
			if agentMode {
				tags += " → [Enter]"
			}
			if warcraftMode {
				tags += " → [Yes, me lord]"
			}
			fmt.Printf("slap #%d [%s amp=%.5fg]%s\n", num, ev.Severity, ev.Amplitude, tags)
		}

		// Always play the whip (or primary sound)
		go playAudio(primary, file, ev.Amplitude, &speakerInit)

		// Sexy also: play moan after whip when both modes are enabled
		if sexyExtra != nil {
			go func(amp float64) {
				time.Sleep(500 * time.Millisecond)
				sexyFile := sexyExtra.files[rand.Intn(len(sexyExtra.files))]
				playAudio(sexyExtra, sexyFile, amp, &speakerInit)
			}(ev.Amplitude)
		}

		// WC3 peon: one random phrase after the whip crack (different each time)
		if warcraft != nil {
			go func(amp float64) {
				time.Sleep(300 * time.Millisecond)
				peonFile := warcraft.files[rand.Intn(len(warcraft.files))]
				playAudio(warcraft, peonFile, amp, &speakerInit)
			}(ev.Amplitude)
		}

		// Auto-press Enter: fires 80ms after impact so the crack lands first
		if agentMode {
			go func() {
				time.Sleep(80 * time.Millisecond)
				pressEnter()
			}()
		}
	}
}

// pressEnter sends a synthetic Return/Enter keypress.
//
// We run as root (sudo), but CGEventPost from a root daemon has no
// WindowServer connection on modern macOS and is silently ignored.
// Instead we delegate to osascript running as the real user — System Events
// already has Accessibility on most Macs, so no manual setup needed.
func pressEnter() {
	// SUDO_USER is set by sudo to the original username.
	user := os.Getenv("SUDO_USER")
	var cmd *exec.Cmd
	if user != "" {
		// Run as the real (non-root) user so their TCC/Accessibility applies.
		cmd = exec.Command("sudo", "-u", user,
			"osascript", "-e", `tell application "System Events" to key code 36`)
	} else {
		// Fallback: already running as a normal user.
		cmd = exec.Command("osascript", "-e", `tell application "System Events" to key code 36`)
	}
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "spank-the-agent: pressEnter: %v\n", err)
		fmt.Fprintln(os.Stderr, "  → grant Accessibility to System Events in System Preferences")
	}
}

var speakerMu sync.Mutex

func amplitudeToVolume(amplitude float64) float64 {
	const (
		minAmp = 0.05
		maxAmp = 0.80
		minVol = -3.0
		maxVol = 0.0
	)
	if amplitude <= minAmp {
		return minVol
	}
	if amplitude >= maxAmp {
		return maxVol
	}
	t := (amplitude - minAmp) / (maxAmp - minAmp)
	t = math.Log(1+t*99) / math.Log(100)
	return minVol + t*(maxVol-minVol)
}

func playAudio(pack *soundPack, path string, amplitude float64, speakerInit *bool) {
	var streamer beep.StreamSeekCloser
	var format beep.Format

	if pack.custom {
		file, err := os.Open(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "spank-the-agent: open %s: %v\n", path, err)
			return
		}
		defer file.Close()
		streamer, format, err = mp3.Decode(file)
		if err != nil {
			fmt.Fprintf(os.Stderr, "spank-the-agent: decode %s: %v\n", path, err)
			return
		}
	} else {
		data, err := pack.fs.ReadFile(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "spank-the-agent: read %s: %v\n", path, err)
			return
		}
		streamer, format, err = mp3.Decode(io.NopCloser(bytes.NewReader(data)))
		if err != nil {
			fmt.Fprintf(os.Stderr, "spank-the-agent: decode %s: %v\n", path, err)
			return
		}
	}
	defer streamer.Close()

	speakerMu.Lock()
	if !*speakerInit {
		speaker.Init(format.SampleRate, format.SampleRate.N(time.Second/10))
		*speakerInit = true
	}
	speakerMu.Unlock()

	var source beep.Streamer = streamer
	if volumeScaling {
		source = &effects.Volume{
			Streamer: streamer,
			Base:     2,
			Volume:   amplitudeToVolume(amplitude),
			Silent:   false,
		}
	}
	if speedRatio != 1.0 && speedRatio > 0 {
		fakeRate := beep.SampleRate(int(float64(format.SampleRate) * speedRatio))
		source = beep.Resample(4, fakeRate, format.SampleRate, source)
	}

	done := make(chan bool)
	speaker.Play(beep.Seq(source, beep.Callback(func() {
		done <- true
	})))
	<-done
}

type stdinCommand struct {
	Cmd       string  `json:"cmd"`
	Amplitude float64 `json:"amplitude,omitempty"`
	Cooldown  int     `json:"cooldown,omitempty"`
	Speed     float64 `json:"speed,omitempty"`
}

func readStdinCommands() {
	processCommands(os.Stdin, os.Stdout)
}

func processCommands(r io.Reader, w io.Writer) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var cmd stdinCommand
		if err := json.Unmarshal([]byte(line), &cmd); err != nil {
			if stdioMode {
				fmt.Fprintf(w, `{"error":"invalid command: %s"}`+"\n", err.Error())
			}
			continue
		}
		switch cmd.Cmd {
		case "pause":
			pausedMu.Lock()
			paused = true
			pausedMu.Unlock()
			if stdioMode {
				fmt.Fprintln(w, `{"status":"paused"}`)
			}
		case "resume":
			pausedMu.Lock()
			paused = false
			pausedMu.Unlock()
			if stdioMode {
				fmt.Fprintln(w, `{"status":"resumed"}`)
			}
		case "set":
			if cmd.Amplitude > 0 && cmd.Amplitude <= 1 {
				minAmplitude = cmd.Amplitude
			}
			if cmd.Cooldown > 0 {
				cooldownMs = cmd.Cooldown
			}
			if cmd.Speed > 0 {
				speedRatio = cmd.Speed
			}
			if stdioMode {
				fmt.Fprintf(w, `{"status":"settings_updated","amplitude":%.4f,"cooldown":%d,"speed":%.2f}`+"\n",
					minAmplitude, cooldownMs, speedRatio)
			}
		case "status":
			pausedMu.RLock()
			isPaused := paused
			pausedMu.RUnlock()
			if stdioMode {
				fmt.Fprintf(w, `{"status":"ok","paused":%t,"amplitude":%.4f,"cooldown":%d,"volume_scaling":%t,"speed":%.2f,"agent_mode":%t,"warcraft_mode":%t}`+"\n",
					isPaused, minAmplitude, cooldownMs, volumeScaling, speedRatio, agentMode, warcraftMode)
			}
		default:
			if stdioMode {
				fmt.Fprintf(w, `{"error":"unknown command: %s"}`+"\n", cmd.Cmd)
			}
		}
	}
}
