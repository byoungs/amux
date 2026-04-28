/// Tests for tmux configuration: border formats, status-right, key bindings.
///
/// Ported from tests/config_test.rs. Tests that inspect format string constants
/// are adapted to read the values from tmux after amux applies its config.

import Foundation
import AmuxLib

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

            // Alert state: tmux format no longer references @amux-alert
            // (TerminalView.rebuildOverlays reads the option and paints overlays).
            // Verify (a) the format doesn't touch @amux-alert at all, and
            // (b) setPaneStyle(alert: true) sets @amux-alert=1 on the pane —
            // which is exactly what TerminalView reads when building overlays.
            do {
                let result = tmux("show-options", "-gv", "pane-border-format")
                let fmt = result.stdout
                check("borderFormatDoesNotReferenceAlert",
                      !fmt.contains("@amux-alert"),
                      "border format must not reference @amux-alert — TerminalView overlays render alert state")

                setPaneStyle(session: ts.name, pane: 1, alert: true)
                let alertOpt = tmux("show-options", "-p", "-t", "\(ts.name):.1", "-v", "@amux-alert")
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                check("setPaneStyleAlertSetsPaneOption",
                      alertOpt == "1",
                      "setPaneStyle(alert: true) must set @amux-alert=1 on the pane (got: \(alertOpt))")

                // Positive color assertion: the overlay engine must paint amber
                // for a non-active alerted pane. This is the actual
                // user-observable behavior the old "amber" tests guarded.
                check("alertRendersAmberOverlay",
                      overlayColor(alert: true, splitSelected: false, active: false)
                        == OverlayColor(r: 214, g: 135, b: 0),
                      "alert on non-active pane must render amber (214,135,0)")
                check("activeAlertedPaneNoOverlay",
                      overlayColor(alert: true, splitSelected: false, active: true) == nil,
                      "alert on active pane must not render overlay (alert clears on focus)")

                // Reset so later checks see a clean state.
                setPaneStyle(session: ts.name, pane: 1, alert: false)
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

            // Split-selected state: same architectural split as alert —
            // tmux format doesn't mention @amux-split-selected; TerminalView
            // paints the red overlay. Verify the pane option is still the
            // contract that setPaneStyle writes and TerminalView reads.
            do {
                let result = tmux("show-options", "-gv", "pane-border-format")
                let fmt = result.stdout
                check("borderFormatDoesNotReferenceSplitSelected",
                      !fmt.contains("@amux-split-selected"),
                      "border format must not reference @amux-split-selected — TerminalView overlays render split-selected state")

                setPaneStyle(session: ts.name, pane: 0, splitSelected: true)
                let splitOpt = tmux("show-options", "-p", "-t", "\(ts.name):.0", "-v", "@amux-split-selected")
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                check("setPaneStyleSplitSelectedSetsPaneOption",
                      splitOpt == "1",
                      "setPaneStyle(splitSelected: true) must set @amux-split-selected=1 on the pane (got: \(splitOpt))")

                // Positive color assertion: the overlay engine must paint red
                // for a split-selected pane, regardless of active state.
                check("splitSelectedRendersRedOverlay",
                      overlayColor(alert: false, splitSelected: true, active: false)
                        == OverlayColor(r: 255, g: 0, b: 0),
                      "split-selected must render red (255,0,0)")
                check("splitSelectedWinsOverAlert",
                      overlayColor(alert: true, splitSelected: true, active: false)
                        == OverlayColor(r: 255, g: 0, b: 0),
                      "split-selected must win over alert (red, not amber)")

                setPaneStyle(session: ts.name, pane: 0, splitSelected: false)
            }

            // Key bindings moved from tmux to the Swift app (KeyInput.swift).
            // Verify the pure character→command mapping that KeyInput delegates to:
            //   Cmd-= → zoomIn,  Cmd-1 → zoomTo(0).
            // The session is resolved at dispatch time by the caller, so there's
            // no "--session" flag to check anymore — the AmuxCommand itself carries
            // the intent and the caller binds it to the active session.
            do {
                check("cmdEqualsMapsToZoomIn",
                      KeyCommand.amuxCommand(for: "=") == .zoomIn,
                      "Cmd-= must map to AmuxCommand.zoomIn (got: \(String(describing: KeyCommand.amuxCommand(for: "="))))")

                check("cmd1MapsToZoomToPane0",
                      KeyCommand.amuxCommand(for: "1") == .zoomTo(0),
                      "Cmd-1 must map to AmuxCommand.zoomTo(0) (got: \(String(describing: KeyCommand.amuxCommand(for: "1"))))")
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
