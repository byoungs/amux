#if DEBUG
import Foundation

/// Snapshot persistence. The file is written on every pane event and read
/// exactly once — at startup, when nothing else can recover the panes — so
/// round-tripping every PaneKind and surviving a corrupt file both matter.
public enum SessionSnapshotTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amux-snapshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session-snapshot.json")

        let snap = SessionSnapshot(
            capturedAt: 1_756_700_000,
            cleanExit: true,
            spaces: [
                SpaceSnapshot(name: "amux", panes: [
                    PaneSnapshot(index: 0, cwd: "/Users/b/src/amux", title: "amux",
                                 kind: .claude(sessionID: "abc", confidence: .resumeArg)),
                    PaneSnapshot(index: 1, cwd: "/Users/b/src/amux", title: "shell",
                                 kind: .shell),
                    PaneSnapshot(index: 2, cwd: "/Users/b", title: "wtr",
                                 kind: .command("wtr")),
                    PaneSnapshot(index: 3, cwd: "/Users/b", title: "unknown",
                                 kind: .claude(sessionID: nil, confidence: .none)),
                ], selectedPane: 2),
                SpaceSnapshot(name: "parked-thing", panes: [
                    PaneSnapshot(index: 0, cwd: "/Users/b/src/other", title: "other",
                                 kind: .claude(sessionID: "def", confidence: .topicMatch)),
                ], selectedPane: 0, parkedFrom: "amux"),
            ],
            backlog: ["parked-thing"])

        do {
            try snap.save(to: path)
            let loaded = SessionSnapshot.load(from: path)
            check("round-trip", loaded == snap, String(describing: loaded))
            check("pane-count", snap.paneCount == 5, "\(snap.paneCount)")

            // Overwrite in place — the capture path rewrites this file constantly.
            var second = snap
            second.cleanExit = false
            try second.save(to: path)
            check("overwrite", SessionSnapshot.load(from: path)?.cleanExit == false)
        } catch {
            check("save", false, "\(error)")
        }

        // Corrupt and missing files must return nil, not crash startup.
        let corrupt = dir.appendingPathComponent("corrupt.json")
        try? Data("{ not json".utf8).write(to: corrupt)
        check("corrupt-nil", SessionSnapshot.load(from: corrupt) == nil)
        check("missing-nil", SessionSnapshot.load(from: dir.appendingPathComponent("nope.json")) == nil)

        // Prefs: separate file so a capture can't wipe the opt-out.
        let prefsPath = dir.appendingPathComponent("restore-prefs.json")
        check("prefs-default", RestorePrefs.load(from: prefsPath) == RestorePrefs())
        do {
            try RestorePrefs(dontAsk: true, consumedCapturedAt: 1_756_700_000).save(to: prefsPath)
            let p = RestorePrefs.load(from: prefsPath)
            check("prefs-round-trip", p.dontAsk && p.consumedCapturedAt == 1_756_700_000,
                  String(describing: p))
        } catch {
            check("prefs-save", false, "\(error)")
        }

        print("SessionSnapshot tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("SessionSnapshot tests failed") }
    }
}
#endif
