/// Hook scoping tests: hooks act only on their intended managed space.
///
/// Ported from tests/hook_scoping_test.rs.

import Foundation
import AmuxLib

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

        // Explicit kill-pane does not emit pane-exited. Exercise the real
        // installed hook without a manual applyLayout masking the omission.
        do {
            let ts = TestSession(paneCount: 5)
            let other = TestSession(paneCount: 3)
            let otherBefore = tmux("list-panes", "-t", other.name, "-F",
                                   "#{pane_id} #{pane_pid} #{pane_left} #{pane_top} #{pane_width} #{pane_height}").stdout
            let before = tmux("list-panes", "-t", ts.name, "-F", "#{pane_id} #{pane_pid}")
                .stdout.split(separator: "\n").map(String.init)
            let victim = before[0].split(separator: " ")[0]
            let result = tmux("kill-pane", "-t", String(victim))
            check("explicitKill-success", result.success, result.stderr)
            var state = try! Tmux.gatherLayoutState(ts.name)
            for _ in 0..<100 {
                if state.panes.count == 4 && Set(state.panes.map { $0.x }).count == 2
                    && Set(state.panes.map { $0.y }).count == 2 { break }
                Thread.sleep(forTimeInterval: 0.02)
                state = try! Tmux.gatherLayoutState(ts.name)
            }
            check("explicitKill-restoresFourPaneGrid",
                  state.panes.count == 4 && Set(state.panes.map { $0.x }).count == 2
                    && Set(state.panes.map { $0.y }).count == 2
                    && (state.panes.map { $0.w }.max()! - state.panes.map { $0.w }.min()!) <= 1
                    && (state.panes.map { $0.h }.max()! - state.panes.map { $0.h }.min()!) <= 1,
                  "explicit close must restore a balanced 2x2 grid")
            let after = tmux("list-panes", "-t", ts.name, "-F", "#{pane_id} #{pane_pid}")
                .stdout.split(separator: "\n").map(String.init)
            check("explicitKill-preservesSurvivingProcesses", Set(after) == Set(before.dropFirst()))
            check("explicitKill-leavesOtherSpaceAlone",
                  tmux("list-panes", "-t", other.name, "-F",
                       "#{pane_id} #{pane_pid} #{pane_left} #{pane_top} #{pane_width} #{pane_height}").stdout == otherBefore)
        }

        // Ordinary layout notifications are no-ops once the pane count is
        // current (no recursive retiling).
        do {
            let ts = TestSession(paneCount: 4)
            let window = tmux("display-message", "-p", "-t", ts.name, "#{window_id}")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let layout = tmux("display-message", "-p", "-t", ts.name, "#{window_layout}").stdout
            check("paneCountRepair-isIdempotent", (try? Tmux.reconcilePaneCount(window: window)) == false)
            check("paneCountRepair-keepsLayout", tmux("display-message", "-p", "-t", ts.name,
                                                      "#{window_layout}").stdout == layout)
        }

        // A global notification must not take ownership of an unrelated tmux
        // window. It also must not fall back to another space after destruction.
        do {
            let unmanaged = TestSession(paneCount: 0)
            tmux("set-option", "-wu", "-t", unmanaged.name, "@amux-layout-pane-count")
            tmux("split-window", "-d", "-t", unmanaged.name)
            let window = tmux("display-message", "-p", "-t", unmanaged.name, "#{window_id}")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let layout = tmux("display-message", "-p", "-t", unmanaged.name, "#{window_layout}").stdout
            check("paneCountRepair-ignoresUnmanaged", (try? Tmux.reconcilePaneCount(window: window)) == false)
            check("paneCountRepair-unmanagedLayoutUnchanged",
                  tmux("display-message", "-p", "-t", unmanaged.name, "#{window_layout}").stdout == layout)
            tmux("kill-session", "-t", unmanaged.name)
            check("paneCountRepair-ignoresDestroyedWindow", (try? Tmux.reconcilePaneCount(window: window)) == false)
        }

        print("HookScopingTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
