/// Border visual state integration tests — verify pane visual state
/// is set correctly for every state and state transition.
///
/// ## Architecture
///
/// Visual rendering is split between two layers:
///   - tmux global pane-border-format: active (teal) vs inactive (gray)
///   - TerminalView overlay: top border row colored for alert (amber)
///     and split-selected (red)
///
/// setPaneStyle sets tmux user options (@amux-alert, @amux-split-selected)
/// which TerminalView reads to determine overlay colors. No per-pane
/// pane-border-format overrides are used.
///
/// Color codes:
///   colour43  = teal  (active pane — tmux format)
///   colour214 = amber (alert pane — TerminalView overlay)
///   colour196 = red   (split-selected pane — TerminalView overlay)

import Foundation
import AmuxLib

enum BorderFormatTests {

    // MARK: - Helpers

    /// Get the per-pane pane-border-format for a specific pane.
    /// Returns nil if no per-pane override is set (pane uses global format).
    private static func paneBorderFormat(_ session: String, _ pane: Int) -> String? {
        let result = tmux("show-options", "-p", "-t", "\(session):.\(pane)", "-v", "pane-border-format")
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.success || trimmed.isEmpty { return nil }
        return trimmed
    }

    /// Get a pane user option value.
    private static func paneOpt(_ session: String, _ pane: Int, _ key: String) -> String? {
        let result = tmux("show-options", "-p", "-t", "\(session):.\(pane)", "-v", key)
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.success || trimmed.isEmpty { return nil }
        return trimmed
    }

    /// Get the global pane-border-format.
    private static func globalBorderFormat() -> String {
        let result = tmux("show-options", "-gv", "pane-border-format")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tests

    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // === 1. No pane gets per-pane border format override ===
        do {
            let ts = TestSession(paneCount: 3)

            // Set various states
            setPaneStyle(session: ts.name, pane: 0, alert: true)
            setPaneStyle(session: ts.name, pane: 1, splitSelected: true)

            for i in 0..<3 {
                check("noOverride-pane\(i)", paneBorderFormat(ts.name, i) == nil,
                      "pane \(i) must not have per-pane pane-border-format override")
            }
        }

        // === 2. setPaneStyle sets alert user option ===
        do {
            let ts = TestSession(paneCount: 3)

            setPaneStyle(session: ts.name, pane: 1, alert: true)
            check("alert-set", paneOpt(ts.name, 1, "@amux-alert") == "1")

            setPaneStyle(session: ts.name, pane: 1, alert: false)
            check("alert-cleared", paneOpt(ts.name, 1, "@amux-alert") == "0")
        }

        // === 3. setPaneStyle sets split-selected user option ===
        do {
            let ts = TestSession(paneCount: 3)

            setPaneStyle(session: ts.name, pane: 0, splitSelected: true)
            check("split-set", paneOpt(ts.name, 0, "@amux-split-selected") == "1")

            setPaneStyle(session: ts.name, pane: 0, splitSelected: false)
            check("split-cleared", paneOpt(ts.name, 0, "@amux-split-selected") == "0")
        }

        // === 4. Alert via amuxCmd sets alert state ===
        do {
            let ts = TestSession(paneCount: 3)

            let result = amuxCmd(session: ts.name, args: ["alert-pane", "1"])
            check("amuxCmdAlert-succeeds", result.success, "alert-pane should succeed: \(result.stderr)")
            check("amuxCmdAlert-setsOption", paneOpt(ts.name, 1, "@amux-alert") == "1",
                  "amux-cli alert-pane should set @amux-alert=1")
            // Must NOT set per-pane border format
            check("amuxCmdAlert-noOverride", paneBorderFormat(ts.name, 1) == nil,
                  "amux-cli alert-pane must not set per-pane pane-border-format")
        }

        // === 5. Focus to alerted pane clears alert ===
        do {
            let ts = TestSession(paneCount: 3)

            amuxCmd(session: ts.name, args: ["alert-pane", "1"])
            amuxCmd(session: ts.name, args: ["zoom", "1"])

            check("focusToAlert-cleared",
                  paneOpt(ts.name, 1, "@amux-alert") != "1",
                  "alert should be cleared after zoom-to")
        }

        // === 6. Multiple state transitions ===
        do {
            let ts = TestSession(paneCount: 3)

            // Alert pane 1
            setPaneStyle(session: ts.name, pane: 1, alert: true)
            check("transition-1-alert", paneOpt(ts.name, 1, "@amux-alert") == "1")

            // Clear alert
            setPaneStyle(session: ts.name, pane: 1, alert: false)
            check("transition-2-alertCleared", paneOpt(ts.name, 1, "@amux-alert") == "0")

            // Split-select pane 1
            setPaneStyle(session: ts.name, pane: 1, splitSelected: true)
            check("transition-3-split", paneOpt(ts.name, 1, "@amux-split-selected") == "1")

            // Clear split-selected
            setPaneStyle(session: ts.name, pane: 1, splitSelected: false)
            check("transition-4-splitCleared", paneOpt(ts.name, 1, "@amux-split-selected") == "0")

            // No per-pane overrides at any point
            check("transition-noOverride", paneBorderFormat(ts.name, 1) == nil)
        }

        // === 7. Global format: active (teal) and inactive only ===
        do {
            let _ts = TestSession(paneCount: 1)
            _ = _ts
            let globalFmt = globalBorderFormat()
            check("globalFormat-hasPaneActive", globalFmt.contains("pane_active"),
                  "global format should check pane_active")
            check("globalFormat-hasTeal", globalFmt.contains("colour43"),
                  "global format should have teal for active")
            // No alert or split-selected — overlay handles those
            check("globalFormat-noAlert", !globalFmt.contains("@amux-alert"),
                  "global format should NOT check alert (overlay handles it)")
            check("globalFormat-noSplitSelected", !globalFmt.contains("@amux-split-selected"),
                  "global format should NOT check split-selected (overlay handles it)")
        }

        // === 8. resetBorderStyles sets both borders to dark ===
        do {
            let _ts = TestSession(paneCount: 1)
            _ = _ts
            resetBorderStyles()

            let activeResult = tmux("show-options", "-gv", "pane-active-border-style")
            let inactiveResult = tmux("show-options", "-gv", "pane-border-style")
            check("resetBorderStyles-active",
                  activeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "fg=colour235")
            check("resetBorderStyles-inactive",
                  inactiveResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "fg=colour235")
        }

        // === 9. Full split-start → cancel flow ===
        do {
            let ts = TestSession(paneCount: 3)

            amuxCmd(session: ts.name, args: ["split-start"])

            check("splitFlow-start-splitSet",
                  paneOpt(ts.name, 0, "@amux-split-selected") == "1",
                  "split-start should set @amux-split-selected=1 on active pane")
            check("splitFlow-start-noOverride",
                  paneBorderFormat(ts.name, 0) == nil,
                  "split-start must not set per-pane pane-border-format")

            amuxCmd(session: ts.name, args: ["split-cancel"])

            check("splitFlow-cancel-splitCleared",
                  paneOpt(ts.name, 0, "@amux-split-selected") != "1",
                  "split-cancel should clear @amux-split-selected")
        }

        print("BorderFormatTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
