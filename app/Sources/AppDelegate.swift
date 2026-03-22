import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!

    var agentMode: Bool    = UserDefaults.standard.object(forKey: "agentMode")    == nil ? true : UserDefaults.standard.bool(forKey: "agentMode")
    var warcraftMode: Bool = UserDefaults.standard.object(forKey: "warcraftMode") == nil ? true : UserDefaults.standard.bool(forKey: "warcraftMode")

    var helperPath: String {
        Bundle.main.path(forResource: "spank-the-agent-helper", ofType: nil)
            ?? "/usr/local/bin/spank-the-agent"
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
    }

    // MARK: - Menu

    func rebuildMenu() {
        let running = isRunning()
        if let button = statusItem.button {
            let symbolName = running ? "bolt.fill" : "bolt.slash"
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                img.isTemplate = true // adapts to dark/light menu bar automatically
                button.image = img
                button.title = ""
            } else {
                button.title = running ? "⚡" : "💤"
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
        menu.addItem(NSMenuItem(title: "Show log", action: #selector(showLog), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc func toggleDaemon() {
        if isRunning() {
            stopProcess()
        } else {
            startProcess()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.rebuildMenu() }
    }

    @objc func toggleAgent() {
        agentMode.toggle()
        UserDefaults.standard.set(agentMode, forKey: "agentMode")
        if isRunning() { stopProcess(); startProcess() }
        rebuildMenu()
    }

    @objc func toggleWarcraft() {
        warcraftMode.toggle()
        UserDefaults.standard.set(warcraftMode, forKey: "warcraftMode")
        if isRunning() { stopProcess(); startProcess() }
        rebuildMenu()
    }

    @objc func showLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/spank-the-agent.log"))
    }

    // MARK: - Process management

    func startProcess() {
        var cmd = "\(helperPath)"
        if agentMode    { cmd += " --agent" }
        if warcraftMode { cmd += " --warcraft" }

        // nohup backgrounds it so `do shell script` returns immediately.
        // Redirect output to log so we can inspect it.
        let fullCmd = "nohup \(cmd) > /tmp/spank-the-agent.log 2>&1 &"
        let script = "do shell script \"\(fullCmd)\" with administrator privileges"

        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        if let err = error {
            showAlert("Failed to start", message: "\(err)")
        }
    }

    func stopProcess() {
        let script = "do shell script \"pkill -f 'spank-the-agent-helper' 2>/dev/null; true\" with administrator privileges"
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
