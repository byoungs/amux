#if DEBUG
import Foundation

/// Where amux keeps its state. The override exists so tests (and anyone
/// running two amux builds side by side) can drive the real code paths —
/// including the CLI prompt — without touching the user's live ~/.amux.
public enum AmuxPathsTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let home = NSHomeDirectory()

        // Default: ~/.amux, exactly as before the override existed.
        check("default-home",
              AmuxPaths.home(env: [:]).path == "\(home)/.amux",
              AmuxPaths.home(env: [:]).path)
        check("default-state",
              AmuxPaths.state(env: [:]).path == "\(home)/.amux/state.json",
              AmuxPaths.state(env: [:]).path)
        check("default-snapshot",
              AmuxPaths.snapshot(env: [:]).path == "\(home)/.amux/session-snapshot.json",
              AmuxPaths.snapshot(env: [:]).path)

        // AMUX_HOME moves every file together — state, snapshot, prefs and the
        // coalescing marker. A test that redirects one but not the others would
        // silently write into the user's real directory.
        let env = ["AMUX_HOME": "/tmp/amux-test-home"]
        check("override-home", AmuxPaths.home(env: env).path == "/tmp/amux-test-home")
        check("override-state", AmuxPaths.state(env: env).path == "/tmp/amux-test-home/state.json")
        check("override-snapshot",
              AmuxPaths.snapshot(env: env).path == "/tmp/amux-test-home/session-snapshot.json")
        check("override-prefs",
              AmuxPaths.restorePrefs(env: env).path == "/tmp/amux-test-home/restore-prefs.json")
        check("override-request",
              AmuxPaths.snapshotRequest(env: env).path == "/tmp/amux-test-home/snapshot-request")

        // An empty value is not an override — that would silently redirect
        // everything to the filesystem root.
        check("empty-ignored",
              AmuxPaths.home(env: ["AMUX_HOME": ""]).path == "\(home)/.amux")

        // The defaults the rest of the code reads must go through the same
        // resolution, or the override only half-works.
        check("snapshot-default-path-matches",
              SessionSnapshot.defaultPath == AmuxPaths.snapshot())
        check("prefs-default-path-matches",
              RestorePrefs.defaultPath == AmuxPaths.restorePrefs())
        check("state-default-path-matches",
              AmuxState.defaultPath == AmuxPaths.state())
        check("request-default-path-matches",
              SnapshotCapture.requestMarkerPath == AmuxPaths.snapshotRequest())

        print("AmuxPaths tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("AmuxPaths tests failed") }
    }
}
#endif
