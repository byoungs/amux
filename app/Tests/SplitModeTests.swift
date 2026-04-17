/// End-to-end tests for split mode visual feedback via CLI.
///
/// Ported from tests/split_mode_test.rs.

import Foundation

enum SplitModeTests {
    private static func getSplitSelected(_ session: String, _ pane: Int) -> Bool {
        let result = tmux("show-options", "-p", "-t", "\(session):.\(pane)", "-v", "@amux-split-selected")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private static func getPicking(_ session: String) -> Bool {
        let result = tmux("show-options", "-t", session, "-v", "@amux-picking")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private static func getSplitFirstLabel(_ session: String) -> String {
        let result = tmux("show-options", "-t", session, "-v", "@amux-split-first-label")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // split_start_sets_visual_state
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name).1")
            amuxCmd(session: ts.name, args: ["split-start"])

            check("splitStartSetsVisualState-selected", getSplitSelected(ts.name, 1),
                  "active pane should be marked as split-selected")
            check("splitStartSetsVisualState-picking", getPicking(ts.name),
                  "session should be in picking mode")
            let label = getSplitFirstLabel(ts.name)
            check("splitStartSetsVisualState-label", label.hasPrefix("2"),
                  "label should start with 1-indexed pane number '2', got: \(label)")
        }

        // split_start_unzooms_if_zoomed
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name).0")
            tmux("resize-pane", "-t", "\(ts.name).0", "-Z")
            check("splitStartUnzooms-preZoomed", isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["split-start"])
            check("splitStartUnzooms-unzoomed", !isZoomed(ts.name),
                  "should unzoom on split-start")
        }

        // split_pick_clears_visual_state
        do {
            let ts = TestSession(paneCount: 4)
            tmux("select-pane", "-t", "\(ts.name).0")
            amuxCmd(session: ts.name, args: ["split-start"])
            check("splitPickClears-prePicking", getPicking(ts.name))

            amuxCmd(session: ts.name, args: ["split-pick", "1"])
            check("splitPickClears-selected", !getSplitSelected(ts.name, 0),
                  "split-selected should be cleared after pick")
            check("splitPickClears-picking", !getPicking(ts.name),
                  "picking mode should be cleared after pick")
        }

        // split_cancel_clears_visual_state
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name).1")
            amuxCmd(session: ts.name, args: ["split-start"])
            check("splitCancelClears-prePicking", getPicking(ts.name))

            amuxCmd(session: ts.name, args: ["split-cancel"])
            check("splitCancelClears-selected", !getSplitSelected(ts.name, 1),
                  "split-selected should be cleared")
            check("splitCancelClears-picking", !getPicking(ts.name),
                  "picking mode should be cleared")
            let label = getSplitFirstLabel(ts.name)
            check("splitCancelClears-label", label.isEmpty,
                  "label should be cleared, got '\(label)'")
        }

        // split_cancel_restores_zoom_if_was_zoomed
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name).0")
            tmux("resize-pane", "-t", "\(ts.name).0", "-Z")
            check("splitCancelRestoresZoom-preZoomed", isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["split-start"])
            check("splitCancelRestoresZoom-unzoomed", !isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["split-cancel"])
            check("splitCancelRestoresZoom-restored", isZoomed(ts.name),
                  "cancel should restore zoom state")
        }

        // split_cancel_does_not_zoom_if_was_not_zoomed
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name).0")
            check("splitCancelNoZoom-preNotZoomed", !isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["split-start"])
            amuxCmd(session: ts.name, args: ["split-cancel"])
            check("splitCancelNoZoom-stillNotZoomed", !isZoomed(ts.name),
                  "cancel should not zoom when it wasn't zoomed before")
        }

        print("SplitModeTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
