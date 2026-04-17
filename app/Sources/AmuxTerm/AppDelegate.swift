import AppKit
import AmuxLib
import CVterm

@main
struct AmuxTermApp {
    static func main() {
        // --run-tests: run unit tests and exit without launching GUI
        if CommandLine.arguments.contains("--run-tests") {
            #if DEBUG
            KeyInputTests.runAll()
            VTerminalTests.runAll()
            LayoutTests.runAll()
            BellTests.runAll()
            LandingTests.runAll()
            AlertTests.runAll()
            LayoutEngineTests.runAll()
            StickyTests.runAll()
            FakeTmuxTests.runAll()
            AppControllerTests.runAll()
            SplitRestoreTests.runAll()
            PaneStyleTests.runAll()
            LinkDetectorTests.runAll()
            print("All tests passed")
            #else
            print("Tests only available in debug builds")
            #endif
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var termView: TerminalView?
    var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Set app icon
        if let iconURL = Bundle.module.url(forResource: "amux", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // Find tmux binary
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path
            ?? ProcessInfo.processInfo.arguments[0]
                .split(separator: "/").dropLast().joined(separator: "/")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tmuxPath = findBinary("tmux", searchDirs: [
            execDir,                         // bundled tmux (inside .app)
            "/opt/homebrew/bin",              // Homebrew ARM
            "/usr/local/bin",                 // Homebrew Intel
        ])

        // Find amux-cli binary for hooks (next to our executable, or fall back)
        let amuxCliPath = findBinaryOptional("amux-cli", searchDirs: [
            execDir,
            "\(home)/.local/bin",
        ])

        // Symlink tmux and amux-cli to ~/.local/bin so tmux hooks can find them
        installCLISymlink(name: "tmux", targetPath: tmuxPath)
        if let cliPath = amuxCliPath {
            installCLISymlink(name: "amux-cli", targetPath: cliPath)
        }

        // Ensure PATH includes bundle dir and ~/.local/bin
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let enhancedPath = "\(execDir):\(home)/.local/bin:\(currentPath)"
        setenv("PATH", enhancedPath, 1)

        // Resolve session name
        let session = ProcessInfo.processInfo.environment["AMUX_SESSION"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? "amux"

        // Create AppController and run startup (creates session, applies config, hooks)
        let controller = AppController(session: session)
        self.controller = controller
        do {
            try controller.startup()
        } catch {
            fputs("amux: startup failed: \(error)\n", stderr)
        }

        let rows: UInt16 = 40
        let cols: UInt16 = 120
        let terminal = VTerminal(rows: Int(rows), cols: Int(cols))

        // Attach to the tmux session via PTY (NOT launching amux binary)
        guard let pty = PTY(executable: tmuxPath,
                            args: ["tmux", "attach-session", "-t", session],
                            rows: rows, cols: cols,
                            env: ["PATH": enhancedPath]) else {
            fatalError("Failed to create PTY for tmux attach")
        }

        let termView = TerminalView(terminal: terminal, pty: pty)
        termView.session = session
        controller.clientTTY = pty.slavePath
        self.termView = termView

        // Wire up split-selected border overlay
        controller.onSplitSelectedChanged = { [weak termView] bounds in
            guard let tv = termView else { return }
            if let (top, left, width, height) = bounds {
                tv.splitSelectedPaneBounds = TerminalView.PaneBounds(
                    top: top, left: left, width: width, height: height)
            } else {
                tv.splitSelectedPaneBounds = nil
            }
            tv.needsDisplay = true
        }

        pty.onExit = {
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }

        // Window setup
        let defaults = UserDefaults.standard
        var width = defaults.double(forKey: "amux-window-width")
        var height = defaults.double(forKey: "amux-window-height")
        if width < 400 || height < 300 {
            width = 960
            height = 640
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "amux"
        window.contentView = termView
        window.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window, queue: .main
        ) { notification in
            guard let w = notification.object as? NSWindow else { return }
            defaults.set(w.frame.width, forKey: "amux-window-width")
            defaults.set(w.frame.height, forKey: "amux-window-height")
        }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(termView)
        self.window = window

        // Menu bar
        let menuBar = NSMenu()
        let appMenuItem = NSMenuItem()
        menuBar.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit amux",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        menuBar.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(TerminalView.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(TerminalView.paste(_:)),
                         keyEquivalent: "v")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = menuBar

        // Intercept keys at the application level.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let controller = self.controller else { return event }

            #if DEBUG
            if let chars = event.charactersIgnoringModifiers,
               chars == "d" && event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) {
                if let tv = self.termView {
                    tv.profilingEnabled.toggle()
                    fputs("=== Latency profiling \(tv.profilingEnabled ? "ON" : "OFF") ===\n", stderr)
                    fputs("Type to see: PTY roundtrip + draw time + total key→pixel\n", stderr)
                }
                return nil
            }
            #endif

            let action = KeyInput.action(for: event, mode: controller.mode)
            switch action {
            case .amux(let command):
                controller.handleAction(command)
                return nil
            case .sendToPTY(let data):
                self.termView?.pty.write(data)
                return nil
            case .ignore:
                return nil
            case .system:
                return event
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func findBinary(_ name: String, searchDirs: [String]) -> String {
        for dir in searchDirs {
            let path = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        fatalError("\(name) not found. Searched: \(searchDirs.joined(separator: ", "))")
    }

    private func findBinaryOptional(_ name: String, searchDirs: [String]) -> String? {
        for dir in searchDirs {
            let path = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func installCLISymlink(name: String, targetPath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let binDir = "\(home)/.local/bin"
        let symlinkPath = "\(binDir)/\(name)"
        try? FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: symlinkPath)
        try? FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: targetPath)
    }
}
