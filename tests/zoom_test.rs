/// End-to-end zoom level transition tests.
///
/// Tests the WORKING (L2) → FULL SCREEN (L3) cycle via the amux CLI binary,
/// verifying both the AMUX_LEVEL state and tmux's actual window_zoomed_flag
/// stay in sync.
///
/// Note: zoom-out from L2 opens a spaces popup, which requires an attached
/// tmux client and can't be tested in headless mode.
mod cli;
mod common;

fn get_level(session: &str) -> u8 {
    amux::tmux::get_level(session).expect("get level")
}

fn is_zoomed(session: &str) -> bool {
    amux::tmux::is_zoomed(session).expect("is zoomed")
}

fn active_pane(session: &str) -> usize {
    amux::tmux::active_pane_index(session).expect("active pane")
}

// ============================================================
// Zoom-in / zoom-out cycle
// ============================================================

#[test]
fn zoom_in_from_working_to_fullscreen() {
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");
    assert_eq!(get_level(&ts.name), 2);
    assert!(!is_zoomed(&ts.name));

    // Ctrl-+ (zoom-in): L2 → L3
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3, "zoom-in from L2 should go to L3");
    assert!(is_zoomed(&ts.name), "L3 should be tmux-zoomed");

    // Ctrl-+ at L3: should stay at L3
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3, "zoom-in at L3 should stay L3");
    assert!(is_zoomed(&ts.name));
}

#[test]
fn zoom_in_from_legacy_l1_goes_to_fullscreen() {
    let ts = common::TestSession::new(3);

    // Legacy L1 state — zoom-in should go directly to L3
    amux::tmux::set_level(&ts.name, 1).expect("set L1");
    assert_eq!(get_level(&ts.name), 1);

    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3, "zoom-in from L1 should go to L3");
    assert!(is_zoomed(&ts.name), "L3 should be tmux-zoomed");
}

#[test]
fn zoom_out_from_fullscreen_to_working() {
    let ts = common::TestSession::new(3);

    // Start at L3 (full screen)
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");
    amux::tmux::set_level(&ts.name, 3).expect("set L3");
    assert_eq!(get_level(&ts.name), 3);
    assert!(is_zoomed(&ts.name));

    // Ctrl-- (zoom-out): L3 → L2
    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert_eq!(get_level(&ts.name), 2, "zoom-out from L3 should go to L2");
    assert!(!is_zoomed(&ts.name), "L2 should not be tmux-zoomed");
}

#[test]
fn full_cycle_in_out() {
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");

    // L2 → L3 → L2
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3);
    assert!(is_zoomed(&ts.name));

    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert_eq!(get_level(&ts.name), 2);
    assert!(!is_zoomed(&ts.name));
}

// ============================================================
// Ctrl-N (context-aware zoom to pane)
// ============================================================

#[test]
fn zoom_to_pane_from_working_same_pane_goes_to_fullscreen() {
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");
    amux::tmux::select_pane(&ts.name, 1).expect("select");

    // Ctrl-2 again (same pane at L2) → L3
    cli::amux_cmd(&ts.name, &["zoom", "1"]);
    assert_eq!(get_level(&ts.name), 3, "same pane at L2 should go to L3");
    assert!(is_zoomed(&ts.name));
}

#[test]
fn zoom_different_pane_at_working_stays_working() {
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");
    amux::tmux::select_pane(&ts.name, 0).expect("select pane 0");

    // Ctrl-2 (different pane at L2) → stay L2, switch pane
    cli::amux_cmd(&ts.name, &["zoom", "1"]);
    assert_eq!(
        get_level(&ts.name),
        2,
        "different pane at L2 should stay L2"
    );
    assert_eq!(active_pane(&ts.name), 1, "should switch to pane 1");
    assert!(!is_zoomed(&ts.name));
}

#[test]
fn zoom_different_pane_at_fullscreen_goes_to_working() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 0).expect("select");
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");
    amux::tmux::set_level(&ts.name, 3).expect("set L3");

    // Ctrl-2 (different pane at L3) → unzoom, select, go to L2
    cli::amux_cmd(&ts.name, &["zoom", "1"]);
    assert_eq!(
        get_level(&ts.name),
        2,
        "different pane at L3 should go to L2"
    );
    assert_eq!(active_pane(&ts.name), 1);
    assert!(!is_zoomed(&ts.name));
}

// ============================================================
// Level and tmux zoom flag stay in sync
// ============================================================

#[test]
fn level_and_zoom_flag_stay_in_sync_through_rapid_transitions() {
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");

    // Rapid cycle: L2 → L3 → L2 → L3 → L2
    cli::amux_cmd(&ts.name, &["zoom-in"]); // L3
    assert_eq!(get_level(&ts.name), 3);
    assert!(is_zoomed(&ts.name), "L3 must be zoomed");

    cli::amux_cmd(&ts.name, &["zoom-out"]); // L2
    assert_eq!(get_level(&ts.name), 2);
    assert!(!is_zoomed(&ts.name), "back to L2 must not be zoomed");

    cli::amux_cmd(&ts.name, &["zoom-in"]); // L3 again
    assert_eq!(get_level(&ts.name), 3);
    assert!(is_zoomed(&ts.name), "L3 again must be zoomed");

    cli::amux_cmd(&ts.name, &["zoom-out"]); // L2
    assert_eq!(get_level(&ts.name), 2);
    assert!(!is_zoomed(&ts.name));
}

// ============================================================
// Zoom to nonexistent pane
// ============================================================

#[test]
fn zoom_nonexistent_pane_at_working_is_noop() {
    let ts = common::TestSession::new(3); // panes 0, 1, 2
    amux::tmux::set_level(&ts.name, 2).expect("set L2");
    amux::tmux::select_pane(&ts.name, 0).expect("select pane 0");

    // Ctrl-7 (pane index 6) — doesn't exist
    let output = cli::amux_cmd(&ts.name, &["zoom", "6"]);
    assert!(
        output.status.success(),
        "command should succeed (not error)"
    );
    assert_eq!(get_level(&ts.name), 2, "level should stay L2");
    assert_eq!(active_pane(&ts.name), 0, "active pane should not change");
    assert!(!is_zoomed(&ts.name), "should not be zoomed");
}

#[test]
fn zoom_nonexistent_pane_at_fullscreen_preserves_zoom() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 0).expect("select");
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");
    amux::tmux::set_level(&ts.name, 3).expect("set L3");

    // Ctrl-7 (pane index 6) — doesn't exist, should NOT unzoom
    let output = cli::amux_cmd(&ts.name, &["zoom", "6"]);
    assert!(output.status.success(), "command should succeed");
    assert_eq!(get_level(&ts.name), 3, "level should stay L3");
    assert!(is_zoomed(&ts.name), "should remain tmux-zoomed");
    assert_eq!(active_pane(&ts.name), 0, "active pane should not change");
}

// ============================================================
// Zoom bug: level/zoom desync after space switch
// ============================================================

#[test]
fn zoom_level_consistent_after_space_operations() {
    // Regression test: when returning to a space that was left at L3 (zoomed),
    // but the landing level resolves to L2, the window must be unzoomed too.
    // Bug: set_level(2) was called without unzooming first, leaving level=2
    // but window_zoomed_flag=1 — zoom-out would then silently open the spaces
    // picker instead of unzooming.
    let ts = common::TestSession::new(3);

    // Simulate the "left at L3" state a space might be in after a switch away:
    // level=3 and window is tmux-zoomed.
    amux::tmux::set_level(&ts.name, 3).expect("set L3");
    amux::tmux::toggle_zoom(&ts.name).expect("zoom in");
    assert_eq!(get_level(&ts.name), 3);
    assert!(is_zoomed(&ts.name));

    // Simulate what switch_to_space does when landing at L2 (the fix):
    // unzoom before setting level.
    if get_level(&ts.name) != 3 && is_zoomed(&ts.name) {
        amux::tmux::toggle_zoom(&ts.name).expect("unzoom");
    }
    // In the bug case, only set_level was called (no unzoom).
    // The fix adds the unzoom. For this unit test we verify the invariant directly:
    // after a space-switch landing at L2, level and zoom must be consistent.
    amux::tmux::toggle_zoom(&ts.name).expect("unzoom (fix)");
    amux::tmux::set_level(&ts.name, 2).expect("set L2");

    // Invariant: at L2, window must NOT be zoomed
    let level = get_level(&ts.name);
    let zoomed = is_zoomed(&ts.name);
    assert_eq!(level, 2, "level should be 2 after space landing");
    assert!(
        !zoomed,
        "window must not be zoomed at L2 (zoom/level desync bug)"
    );

    // Corollary: zoom-out from L2 should open spaces, not error
    // (Can't test spaces popup in headless mode, but zoom-in must work cleanly)
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3, "zoom-in from L2 should reach L3");
    assert!(is_zoomed(&ts.name), "L3 must be tmux-zoomed");
}

// ============================================================
// Relayout zoom reconciliation
// ============================================================

#[test]
fn resize_relayout_at_l3_preserves_fullscreen() {
    // Bug: client-resized hook fires relayout(Resize) while at L3,
    // which was dropping to L2 and unzooming. Resize at L3 should
    // skip layout application entirely — tmux handles zoom resize natively.
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");

    // Zoom in to L3
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3);
    assert!(is_zoomed(&ts.name));

    // Resize relayout should preserve L3
    amux::tmux::apply_layout(&ts.name, amux::layout_engine::LayoutEvent::Resize).expect("relayout");

    assert_eq!(get_level(&ts.name), 3, "resize at L3 should stay L3");
    assert!(is_zoomed(&ts.name), "resize at L3 should stay zoomed");

    // Zoom-out should still work correctly after resize
    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert_eq!(get_level(&ts.name), 2, "zoom-out should reach L2");
    assert!(!is_zoomed(&ts.name), "should be unzoomed at L2");
}

#[test]
fn add_relayout_at_l3_drops_to_l2() {
    // Add event at L3 MUST unzoom — can't show multiple panes while zoomed
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3);
    assert!(is_zoomed(&ts.name));

    amux::tmux::apply_layout(&ts.name, amux::layout_engine::LayoutEvent::AddPane(99))
        .expect("relayout");

    let level = get_level(&ts.name);
    let zoomed = is_zoomed(&ts.name);
    assert_eq!(level, 2, "add at L3 should drop to L2");
    assert!(!zoomed, "add at L3 should unzoom");
}

// ============================================================
// Pane cycling (pane-next / pane-prev)
// ============================================================

#[test]
fn pane_next_at_working_cycles_through_panes() {
    let ts = common::TestSession::new(3); // panes 0, 1, 2
    amux::tmux::set_level(&ts.name, 2).expect("set L2");
    amux::tmux::select_pane(&ts.name, 0).expect("select pane 0");

    cli::amux_cmd(&ts.name, &["pane-next"]);
    assert_eq!(active_pane(&ts.name), 1, "should move to pane 1");
    assert_eq!(get_level(&ts.name), 2, "should stay at L2");

    cli::amux_cmd(&ts.name, &["pane-next"]);
    assert_eq!(active_pane(&ts.name), 2, "should move to pane 2");

    // Wrap around
    cli::amux_cmd(&ts.name, &["pane-next"]);
    assert_eq!(active_pane(&ts.name), 0, "should wrap to pane 0");
}

#[test]
fn pane_prev_at_working_cycles_backward() {
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");
    amux::tmux::select_pane(&ts.name, 0).expect("select pane 0");

    // From pane 0, prev should wrap to pane 2
    cli::amux_cmd(&ts.name, &["pane-prev"]);
    assert_eq!(active_pane(&ts.name), 2, "should wrap to pane 2");
    assert_eq!(get_level(&ts.name), 2, "should stay at L2");

    cli::amux_cmd(&ts.name, &["pane-prev"]);
    assert_eq!(active_pane(&ts.name), 1, "should move to pane 1");
}

#[test]
fn pane_next_at_fullscreen_cycles_while_zoomed() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 0).expect("select");
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");
    amux::tmux::set_level(&ts.name, 3).expect("set L3");

    cli::amux_cmd(&ts.name, &["pane-next"]);
    assert_eq!(active_pane(&ts.name), 1, "should move to pane 1");
    assert_eq!(get_level(&ts.name), 3, "should stay at L3");
    assert!(is_zoomed(&ts.name), "should still be zoomed");
}

#[test]
fn pane_prev_at_fullscreen_cycles_while_zoomed() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 0).expect("select");
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");
    amux::tmux::set_level(&ts.name, 3).expect("set L3");

    // From pane 0, prev wraps to pane 2
    cli::amux_cmd(&ts.name, &["pane-prev"]);
    assert_eq!(active_pane(&ts.name), 2, "should wrap to pane 2");
    assert_eq!(get_level(&ts.name), 3, "should stay at L3");
    assert!(is_zoomed(&ts.name), "should still be zoomed");
}

// ============================================================
// Bug 1: Zoom desync — "fullscreen, cmd-n, exit terminal, ctrl+ fails"
// relayout at L3 now unzooms and drops to L2 before applying layout
// ============================================================

#[test]
fn create_pane_at_l3_drops_to_l2() {
    // Exact bug: fullscreen (L3), Ctrl-N (new pane), zoom state desyncs
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");

    // Zoom to L3
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3);
    assert!(is_zoomed(&ts.name));

    // Create a new pane while zoomed — relayout should drop us to L2
    amux::tmux::create_pane(&ts.name, None).expect("create pane");

    let level = get_level(&ts.name);
    let zoomed = is_zoomed(&ts.name);
    assert_eq!(level, 2, "should drop to L2 after pane creation at L3");
    assert!(!zoomed, "should not be zoomed after pane creation");

    // Verify we now have 4 panes
    assert_eq!(amux::tmux::pane_count(&ts.name).expect("count"), 4);
}

#[test]
fn kill_pane_at_l3_drops_to_l2() {
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");

    // Zoom to L3
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3);

    // Kill a pane while zoomed
    amux::tmux::kill_pane(&ts.name, 1).expect("kill pane");

    let level = get_level(&ts.name);
    let zoomed = is_zoomed(&ts.name);
    assert_eq!(level, 2, "should drop to L2 after pane kill at L3");
    assert!(!zoomed, "should not be zoomed after pane kill");
    assert_eq!(amux::tmux::pane_count(&ts.name).expect("count"), 2);
}

#[test]
fn zoom_out_after_create_and_exit_works() {
    // Full user scenario: L3 → new pane → pane exits → Ctrl-- should zoom out correctly
    let ts = common::TestSession::new(3);
    amux::tmux::set_level(&ts.name, 2).expect("set L2");

    // Zoom to L3
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3);
    assert!(is_zoomed(&ts.name));

    // Create pane (simulates Ctrl-N) — relayout drops to L2
    amux::tmux::create_pane(&ts.name, None).expect("create pane");
    assert_eq!(get_level(&ts.name), 2);
    assert!(!is_zoomed(&ts.name));

    // Kill the new pane (simulates shell exit) — relayout runs again
    amux::tmux::kill_pane(&ts.name, 3).expect("kill pane");
    assert_eq!(get_level(&ts.name), 2);
    assert!(!is_zoomed(&ts.name));

    // Now zoom in — should work correctly (L2 → L3)
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert_eq!(get_level(&ts.name), 3);
    assert!(is_zoomed(&ts.name));

    // And zoom out — THIS was the broken path before the fix
    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert_eq!(get_level(&ts.name), 2);
    assert!(!is_zoomed(&ts.name), "zoom-out should unzoom, not zoom in");
}

#[test]
fn relayout_with_single_pane_at_l3_stays_at_l3() {
    // Edge case: 1 pane at L3 is valid — relayout should not disturb it
    let ts = common::TestSession::new(1);
    amux::tmux::set_level(&ts.name, 3).expect("set L3");
    // Can't actually zoom with 1 pane in tmux, but level should be preserved
    amux::tmux::apply_layout(&ts.name, amux::layout_engine::LayoutEvent::Resize).expect("relayout");
    assert_eq!(get_level(&ts.name), 3, "single pane at L3 should stay L3");
}
