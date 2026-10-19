#if DEBUG
import AppKit
import AmuxLib

/// Optional local smoke test with the installed Codex CLI. Types an unsent
/// draft, expands/collapses its pane and resizes the native view. No model
/// request is submitted. Run with --test-codex-resize.
enum TerminalCodexResizeProbe {
    static func run() -> Bool {
        let socket = "amux-codex-probe-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(socket).resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        // Isolate trust/config/history; reuse credentials without printing or
        // copying their contents. This probe never submits its draft.
        let auth = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        if FileManager.default.fileExists(atPath: auth.path) {
            try! FileManager.default.createSymbolicLink(at: root.appendingPathComponent("auth.json"), withDestinationURL: auth)
        }
        try! "[projects.\"\(root.path)\"]\ntrust_level = \"trusted\"\n".write(
            to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let tmux = LiveTmux(socket: socket)
        let old = Tmux.executor
        Tmux.executor = tmux
        defer { Tmux.executor = old }
        guard let pty = PTY(executable: "/usr/bin/env", args: ["env", "-u", "TMUX", "tmux", "-L", socket,
                           "-f", "/dev/null", "new-session", "-s", "probe",
                           "env CODEX_HOME=\(SessionRestore.singleQuoted(root.path)) codex -C \(SessionRestore.singleQuoted(root.path))"], rows: 40, cols: 140)
        else { return false }
        defer {
            _ = try? tmux.execute(["kill-server"])
            var status: Int32 = 0
            waitpid(pty.childPid, &status, 0)
        }
        let term = VTerminal(rows: 40, cols: 140)
        let view = TerminalView(terminal: term, pty: pty)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: view.cellWidth * 140, height: view.cellHeight * 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        func text() -> String {
            (0..<term.rows).map { row in
                (0..<term.cols).map {
                    let cell = VTerminal.cellString(term.cell(row: row, col: $0))
                    return cell.isEmpty ? " " : cell
                }.joined()
            }.joined(separator: "\n")
        }
        @discardableResult func wait(_ seconds: Double = 5, _ predicate: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !predicate() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return predicate()
        }
        guard wait(20, { text().contains("context left") || text().contains("? for shortcuts") }) else {
            print("Codex probe did not reach the composer:\n\(text())")
            return false
        }
        let draft = "amux-resize-probe-unsent"
        pty.write(Data(draft.utf8))
        guard wait(15, { text().contains(draft) }) else {
            print("Codex probe did not reach a draft input: \(text().prefix(1200))")
            return false
        }
        _ = try? tmux.execute(["split-window", "-d", "-h", "-t", "probe", "/bin/zsh -f"])
        wait { text().contains(draft) }
        let controller = AppController(session: "probe")
        controller.clientTTY = pty.slavePath
        var success = true
        for index in 0..<6 {
            let before = Date()
            var done = false
            DispatchQueue.global().async {
                controller.handleAction(index % 2 == 0 ? .zoomIn : .zoomOut)
                DispatchQueue.main.async { done = true }
            }
            wait { done }
            // Require fresh output at the new pane size, then check the draft.
            wait(0.15) { false }
            let ok = wait(3) { text().contains(draft) && !term.isInsideSyncUpdate }
            print("Codex pane toggle \(index): \(ok ? "PASS" : "FAIL") \(Int(Date().timeIntervalSince(before) * 1000))ms")
            if !ok {
                print("sync=\(term.isInsideSyncUpdate), grid=\(term.cols)x\(term.rows)\nNative:\n\(text())")
                print("tmux:\n\(Tmux.runRaw(["capture-pane", "-p", "-t", "probe:0.0"]))")
                fflush(stdout)
            }
            success = success && ok
        }
        for (cols, rows) in [(340, 81), (140, 40), (340, 81)] {
            let before = Date()
            view.setFrameSize(NSSize(width: view.cellWidth * CGFloat(cols), height: view.cellHeight * CGFloat(rows)))
            wait(0.15) { false }
            let ok = wait(3) { text().contains(draft) && !term.isInsideSyncUpdate }
            print("Codex window \(cols)x\(rows): \(ok ? "PASS" : "FAIL") \(Int(Date().timeIntervalSince(before) * 1000))ms")
            success = success && ok
        }
        return success
    }
}
#endif
