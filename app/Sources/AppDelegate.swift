import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!

    var agentMode:      Bool = UserDefaults.standard.object(forKey: "agentMode")      == nil ? true  : UserDefaults.standard.bool(forKey: "agentMode")
    var warcraftMode:   Bool = UserDefaults.standard.object(forKey: "warcraftMode")   == nil ? true  : UserDefaults.standard.bool(forKey: "warcraftMode")
    var sexyMode:       Bool = UserDefaults.standard.object(forKey: "sexyMode")       == nil ? false : UserDefaults.standard.bool(forKey: "sexyMode")
    var multiSlapCount: Int  = UserDefaults.standard.object(forKey: "multiSlapCount") == nil ? 2     : UserDefaults.standard.integer(forKey: "multiSlapCount")

    var helperPath: String {
        Bundle.main.path(forResource: "spank-the-agent-helper", ofType: nil)
            ?? "/usr/local/bin/spank-the-agent"
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()

        // Show setup if never completed OR if sudoers file is missing (e.g. after reinstall)
        let setupDone = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let sudoersExists = FileManager.default.fileExists(atPath: "/etc/sudoers.d/spank-the-agent")
        if !setupDone || !sudoersExists {
            UserDefaults.standard.set(false, forKey: "hasCompletedSetup")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.runFirstTimeSetup()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopProcess()
    }

    // MARK: - First-time setup

    func runFirstTimeSetup() {
        let alert = NSAlert()
        alert.messageText     = "Welcome to SpankTheAgent"
        alert.informativeText = """
SpankTheAgent needs two things to work:

1. Administrator access — to read your MacBook's accelerometer (IOKit). This is required once and won't be asked again.

2. Accessibility access — only if you use Agent mode (auto-confirm). This lets the app press Enter on your behalf to confirm AI prompts.

We'll set this up now.
"""
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set Up (once)")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        runSudoersSetup()
    }

    func runSudoersSetup() {
        let hp = helperPath

        // Step 1: write sudoers content to /tmp (no privileges needed)
        // Avoids all AppleScript quoting nightmares.
        let tmpFile = "/tmp/spank-sudoers"
        let content = "ALL ALL=(ALL) NOPASSWD: \(hp), /usr/bin/pkill\n"
        do {
            try content.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        } catch {
            showAlert("Setup failed", message: "Could not write temp file: \(error)\n\nApp will ask for your password each time.")
            if agentMode { checkAccessibility() }
            return
        }

        // Step 2: copy temp file into /etc/sudoers.d with admin privileges (ONE time)
        let script = "do shell script \"cp /tmp/spank-sudoers /etc/sudoers.d/spank-the-agent && chmod 440 /etc/sudoers.d/spank-the-agent && rm /tmp/spank-sudoers\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        if let err = error {
            showAlert("Setup failed", message: "Could not install sudoers rule:\n\(err)\n\nApp will ask for your password each time.")
        } else {
            UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
        }

        if agentMode { checkAccessibility() }
    }

    func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        if trusted { return }

        let alert = NSAlert()
        alert.messageText     = "Accessibility Access Needed"
        alert.informativeText = """
Agent mode presses Enter to confirm AI permission prompts — this is the whole point of SpankTheAgent.

To allow this:
System Settings → Privacy & Security → Accessibility → add SpankTheAgent

You only need to do this once.
"""
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Skip (Agent mode won't work)")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
    }

    // MARK: - Menu

    func rebuildMenu() {
        let running = isRunning()
        if let button = statusItem.button {
            let symbolName = running ? "hand.raised.fill" : "hand.raised.slash"
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                img.isTemplate = true
                button.image = img
                button.title = ""
            } else {
                button.title = running ? "✊" : "🤚"
            }
        }

        let menu = NSMenu()

        let statusLabel = NSMenuItem(title: running ? "● Running" : "○ Stopped", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: running ? "Stop" : "Start",
            action: #selector(toggleDaemon),
            keyEquivalent: "s"
        ))

        menu.addItem(.separator())

        let agentItem = NSMenuItem(title: "⌨️  Agent mode (auto-confirm)", action: #selector(toggleAgent), keyEquivalent: "")
        agentItem.state = agentMode ? .on : .off
        menu.addItem(agentItem)

        let warcraftItem = NSMenuItem(title: "⚔️  Warcraft (Yes, me lord)", action: #selector(toggleWarcraft), keyEquivalent: "")
        warcraftItem.state = warcraftMode ? .on : .off
        menu.addItem(warcraftItem)

        menu.addItem(.separator())

        // Sound mode: Whip vs Moan (mutually exclusive radio)
        let soundLabel = NSMenuItem(title: "Sound:", action: nil, keyEquivalent: "")
        soundLabel.isEnabled = false
        menu.addItem(soundLabel)

        let whipItem = NSMenuItem(title: "  🪶  Whip", action: #selector(selectWhip), keyEquivalent: "")
        whipItem.state = sexyMode ? .off : .on
        menu.addItem(whipItem)

        let moanItem = NSMenuItem(title: "  🔞  Moan", action: #selector(selectMoan), keyEquivalent: "")
        moanItem.state = sexyMode ? .on : .off
        menu.addItem(moanItem)

        menu.addItem(.separator())

        // Slap count submenu
        let slapCountItem = NSMenuItem(title: "Slaps to trigger: \(multiSlapCount)×", action: nil, keyEquivalent: "")
        let slapSubmenu = NSMenu()
        for n in [1, 2, 3] {
            let item = NSMenuItem(title: "\(n)×\(n == 1 ? " (any single slap)" : n == 2 ? " (double slap)" : " (triple slap)")", action: #selector(setSlapCount(_:)), keyEquivalent: "")
            item.tag = n
            item.state = multiSlapCount == n ? .on : .off
            slapSubmenu.addItem(item)
        }
        slapCountItem.submenu = slapSubmenu
        menu.addItem(slapCountItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show log", action: #selector(showLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Accessibility settings…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc func toggleDaemon() {
        if isRunning() {
            stopProcess()
        } else {
            // Check Accessibility when starting in agent mode
            if agentMode && !AXIsProcessTrusted() {
                checkAccessibility()
            }
            startProcess()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.rebuildMenu() }
    }

    @objc func toggleAgent() {
        agentMode.toggle()
        UserDefaults.standard.set(agentMode, forKey: "agentMode")
        // If turning on agent mode, check Accessibility
        if agentMode && !AXIsProcessTrusted() {
            checkAccessibility()
        }
        if isRunning() { stopProcess(); startProcess() }
        rebuildMenu()
    }

    @objc func toggleWarcraft() {
        warcraftMode.toggle()
        UserDefaults.standard.set(warcraftMode, forKey: "warcraftMode")
        if isRunning() { stopProcess(); startProcess() }
        rebuildMenu()
    }

    @objc func selectWhip() {
        guard sexyMode else { return }  // already whip, no restart needed
        sexyMode = false
        UserDefaults.standard.set(false, forKey: "sexyMode")
        if isRunning() { stopProcess(); startProcess() }
        rebuildMenu()
    }

    @objc func selectMoan() {
        guard !sexyMode else { return }  // already moan, no restart needed
        sexyMode = true
        UserDefaults.standard.set(true, forKey: "sexyMode")
        if isRunning() { stopProcess(); startProcess() }
        rebuildMenu()
    }

    @objc func setSlapCount(_ sender: NSMenuItem) {
        guard multiSlapCount != sender.tag else { return }  // already set, no restart
        multiSlapCount = sender.tag
        UserDefaults.standard.set(multiSlapCount, forKey: "multiSlapCount")
        if isRunning() { stopProcess(); startProcess() }
        rebuildMenu()
    }

    @objc func showLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/spank-the-agent.log"))
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    // MARK: - Process management

    func startProcess() {
        var cmd = "\(helperPath)"
        if agentMode    { cmd += " --agent" }
        if warcraftMode { cmd += " --warcraft" }
        if sexyMode     { cmd += " --sexy" }
        if multiSlapCount > 1 { cmd += " --multi-slap \(multiSlapCount)" }

        let fullCmd = "nohup sudo \(cmd) > /tmp/spank-the-agent.log 2>&1 &"

        // After setup: sudo is NOPASSWD for this binary — no password dialog.
        // Before setup (or if sudoers write failed): fall back to admin privileges.
        let hasSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let script: String
        if hasSetup {
            script = "do shell script \"\(fullCmd)\""
        } else {
            script = "do shell script \"\(fullCmd)\" with administrator privileges"
        }

        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        if let err = error {
            // If passwordless sudo failed, retry with admin privileges
            let fallback = "do shell script \"\(fullCmd)\" with administrator privileges"
            var err2: NSDictionary?
            NSAppleScript(source: fallback)?.executeAndReturnError(&err2)
            if let e2 = err2 {
                showAlert("Failed to start", message: "\(e2)")
            }
        }
    }

    func stopProcess() {
        let hasSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let killCmd = "sudo pkill -f 'spank-the-agent-helper' 2>/dev/null; true"
        let script: String
        if hasSetup {
            script = "do shell script \"\(killCmd)\""
        } else {
            script = "do shell script \"\(killCmd)\" with administrator privileges"
        }
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    func isRunning() -> Bool {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        task.launchPath = "/bin/sh"
        task.arguments  = ["-c", "pgrep -f 'spank-the-agent-helper' 2>/dev/null"]
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Alert

    func showAlert(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = message
        alert.alertStyle      = .warning
        alert.runModal()
    }
}
