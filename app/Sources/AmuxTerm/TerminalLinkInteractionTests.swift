#if DEBUG
import AppKit
import AmuxLib

/// Real tmux output -> libvterm -> native Cmd-click -> URL opener.
/// Uses an isolated socket and an unopened window; never opens a browser.
enum TerminalLinkInteractionTests {
    static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }
        func wait(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !predicate() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        let socket = "amux-link-test-\(UUID().uuidString)"
        let tmux = LiveTmux(socket: socket)
        defer { _ = try? tmux.execute(["kill-server"]) }
        let url = "https://example.com/docs_(v2)?a=1&b=2"
        let reviewURL = "https://example.com/review/1211"
        let edgeLine = String(repeating: " ", count: 80 - reviewURL.count - 1) + reviewURL + ")"
        // tmux redraws this label with cursor-addressing sequences, then
        // positions the cursor elsewhere. Both must preserve the OSC 8 link.
        let output = "\u{1B}]8;;\(url)\u{1B}\\Read docs\u{1B}]8;;\u{1B}\\\r\n漢 e\u{301} https://example.com/plain\r\n\(edgeLine)\r\n  and matches the reviewed commit.\r\n"
        let script = "printf %s \(SessionRestore.singleQuoted(output)); exec /bin/cat"
        guard let pty = PTY(executable: "/usr/bin/env",
                            args: ["env", "-u", "TMUX", "tmux", "-L", socket, "-f", "/dev/null",
                                   "-T", "hyperlinks", "new-session", "-s", "links", script], rows: 12, cols: 80)
        else { fatalError("Could not create link test PTY") }
        let terminal = VTerminal(rows: 12, cols: 80)
        let view = TerminalView(terminal: terminal, pty: pty)
        var outputGeneration = 0
        let receive = pty.onOutput
        pty.onOutput = { outputGeneration += 1; receive?($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: view.cellWidth * 80, height: view.cellHeight * 12),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var opened: [String] = []
        view.openURL = { opened.append($0.absoluteString); return true }
        wait { terminal.hyperlinkURI(row: 0, col: 0) == url }
        check("tmux-label-retains-target", terminal.hyperlinkURI(row: 0, col: 8) == url)

        func event(_ type: NSEvent.EventType, row: Int, col: Int) -> NSEvent {
            let point = view.convert(NSPoint(x: (CGFloat(col) + 0.5) * view.cellWidth,
                                            y: (CGFloat(row) + 0.5) * view.cellHeight), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.command], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, row: 0, col: 4))
        view.mouseUp(with: event(.leftMouseUp, row: 0, col: 4))
        wait { !opened.isEmpty }
        check("cmd-click-opens-actual-label-url", opened == [url])
        let menu = view.menu(for: event(.rightMouseDown, row: 0, col: 4))
        check("link-context-menu", menu?.items.prefix(2).map(\.title) == ["Open Link", "Copy Link Address"])

        // Exercise the last cell too, where the former cursor-based tracker
        // dropped link metadata.
        view.mouseDown(with: event(.leftMouseDown, row: 0, col: 8))
        view.mouseUp(with: event(.leftMouseUp, row: 0, col: 8))
        wait { opened.count >= 2 }
        check("cmd-click-label-last-cell", opened.count == 2 && opened.last == url)
        if let link = TerminalLinkScanner.scan(terminal).first(where: { $0.url == "https://example.com/plain" }) {
            view.mouseDown(with: event(.leftMouseDown, row: link.row, col: link.startCol))
            view.mouseUp(with: event(.leftMouseUp, row: link.row, col: link.startCol))
            wait { opened.count >= 3 }
            check("cmd-click-after-unicode", opened.last == "https://example.com/plain")
        } else { check("cmd-click-after-unicode", false) }

        view.mouseDown(with: event(.leftMouseDown, row: 2, col: 75))
        view.mouseUp(with: event(.leftMouseUp, row: 2, col: 75))
        wait { opened.count >= 4 }
        check("cmd-click-edge-url-excludes-next-line-prose", opened.count == 4 && opened.last == reviewURL)

        let before = outputGeneration
        let redraw = try? tmux.execute(["refresh-client"])
        check("tmux-full-refresh", redraw != nil)
        wait { outputGeneration > before && !terminal.isInsideSyncUpdate }
        check("link-survives-full-refresh", terminal.hyperlinkURI(row: 0, col: 4) == url)

        _ = try? tmux.execute(["kill-server"])
        var status: Int32 = 0
        waitpid(pty.childPid, &status, 0)
        print("Terminal link interaction tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("Terminal link interaction tests failed") }
    }
}
#endif
