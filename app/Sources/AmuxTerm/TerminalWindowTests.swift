#if DEBUG
import AppKit
import AmuxLib
import Darwin

/// A wheel event delivered directly to an offscreen view, never posted to macOS.
final class TerminalTestScrollEvent: NSEvent {
    var point = NSPoint.zero
    var amount: CGFloat = 1
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { amount }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var momentumPhase: NSEvent.Phase { [] }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}

/// Exercise the real Spaces popup, IPC, native windows and tmux clients together.
/// A private server and state directory keep existing user sessions untouched.
enum TerminalWindowTests {
    static func runAll() {
        let foreground = ProcessInfo.processInfo.environment["AMUX_FOREGROUND_TESTS"] == "1"
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        if foreground { application.setActivationPolicy(.regular) }
        defer { if foreground { application.setActivationPolicy(previousPolicy) } }
        var passed = 0, failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1; print("FAIL: windows-\(name)") }
            fflush(stdout)
        }
        @discardableResult func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                if foreground {
                    while let event = application.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                        application.sendEvent(event)
                    }
                }
            }
            return condition()
        }
        let socket = "amux-windows-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(socket)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldEnv = ProcessInfo.processInfo.environment
        for (key, value) in ["AMUX_HOME": root.path, "AMUX_TMUX_SOCKET": socket] { setenv(key, value, 1) }
        let previousExecutor = Tmux.executor
        let tmux = LiveTmux(socket: socket)
        Tmux.executor = tmux
        let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }!
        let app = AppDelegate(tmuxPath: tmuxPath, presentsWindows: foreground)
        defer {
            app.stopWindowRequestServer()
            for owner in app.terminalWindows { owner.window.close() }
            _ = try? tmux.execute(["kill-server"])
            Tmux.executor = previousExecutor
            for key in ["AMUX_HOME", "AMUX_TMUX_SOCKET"] {
                if let value = oldEnv[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        for name in ["alpha", "beta", "gamma"] {
            _ = try! tmux.execute(["-f", "/dev/null", "new-session", "-d", "-s", name, "-x", "120", "-y", "40", "/bin/zsh -f"])
            Tmux.markAsManaged(name)
            try! Config.applyConfig(session: name)
            for hook in ["client-resized", "after-select-pane", "pane-exited"] {
                _ = try? tmux.execute(["set-hook", "-u", "-t", name, hook])
            }
        }
        _ = try! tmux.execute(["set-option", "-g", "default-command", "/bin/zsh -f"])
        let originalPIDs = Tmux.runRaw(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        app.startWindowRequestServer()
        let first = app.openTerminalWindow(controller: AppController(session: "alpha"))
        check("first-attached", wait { first.controller.attachedSession() == "alpha" })

        func screen(_ owner: TerminalWindow) -> String {
            guard let terminal = owner.termView?.terminal else { return "" }
            return (0..<terminal.rows).map { row in
                (0..<terminal.cols).map {
                    let text = VTerminal.cellString(terminal.cell(row: row, col: $0))
                    return text.isEmpty ? " " : text
                }.joined()
            }.joined(separator: "\n")
        }
        func key(_ owner: TerminalWindow, _ text: String, code: UInt16 = 0,
                 flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: 0, windowNumber: owner.window.windowNumber,
                                        context: nil, characters: text, charactersIgnoringModifiers: text,
                                        isARepeat: false, keyCode: code)!
            _ = app.handleKey(event)
        }
        func type(_ owner: TerminalWindow, _ text: String) {
            for character in text { key(owner, String(character)) }
        }
        func picker(_ owner: TerminalWindow) {
            key(owner, "p", flags: .command)
            let visible = wait { screen(owner).contains("w new window") }
            if !visible {
                print("Picker failed: session=\(owner.controller.session), tty=\(owner.controller.clientTTY ?? "nil"), clients=\(Tmux.runRaw(["list-clients", "-F", "#{client_tty}:#{client_session}:#{client_flags}"]))\n\(screen(owner))")
            }
            check("picker-shows-window-hint", visible)
        }
        picker(first)
        key(first, "\u{f701}", code: 125) // beta
        key(first, "w")
        check("w-creates-second-native-window", wait { app.terminalWindows.count == 2 })
        guard app.terminalWindows.count == 2 else { fatalError("Window request failed") }
        let second = app.terminalWindows[1]
        check("second-attaches-selected-space", wait { second.controller.attachedSession() == "beta" })
        check("opening-leaves-first-space-alone", first.controller.attachedSession() == "alpha")
        check("opening-preserves-shell-processes", originalPIDs == Tmux.runRaw(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]))

        // The monitor used to pass these through, only for TerminalView's
        // performKeyEquivalent fallback to swallow them before AppKit cycled.
        for (chars, flags) in [("`", NSEvent.ModifierFlags.command),
                               ("~", [.command, .shift]), ("m", .command)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                         timestamp: 0, windowNumber: first.window.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: chars == "m" ? 46 : 50)!
            check("monitor-defers-Cmd-\(chars)", app.handleKey(event) === event)
            check("terminal-view-defers-Cmd-\(chars)", !first.termView!.performKeyEquivalent(with: event))
        }

        type(first, "printf 'ALPHA_%s\\n' INPUT\r")
        type(second, "printf 'BETA_%s\\n' INPUT\r")
        check("first-keyboard-reaches-first-shell", wait { Tmux.capturePane("alpha", paneIndex: 0, lines: 0).contains("ALPHA_INPUT") })
        check("second-keyboard-reaches-second-shell", wait { Tmux.capturePane("beta", paneIndex: 0, lines: 0).contains("BETA_INPUT") })
        check("input-does-not-cross-windows", !Tmux.capturePane("alpha", paneIndex: 0, lines: 0).contains("BETA_INPUT"))

        // Use a private pasteboard and the same event routing as the running
        // app, rather than calling TerminalView.pasteStep directly.
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        app.clipboardPasteboard = clipboard
        app.startClipboardServer()
        defer { app.stopClipboardServer() }
        first.termView!.pasteboard = clipboard
        second.termView!.pasteboard = clipboard
        clipboard.setString("printf 'PASTED_%s\\n' ALPHA", forType: .string)
        key(first, "v", code: 9, flags: .command)
        key(first, "\r", code: 36)
        check("cmd-v-pastes-through-window-dispatch", wait {
            Tmux.capturePane("alpha", paneIndex: 0, lines: 0).contains("PASTED_ALPHA")
        })
        check("cmd-v-does-not-paste-in-other-window", !Tmux.capturePane("beta", paneIndex: 0, lines: 0).contains("PASTED_ALPHA"))
        key(first, "c", code: 8, flags: .command)
        type(first, "printf 'AFTER_%s\\n' COPY\r")
        check("cmd-c-without-selection-preserves-clipboard", wait {
            Tmux.capturePane("alpha", paneIndex: 0, lines: 0).contains("AFTER_COPY")
        } && clipboard.string(forType: .string) == "printf 'PASTED_%s\\n' ALPHA")

        type(first, "for i in {1..150}; do echo history-$i; done\r")
        check("scroll-fixture-has-history", wait { screen(first).contains("history-150") })
        let scroll = TerminalTestScrollEvent()
        scroll.point = first.termView!.convert(NSPoint(x: first.termView!.cellWidth * 3,
                                                       y: first.termView!.cellHeight * 3), to: nil)
        scroll.amount = 3
        first.termView!.scrollWheel(with: scroll)
        check("wheel-enters-history-in-originating-window", wait {
            Tmux.runRaw(["display-message", "-p", "-t", "alpha", "#{pane_in_mode}"]) == "1"
        })
        check("wheel-does-not-scroll-other-window", Tmux.runRaw(["display-message", "-p", "-t", "beta", "#{pane_in_mode}"]) == "0")
        check("wheel-arms-copy-mode-exit-behind-tmux", first.termView!.mayBeInCopyMode)
        type(first, "printf 'AFTER_%s\\n' SCROLL\r")
        check("typing-after-scroll-reaches-shell", wait {
            Tmux.capturePane("alpha", paneIndex: 0, lines: 0).contains("AFTER_SCROLL")
        })
        // Clean up even on regression so subsequent window checks remain useful.
        _ = try? tmux.execute(["send-keys", "-t", "alpha", "-X", "cancel"])

        first.termView!.scrollWheel(with: scroll)
        check("second-scroll-enters-history", wait {
            Tmux.runRaw(["display-message", "-p", "-t", "alpha", "#{pane_in_mode}"]) == "1"
        })
        _ = try! tmux.execute(["send-keys", "-t", "alpha", "-X", "search-backward", "history-100"])
        for command in ["start-of-line", "begin-selection", "end-of-line"] {
            _ = try! tmux.execute(["send-keys", "-t", "alpha", "-X", command])
        }
        clipboard.clearContents()
        key(first, "c", code: 8, flags: .command)
        check("cmd-c-copies-history-from-originating-window", wait {
            !(clipboard.string(forType: .string) ?? "").isEmpty
                && Tmux.runRaw(["display-message", "-p", "-t", "alpha", "#{pane_in_mode}"]) == "0"
        })
        first.termView!.scrollWheel(with: scroll)
        check("paste-fixture-enters-history", wait {
            Tmux.runRaw(["display-message", "-p", "-t", "alpha", "#{pane_in_mode}"]) == "1"
        })
        clipboard.clearContents()
        clipboard.setString("printf 'PASTE_AFTER_%s\\n' SCROLL", forType: .string)
        key(first, "v", code: 9, flags: .command)
        key(first, "\r", code: 36)
        check("cmd-v-exits-history-and-pastes-in-originating-window", wait {
            Tmux.capturePane("alpha", paneIndex: 0, lines: 0).contains("PASTE_AFTER_SCROLL")
        })
        check("history-paste-does-not-cross-windows", !Tmux.capturePane("beta", paneIndex: 0, lines: 0).contains("PASTE_AFTER_SCROLL"))
        var rapidPasteOK = true
        for attempt in 0..<6 {
            clipboard.clearContents()
            clipboard.setString("printf 'RAPID_PASTE_%s\\n' \(attempt)", forType: .string)
            first.termView!.scrollWheel(with: scroll)
            key(first, "v", code: 9, flags: .command)
            key(first, "\r", code: 36)
            rapidPasteOK = wait {
                Tmux.capturePane("alpha", paneIndex: 0, lines: 0).contains("RAPID_PASTE_\(attempt)")
            } && rapidPasteOK
        }
        check("immediate-scroll-then-paste-does-not-lose-input", rapidPasteOK)

        // Open a popup in beta, then make alpha the most recently active client.
        // Enter must still switch beta's client, not tmux's implicit last client.
        picker(second)
        type(first, "printf 'ACTIVE_%s\\n' ALPHA\r")
        check("other-client-input-consumed-before-switch", wait { screen(first).contains("ACTIVE_ALPHA") })
        key(second, "\u{f701}", code: 125) // gamma
        key(second, "\r", code: 36)
        check("enter-switches-originating-window", wait { second.controller.attachedSession() == "gamma" })
        check("enter-leaves-other-window-alone", first.controller.attachedSession() == "alpha")

        picker(first)
        key(first, "\u{1b}", code: 53)
        check("escape-cancels-picker", wait { !screen(first).contains("w new window") })
        check("cancel-keeps-both-clients", first.controller.attachedSession() == "alpha" && second.controller.attachedSession() == "gamma")

        // Commands and the immediately following keys retain their window even
        // while an off-main action is running and focus changes.
        let oldGammaPane = Tmux.runRaw(["display-message", "-p", "-t", "gamma", "#{pane_id}"])
        key(second, "n", flags: .command)
        type(second, "printf 'NEW_%s\\n' PANE\r")
        type(first, "printf 'STILL_%s\\n' ALPHA\r")
        check("cmd-n-creates-pane-in-own-window", wait { (try? Tmux.paneCount("gamma")) == 2 })
        check("queued-input-follows-cmd-n", wait {
            let active = Tmux.runRaw(["display-message", "-p", "-t", "gamma", "#{pane_id}"])
            return active != oldGammaPane && Tmux.runRaw(["capture-pane", "-p", "-t", active]).contains("NEW_PANE")
        })
        check("other-window-input-keeps-destination", wait { Tmux.capturePane("alpha", paneIndex: 0, lines: 0).contains("STILL_ALPHA") })
        check("cmd-n-does-not-add-pane-elsewhere", (try? Tmux.paneCount("alpha")) == 1)

        _ = try! tmux.execute(["set-option", "-t", "gamma", "@amux-space-title", "Third space"])
        app.refreshWindowTitles()
        check("title-follows-switch-and-manual-name", wait { second.window.title == "amux — Third space" })
        app.focusNotification(.switchToSessionPane(session: "alpha", pane: 0))
        if foreground {
            check("notification-raises-matching-window", wait { first.window.isKeyWindow })
        } else {
            print("SKIP: foreground window focus check (background-only work; see CLAUDE.md)")
            // Wait for the queued routing operation without presenting a window.
            first.window.title = "Awaiting refresh"
            app.refreshWindowTitles()
            check("notification-routing-completes-offscreen", wait { first.window.title == "amux — alpha" })
        }
        check("notification-preserves-other-space", second.controller.attachedSession() == "gamma")

        // Closing either window detaches only its client, keeping every shell.
        let secondTTY = second.controller.clientTTY!
        key(second, "w", flags: .command)
        check("close-removes-only-one-window", app.terminalWindows.count == 1)
        check("close-detaches-only-own-client", wait { !Tmux.runRaw(["list-clients", "-F", "#{client_tty}"]).contains(secondTTY) })
        check("closed-client-has-no-arbitrary-fallback", second.controller.attachedSession() == nil)
        check("closed-space-shells-stay-alive", (try? Tmux.paneCount("gamma")) == 2)
        type(first, "printf 'AFTER_%s\\n' CLOSE\r")
        check("remaining-window-still-accepts-input", wait { Tmux.capturePane("alpha", paneIndex: 0, lines: 0).contains("AFTER_CLOSE") })

        // Exit of the tmux client must close its window, not terminate the app.
        let third = app.openTerminalWindow(controller: AppController(session: "beta"))
        check("third-attached", wait { third.controller.attachedSession() == "beta" })
        _ = try! tmux.execute(["detach-client", "-t", third.controller.clientTTY!])
        check("pty-exit-closes-only-own-window", wait { app.terminalWindows.count == 1 })
        check("surviving-client-stays-attached", first.controller.attachedSession() == "alpha")

        app.stopWindowRequestServer()
        picker(first)
        key(first, "w")
        check("missing-gui-endpoint-shows-error", wait { screen(first).contains("Could not open window") })
        key(first, "x")
        check("failed-request-returns-to-picker", wait { screen(first).contains("w new window") })
        key(first, "\u{1b}", code: 53)
        check("failed-request-keeps-existing-window", app.terminalWindows.count == 1 && first.controller.attachedSession() == "alpha")

        print("Terminal window tests: \(passed) passed, \(failed) failed")
        fflush(stdout)
        if failed > 0 { fatalError("Terminal window tests failed") }
    }
}
#endif
