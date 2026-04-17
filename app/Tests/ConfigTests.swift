/// Tests for tmux configuration: border formats, status-right, key bindings.
///
/// Ported from tests/config_test.rs. Tests that inspect format string constants
/// are adapted to read the values from tmux after amux applies its config.

import Foundation

enum ConfigTests {
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

        // Tests that inspect tmux options after config is applied
        do {
            let ts = TestSession(paneCount: 2)

            // border_format_uses_explicit_alert_comparison
            do {
                let result = tmux("show-options", "-gv", "pane-border-format")
                let fmt = result.stdout
                check("borderFormatNoTruthyAlertCheck",
                      !fmt.contains("#{?@amux-alert"),
                      "border format must not use truthy check on @amux-alert")
                check("borderFormatExplicitAlertComparison",
                      fmt.contains("#{==:#{@amux-alert},1}"),
                      "border format must use explicit ==1 comparison for @amux-alert")
            }

            // border_format_contains_unicode_characters
            do {
                let result = tmux("show-options", "-gv", "pane-border-format")
                let fmt = result.stdout
                check("borderFormatContainsLeftQuarterBlock",
                      fmt.contains("\u{258E}"),
                      "border format must contain \u{258E} (LEFT ONE QUARTER BLOCK)")
                check("borderFormatContainsBlackCircle",
                      fmt.contains("\u{25CF}"),
                      "border format must contain \u{25CF} (BLACK CIRCLE)")
            }

            // status_right_uses_cmd_symbol
            do {
                let result = tmux("show-options", "-t", ts.name, "-v", "status-right")
                let fmt = result.stdout
                check("statusRightNoTruthyAlertCheck",
                      !fmt.contains("#{?@amux-alert,"),
                      "status-right must not use truthy check on @amux-alert")
                check("statusRightUsesCmdSymbol",
                      fmt.contains("⌘"),
                      "status-right must use ⌘ symbol for key hints")
                check("statusRightHasZoom",
                      fmt.contains("zoom"),
                      "status-right must show zoom action")
                check("statusRightHasHelp",
                      fmt.contains("⌘?"),
                      "status-right must show ⌘? help shortcut")
                check("statusRightHasCmdHeldConditional",
                      fmt.contains("@amux-cmd-held"),
                      "status-right must have cmd-held color conditional")
            }

            // border_format_has_split_selected_state
            do {
                let result = tmux("show-options", "-gv", "pane-border-format")
                let fmt = result.stdout
                check("borderFormatHasSplitSelectedState",
                      fmt.contains("#{==:#{@amux-split-selected},1}"),
                      "border format must check @amux-split-selected with explicit ==1 comparison")
            }

            // key_bindings_pass_session_flag
            do {
                let result = tmux("list-keys", "-T", "root")
                let keys = result.stdout

                let zoomInLine = keys.components(separatedBy: "\n")
                    .first { $0.contains("C-=") && $0.contains("amux") }
                check("keyBindingZoomInHasSessionFlag",
                      zoomInLine?.contains("--session") ?? false,
                      "C-= binding should include --session flag. Found: \(zoomInLine ?? "nil")")

                let zoom1Line = keys.components(separatedBy: "\n")
                    .first { $0.contains("C-1") && $0.contains("amux") }
                check("keyBindingZoom1HasSessionFlag",
                      zoom1Line?.contains("--session") ?? false,
                      "C-1 binding should include --session flag. Found: \(zoom1Line ?? "nil")")
            }

            // status_right_has_picking_mode
            do {
                let result = tmux("show-options", "-t", ts.name, "-v", "status-right")
                let fmt = result.stdout
                check("statusRightHasPickingMode",
                      fmt.contains("@amux-picking"),
                      "status-right must check @amux-picking for split pick mode")
                check("statusRightHasSplitFirstLabel",
                      fmt.contains("@amux-split-first-label"),
                      "status-right must show the split-first label")
            }
        }

        // apply_hooks_source_uses_after_select_pane (filesystem check)
        do {
            let projectRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Tests/
                .deletingLastPathComponent() // app/
                .deletingLastPathComponent() // project root
                .path
            let configPath = "\(projectRoot)/app/Sources/AmuxLib/Config.swift"
            let source = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
            check("applyHooksUsesAfterSelectPane",
                  source.contains("after-select-pane"),
                  "Config.swift must use after-select-pane hook")
        }

        print("ConfigTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
