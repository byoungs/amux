/// End-to-end zoom transition tests.
///
/// Tests the WORKING (unzoomed) ↔ FULL SCREEN (zoomed) cycle via the amux CLI
/// binary, verifying tmux's window_zoomed_flag is the single source of truth.
///
/// Note: zoom-out from working opens a spaces popup, which requires an attached
/// tmux client and can't be tested in headless mode.
mod cli;
mod common;

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
    assert!(!is_zoomed(&ts.name));

    // Ctrl-+ (zoom-in): working → full screen
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(is_zoomed(&ts.name), "zoom-in should activate tmux zoom");

    // Ctrl-+ again: already zoomed, no-op
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(
        is_zoomed(&ts.name),
        "zoom-in when zoomed should stay zoomed"
    );
}

#[test]
fn zoom_out_from_fullscreen_to_working() {
    let ts = common::TestSession::new(3);

    // Start zoomed
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");
    assert!(is_zoomed(&ts.name));

    // Ctrl-- (zoom-out): full screen → working
    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert!(!is_zoomed(&ts.name), "zoom-out should deactivate tmux zoom");
}

#[test]
fn full_cycle_in_out() {
    let ts = common::TestSession::new(3);

    // working → full screen → working
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(is_zoomed(&ts.name));

    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert!(!is_zoomed(&ts.name));
}

// ============================================================
// Ctrl-N (context-aware zoom to pane)
// ============================================================

#[test]
fn zoom_to_pane_from_working_same_pane_goes_to_fullscreen() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 1).expect("select");

    // Ctrl-2 again (same pane at working) → full screen
    cli::amux_cmd(&ts.name, &["zoom", "1"]);
    assert!(is_zoomed(&ts.name), "same pane at working should zoom in");
}

#[test]
fn zoom_different_pane_at_working_stays_working() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 0).expect("select pane 0");

    // Ctrl-2 (different pane at working) → stay working, switch pane
    cli::amux_cmd(&ts.name, &["zoom", "1"]);
    assert_eq!(active_pane(&ts.name), 1, "should switch to pane 1");
    assert!(!is_zoomed(&ts.name), "different pane should stay unzoomed");
}

#[test]
fn zoom_different_pane_at_fullscreen_goes_to_working() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 0).expect("select");
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");

    // Ctrl-2 (different pane while zoomed) → unzoom, select
    cli::amux_cmd(&ts.name, &["zoom", "1"]);
    assert_eq!(active_pane(&ts.name), 1);
    assert!(!is_zoomed(&ts.name), "different pane should unzoom");
}

// ============================================================
// Zoom state stays consistent through rapid transitions
// ============================================================

#[test]
fn zoom_flag_stays_consistent_through_rapid_transitions() {
    let ts = common::TestSession::new(3);

    // Rapid cycle: working → zoomed → working → zoomed → working
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(is_zoomed(&ts.name));

    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert!(!is_zoomed(&ts.name));

    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(is_zoomed(&ts.name));

    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert!(!is_zoomed(&ts.name));
}

// ============================================================
// Zoom to nonexistent pane
// ============================================================

#[test]
fn zoom_nonexistent_pane_at_working_is_noop() {
    let ts = common::TestSession::new(3); // panes 0, 1, 2
    amux::tmux::select_pane(&ts.name, 0).expect("select pane 0");

    // Ctrl-7 (pane index 6) — doesn't exist
    let output = cli::amux_cmd(&ts.name, &["zoom", "6"]);
    assert!(output.status.success());
    assert_eq!(active_pane(&ts.name), 0, "active pane should not change");
    assert!(!is_zoomed(&ts.name), "should not be zoomed");
}

#[test]
fn zoom_nonexistent_pane_at_fullscreen_preserves_zoom() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 0).expect("select");
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");

    // Ctrl-7 (pane index 6) — doesn't exist, should NOT unzoom
    let output = cli::amux_cmd(&ts.name, &["zoom", "6"]);
    assert!(output.status.success());
    assert!(is_zoomed(&ts.name), "should remain zoomed");
    assert_eq!(active_pane(&ts.name), 0, "active pane should not change");
}

// ============================================================
// Regression: zoom-out must unzoom even after desync
// ============================================================

#[test]
fn zoom_out_unzooms_even_if_desync() {
    // Regression test for the zoom-in → Ctrl-P → zoom-out bug.
    // The old code had a separate AMUX_LEVEL variable that could desync
    // from tmux's actual zoom state. With AMUX_LEVEL removed, zoom-out
    // always checks window_zoomed_flag directly — desync is impossible.
    //
    // This test simulates the scenario: tmux is zoomed (the user zoomed in),
    // then something external happens (popup, space switch) — zoom-out must
    // still unzoom, never open the spaces picker.
    let ts = common::TestSession::new(3);

    // Zoom in via tmux directly (simulating any path that results in zoom)
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");
    assert!(is_zoomed(&ts.name));

    // zoom-out should see the zoomed flag and unzoom
    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert!(
        !is_zoomed(&ts.name),
        "zoom-out must unzoom when tmux is zoomed, regardless of how we got here"
    );
}

// ============================================================
// Relayout zoom reconciliation
// ============================================================

#[test]
fn resize_relayout_while_zoomed_preserves_zoom() {
    let ts = common::TestSession::new(3);

    // Zoom in
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(is_zoomed(&ts.name));

    // Resize relayout should preserve zoom
    amux::tmux::apply_layout(&ts.name, amux::layout_engine::LayoutEvent::Resize).expect("relayout");
    assert!(
        is_zoomed(&ts.name),
        "resize while zoomed should stay zoomed"
    );

    // Zoom-out should still work correctly after resize
    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert!(!is_zoomed(&ts.name), "should be unzoomed after zoom-out");
}

#[test]
fn add_relayout_while_zoomed_unzooms() {
    // Add event while zoomed MUST unzoom — can't show multiple panes while zoomed
    let ts = common::TestSession::new(3);
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(is_zoomed(&ts.name));

    amux::tmux::apply_layout(&ts.name, amux::layout_engine::LayoutEvent::AddPane(99))
        .expect("relayout");

    assert!(!is_zoomed(&ts.name), "add while zoomed should unzoom");
}

// ============================================================
// Pane cycling (pane-next / pane-prev)
// ============================================================

#[test]
fn pane_next_at_working_cycles_through_panes() {
    let ts = common::TestSession::new(3); // panes 0, 1, 2
    amux::tmux::select_pane(&ts.name, 0).expect("select pane 0");

    cli::amux_cmd(&ts.name, &["pane-next"]);
    assert_eq!(active_pane(&ts.name), 1, "should move to pane 1");
    assert!(!is_zoomed(&ts.name), "should stay unzoomed");

    cli::amux_cmd(&ts.name, &["pane-next"]);
    assert_eq!(active_pane(&ts.name), 2, "should move to pane 2");

    // Wrap around
    cli::amux_cmd(&ts.name, &["pane-next"]);
    assert_eq!(active_pane(&ts.name), 0, "should wrap to pane 0");
}

#[test]
fn pane_prev_at_working_cycles_backward() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 0).expect("select pane 0");

    // From pane 0, prev should wrap to pane 2
    cli::amux_cmd(&ts.name, &["pane-prev"]);
    assert_eq!(active_pane(&ts.name), 2, "should wrap to pane 2");
    assert!(!is_zoomed(&ts.name), "should stay unzoomed");

    cli::amux_cmd(&ts.name, &["pane-prev"]);
    assert_eq!(active_pane(&ts.name), 1, "should move to pane 1");
}

#[test]
fn pane_next_at_fullscreen_cycles_while_zoomed() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 0).expect("select");
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");

    cli::amux_cmd(&ts.name, &["pane-next"]);
    assert_eq!(active_pane(&ts.name), 1, "should move to pane 1");
    assert!(is_zoomed(&ts.name), "should still be zoomed");
}

#[test]
fn pane_prev_at_fullscreen_cycles_while_zoomed() {
    let ts = common::TestSession::new(3);
    amux::tmux::select_pane(&ts.name, 0).expect("select");
    amux::tmux::toggle_zoom(&ts.name).expect("zoom");

    // From pane 0, prev wraps to pane 2
    cli::amux_cmd(&ts.name, &["pane-prev"]);
    assert_eq!(active_pane(&ts.name), 2, "should wrap to pane 2");
    assert!(is_zoomed(&ts.name), "should still be zoomed");
}

// ============================================================
// Bug: Zoom desync — create pane while zoomed
// ============================================================

#[test]
fn create_pane_while_zoomed_unzooms() {
    let ts = common::TestSession::new(3);

    // Zoom in
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(is_zoomed(&ts.name));

    // Create a new pane while zoomed — relayout should unzoom
    amux::tmux::create_pane(&ts.name, None).expect("create pane");
    assert!(!is_zoomed(&ts.name), "should unzoom after pane creation");

    // Verify we now have 4 panes
    assert_eq!(amux::tmux::pane_count(&ts.name).expect("count"), 4);
}

#[test]
fn kill_pane_while_zoomed_unzooms() {
    let ts = common::TestSession::new(3);

    // Zoom in
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(is_zoomed(&ts.name));

    // Kill a pane while zoomed
    amux::tmux::kill_pane(&ts.name, 1).expect("kill pane");
    assert!(!is_zoomed(&ts.name), "should unzoom after pane kill");
    assert_eq!(amux::tmux::pane_count(&ts.name).expect("count"), 2);
}

#[test]
fn zoom_out_after_create_and_exit_works() {
    // Full user scenario: zoomed → new pane → pane exits → zoom-out should work
    let ts = common::TestSession::new(3);

    // Zoom in
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(is_zoomed(&ts.name));

    // Create pane (simulates Ctrl-N) — relayout unzooms
    amux::tmux::create_pane(&ts.name, None).expect("create pane");
    assert!(!is_zoomed(&ts.name));

    // Kill the new pane (simulates shell exit) — relayout runs again
    amux::tmux::kill_pane(&ts.name, 3).expect("kill pane");
    assert!(!is_zoomed(&ts.name));

    // Zoom in — should work correctly
    cli::amux_cmd(&ts.name, &["zoom-in"]);
    assert!(is_zoomed(&ts.name));

    // And zoom out — THIS was the broken path before the fix
    cli::amux_cmd(&ts.name, &["zoom-out"]);
    assert!(!is_zoomed(&ts.name), "zoom-out should unzoom");
}
