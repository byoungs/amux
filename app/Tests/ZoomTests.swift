/// End-to-end zoom transition tests.
///
/// Tests the WORKING (unzoomed) <-> FULL SCREEN (zoomed) cycle via the amux CLI
/// binary, verifying tmux's window_zoomed_flag is the single source of truth.
///
/// Ported from tests/zoom_test.rs.

enum ZoomTests {
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

        // ============================================================
        // Zoom-in / zoom-out cycle
        // ============================================================

        // Test: zoom_in_from_working_to_fullscreen
        do {
            let ts = TestSession(paneCount: 3)
            check("zoomIn-startsUnzoomed", !isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("zoomIn-activatesZoom",
                  isZoomed(ts.name),
                  "zoom-in should activate tmux zoom")

            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("zoomIn-alreadyZoomedIsNoop",
                  isZoomed(ts.name),
                  "zoom-in when zoomed should stay zoomed")
        }

        // Test: zoom_out_from_fullscreen_to_working
        do {
            let ts = TestSession(paneCount: 3)
            tmux("resize-pane", "-t", ts.name, "-Z")
            check("zoomOut-startsZoomed", isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["zoom-out"])
            check("zoomOut-deactivatesZoom",
                  !isZoomed(ts.name),
                  "zoom-out should deactivate tmux zoom")
        }

        // Test: full_cycle_in_out
        do {
            let ts = TestSession(paneCount: 3)

            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("fullCycle-zoomIn", isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["zoom-out"])
            check("fullCycle-zoomOut", !isZoomed(ts.name))
        }

        // ============================================================
        // Ctrl-N (context-aware zoom to pane)
        // ============================================================

        // Test: zoom_to_pane_from_working_same_pane_goes_to_fullscreen
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.1")

            amuxCmd(session: ts.name, args: ["zoom", "1"])
            check("zoomSamePaneAtWorking-zooms",
                  isZoomed(ts.name),
                  "same pane at working should zoom in")
        }

        // Test: zoom_different_pane_at_working_stays_working
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")

            amuxCmd(session: ts.name, args: ["zoom", "1"])
            check("zoomDiffPaneAtWorking-switchesPane",
                  activePane(ts.name) == 1,
                  "should switch to pane 1, got \(activePane(ts.name))")
            check("zoomDiffPaneAtWorking-staysUnzoomed",
                  !isZoomed(ts.name),
                  "different pane should stay unzoomed")
        }

        // Test: zoom_different_pane_at_fullscreen_goes_to_working
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")
            tmux("resize-pane", "-t", ts.name, "-Z")

            amuxCmd(session: ts.name, args: ["zoom", "1"])
            check("zoomDiffPaneAtFullscreen-switchesPane",
                  activePane(ts.name) == 1,
                  "should switch to pane 1, got \(activePane(ts.name))")
            check("zoomDiffPaneAtFullscreen-unzooms",
                  !isZoomed(ts.name),
                  "different pane should unzoom")
        }

        // ============================================================
        // Zoom state stays consistent through rapid transitions
        // ============================================================

        // Test: zoom_flag_stays_consistent_through_rapid_transitions
        do {
            let ts = TestSession(paneCount: 3)

            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("rapidTransitions-1-zoomed", isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["zoom-out"])
            check("rapidTransitions-2-unzoomed", !isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("rapidTransitions-3-zoomed", isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["zoom-out"])
            check("rapidTransitions-4-unzoomed", !isZoomed(ts.name))
        }

        // ============================================================
        // Zoom to nonexistent pane
        // ============================================================

        // Test: zoom_nonexistent_pane_at_working_is_noop
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")

            let output = amuxCmd(session: ts.name, args: ["zoom", "6"])
            check("zoomNonexistentAtWorking-succeeds", output.success)
            check("zoomNonexistentAtWorking-paneUnchanged",
                  activePane(ts.name) == 0,
                  "active pane should not change, got \(activePane(ts.name))")
            check("zoomNonexistentAtWorking-staysUnzoomed",
                  !isZoomed(ts.name),
                  "should not be zoomed")
        }

        // Test: zoom_nonexistent_pane_at_fullscreen_preserves_zoom
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")
            tmux("resize-pane", "-t", ts.name, "-Z")

            let output = amuxCmd(session: ts.name, args: ["zoom", "6"])
            check("zoomNonexistentAtFullscreen-succeeds", output.success)
            check("zoomNonexistentAtFullscreen-staysZoomed",
                  isZoomed(ts.name),
                  "should remain zoomed")
            check("zoomNonexistentAtFullscreen-paneUnchanged",
                  activePane(ts.name) == 0,
                  "active pane should not change, got \(activePane(ts.name))")
        }

        // ============================================================
        // Regression: zoom-out must unzoom even after desync
        // ============================================================

        // Test: zoom_out_unzooms_even_if_desync
        do {
            let ts = TestSession(paneCount: 3)

            // Zoom in via tmux directly (simulating any path that results in zoom)
            tmux("resize-pane", "-t", ts.name, "-Z")
            check("zoomOutDesync-startsZoomed", isZoomed(ts.name))

            amuxCmd(session: ts.name, args: ["zoom-out"])
            check("zoomOutDesync-unzooms",
                  !isZoomed(ts.name),
                  "zoom-out must unzoom when tmux is zoomed, regardless of how we got here")
        }

        // ============================================================
        // Relayout zoom reconciliation
        // ============================================================

        // Test: resize_relayout_while_zoomed_preserves_zoom
        do {
            let ts = TestSession(paneCount: 3)

            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("resizeRelayoutWhileZoomed-startsZoomed", isZoomed(ts.name))

            // Resize relayout should preserve zoom
            amuxCmd(session: ts.name, args: ["layout", ts.name])
            check("resizeRelayoutWhileZoomed-staysZoomed",
                  isZoomed(ts.name),
                  "resize while zoomed should stay zoomed")

            amuxCmd(session: ts.name, args: ["zoom-out"])
            check("resizeRelayoutWhileZoomed-zoomOutWorks",
                  !isZoomed(ts.name),
                  "should be unzoomed after zoom-out")
        }

        // Test: add_relayout_while_zoomed_unzooms
        do {
            let ts = TestSession(paneCount: 3)
            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("addRelayoutWhileZoomed-startsZoomed", isZoomed(ts.name))

            // Simulate AddPane: create a pane then call layout
            tmux("split-window", "-t", ts.name, "-d")
            amuxCmd(session: ts.name, args: ["layout", ts.name])

            check("addRelayoutWhileZoomed-unzooms",
                  !isZoomed(ts.name),
                  "add while zoomed should unzoom")
        }

        // ============================================================
        // Pane cycling (pane-next / pane-prev)
        // ============================================================

        // Test: pane_next_at_working_cycles_through_panes
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")

            amuxCmd(session: ts.name, args: ["pane-next"])
            check("paneNextAtWorking-movesToPane1",
                  activePane(ts.name) == 1,
                  "should move to pane 1, got \(activePane(ts.name))")
            check("paneNextAtWorking-staysUnzoomed",
                  !isZoomed(ts.name),
                  "should stay unzoomed")

            amuxCmd(session: ts.name, args: ["pane-next"])
            check("paneNextAtWorking-movesToPane2",
                  activePane(ts.name) == 2,
                  "should move to pane 2, got \(activePane(ts.name))")

            // Wrap around
            amuxCmd(session: ts.name, args: ["pane-next"])
            check("paneNextAtWorking-wrapsToPane0",
                  activePane(ts.name) == 0,
                  "should wrap to pane 0, got \(activePane(ts.name))")
        }

        // Test: pane_prev_at_working_cycles_backward
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")

            amuxCmd(session: ts.name, args: ["pane-prev"])
            check("panePrevAtWorking-wrapsToPane2",
                  activePane(ts.name) == 2,
                  "should wrap to pane 2, got \(activePane(ts.name))")
            check("panePrevAtWorking-staysUnzoomed",
                  !isZoomed(ts.name),
                  "should stay unzoomed")

            amuxCmd(session: ts.name, args: ["pane-prev"])
            check("panePrevAtWorking-movesToPane1",
                  activePane(ts.name) == 1,
                  "should move to pane 1, got \(activePane(ts.name))")
        }

        // Test: pane_next_at_fullscreen_cycles_while_zoomed
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")
            tmux("resize-pane", "-t", ts.name, "-Z")

            amuxCmd(session: ts.name, args: ["pane-next"])
            check("paneNextAtFullscreen-movesToPane1",
                  activePane(ts.name) == 1,
                  "should move to pane 1, got \(activePane(ts.name))")
            check("paneNextAtFullscreen-staysZoomed",
                  isZoomed(ts.name),
                  "should still be zoomed")
        }

        // Test: pane_prev_at_fullscreen_cycles_while_zoomed
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name):.0")
            tmux("resize-pane", "-t", ts.name, "-Z")

            amuxCmd(session: ts.name, args: ["pane-prev"])
            check("panePrevAtFullscreen-wrapsToPane2",
                  activePane(ts.name) == 2,
                  "should wrap to pane 2, got \(activePane(ts.name))")
            check("panePrevAtFullscreen-staysZoomed",
                  isZoomed(ts.name),
                  "should still be zoomed")
        }

        // ============================================================
        // Bug: Zoom desync -- create pane while zoomed
        // ============================================================

        // Test: create_pane_while_zoomed_unzooms
        do {
            let ts = TestSession(paneCount: 3)

            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("createPaneWhileZoomed-startsZoomed", isZoomed(ts.name))

            // Create a new pane while zoomed -- tmux unzooms on split
            tmux("split-window", "-t", ts.name, "-d")
            check("createPaneWhileZoomed-unzooms",
                  !isZoomed(ts.name),
                  "should unzoom after pane creation")

            check("createPaneWhileZoomed-hasFourPanes",
                  paneCount(ts.name) == 4,
                  "expected 4 panes, got \(paneCount(ts.name))")
        }

        // Test: kill_pane_while_zoomed_unzooms
        do {
            let ts = TestSession(paneCount: 3)

            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("killPaneWhileZoomed-startsZoomed", isZoomed(ts.name))

            tmux("kill-pane", "-t", "\(ts.name):.1")
            check("killPaneWhileZoomed-unzooms",
                  !isZoomed(ts.name),
                  "should unzoom after pane kill")
            check("killPaneWhileZoomed-hasTwoPanes",
                  paneCount(ts.name) == 2,
                  "expected 2 panes, got \(paneCount(ts.name))")
        }

        // Test: zoom_out_after_create_and_exit_works
        do {
            let ts = TestSession(paneCount: 3)

            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("zoomOutAfterCreateAndExit-startsZoomed", isZoomed(ts.name))

            // Create pane (simulates Ctrl-N) -- tmux unzooms on split
            tmux("split-window", "-t", ts.name, "-d")
            check("zoomOutAfterCreateAndExit-unzoomsOnCreate", !isZoomed(ts.name))

            // Kill the new pane (simulates shell exit)
            tmux("kill-pane", "-t", "\(ts.name):.3")
            check("zoomOutAfterCreateAndExit-staysUnzoomedAfterKill", !isZoomed(ts.name))

            // Zoom in -- should work correctly
            amuxCmd(session: ts.name, args: ["zoom-in"])
            check("zoomOutAfterCreateAndExit-zoomInWorks", isZoomed(ts.name))

            // And zoom out -- THIS was the broken path before the fix
            amuxCmd(session: ts.name, args: ["zoom-out"])
            check("zoomOutAfterCreateAndExit-zoomOutWorks",
                  !isZoomed(ts.name),
                  "zoom-out should unzoom")
        }

        print("Zoom tests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
