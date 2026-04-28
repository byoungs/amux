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

        // Mouse + wheel bindings: tmux must intercept wheel for copy-mode
        // entry on main screen and pass-through on alt-screen.
        do {
            let ts = TestSession(paneCount: 1)
            _ = ts  // hold session alive through queries

            let mouse = tmux("show-options", "-gv", "mouse")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("mouse-on", mouse == "on",
                  "expected mouse=on so wheel bindings can fire (got '\(mouse)')")

            // list-keys -T root <key> is buggy across tmux versions for
            // WheelUpPane keys. Filter the full table dump.
            let allRoot = tmux("list-keys", "-T", "root").stdout
            let upBinding = allRoot.split(separator: "\n")
                .filter { $0.contains("WheelUpPane") }.joined(separator: "\n")
            check("wheel-up-binding-exists", !upBinding.isEmpty)
            check("wheel-up-binding-alternate-on",
                  upBinding.contains("alternate_on"),
                  "got: \(upBinding)")
            check("wheel-up-binding-copy-mode",
                  upBinding.contains("copy-mode"),
                  "got: \(upBinding)")

            let downBinding = allRoot.split(separator: "\n")
                .filter { $0.contains("WheelDownPane") }.joined(separator: "\n")
            check("wheel-down-binding-exists", !downBinding.isEmpty)
            check("wheel-down-binding-passthrough",
                  downBinding.contains("send-keys -M"),
                  "got: \(downBinding)")

            // MouseDrag1Border must be unbound to prevent accidental pane
            // resize via border drag (causes mixed-width scrollback).
            let dragBinding = allRoot.split(separator: "\n")
                .filter { $0.contains("MouseDrag1Border") }.joined(separator: "\n")
            check("border-drag-unbound", dragBinding.isEmpty,
                  "MouseDrag1Border should not be bound; got: \(dragBinding)")
        }

        // After amux's applyLayout pipeline, the active pane's width must
        // equal the window width. If amux's layout engine produces a
        // pane narrower than the window, content wraps at that narrower
        // width and leaves visible empty space on the right (the "text
        // doesn't fill the width" symptom).
        do {
            let ts = TestSession(paneCount: 1)
            _ = ts
            _ = tmux("resize-window", "-t", ts.name, "-x", "120", "-y", "30")
            try? Tmux.applyLayout(ts.name, event: .resize)
            let paneWidth = tmux("display-message", "-p", "-t", ts.name, "#{pane_width}")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let windowWidth = tmux("display-message", "-p", "-t", ts.name, "#{window_width}")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("pane-width-matches-window-after-layout",
                  paneWidth == windowWidth,
                  "pane=\(paneWidth) window=\(windowWidth)")
            check("pane-width-is-120",
                  paneWidth == "120",
                  "expected 120, got \(paneWidth)")
        }

        // The inner program inside tmux's pane sees pane_width as its
        // COLUMNS / stty cols. Verify tmux exports the right width to
        // the running shell via TIOCSWINSZ.
        do {
            let ts = TestSession(paneCount: 1)
            _ = ts
            _ = tmux("resize-window", "-t", ts.name, "-x", "150", "-y", "30")
            try? Tmux.applyLayout(ts.name, event: .resize)
            let resultFile = "/tmp/amux-stty-test-\(ProcessInfo.processInfo.processIdentifier).out"
            try? FileManager.default.removeItem(atPath: resultFile)
            _ = tmux("send-keys", "-t", ts.name, "stty -a > \(resultFile) 2>&1", "Enter")
            // Wait for write
            for _ in 0..<20 {
                if FileManager.default.fileExists(atPath: resultFile) { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            Thread.sleep(forTimeInterval: 0.2)  // ensure full write
            let stty = (try? String(contentsOfFile: resultFile, encoding: .utf8)) ?? ""
            // BSD stty reports "speed 9600 baud; 30 rows; 150 columns;"
            // Linux stty reports "rows 30; columns 150;" or "rows=30; columns=150;"
            // Pull the integer immediately preceding or following "columns".
            var ttyCols = -1
            let parts = stty.replacingOccurrences(of: ";", with: " ")
                .replacingOccurrences(of: "=", with: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            for (i, t) in parts.enumerated() {
                if t == "columns" {
                    if i + 1 < parts.count, let n = Int(parts[i + 1]) { ttyCols = n; break }
                    if i > 0, let n = Int(parts[i - 1]) { ttyCols = n; break }
                }
            }
            check("inner-tty-cols-matches-pane",
                  ttyCols == 150,
                  "expected stty columns=150; got \(ttyCols); raw stty: \(stty.prefix(300))")
            try? FileManager.default.removeItem(atPath: resultFile)
        }

        // Reflow at narrow→wide: capture at narrow width, resize wider,
        // assert capture-pane -pJ at the wider width returns the original
        // logical line. If tmux preserves continuation across resize,
        // amux's scroll-up-after-resize will show wide content. If it
        // doesn't (line stuck at narrow width), the symptom is on tmux's
        // side and we know about it.
        do {
            let ts = TestSession(paneCount: 1)
            _ = ts
            _ = tmux("resize-window", "-t", ts.name, "-x", "60", "-y", "10")
            try? Tmux.applyLayout(ts.name, event: .resize)
            let kLine = String(repeating: "k", count: 100)
            _ = tmux("send-keys", "-t", ts.name, "echo \(kLine)", "Enter")
            for i in 1...3 {
                _ = tmux("send-keys", "-t", ts.name, "echo m\(i)", "Enter")
            }
            _ = tmux("display-message", "-p", "-t", ts.name, "")
            _ = tmux("resize-window", "-t", ts.name, "-x", "120", "-y", "10")
            try? Tmux.applyLayout(ts.name, event: .resize)
            _ = tmux("display-message", "-p", "-t", ts.name, "")
            let joined = tmux("capture-pane", "-t", ts.name, "-peqJ", "-S", "-30", "-E", "-1").stdout
            check("history-rejoins-after-narrow-to-wide",
                  joined.contains(kLine),
                  "pane 60→120; expected 100 contiguous k's; got: \(joined.prefix(400))")
        }

        // Tmux history reflows uniformly on resize — verifies the fundamental
        // assumption behind delegating scrollback to tmux's copy-mode.
        // Output a 100-char line that wraps, do multiple resizes during
        // additional output, then assert capture-pane returns the original
        // 100 chars rejoined as a single logical line at any width.
        do {
            let ts = TestSession(paneCount: 1)
            _ = ts
            _ = tmux("resize-window", "-t", ts.name, "-x", "100", "-y", "10")
            let line100 = String(repeating: "X", count: 100)
            _ = tmux("send-keys", "-t", ts.name, "echo \(line100)", "Enter")
            // Push it off-screen with more output through varying widths.
            for w in [90, 110, 95, 100] {
                _ = tmux("resize-window", "-t", ts.name, "-x", String(w), "-y", "10")
                _ = tmux("send-keys", "-t", ts.name, "echo line", "Enter")
            }
            // Final width 100. capture-pane -peqJ joins continuation rows.
            let captured = tmux("capture-pane", "-t", ts.name, "-peqJ", "-S", "-50", "-E", "-1").stdout
            check("tmux-reflow-preserves-line",
                  captured.contains(line100),
                  "expected 100-char X line in capture-pane -J output; got: '\(captured)'")
        }

        print("ConfigTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
