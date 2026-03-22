# spank-the-agent

> Slap your MacBook. Your AI agent obeys.

You know that moment when Claude Code asks *"May I proceed with this?"* and you have to stop what you're doing, look at the screen, move your hand to the keyboard, and... press Enter?

**What if you could just slap your laptop instead?**

`spank-the-agent` detects the physical impact via the Apple Silicon accelerometer, plays a sound, and automatically fires an Enter keypress — telling your AI agent to stop asking permission and just do the thing.

Peak productivity. Zero regrets.

---

## Requirements

- macOS on Apple Silicon (M2+)
- `sudo` (for IOKit HID accelerometer access)
- Accessibility permission (for synthetic keypress in agent mode)
- Go 1.22+ (to build from source)

---

## Install (App — no terminal needed)

1. Download **SpankTheAgent.zip** from [Releases](https://github.com/zkblk/spank-the-agent/releases/latest)
2. Unzip → drag **SpankTheAgent.app** to `/Applications`
3. Run this once in Terminal to clear the macOS quarantine flag:
   ```bash
   xattr -dr com.apple.quarantine /Applications/SpankTheAgent.app
   ```
   > This is normal for open-source apps not distributed via the App Store.
4. Open the app — a hand icon appears in the menu bar
5. Click → **Start** → enter password once (for accelerometer access)
6. Slap your MacBook

## Install (CLI — from source)

```bash
go install github.com/zkblk/spank-the-agent@latest
sudo cp "$(go env GOPATH)/bin/spank-the-agent" /usr/local/bin/spank-the-agent
```

Then grant Accessibility permission:
**System Preferences → Privacy & Security → Accessibility → add your terminal**

---

## Usage

```bash
# Default — whip crack on every slap
sudo spank-the-agent

# Warcraft mode — whip crack, then your peon reports for duty
sudo spank-the-agent --warcraft

# Agent mode — slap → whip → Enter auto-pressed → AI proceeds
sudo spank-the-agent --agent

# The full experience — whip, peon, AI confirmed
sudo spank-the-agent --agent --warcraft

# Fast mode — shorter cooldown, higher sensitivity
sudo spank-the-agent --agent --warcraft --fast

# Halo death sounds instead of whip (still works with --agent and --warcraft)
sudo spank-the-agent --agent --warcraft --halo

# Sexy mode (escalating) instead of whip
sudo spank-the-agent --agent --warcraft --sexy
```

### All flags

| Flag | Default | Description |
|------|---------|-------------|
| `--agent` | off | Auto-press Enter on each slap (confirms AI prompts) |
| `--warcraft` | off | Play WC3 peon response 300ms after the whip crack |
| `--fast` | off | Faster polling (4ms), shorter cooldown (350ms) |
| `--sexy` | off | Escalating audio instead of whip |
| `--halo` | off | Halo death sounds instead of whip |
| `--custom <dir>` | — | Your own MP3 directory instead of whip |
| `--min-amplitude` | 0.05 | Detection threshold (lower = more sensitive) |
| `--cooldown` | 750 | Cooldown between responses (ms) |
| `--volume-scaling` | off | Harder hits = louder sound |
| `--speed` | 1.0 | Playback speed multiplier |

---

## How it works

1. Reads raw accelerometer data from the Bosch BMI286 IMU via IOKit HID
2. Runs STA/LTA + CUSUM + kurtosis detection to identify genuine impacts
3. Plays an embedded MP3 response (or your custom sounds)
4. **With `--agent`**: fires `CGEventPost(kCGHIDEventTap, Enter)` via CoreGraphics — a synthetic keypress that lands in whatever window has focus

The keypress fires 80ms after the impact — just after the sound starts — so the crack lands before the confirmation, not after. The ordering matters.

---

## Running as a Service

```bash
sudo tee /Library/LaunchDaemons/com.zkblk.spank-the-agent.plist > /dev/null << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zkblk.spank-the-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/spank-the-agent</string>
        <string>--agent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/spank-the-agent.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/spank-the-agent.err</string>
</dict>
</plist>
EOF

sudo launchctl load /Library/LaunchDaemons/com.zkblk.spank-the-agent.plist
```

---

## FAQ

**Does this work with other AI tools (Cursor, Copilot, etc.)?**
Yes. It just presses Enter. It doesn't know or care what's on screen.

**Is this safe?**
It presses Enter in whatever window has focus. You are responsible for making sure that window is actually the AI asking for permission, and not your production database prompt.

**My AI is asking something really consequential. Should I slap my laptop?**
That's between you and your laptop.

**Why is there a 80ms delay before the Enter press?**
So the sound starts before the key fires. The whip should crack *before* the door swings open.

---

## Credits

Built on top of [spank](https://github.com/taigrr/spank) by Tai Groot.
Sensor detection ported from [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer).

## License

MIT — see [LICENSE](LICENSE)
