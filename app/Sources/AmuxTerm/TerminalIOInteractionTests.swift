#if DEBUG
import AppKit
import AmuxLib
import Darwin

/// Exercise native mouse/paste and resize against a real mouse-aware TUI.
/// All terminal processes and state live on a disposable tmux socket.
enum TerminalIOInteractionTests {
    static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }
        func wait(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !predicate() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        let socket = "amux-io-test-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(socket)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldHome = ProcessInfo.processInfo.environment["AMUX_HOME"]
        setenv("AMUX_HOME", root.path, 1)
        defer {
            if let oldHome { setenv("AMUX_HOME", oldHome, 1) } else { unsetenv("AMUX_HOME") }
        }
        let received = root.appendingPathComponent("input")
        let fixture = root.appendingPathComponent("tui.py")
        try! """
        import base64, os, signal, sys, tty
        tty.setraw(0)
        def draw(*_):
            size = os.get_terminal_size()
            os.write(1, ('\\x1b[?1049h\\x1b[?1002h\\x1b[?1006h\\x1b[?2004h'
                         '\\x1b[H\\x1b[2Jcopy this text\\r\\nSIZE:%dx%d' % (size.columns, size.lines)).encode())
        signal.signal(signal.SIGWINCH, draw)
        draw()
        probe = b''
        with open(sys.argv[1], 'ab', buffering=0) as out:
            while True:
                data = os.read(0, 65536)
                if not data: break
                out.write(data)
                probe = (probe + data)[-100:]
                if probe.endswith(b'clipboard-probe'):
                    os.write(1, b'\\x1b]52;c;' + base64.b64encode(b'remote copy') + b'\\x07')
                    probe = b''
                if probe.endswith(b'main-screen-probe'):
                    os.write(1, b'\\x1b[?1049l\\x1b[H\\x1b[2Jcopy this text')
                    probe = b''
                if probe.endswith(b'no-mouse-probe'):
                    os.write(1, b'\\x1b[?1002l\\x1b[?1006l\\x1b[?1049h\\x1b[H\\x1b[2Jcopy this text')
                    probe = b''
        """.write(to: fixture, atomically: true, encoding: .utf8)
        let oldExecutor = Tmux.executor
        let tmux = LiveTmux(socket: socket)
        Tmux.executor = tmux
        defer {
            _ = try? tmux.execute(["kill-server"])
            Tmux.executor = oldExecutor
            try? FileManager.default.removeItem(at: root)
        }
        let command = "/usr/bin/python3 \(SessionRestore.singleQuoted(fixture.path)) \(SessionRestore.singleQuoted(received.path))"
        _ = try! tmux.execute(["-f", "/dev/null", "new-session", "-d", "-s", "io", "-x", "80", "-y", "24", command])
        // Production configures terminal capabilities before attaching. Doing
        // it after attach races tmux's capability negotiation/OSC 52 support.
        try! Config.applyConfig(session: "io")
        check("native-copy-command", Tmux.runRaw(["show-options", "-s", "-v", "copy-command"]) == clipboardCommand(binary: Config.findAmuxCLI()))
        for hook in ["client-resized", "after-select-pane", "pane-exited"] {
            _ = try? tmux.execute(["set-hook", "-u", "-t", "io", hook])
        }
        _ = try? tmux.execute(["set-option", "-g", "pane-border-status", "off"])
        guard let pty = PTY(executable: "/usr/bin/env", args: ["env", "-u", "TMUX", "tmux", "-L", socket,
                            "attach-session", "-t", "io"], rows: 24, cols: 80)
        else { fatalError("Could not create I/O test PTY") }
        let terminal = VTerminal(rows: 24, cols: 80)
        let view = TerminalView(terminal: terminal, pty: pty)
        let pb = NSPasteboard.withUniqueName()
        view.pasteboard = pb
        defer { pb.releaseGlobally() }
        let app = AppDelegate(presentsWindows: false)
        app.clipboardPasteboard = pb
        app.startClipboardServer()
        defer { app.stopClipboardServer() }
        func setClipboard(_ text: String) {
            pb.clearContents(); pb.setString(text, forType: .string)
        }
        view.currentSession = { "io" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: view.cellWidth * 80, height: view.cellHeight * 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        func text() -> String {
            (0..<terminal.rows).map { row in
                (0..<terminal.cols).map {
                    let cell = VTerminal.cellString(terminal.cell(row: row, col: $0))
                    return cell.isEmpty ? " " : cell
                }.joined()
            }.joined(separator: "\n")
        }
        wait { text().contains("copy this text") }
        wait { text().contains("SIZE:80x23") }
        func kernelSize() -> (Int, Int) {
            var size = winsize()
            _ = ioctl(pty.masterFd, TIOCGWINSZ, &size)
            return (Int(size.ws_col), Int(size.ws_row))
        }
        view.setFrameSize(NSSize(width: view.cellWidth * 140, height: view.cellHeight * 40))
        check("resize-grid-and-pty-stay-in-step", kernelSize() == (terminal.cols, terminal.rows))
        // AppKit uses a tracking run loop during window resizing.
        let end = Date().addingTimeInterval(0.2)
        while Date() < end {
            _ = RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
        }
        check("resize-reaches-pty-during-tracking", kernelSize() == (140, 40))
        wait { text().contains("SIZE:140x39") }
        check("resize-tui-redraw-without-scroll", text().contains("SIZE:140x39"))

        func event(_ type: NSEvent.EventType, col: Int) -> NSEvent {
            let point = view.convert(NSPoint(x: (CGFloat(col) + 0.5) * view.cellWidth, y: 0.5 * view.cellHeight), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        }
        var copied = ""
        terminal.onSetClipboard = { copied = $0; setClipboard($0) }
        view.mouseDown(with: event(.leftMouseDown, col: 0))
        view.mouseDragged(with: event(.leftMouseDragged, col: 4))
        view.mouseDragged(with: event(.leftMouseDragged, col: 14))
        view.mouseUp(with: event(.leftMouseUp, col: 14))
        wait { pb.string(forType: .string) == "copy this text" }
        check("drag-selection-reaches-native-clipboard", pb.string(forType: .string) == "copy this text")
        // tmux's defaults forward double/triple clicks to mouse-aware TUIs.
        // Native terminal users still expect those gestures to copy a word/line.
        func click() {
            view.mouseDown(with: event(.leftMouseDown, col: 1))
            view.mouseUp(with: event(.leftMouseUp, col: 1))
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        pb.clearContents()
        click(); click()
        wait { pb.string(forType: .string) == "copy" }
        check("double-click-copies-word-from-tui", pb.string(forType: .string) == "copy")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        pb.clearContents()
        click(); click(); click()
        wait { pb.string(forType: .string)?.hasPrefix("copy this text") == true }
        check("triple-click-copies-line-from-tui", pb.string(forType: .string)?.hasPrefix("copy this text") == true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        pb.clearContents()
        view.mouseDown(with: event(.leftMouseDown, col: 0))
        view.mouseDragged(with: event(.leftMouseDragged, col: 4))
        view.mouseDragged(with: event(.leftMouseDragged, col: 14))
        wait { Tmux.runRaw(["display-message", "-p", "-t", "io", "#{selection_present}"]) == "1" }
        view.copy(nil)
        wait { pb.string(forType: .string) == "copy this text" }
        check("cmd-c-finishes-active-selection-to-native-clipboard", pb.string(forType: .string) == "copy this text")
        view.mouseUp(with: event(.leftMouseUp, col: 14))
        pty.write(Data("clipboard-probe".utf8))
        wait { copied == "remote copy" }
        check("application-clipboard-crosses-outer-tmux", copied == "remote copy")

        setClipboard("fresh remote clipboard")
        var copyFinished = false
        if case .offMain(let work) = view.copyStep() {
            DispatchQueue.global().async { work(); DispatchQueue.main.async { copyFinished = true } }
        }
        wait { copyFinished }
        check("cmd-c-does-not-replace-remote-copy-with-stale-buffer", pb.string(forType: .string) == "fresh remote clipboard")
        let payload = "pasted 日本語\n  indentation\n"
        setClipboard(payload)
        _ = try? tmux.execute(["copy-mode", "-t", "io"])
        view.paste(nil)
        let expected = Data(("\u{1b}[200~" + payload + "\u{1b}[201~").utf8)
        wait { (try? Data(contentsOf: received).range(of: expected)) != nil }
        check("paste-exits-copy-mode-and-arrives-intact", (try? Data(contentsOf: received).range(of: expected)) != nil)
        let large = String(repeating: "  日本語 text with indentation\n", count: 8000)
        setClipboard(large)
        view.paste(nil)
        let largeExpected = Data(("\u{1b}[200~" + large + "\u{1b}[201~").utf8)
        wait { (try? Data(contentsOf: received).range(of: largeExpected)) != nil }
        check("large-unicode-multiline-paste-arrives-intact", (try? Data(contentsOf: received).range(of: largeExpected)) != nil)

        // The real CLI/server/native path must preserve whitespace and accept
        // copies larger than the alert transport's ordinary 64 KiB ceiling.
        let largeCopy = String(repeating: "  日本語\ttext with indentation\n", count: 4000) + "  "
        let copyInput = root.appendingPathComponent("copy-input")
        try! Data(largeCopy.utf8).write(to: copyInput)
        let copyProcess = Process()
        copyProcess.executableURL = URL(fileURLWithPath: Config.findAmuxCLI())
        copyProcess.arguments = ["copy-to-clipboard", defaultClipboardSocketPath()]
        let input = try! FileHandle(forReadingFrom: copyInput)
        defer { try? input.close() }
        copyProcess.standardInput = input
        try! copyProcess.run()
        wait { !copyProcess.isRunning && pb.string(forType: .string) == largeCopy }
        check("large-copy-reaches-native-clipboard-intact", !copyProcess.isRunning && copyProcess.terminationStatus == 0 && pb.string(forType: .string) == largeCopy)

        let scroll = TerminalTestScrollEvent()
        scroll.point = view.convert(NSPoint(x: 2.5 * view.cellWidth, y: 2.5 * view.cellHeight), to: nil)
        func wheelCount() -> Int {
            let data = (try? Data(contentsOf: received)) ?? Data()
            return String(decoding: data, as: UTF8.self).components(separatedBy: "\u{1b}[<64;").count - 1
        }
        var beforeWheel = wheelCount()
        view.scrollWheel(with: scroll)
        wait { wheelCount() > beforeWheel }
        check("wheel-reaches-mouse-aware-alternate-screen", wheelCount() > beforeWheel)
        pty.write(Data("main-screen-probe".utf8))
        wait { Tmux.runRaw(["display-message", "-p", "-t", "io", "#{alternate_on}"]) == "0" }
        beforeWheel = wheelCount()
        view.scrollWheel(with: scroll)
        wait { wheelCount() > beforeWheel }
        check("wheel-reaches-mouse-aware-main-screen", wheelCount() > beforeWheel)
        _ = try? tmux.execute(["send-keys", "-t", "io", "-X", "cancel"])
        pty.write(Data("no-mouse-probe".utf8))
        wait { Tmux.runRaw(["display-message", "-p", "-t", "io", "#{alternate_on}:#{mouse_any_flag}"]) == "1:0" }
        view.scrollWheel(with: scroll)
        wait { Tmux.runRaw(["display-message", "-p", "-t", "io", "#{pane_in_mode}"]) == "1" }
        check("wheel-opens-history-when-app-does-not-handle-mouse", Tmux.runRaw(["display-message", "-p", "-t", "io", "#{pane_in_mode}"]) == "1")
        _ = try? tmux.execute(["kill-server"])
        var status: Int32 = 0
        waitpid(pty.childPid, &status, 0)
        print("Terminal I/O interaction tests: \(passed) passed, \(failed) failed")
        fflush(stdout)
        if failed > 0 { fatalError("Terminal I/O interaction tests failed") }
    }
}
#endif
