import AppKit
import AmuxLib
import CVterm
import Darwin
import UserNotifications

@main
struct AmuxTermApp {
    static func main() {
        // Shim: if argv looks like a CLI invocation (`amux alert-pane 0`,
        // `amux bell-watch ...`), exec `amux-cli` with the same args.
        // Historical hooks installed against the pre-Swift-port `amux`
        // binary still call `amux <subcommand>`; without this dispatch,
        // those invocations open the GUI (or fall through to a stale
        // Rust binary that uses osascript, routing notifications to
        // Script Editor). Must happen BEFORE NSApplication init.
        if shouldDispatchToCli(CommandLine.arguments) {
            dispatchToCli(CommandLine.arguments)
            // dispatchToCli exits unconditionally.
        }

        // --run-tests: run unit tests and exit without launching GUI
        if CommandLine.arguments.contains("--run-tests") {
            #if DEBUG
            KeyInputTests.runAll()
            VTerminalTests.runAll()
            ScrollerStateTests.runAll()
            LayoutTests.runAll()
            BellTests.runAll()
            LandingTests.runAll()
            AlertTests.runAll()
            AlertNotificationTests.runAll()
            LayoutEngineTests.runAll()
            StickyTests.runAll()
            FakeTmuxTests.runAll()
            AppControllerTests.runAll()
            SplitRestoreTests.runAll()
            PaneStyleTests.runAll()
            LinkDetectorTests.runAll()
            AlertEventTransportTests.runAll()
            ClickDispatchTests.runAll()
            CliDispatchTests.runAll()
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

    /// Replace this process with `amux-cli <args...>`. Looks for the CLI
    /// binary adjacent to the current executable (bundle's MacOS/) and
    /// then in `~/.local/bin`. Exits non-zero on failure.
    private static func dispatchToCli(_ args: [String]) -> Never {
        let execPath = Bundle.main.executableURL?.deletingLastPathComponent().path
            ?? (args[0] as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(execPath)/amux-cli", "\(home)/.local/bin/amux-cli"]

        for candidate in candidates {
            // Must be an actual file (not a broken symlink) and executable.
            // `isExecutableFile` follows symlinks and returns false on
            // dangling links — which is the self-referencing-symlink
            // failure mode we want to skip past.
            guard FileManager.default.isExecutableFile(atPath: candidate) else {
                continue
            }
            // argv layout for execv: argv[0] = invoked name, argv[1..] = args.
            var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(candidate)]
            for a in args.dropFirst() { cArgs.append(strdup(a)) }
            cArgs.append(nil)
            execv(candidate, &cArgs)
            // execv only returns on failure.
            fputs("amux: exec \(candidate) failed: \(String(cString: strerror(errno)))\n", stderr)
            exit(1)
        }

        fputs("amux: amux-cli not found. Searched: \(candidates.joined(separator: ", "))\n", stderr)
        exit(1)
    }
}

/// Activator that raises the amux app via NSApp.activate. Used by
/// the notification click dispatcher to ensure the click brings amux
/// to the foreground even when Claude Code (or any other app) is
/// frontmost at click time.
private final class NSAppActivator: AppActivator {
    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow?
    var termView: TerminalView?
    var controller: AppController?

    // Alert-notification plumbing. The poster owns the
    // UNUserNotificationCenter side (bug 1 fix: clicks route to this
    // process, not AppleScript). The server receives AlertEvents from
    // amux-cli (which fires them on bells / Claude-Code hooks) and
    // decides whether to post via `processAlertTrigger`.
    private let notificationPoster = UNNotificationPoster()
    private var alertServer: UnixSocketAlertEventServer?
    private let clickActivator = NSAppActivator()

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

        // Also install `amux` → this executable. Pre-Swift-port hooks
        // (and user-authored debug hooks copied from older READMEs) call
        // `amux alert-pane ...`; if `~/.local/bin/amux` still points at a
        // stale Rust binary, those calls bypass the UN / socket path and
        // post via osascript — which makes macOS route notification
        // clicks to Script Editor, not amux. Pointing `amux` at this
        // process means the argv shim in `AmuxTermApp.main` forwards to
        // `amux-cli`, closing the regression self-heal-on-next-launch.
        if let selfPath = Bundle.main.executableURL?.path {
            installCLISymlink(name: "amux", targetPath: selfPath)
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

        // Wire alert notifications. Ordering matters: set the delegate
        // BEFORE requesting authorization so the OS knows who to call
        // back when the user grants permission, and BEFORE binding the
        // socket so the first event doesn't race delegate registration.
        UNUserNotificationCenter.current().delegate = self
        notificationPoster.requestAuthorization()

        startAlertEventServer()
    }

    private func startAlertEventServer() {
        let path = defaultAlertSocketPath()
        let server = UnixSocketAlertEventServer(socketPath: path)
        self.alertServer = server
        do {
            try server.start { [weak self] event in
                // Server handler runs on a background thread. Hop to
                // main before touching Tmux.executor / UN APIs, both
                // of which are main-thread-affine.
                DispatchQueue.main.async {
                    guard let poster = self?.notificationPoster else { return }
                    let now = UInt64(Date().timeIntervalSince1970)
                    try? processAlertTrigger(event, nowSeconds: now, poster: poster)
                }
            }
            // Success log so integration tests (and users debugging)
            // can wait for a concrete "server is ready" signal instead
            // of sleeping and hoping.
            fputs("amux: alert-event server listening at \(path)\n", stderr)
        } catch {
            fputs("amux: failed to start alert-event server: \(error)\n", stderr)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        alertServer?.stop()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the notification banner even when amux itself is in the
    /// foreground (the user can be in a different space / focused on
    /// a non-amux window within amux's app). Without this, macOS
    /// silently suppresses the banner while amux is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Click handler: route the click back to the originating session
    /// and pane via the pure click router, then dispatch.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        // userInfo is [AnyHashable: Any]; our payload uses [String: String].
        var userInfo: [String: String] = [:]
        for (k, v) in response.notification.request.content.userInfo {
            if let ks = k as? String, let vs = v as? String {
                userInfo[ks] = vs
            }
        }

        let managed = (try? Tmux.listSpacesWithAlerts().sessions) ?? []
        let action = routeNotificationClick(userInfo: userInfo, managedSessions: managed)
        try? performClickAction(action, activator: clickActivator)
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
