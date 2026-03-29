import AppKit
import CVterm

@main
struct AmuxTermApp {
    static func main() {
        // --run-tests: run KeyInput tests and exit without launching GUI
        if CommandLine.arguments.contains("--run-tests") {
            #if DEBUG
            KeyInputTests.runAll()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Set app icon so it shows in Dock even when running as a bare binary
        // (outside the .app bundle, e.g. make app-dev).
        if let iconURL = Bundle.module.url(forResource: "amux", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // Find binaries — check next to our own executable first (works for
        // both .app bundle and bare binary), then fall back to common paths.
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path
            ?? ProcessInfo.processInfo.arguments[0]
                .split(separator: "/").dropLast().joined(separator: "/")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let amuxPath = findBinary("amux", searchDirs: [
            execDir,                         // next to amux-app (inside .app or dev build)
            "\(home)/.cargo/bin",             // dev install
            "\(home)/.local/bin",             // user install
            "/usr/local/bin",
        ])
        let tmuxPath = findBinary("tmux", searchDirs: [
            execDir,                         // bundled tmux (inside .app)
            "/opt/homebrew/bin",              // Homebrew ARM
            "/usr/local/bin",                 // Homebrew Intel
        ])

        // Install symlinks to ~/.local/bin so:
        // - tmux's run-shell can find amux (via PATH)
        // - amux can find tmux (via PATH)
        installCLISymlink(name: "amux", targetPath: amuxPath)
        installCLISymlink(name: "tmux", targetPath: tmuxPath)

        // Ensure PATH includes the bundle dir and ~/.local/bin so both the
        // amux Rust binary and tmux's run-shell commands can find each other.
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let enhancedPath = "\(execDir):\(home)/.local/bin:\(currentPath)"
        setenv("PATH", enhancedPath, 1)

        let rows: UInt16 = 40
        let cols: UInt16 = 120
        let terminal = VTerminal(rows: Int(rows), cols: Int(cols))

        // Run amux — it either attaches to existing workspace or creates a new one
        // with full setup (grid layout, borders, keybindings, hooks)
        guard let pty = PTY(executable: amuxPath,
                            args: ["amux"],
                            rows: rows, cols: cols) else {
            fatalError("Failed to create PTY")
        }

        let termView = TerminalView(terminal: terminal, pty: pty)
        self.termView = termView

        pty.onExit = {
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }

        // Restore saved window size, clamped to current screen bounds.
        let defaults = UserDefaults.standard
        var width = defaults.double(forKey: "amux-window-width")
        var height = defaults.double(forKey: "amux-window-height")
        if width < 400 || height < 300 {
            width = 960
            height = 640
        }
        if let screen = NSScreen.main?.visibleFrame {
            width = min(width, screen.width)
            height = min(height, screen.height)
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

        // Save window size on resize so it persists across launches.
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

        // Intercept Cmd-=/Cmd-- at the application level.
        // macOS may claim these keys for system zoom before performKeyEquivalent
        // reaches our view. This local monitor catches them first.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  event.modifierFlags.contains(.command),
                  let chars = event.charactersIgnoringModifiers else { return event }

            #if DEBUG
            // Cmd-Shift-D: toggle latency profiling
            if chars == "d" && event.modifierFlags.contains(.shift) {
                if let tv = self.termView {
                    tv.profilingEnabled.toggle()
                    fputs("=== Latency profiling \(tv.profilingEnabled ? "ON" : "OFF") ===\n", stderr)
                    fputs("Type to see: PTY roundtrip + draw time + total key→pixel\n", stderr)
                }
                return nil
            }
            #endif

            // Only intercept keys that KeyInput handles (not Cmd-Q, Cmd-C, Cmd-V)
            if ["=", "-", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                "n", "p", "s", "l"].contains(chars) {
                if let data = KeyInput.bytes(for: event) {
                    self.termView?.pty.write(data)
                    return nil  // consumed — don't pass to menu bar
                }
            }
            return event  // pass through
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Find a binary by name, checking directories in order.
    private func findBinary(_ name: String, searchDirs: [String]) -> String {
        for dir in searchDirs {
            let path = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        fatalError("\(name) not found. Searched: \(searchDirs.joined(separator: ", "))")
    }

    /// Symlink a binary to ~/.local/bin. Idempotent — updates if it already exists.
    private func installCLISymlink(name: String, targetPath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let binDir = "\(home)/.local/bin"
        let symlinkPath = "\(binDir)/\(name)"

        try? FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: symlinkPath)
        try? FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: targetPath)
    }
}
