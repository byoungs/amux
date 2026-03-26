/// End-to-end zoom level transition tests.
///
/// Tests the full BIRD'S EYE (L1) → WORKING (L2) → FULL SCREEN (L3) cycle
/// via the amux CLI binary, verifying both the AMUX_LEVEL state and tmux's
/// actual window_zoomed_flag stay in sync.
use std::process::Command;

fn session_name() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let id = COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("amux-zoom-{}-{}", std::process::id(), id)
}

fn cleanup(session: &str) {
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", session])
        .output();
}

fn amux_bin() -> String {
    let manifest = env!("CARGO_MANIFEST_DIR");
    format!("{}/target/debug/amux", manifest)
}

fn setup_session(session: &str, pane_count: usize) {
    amux::tmux::create_session(session).expect("create session");
    amux::config::apply_config(session).expect("apply config");
    for _ in 1..pane_count {
        amux::tmux::create_pane(session, None).expect("create pane");
    }
    amux::tmux::apply_grid_layout(session).expect("layout");
    amux::tmux::select_pane(session, 0).expect("select pane 0");
}

/// Run an amux subcommand against a test session.
fn amux_cmd(session: &str, args: &[&str]) -> std::process::Output {
    Command::new(amux_bin())
        .args(args)
        .env("AMUX_SESSION", session)
        .output()
        .expect("amux command failed")
}

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
fn zoom_in_from_birdeye_to_working_to_fullscreen() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);

    // Start at L1 (bird's eye)
    amux::tmux::set_level(&session, 1).expect("set L1");
    assert_eq!(get_level(&session), 1);
    assert!(!is_zoomed(&session));

    // Ctrl-+ (zoom-in): L1 → L2
    amux_cmd(&session, &["zoom-in"]);
    assert_eq!(get_level(&session), 2, "zoom-in from L1 should go to L2");
    assert!(!is_zoomed(&session), "L2 should not be tmux-zoomed");

    // Ctrl-+ (zoom-in): L2 → L3
    amux_cmd(&session, &["zoom-in"]);
    assert_eq!(get_level(&session), 3, "zoom-in from L2 should go to L3");
    assert!(is_zoomed(&session), "L3 should be tmux-zoomed");

    // Ctrl-+ at L3: should stay at L3
    amux_cmd(&session, &["zoom-in"]);
    assert_eq!(get_level(&session), 3, "zoom-in at L3 should stay L3");
    assert!(is_zoomed(&session));

    cleanup(&session);
}

#[test]
fn zoom_out_from_fullscreen_to_working_to_birdeye() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);

    // Start at L3 (full screen)
    amux::tmux::toggle_zoom(&session).expect("zoom");
    amux::tmux::set_level(&session, 3).expect("set L3");
    assert_eq!(get_level(&session), 3);
    assert!(is_zoomed(&session));

    // Ctrl-- (zoom-out): L3 → L2
    amux_cmd(&session, &["zoom-out"]);
    assert_eq!(get_level(&session), 2, "zoom-out from L3 should go to L2");
    assert!(!is_zoomed(&session), "L2 should not be tmux-zoomed");

    // Ctrl-- (zoom-out): L2 → L1
    amux_cmd(&session, &["zoom-out"]);
    assert_eq!(get_level(&session), 1, "zoom-out from L2 should go to L1");
    assert!(!is_zoomed(&session));

    // Ctrl-- at L1: should stay at L1
    amux_cmd(&session, &["zoom-out"]);
    assert_eq!(get_level(&session), 1, "zoom-out at L1 should stay L1");

    cleanup(&session);
}

#[test]
fn full_cycle_in_out() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);

    // L1 → L2 → L3 → L2 → L1
    amux::tmux::set_level(&session, 1).expect("set L1");

    amux_cmd(&session, &["zoom-in"]);
    assert_eq!(get_level(&session), 2);
    assert!(!is_zoomed(&session));

    amux_cmd(&session, &["zoom-in"]);
    assert_eq!(get_level(&session), 3);
    assert!(is_zoomed(&session));

    amux_cmd(&session, &["zoom-out"]);
    assert_eq!(get_level(&session), 2);
    assert!(!is_zoomed(&session));

    amux_cmd(&session, &["zoom-out"]);
    assert_eq!(get_level(&session), 1);
    assert!(!is_zoomed(&session));

    cleanup(&session);
}

// ============================================================
// Ctrl-N (context-aware zoom to pane)
// ============================================================

#[test]
fn zoom_to_pane_from_birdeye_goes_to_working() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);
    amux::tmux::set_level(&session, 1).expect("set L1");

    // Ctrl-2: from L1, zoom to pane 1 → should go to L2
    amux_cmd(&session, &["zoom", "1"]);
    assert_eq!(get_level(&session), 2, "zoom from L1 should go to L2");
    assert_eq!(active_pane(&session), 1, "should select pane 1");
    assert!(!is_zoomed(&session));

    cleanup(&session);
}

#[test]
fn zoom_same_pane_at_working_goes_to_fullscreen() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);
    amux::tmux::set_level(&session, 2).expect("set L2");
    amux::tmux::select_pane(&session, 1).expect("select");

    // Ctrl-2 again (same pane at L2) → L3
    amux_cmd(&session, &["zoom", "1"]);
    assert_eq!(get_level(&session), 3, "same pane at L2 should go to L3");
    assert!(is_zoomed(&session));

    cleanup(&session);
}

#[test]
fn zoom_different_pane_at_working_stays_working() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);
    amux::tmux::set_level(&session, 2).expect("set L2");
    amux::tmux::select_pane(&session, 0).expect("select pane 0");

    // Ctrl-2 (different pane at L2) → stay L2, switch pane
    amux_cmd(&session, &["zoom", "1"]);
    assert_eq!(
        get_level(&session),
        2,
        "different pane at L2 should stay L2"
    );
    assert_eq!(active_pane(&session), 1, "should switch to pane 1");
    assert!(!is_zoomed(&session));

    cleanup(&session);
}

#[test]
fn zoom_different_pane_at_fullscreen_goes_to_working() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);
    amux::tmux::select_pane(&session, 0).expect("select");
    amux::tmux::toggle_zoom(&session).expect("zoom");
    amux::tmux::set_level(&session, 3).expect("set L3");

    // Ctrl-2 (different pane at L3) → unzoom, select, go to L2
    amux_cmd(&session, &["zoom", "1"]);
    assert_eq!(
        get_level(&session),
        2,
        "different pane at L3 should go to L2"
    );
    assert_eq!(active_pane(&session), 1);
    assert!(!is_zoomed(&session));

    cleanup(&session);
}

// ============================================================
// Level and tmux zoom flag stay in sync
// ============================================================

#[test]
fn level_and_zoom_flag_stay_in_sync_through_rapid_transitions() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);
    amux::tmux::set_level(&session, 1).expect("set L1");

    // Rapid cycle: L1 → L2 → L3 → L2 → L3 → L2 → L1
    amux_cmd(&session, &["zoom-in"]); // L2
    assert_eq!(get_level(&session), 2);
    assert!(!is_zoomed(&session), "L2 must not be zoomed");

    amux_cmd(&session, &["zoom-in"]); // L3
    assert_eq!(get_level(&session), 3);
    assert!(is_zoomed(&session), "L3 must be zoomed");

    amux_cmd(&session, &["zoom-out"]); // L2
    assert_eq!(get_level(&session), 2);
    assert!(!is_zoomed(&session), "back to L2 must not be zoomed");

    amux_cmd(&session, &["zoom-in"]); // L3 again
    assert_eq!(get_level(&session), 3);
    assert!(is_zoomed(&session), "L3 again must be zoomed");

    amux_cmd(&session, &["zoom-out"]); // L2
    assert_eq!(get_level(&session), 2);
    assert!(!is_zoomed(&session));

    amux_cmd(&session, &["zoom-out"]); // L1
    assert_eq!(get_level(&session), 1);
    assert!(!is_zoomed(&session));

    cleanup(&session);
}

// ============================================================
// Zoom to nonexistent pane
// ============================================================

#[test]
fn zoom_nonexistent_pane_at_working_is_noop() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3); // panes 0, 1, 2
    amux::tmux::set_level(&session, 2).expect("set L2");
    amux::tmux::select_pane(&session, 0).expect("select pane 0");

    // Ctrl-7 (pane index 6) — doesn't exist
    let output = amux_cmd(&session, &["zoom", "6"]);
    assert!(
        output.status.success(),
        "command should succeed (not error)"
    );
    assert_eq!(get_level(&session), 2, "level should stay L2");
    assert_eq!(active_pane(&session), 0, "active pane should not change");
    assert!(!is_zoomed(&session), "should not be zoomed");

    cleanup(&session);
}

#[test]
fn zoom_nonexistent_pane_at_fullscreen_preserves_zoom() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);
    amux::tmux::select_pane(&session, 0).expect("select");
    amux::tmux::toggle_zoom(&session).expect("zoom");
    amux::tmux::set_level(&session, 3).expect("set L3");

    // Ctrl-7 (pane index 6) — doesn't exist, should NOT unzoom
    let output = amux_cmd(&session, &["zoom", "6"]);
    assert!(output.status.success(), "command should succeed");
    assert_eq!(get_level(&session), 3, "level should stay L3");
    assert!(is_zoomed(&session), "should remain tmux-zoomed");
    assert_eq!(active_pane(&session), 0, "active pane should not change");

    cleanup(&session);
}
