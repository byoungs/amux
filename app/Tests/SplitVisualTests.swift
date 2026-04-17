/// Split mode visual state tests: @amux-split-selected, @amux-picking,
/// @amux-split-first-label.
///
/// Ported from tests/split_visual_test.rs.

import Foundation

enum SplitVisualTests {
    private static func getSplitSelected(_ session: String, _ pane: Int) -> Bool {
        let result = tmux("show-options", "-p", "-t", "\(session):.\(pane)", "-v", "@amux-split-selected")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private static func setSplitSelected(_ session: String, _ pane: Int, _ value: Bool) {
        tmux("set-option", "-p", "-t", "\(session):.\(pane)", "@amux-split-selected", value ? "1" : "0")
    }

    private static func getPicking(_ session: String) -> Bool {
        let result = tmux("show-options", "-t", session, "-v", "@amux-picking")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private static func setPicking(_ session: String, _ value: Bool) {
        tmux("set-option", "-t", session, "@amux-picking", value ? "1" : "0")
    }

    private static func getSplitFirstLabel(_ session: String) -> String {
        let result = tmux("show-options", "-t", session, "-v", "@amux-split-first-label")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func setSplitFirstLabel(_ session: String, _ label: String) {
        tmux("set-option", "-t", session, "@amux-split-first-label", label)
    }

    private static func clearSplitFirstLabel(_ session: String) {
        tmux("set-option", "-t", session, "-u", "@amux-split-first-label")
    }

    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // set_and_get_split_selected
        do {
            let ts = TestSession(paneCount: 3)
            check("splitSelected-initialFalse", !getSplitSelected(ts.name, 0))
            setSplitSelected(ts.name, 0, true)
            check("splitSelected-setTrue", getSplitSelected(ts.name, 0))
            setSplitSelected(ts.name, 0, false)
            check("splitSelected-setFalse", !getSplitSelected(ts.name, 0))
        }

        // set_and_get_picking_mode
        do {
            let ts = TestSession(paneCount: 3)
            check("pickingMode-initialFalse", !getPicking(ts.name))
            setPicking(ts.name, true)
            check("pickingMode-setTrue", getPicking(ts.name))
            setPicking(ts.name, false)
            check("pickingMode-setFalse", !getPicking(ts.name))
        }

        // set_and_get_split_first_label
        do {
            let ts = TestSession(paneCount: 3)
            setSplitFirstLabel(ts.name, "2 amux/main")
            let label = getSplitFirstLabel(ts.name)
            check("splitFirstLabel-set", label == "2 amux/main",
                  "expected '2 amux/main', got '\(label)'")
            clearSplitFirstLabel(ts.name)
            let cleared = getSplitFirstLabel(ts.name)
            check("splitFirstLabel-cleared", cleared.isEmpty,
                  "label should be empty after clear, got '\(cleared)'")
        }

        print("SplitVisualTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
