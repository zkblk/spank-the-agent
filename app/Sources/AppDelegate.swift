import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!

    var agentMode: Bool   = UserDefaults.standard.object(forKey: "agentMode")   == nil ? true  : UserDefaults.standard.bool(forKey: "agentMode")
    var warcraftMode: Bool = UserDefaults.standard.object(forKey: "warcraftMode") == nil ? true  : UserDefaults.standard.bool(forKey: "warcraftMode")

    let daemonLabel    = "com.zkblk.spank-the-agent"
    let daemonPlist    = "/Library/LaunchDaemons/com.zkblk.spank-the-agent.plist"

    // The Go helper binary lives next to the Swift binary inside the .app bundle.
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
        statusItem.button?.title = running ? "🎯 on" : "💤 off"

        let menu = NSMenu()

        let statusLabel = NSMenuItem(title: running ? "● Running" : "○ Stopped", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: running ? "Stop" : "Start",
            action: #selector(toggleDaemon),
            keyEquivalent: "s"
        )
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let agentItem = NSMenuItem(title: "⌨️  Agent mode (auto-confirm)", action: #selector(toggleAgent), keyEquivalent: "")
        agentItem.state = agentMode ? .on : .off
        menu.addItem(agentItem)

        let warcraftItem = NSMenuItem(title: "⚔️  Warcraft mode (Yes, me lord)", action: #selector(toggleWarcraft), keyEquivalent: "")
        warcraftItem.state = warcraftMode ? .on : .off
        menu.addItem(warcraftItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc func toggleDaemon() {
        if isRunning() {
            stopDaemon()
        } else {
            startDaemon()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.rebuildMenu() }
    }

    @objc func toggleAgent() {
        agentMode.toggle()
        UserDefaults.standard.set(agentMode, forKey: "agentMode")
        if isRunning() { stopDaemon(); startDaemon() }
        rebuildMenu()
    }

    @objc func toggleWarcraft() {
        warcraftMode.toggle()
        UserDefaults.standard.set(warcraftMode, forKey: "warcraftMode")
        if isRunning() { stopDaemon(); startDaemon() }
        rebuildMenu()
    }

    // MARK: - Daemon management

    func startDaemon() {
        var args = [helperPath]
        if agentMode   { args.append("--agent") }
        if warcraftMode { args.append("--warcraft") }

        let argXml = args.map { "<string>\($0)</string>" }.joined(separator: "\n                ")

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                \(argXml)
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
        """

        let tmpPlist = "/tmp/spank-the-agent-daemon.plist"
        try? plist.write(toFile: tmpPlist, atomically: true, encoding: .utf8)

        let script = """
        do shell script "cp '\(tmpPlist)' '\(daemonPlist)' && launchctl load '\(daemonPlist)'" with administrator privileges
        """
        runAppleScript(script)
    }

    func stopDaemon() {
        let script = """
        do shell script "launchctl unload '\(daemonPlist)' 2>/dev/null; rm -f '\(daemonPlist)'" with administrator privileges
        """
        runAppleScript(script)
    }

    func isRunning() -> Bool {
        let out = shell("launchctl list 2>/dev/null | grep '\(daemonLabel)'")
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Helpers

    @discardableResult
    func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let err = error { print("AppleScript error: \(err)") }
        return error == nil
    }

    func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        task.launchPath = "/bin/sh"
        task.arguments  = ["-c", command]
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
