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

        // --test-osc52: drive a VTerminal in-process with the bug's reproducer
        // byte sequences and verify they land on the macOS pasteboard. Used to
        // confirm the OSC 52 fix end-to-end (the unit tests cover the
        // decoder/parser path but inject a fake clipboard sink). Backs up and
        // restores the pasteboard around the run.
        if CommandLine.arguments.contains("--test-osc52") {
            #if DEBUG
            exit(Osc52Reproducer.run() ? 0 : 1)
            #else
            print("--test-osc52 only available in debug builds")
            exit(1)
            #endif
        }

        // --run-tests: run unit tests and exit without launching GUI
        #if DEBUG
        if CommandLine.arguments.contains("--test-windows") {
            TerminalWindowTests.runAll()
            exit(0)
        }
        if CommandLine.arguments.contains("--test-terminal-io") {
            TerminalIOInteractionTests.runAll()
            exit(0)
        }
        if CommandLine.arguments.contains("--test-codex-resize") {
            exit(TerminalCodexResizeProbe.run() ? 0 : 1)
        }
        #endif
        if CommandLine.arguments.contains("--run-tests") {
            #if DEBUG
            KeyInputTests.runAll()
            ScrollAccumulatorTests.runAll()
            TerminalFontMetricsTests.runAll()
            PassthroughDecoderTests.runAll()
            VTerminalTests.runAll()
            PTYTests.runAll()
            SyncOutputTests.runAll()
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
            HyperlinksTests.runAll()
            TerminalLinkInteractionTests.runAll()
            TerminalIOInteractionTests.runAll()
            TerminalWindowTests.runAll()
            AlertEventTransportTests.runAll()
            ClickDispatchTests.runAll()
            CliDispatchTests.runAll()
            PermissionPromptTests.runAll()
            PromptQueueTests.runAll()
            OrderedDispatcherTests.runAll()
            SpaceNameTests.runAll()
            LinkTargetTests.runAll()
            PermissionWatcherTests.runAll()
            TmuxBackgroundTests.runAll()
            SessionSnapshotTests.runAll()
            ClaudeSessionTests.runAll()
            RestorePlanTests.runAll()
            AmuxPathsTests.runAll()
            HooksTests.runAll()
            AtomicFileTests.runAll()
            TmuxSocketTests.runAll()
            ClaudeScanTests.runAll()
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
    private(set) var terminalWindows: [TerminalWindow] = []
    private var focusedWindow: TerminalWindow? {
        terminalWindows.first { $0.window === NSApp.keyWindow }
            ?? terminalWindows.first { $0.window === NSApp.mainWindow }
            ?? terminalWindows.last
    }
    private let focusLock = NSLock()
    private var focusedController: AppController?
    private var tmuxPath = ""
    private var enhancedPath = ""
    private var windowServer: UnixSocketWindowRequestServer?
    private var clipboardServer: UnixSocketMessageServer<ClipboardRequest>?
    var clipboardPasteboard: NSPasteboard = .general
    private var titleTimer: Timer?
    private let presentsWindows: Bool

    init(tmuxPath: String = "", enhancedPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
         presentsWindows: Bool = true) {
        self.presentsWindows = presentsWindows
        self.tmuxPath = tmuxPath
        self.enhancedPath = enhancedPath
        super.init()
    }

    // Alert-notification plumbing. The poster owns the
    // UNUserNotificationCenter side (bug 1 fix: clicks route to this
    // process, not AppleScript). The server receives AlertEvents from
    // amux-cli (which fires them on bells / Claude-Code hooks) and
    // decides whether to post via `processAlertTrigger`.
    private let notificationPoster = UNNotificationPoster()
    private var alertServer: UnixSocketAlertEventServer?
    private let clickActivator = NSAppActivator()

    // Permission-peek: polls background panes for Claude permission prompts
    // and drives the status-bar indicator (amber ● + ⌘y) + Cmd-Y popup overlay.
    var permissionWatcher: PermissionWatcher?
    // Last peek count pushed to the status bar; avoids redundant option-sets
    // and status refreshes when the count is unchanged between polls.
    private var lastPeekCount = -1

    // tmux work that used to block the main thread — key-bound actions and
    // alert events — runs here, one at a time. Serial so actions never
    // interleave their tmux commands with each other.
    private let actionQueue = DispatchQueue(label: "amux.actions", qos: .userInteractive)

    // App Nap activity assertion. macOS throttles backgrounded apps —
    // including their main dispatch queue — which delays the
    // socket-handler hop from the AlertEventServer's accept thread back
    // to main, so notifications only deliver after the user re-foregrounds
    // amux. Spec (docs/attention-management.md, System Notifications):
    // "First bell: Immediate macOS notification". Holding a background
    // activity for the lifetime of the app keeps the main queue running
    // promptly even when amux is not frontmost.
    private var appNapAssertion: NSObjectProtocol?

    /// Command line for the embedded tmux client. `-T hyperlinks` declares
    /// OSC 8 support for this client: tmux tracks hyperlinks in its grid but
    /// only re-emits them to clients that advertise the feature, and the
    /// xterm-256color terminfo the PTY presents does not. Without it, tmux
    /// draws link labels and silently drops the URIs.
    static func tmuxAttachArgs(session: String) -> [String] {
        TmuxSocket.resolve().tmuxArgv(["-T", "hyperlinks", "attach-session", "-t", "=\(session)"])
    }

    @objc func renameTerminal() { focusedWindow?.submit(.rename) }
    @objc func renameSpace() { focusedWindow?.submit(.renameSpace) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Set app icon
        if let iconURL = Bundle.main.url(forResource: "amux", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // Find tmux binary
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path
            ?? ProcessInfo.processInfo.arguments[0]
                .split(separator: "/").dropLast().joined(separator: "/")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        tmuxPath = findBinary("tmux", searchDirs: [
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
        enhancedPath = "\(execDir):\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(currentPath)"
        setenv("PATH", enhancedPath, 1)

        // Resolve session name
        let session = ProcessInfo.processInfo.environment["AMUX_SESSION"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? "amux"

        Tmux.executor = LiveTmux(socket: TmuxSocket.resolve())

        // Create AppController and run startup (creates session, applies config, hooks)
        let controller = AppController(session: session)
        do {
            try controller.startup()
        } catch {
            fputs("amux: startup failed: \(error)\n", stderr)
        }

        startWindowRequestServer()
        startClipboardServer()
        openTerminalWindow(controller: controller)
        titleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshWindowTitles()
        }

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
        editMenu.addItem(withTitle: "Rename Pane / Session…", action: #selector(renameTerminal), keyEquivalent: "r")
        let renameSpaceItem = editMenu.addItem(withTitle: "Rename Space…", action: #selector(renameSpace), keyEquivalent: "r")
        renameSpaceItem.keyEquivalentModifierMask = [.command, .shift]
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        menuBar.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menuBar
        Names.background(["sync"])
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Names.background(["sync"]) }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Names.background(["sync", "--refresh"]) }

        // Intercept keys at the application level.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }

        NSApp.activate(ignoringOtherApps: true)

        // Wire alert notifications. Ordering matters: set the delegate
        // BEFORE requesting authorization so the OS knows who to call
        // back when the user grants permission, and BEFORE binding the
        // socket so the first event doesn't race delegate registration.
        UNUserNotificationCenter.current().delegate = self
        notificationPoster.requestAuthorization()

        // Hold a background activity assertion so macOS doesn't App-Nap
        // amux-app and stall the main queue while we're not frontmost.
        // Without this, AlertEvents accepted by the socket server land
        // on a backed-up main queue and only fire `processAlertTrigger`
        // (and its UN post) once the user re-activates the app — making
        // notifications appear "after switching back to amux" instead of
        // when the agent actually goes ready.
        appNapAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.background],
            reason: "amux alert notifications must deliver while backgrounded")

        startAlertEventServer()

        // Permission-peek watcher: polls background panes every 4s for Claude
        // permission prompts; never touches the focused pane the user sees.
        let watcher = PermissionWatcher(attachedSession: { [weak self] in
            guard let self = self else { return nil }
            self.focusLock.lock()
            let controller = self.focusedController
            self.focusLock.unlock()
            guard let controller, let session = controller.attachedSession() else { return nil }
            let active = (try? Tmux.activePaneIndex(session)) ?? -1
            return (session, active)
        })
        watcher.onChange = { [weak self] in
            // onChange already hops to main inside the watcher's poll; the
            // action methods call it on main too. Marshal defensively.
            DispatchQueue.main.async {
                guard let self = self else { return }
                let queue = self.permissionWatcher?.queue
                // Push the count to the status bar only when it changes.
                let count = queue?.count ?? 0
                if count != self.lastPeekCount {
                    self.lastPeekCount = count
                    // Async: N set-options + refresh are fire-and-forget; the
                    // sync version parks the main thread for the subprocess
                    // (plus any in-flight watcher poll holding LiveTmux's lock).
                    Tmux.publishPeekCountAsync(count)
                }
                // Keep the popup in sync if it's open.
                for owner in self.terminalWindows { owner.termView?.updatePeekState(queue) }
            }
        }
        self.permissionWatcher = watcher
        for owner in terminalWindows { owner.permissionWatcher = watcher }
        watcher.start()
    }

    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let owner = terminalWindows.first(where: { $0.window === event.window }) else { return event }
        return owner.handleKey(event)
    }

    @discardableResult
    func openTerminalWindow(controller: AppController, tmuxPath overridePath: String? = nil,
                            attachArgs: [String]? = nil, show: Bool = true) -> TerminalWindow {
        let owner = TerminalWindow(controller: controller, tmuxPath: overridePath ?? tmuxPath,
                                   enhancedPath: enhancedPath, actionQueue: actionQueue, attachArgs: attachArgs)
        owner.permissionWatcher = permissionWatcher
        owner.onClose = { [weak self, weak owner] in
            guard let self, let owner else { return }
            self.terminalWindows.removeAll { $0 === owner }
            self.focusLock.lock()
            self.focusedController = self.focusedWindow?.controller
            self.focusLock.unlock()
        }
        owner.onFocus = { [weak self, weak owner] in
            guard let self else { return }
            self.focusLock.lock()
            self.focusedController = owner?.controller
            self.focusLock.unlock()
        }
        if let previous = focusedWindow {
            owner.window.cascadeTopLeft(from: NSPoint(x: previous.window.frame.minX + 24,
                                                       y: previous.window.frame.maxY - 24))
        }
        terminalWindows.append(owner)
        if show && presentsWindows { owner.show() }
        return owner
    }

    func startWindowRequestServer() {
        let server = UnixSocketWindowRequestServer(socketPath: defaultWindowSocketPath())
        windowServer = server
        do {
            try server.start { [weak self] request in
                self?.actionQueue.async {
                    // Resolve to an exact session before creating a client. Never
                    // create sessions here or run app-wide startup a second time.
                    guard ((try? Tmux.listFocusSessions()) ?? []).contains(request.session) else { return }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.openTerminalWindow(controller: AppController(session: request.session))
                        if self.presentsWindows { NSApp.activate(ignoringOtherApps: true) }
                    }
                }
            }
        } catch {
            fputs("amux: failed to start window-request server: \(error)\n", stderr)
        }
    }

    func stopWindowRequestServer() { windowServer?.stop(); windowServer = nil }

    func startClipboardServer() {
        let server = UnixSocketMessageServer<ClipboardRequest>(socketPath: defaultClipboardSocketPath(),
                                                              maxMessageBytes: ClipboardRequest.maxMessageBytes)
        clipboardServer = server
        do {
            try server.start { [weak self] request in
                guard !request.text.isEmpty, request.text.utf8.count <= ClipboardRequest.maxTextBytes else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.clipboardPasteboard.clearContents()
                    if !self.clipboardPasteboard.setString(request.text, forType: .string) {
                        fputs("amux: macOS rejected clipboard write\n", stderr)
                    }
                }
            }
        } catch {
            fputs("amux: failed to start clipboard server: \(error)\n", stderr)
        }
    }

    func stopClipboardServer() { clipboardServer?.stop(); clipboardServer = nil }

    /// One background query covers all native windows, including spaces renamed
    /// or switched by a popup without passing through the native controller.
    func refreshWindowTitles() {
        actionQueue.async { [weak self] in
            let output = Tmux.runRaw(["list-clients", "-F", "#{client_tty}\t#{client_session}\t#{@amux-space-title}\t."])
            var titles: [String: String] = [:]
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                if parts.count == 4 { titles[String(parts[0])] = String(parts[2].isEmpty ? parts[1] : parts[2]) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for owner in self.terminalWindows {
                    if let tty = owner.controller.clientTTY, let title = titles[tty] {
                        owner.window.title = "amux — \(title)"
                    }
                }
            }
        }
    }

    private func startAlertEventServer() {
        let path = defaultAlertSocketPath()
        let server = UnixSocketAlertEventServer(socketPath: path)
        self.alertServer = server
        do {
            try server.start { [weak self, actionQueue] event in
                // Server handler runs on a background thread. Process on the
                // action queue: several tmux round-trips that must not stall
                // the main thread, serialized with key actions so their
                // alert-state reads and writes don't interleave.
                // UNUserNotificationCenter.add is thread-safe.
                actionQueue.async {
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
        titleTimer?.invalidate()
        stopWindowRequestServer()
        stopClipboardServer()
        alertServer?.stop()
        permissionWatcher?.stop()
        // Final snapshot, marked as a tidy shutdown. Anything else on disk
        // (cleanExit == false) tells the restore prompt the last run died.
        SnapshotCapture.captureNow(cleanExit: true)
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
        DispatchQueue.main.async { [weak self] in self?.focusNotification(action) }
    }

    /// Prefer the window already showing the notification's space; otherwise
    /// switch the focused window explicitly, never tmux's arbitrary last client.
    func focusNotification(_ action: ClickAction) {
        let target: String
        switch action {
        case .switchToSessionPane(let session, _), .switchToManaged(let session): target = session
        case .bringAppForeground:
            if presentsWindows { focusedWindow?.show(); clickActivator.activateApp() }
            return
        case .noop: return
        }
        let owners = terminalWindows
        let fallback = focusedWindow
        actionQueue.async { [weak self] in
            let owner = owners.first { $0.controller.attachedSession() == target } ?? fallback
            guard let owner, let tty = owner.controller.clientTTY else { return }
            try? Tmux.switchSession(target, clientTTY: tty)
            if case .switchToSessionPane(_, let pane) = action { try? Tmux.selectPane(target, paneIndex: pane) }
            DispatchQueue.main.async {
                guard let self, self.terminalWindows.contains(where: { $0 === owner }) else { return }
                if self.presentsWindows {
                    owner.show()
                    self.clickActivator.activateApp()
                }
            }
        }
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
