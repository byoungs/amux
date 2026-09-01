/// Session snapshot + restore against real tmux.
///
/// The unit suites cover the pure planning; this covers the adapter layer —
/// that the capture format strings actually parse, that a planned command
/// list is accepted by tmux in the order it is emitted, and that restoring
/// twice does not double the panes.

import Foundation
import AmuxLib

enum SessionRestoreTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition {
                passed += 1
            } else {
                failed += 1
                print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")")
            }
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("amux-restore-it-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 1. Capture reads live panes: session, cwds, titles, active pane.
        do {
            let ts = TestSession(paneCount: 1)
            Tmux.markAsManaged(ts.name)
            tmux("split-window", "-t", "\(ts.name):0", "-d", "-c", "/usr")
            try? Tmux.setTitle(ts.name, paneIndex: 1, title: "usr-pane")

            let path = scratch.appendingPathComponent("capture.json")
            let snapshot = SnapshotCapture.captureNow(cleanExit: false, to: path, now: 1_000)
            let space = snapshot?.spaces.first(where: { $0.name == ts.name })
            check("capture-space-present", space != nil, String(describing: snapshot?.spaces.map(\.name)))
            check("capture-pane-count", space?.panes.count == 2, "\(space?.panes.count ?? -1)")
            check("capture-cwd", space?.panes.last?.cwd == "/usr", space?.panes.last?.cwd ?? "nil")
            check("capture-title", space?.panes.last?.title == "usr-pane", space?.panes.last?.title ?? "nil")
            check("capture-clean-exit-false", snapshot?.cleanExit == false)

            // The file on disk is what restore will read back.
            let reloaded = SessionSnapshot.load(from: path)
            check("capture-round-trip", reloaded == snapshot)

            // A clean-exit capture is what the terminate path writes.
            let clean = SnapshotCapture.captureNow(cleanExit: true, to: path, now: 1_001)
            check("capture-clean-exit-true", clean?.cleanExit == true)
            check("capture-clean-on-disk", SessionSnapshot.load(from: path)?.cleanExit == true)
        }

        // 2. A planned restore is accepted by real tmux, in order, and lands
        //    the panes at their saved cwds with focus on the saved pane.
        do {
            let name = "amux-restore-\(ProcessInfo.processInfo.processIdentifier)"
            defer { tmux("kill-session", "-t", name) }

            let snapshot = SessionSnapshot(
                capturedAt: 2_000, cleanExit: true,
                // Paths with no symlink in them: /var and /etc resolve to
                // /private/... in pane_current_path and would fail the compare
                // for reasons that have nothing to do with restore.
                spaces: [SpaceSnapshot(name: name, panes: [
                    PaneSnapshot(index: 0, cwd: "/usr", title: "one", kind: .shell),
                    PaneSnapshot(index: 1, cwd: "/usr/lib", title: "two", kind: .shell),
                    PaneSnapshot(index: 2, cwd: "/usr/share", title: "three", kind: .shell),
                ], selectedPane: 2)],
                backlog: [])

            let plan = SessionRestore.planRestore(snapshot: snapshot, existing: [:], now: 2_000)
            SessionRestore.execute(plan)

            let panes = (try? Tmux.listPanes(name)) ?? []
            check("restore-pane-count", panes.count == 3, "\(panes.count)")
            check("restore-titles", panes.map(\.title) == ["one", "two", "three"],
                  panes.map(\.title).joined(separator: ","))
            let cwds = (0..<panes.count).map { (try? Tmux.paneCwd(name, paneIndex: $0)) ?? "" }
            check("restore-cwds", cwds == ["/usr", "/usr/lib", "/usr/share"],
                  cwds.joined(separator: ","))
            check("restore-selected", panes.first(where: \.active)?.index == 2,
                  String(describing: panes.first(where: \.active)?.index))

            // Running it again must not double the panes.
            let second = SessionRestore.planRestore(
                snapshot: snapshot,
                existing: SessionRestore.existingSessionPaneCounts(),
                now: 2_000)
            SessionRestore.execute(second)
            check("restore-idempotent", second.skippedSpaces == [name]
                  && ((try? Tmux.paneCount(name)) ?? 0) == 3,
                  "\(second.skippedSpaces) \((try? Tmux.paneCount(name)) ?? -1)")
        }

        // 3. A backlog space comes back parked, not as a visible space.
        do {
            let name = "amux-restore-parked-\(ProcessInfo.processInfo.processIdentifier)"
            defer { tmux("kill-session", "-t", name) }

            let snapshot = SessionSnapshot(
                capturedAt: 3_000, cleanExit: true,
                spaces: [SpaceSnapshot(name: name, panes: [
                    PaneSnapshot(index: 0, cwd: "/usr", title: "parked", kind: .shell),
                ], selectedPane: 0)],
                backlog: [name])
            SessionRestore.execute(
                SessionRestore.planRestore(snapshot: snapshot, existing: [:], now: 3_000))

            let parked = (try? Tmux.listBackgroundSessions()) ?? []
            let raw = Tmux.runRaw(["list-sessions", "-F",
                                   "#{session_name}|#{@amux-managed}|#{@amux-state}|#{@amux-parked-at}"])
            check("restore-backlog", parked.contains(where: { $0.name == name }),
                  "listed=[\(parked.map(\.name).joined(separator: ","))] raw=[\(raw)]")
            check("restore-backlog-not-foreground",
                  !(((try? Tmux.listFocusSessions()) ?? []).contains(name)))
        }

        print("SessionRestore tests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
