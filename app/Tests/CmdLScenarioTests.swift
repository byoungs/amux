/// Cmd-L split mode scenario tests.
///
/// These describe the DESIRED behavior for the Cmd-L redesign where:
/// - AmuxTerm (Swift app) intercepts Cmd-L and enters pick mode
/// - Pick mode: arrow keys navigate, numbers pick, Esc cancels
/// - Visual feedback: red border on selected pane, status bar instructions
/// - Zoom aware: unzooms on entry, restores on cancel
/// - All pane numbers are 1-based in user-facing output
///
/// These tests call amux CLI commands to verify state transitions.
/// The actual keyboard interception (KeyInput.swift) is tested separately.

enum CmdLScenarioTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // === Scenario 1: Enter pick mode from WORKING ===
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.1")

            amuxCmd(session: ts.name, args: ["split-start"])

            // Visual state should be set
            let selected = tmux("show-options", "-p", "-t", "\(ts.name):.1", "-v", "@amux-split-selected")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("enterFromWorking-splitSelected", selected == "1",
                  "pane 1 should be split-selected, got '\(selected)'")

            let picking = tmux("show-options", "-t", ts.name, "-v", "@amux-picking")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("enterFromWorking-picking", picking == "1",
                  "session should be in picking mode")

            // Label should be 1-based: pane index 1 → display "2"
            let label = tmux("show-options", "-t", ts.name, "-v", "@amux-split-first-label")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("enterFromWorking-label1Based", label.hasPrefix("2"),
                  "label should start with '2' (1-based), got '\(label)'")

            // Should NOT be zoomed
            check("enterFromWorking-notZoomed", !isZoomed(ts.name))

            // Clean up
            amuxCmd(session: ts.name, args: ["split-cancel"])
        }

        // === Scenario 2: Enter pick mode from FULLSCREEN ===
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")
            tmux("resize-pane", "-t", ts.name, "-Z") // zoom in
            check("enterFromFullscreen-preZoomed", isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["split-start"])

            // Should have unzoomed to show the grid
            check("enterFromFullscreen-unzoomed", !isZoomed(ts.name),
                  "split-start should unzoom")

            // Was-zoomed state should be saved
            let wasZoomed = tmux("show-environment", "-t", ts.name, "AMUX_SPLIT_WAS_ZOOMED")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("enterFromFullscreen-wasZoomedSaved", wasZoomed == "AMUX_SPLIT_WAS_ZOOMED=1",
                  "should save was-zoomed state, got '\(wasZoomed)'")

            amuxCmd(session: ts.name, args: ["split-cancel"])
        }

        // === Scenario 3: Cancel from pick mode (was WORKING) ===
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.1")

            amuxCmd(session: ts.name, args: ["split-start"])
            amuxCmd(session: ts.name, args: ["split-cancel"])

            // All visual state should be cleared
            let selected = tmux("show-options", "-p", "-t", "\(ts.name):.1", "-v", "@amux-split-selected")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("cancelFromWorking-cleared", selected != "1",
                  "split-selected should be cleared")

            let picking = tmux("show-options", "-t", ts.name, "-v", "@amux-picking")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("cancelFromWorking-pickingCleared", picking != "1",
                  "picking should be cleared")

            // Should NOT be zoomed (wasn't zoomed before)
            check("cancelFromWorking-notZoomed", !isZoomed(ts.name),
                  "should not zoom after cancel when wasn't zoomed")
        }

        // === Scenario 4: Cancel from pick mode (was FULLSCREEN) ===
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")
            tmux("resize-pane", "-t", ts.name, "-Z") // zoom in

            amuxCmd(session: ts.name, args: ["split-start"])
            check("cancelFromFullscreen-unzoomedDuringPick", !isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["split-cancel"])

            // Should re-zoom (restore previous state)
            check("cancelFromFullscreen-rezoomed", isZoomed(ts.name),
                  "cancel should restore zoom when was zoomed before")
        }

        // === Scenario 5: Pick completes the split ===
        do {
            let ts = TestSession(paneCount: 4)
            tmux("select-pane", "-t", "\(ts.name):.0")

            amuxCmd(session: ts.name, args: ["split-start"])
            amuxCmd(session: ts.name, args: ["split-pick", "1"])

            // Visual state should be cleared
            let picking = tmux("show-options", "-t", ts.name, "-v", "@amux-picking")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("pickCompletes-pickingCleared", picking != "1",
                  "picking should be cleared after pick")

            let selected = tmux("show-options", "-p", "-t", "\(ts.name):.0", "-v", "@amux-split-selected")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("pickCompletes-selectedCleared", selected != "1",
                  "split-selected should be cleared after pick")
        }

        // === Scenario 6: Pane numbers are always 1-based ===
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")

            amuxCmd(session: ts.name, args: ["split-start"])

            // Label for pane 0 should show "1" (1-based)
            let label = tmux("show-options", "-t", ts.name, "-v", "@amux-split-first-label")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("oneBasedNumbers-label", label.hasPrefix("1 "),
                  "pane 0 label should start with '1 ' (1-based), got '\(label)'")

            // Border format should use #{e|+:#{pane_index},1} for 1-based display
            let borderFormat = tmux("show-options", "-gv", "pane-border-format")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("oneBasedNumbers-borderFormat", borderFormat.contains("#{e|+:#{pane_index},1}"),
                  "border format should use 1-based pane numbers")

            // amux list should show 1-based numbers
            let listOutput = amuxCmd(session: ts.name, args: ["list"])
            check("oneBasedNumbers-listOutput", !listOutput.stdout.contains(" 0 "),
                  "amux list should not show pane 0 (should be 1-based)")

            amuxCmd(session: ts.name, args: ["split-cancel"])
        }

        // === Scenario 7: Red border on selected pane ===
        do {
            _ = TestSession(paneCount: 3)

            // Border format should check split-selected BEFORE pane_active
            let borderFormat = tmux("show-options", "-gv", "pane-border-format")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            // split-selected check should appear before pane_active in the format
            let splitSelectedPos = borderFormat.range(of: "@amux-split-selected")?.lowerBound
            let paneActivePos = borderFormat.range(of: "pane_active")?.lowerBound
            check("redBorder-orderMatters",
                  splitSelectedPos != nil && paneActivePos != nil && splitSelectedPos! < paneActivePos!,
                  "split-selected must be checked before pane_active in border format")

            // colour196 (red) should be used for split-selected
            check("redBorder-usesRed", borderFormat.contains("colour196"),
                  "border format should use colour196 (red) for split-selected")
        }

        // === Scenario 8: Status bar shows pick instructions ===
        do {
            let ts = TestSession(paneCount: 3)

            let statusRight = tmux("show-options", "-t", ts.name, "-v", "status-right")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            // Should have picking mode conditional
            check("statusBar-hasPickingMode", statusRight.contains("@amux-picking"),
                  "status bar should check @amux-picking")

            // Should reference the label
            check("statusBar-hasLabel", statusRight.contains("@amux-split-first-label"),
                  "status bar should show split-first-label")

            // Should mention arrow keys in instructions
            check("statusBar-hasArrows", statusRight.contains("←→↑↓"),
                  "status bar should mention arrow key navigation")

            // Should use ⌘ notation
            check("statusBar-usesCmdSymbol", statusRight.contains("⌘"),
                  "status bar should use ⌘ symbol")
        }

        print("CmdLScenarioTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
