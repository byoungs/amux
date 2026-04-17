/// Hook scoping tests: hooks must be session-scoped, not global.
///
/// Ported from tests/hook_scoping_test.rs.

import Foundation

enum HookScopingTests {
    /// Collect all hooks for a session: session-level and window-level.
    private static func allHooks(for session: String) -> String {
        let sessionHooks = tmux("show-hooks", "-t", session)
        let windowHooks = tmux("show-hooks", "-w", "-t", session)
        return sessionHooks.stdout + windowHooks.stdout
    }

    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // hooks_are_session_scoped_not_global
        do {
            let ts = TestSession(paneCount: 2)
            let hooks = allHooks(for: ts.name)

            check("hooksSessionScoped-paneExited",
                  hooks.contains("pane-exited"),
                  "session should have pane-exited hook: \(hooks)")
            check("hooksSessionScoped-afterSelectPane",
                  hooks.contains("after-select-pane"),
                  "session should have after-select-pane hook: \(hooks)")
        }

        // two_sessions_get_independent_hooks
        do {
            let ts1 = TestSession(paneCount: 2)
            let ts2 = TestSession(paneCount: 2)
            let h1 = allHooks(for: ts1.name)
            let h2 = allHooks(for: ts2.name)

            check("independentHooks-ts1", h1.contains("pane-exited"),
                  "ts1 should have hooks")
            check("independentHooks-ts2", h2.contains("pane-exited"),
                  "ts2 should have hooks")
        }

        print("HookScopingTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
