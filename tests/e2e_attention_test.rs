/// End-to-end attention management tests.
///
/// These tests exercise the FULL pipeline — CLI binary, tmux hooks, subprocess
/// context — not just library functions. They catch integration bugs like:
/// - Wrong pane targeting from subprocess context
/// - Missing session name in hook commands
/// - Zoom→dismiss wiring gaps
///
/// Each test creates a real tmux session, runs real commands, and verifies
/// tmux state. Tests are independent and clean up after themselves.
use std::process::Command;

fn session_name() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let id = COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("amux-e2e-{}-{}", std::process::id(), id)
}

fn cleanup(session: &str) {
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", session])
        .output();
}

/// Get the amux binary path (uses cargo-built binary).
fn amux_bin() -> String {
    // Use the debug binary from cargo build
    let manifest = env!("CARGO_MANIFEST_DIR");
    format!("{}/target/debug/amux", manifest)
}

/// Create a test session with config applied and N panes.
fn setup_session(session: &str, pane_count: usize) {
    amux::tmux::create_session(session).expect("create session");
    amux::config::apply_config(session).expect("apply config");
    for _ in 1..pane_count {
        amux::tmux::create_pane(session, None).expect("create pane");
    }
    // Select pane 0 as active
    amux::tmux::select_pane(session, 0).expect("select pane 0");
}

/// Read @amux-alert for a pane.
fn get_alert(session: &str, pane: usize) -> bool {
    amux::tmux::get_alert(session, pane).unwrap_or(false)
}

/// Read @amux-alert-count for a session.
fn get_alert_count(session: &str) -> usize {
    amux::tmux::get_alert_count(session).unwrap_or(0)
}

/// Get the pane ID (%N) for a given pane index.
fn pane_id(session: &str, index: usize) -> String {
    let output = Command::new("tmux")
        .args([
            "display-message",
            "-t",
            &format!("{}:.{}", session, index),
            "-p",
            "#{pane_id}",
        ])
        .output()
        .expect("get pane_id");
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

// ============================================================
// CLI binary tests — run `amux alert-pane` as a subprocess
// ============================================================

#[test]
fn cli_alert_pane_sets_alert_on_non_active_pane() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);

    // Run alert-pane via CLI binary (how the hook calls it)
    let status = Command::new(amux_bin())
        .env("AMUX_SESSION", &session)
        .args(["alert-pane", "1"])
        .status()
        .expect("run amux alert-pane");
    assert!(status.success(), "amux alert-pane should succeed");

    assert!(get_alert(&session, 1), "pane 1 should be alerted");
    assert!(
        !get_alert(&session, 0),
        "pane 0 (active) should not be alerted"
    );
    assert!(!get_alert(&session, 2), "pane 2 should not be alerted");
    assert_eq!(get_alert_count(&session), 1);

    cleanup(&session);
}

#[test]
fn cli_alert_pane_skips_active_pane_when_terminal_frontmost() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 2);

    // Pane 0 is active. Whether it gets skipped depends on whether
    // the terminal is frontmost (which it usually is during tests).
    let status = Command::new(amux_bin())
        .env("AMUX_SESSION", &session)
        .args(["alert-pane", "0"])
        .status()
        .expect("run amux alert-pane");
    assert!(status.success());

    // If terminal is frontmost, active pane should be skipped.
    // If not (user switched apps during test), it would be alerted.
    // We test the common case: terminal is frontmost.
    if amux::notify::is_terminal_frontmost() {
        assert!(
            !get_alert(&session, 0),
            "active pane should not be alerted when terminal is frontmost"
        );
        assert_eq!(get_alert_count(&session), 0);
    }

    cleanup(&session);
}

#[test]
fn cli_alert_pane_allows_active_pane_at_birdeye() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 2);

    // Set level 1 (bird's eye) — "active" pane is just cursor position
    amux::tmux::set_level(&session, 1).expect("set level");

    // Alert pane 0 even though it's active — at L1 this should work
    let status = Command::new(amux_bin())
        .env("AMUX_SESSION", &session)
        .args(["alert-pane", "0"])
        .status()
        .expect("run amux alert-pane");
    assert!(status.success());

    assert!(
        get_alert(&session, 0),
        "at bird's eye, active pane SHOULD be alerted"
    );
    assert_eq!(get_alert_count(&session), 1);

    cleanup(&session);
}

#[test]
fn cli_alert_pane_skips_already_alerted() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 2);

    // Alert pane 1 twice
    Command::new(amux_bin())
        .env("AMUX_SESSION", &session)
        .args(["alert-pane", "1"])
        .status()
        .expect("first alert");
    Command::new(amux_bin())
        .env("AMUX_SESSION", &session)
        .args(["alert-pane", "1"])
        .status()
        .expect("second alert");

    assert!(get_alert(&session, 1));
    assert_eq!(
        get_alert_count(&session),
        1,
        "count should still be 1 after double alert"
    );

    cleanup(&session);
}

// ============================================================
// Hook command simulation — tests the EXACT command from settings.json
// ============================================================

#[test]
fn hook_command_alerts_correct_pane_from_subprocess() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);

    // Select pane 2 as active (simulating user working in pane 2)
    amux::tmux::select_pane(&session, 2).expect("select");

    // Get pane 1's tmux pane ID (like %1576)
    let pane1_id = pane_id(&session, 1);

    // Run the EXACT hook command that Claude Code would run,
    // with $TMUX_PANE set to pane 1's ID (simulating the hook
    // running inside pane 1's shell context)
    let hook_cmd = format!(
        "AMUX_SESSION=$(tmux display-message -t {} -p '#{{session_name}}') {} alert-pane $(tmux display-message -t {} -p '#{{pane_index}}')",
        pane1_id, amux_bin(), pane1_id
    );
    let status = Command::new("sh")
        .args(["-c", &hook_cmd])
        .env("TMUX_PANE", &pane1_id)
        .status()
        .expect("run hook command");
    assert!(status.success(), "hook command should succeed");

    // Pane 1 should be alerted (the hook's pane), NOT pane 2 (active pane)
    assert!(!get_alert(&session, 0), "pane 0 should not be alerted");
    assert!(
        get_alert(&session, 1),
        "pane 1 (hook source) should be alerted"
    );
    assert!(
        !get_alert(&session, 2),
        "pane 2 (active) should not be alerted"
    );

    cleanup(&session);
}

#[test]
fn hook_command_skips_active_pane_when_terminal_frontmost() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 2);

    // Pane 0 is active. Run hook as if it came from pane 0.
    let pane0_id = pane_id(&session, 0);
    let hook_cmd = format!(
        "AMUX_SESSION=$(tmux display-message -t {} -p '#{{session_name}}') {} alert-pane $(tmux display-message -t {} -p '#{{pane_index}}')",
        pane0_id, amux_bin(), pane0_id
    );
    let status = Command::new("sh")
        .args(["-c", &hook_cmd])
        .env("TMUX_PANE", &pane0_id)
        .status()
        .expect("run hook command");
    assert!(status.success());

    // Active pane is only skipped if terminal is frontmost
    if amux::notify::is_terminal_frontmost() {
        assert!(
            !get_alert(&session, 0),
            "active pane should not be alerted when terminal is frontmost"
        );
    }

    cleanup(&session);
}

// ============================================================
// Dismiss via zoom commands — tests the wiring in cmd_zoom
// ============================================================

#[test]
fn zoom_to_alerted_pane_clears_alert() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);

    // Alert pane 1
    amux::tmux::set_alert(&session, 1, true).expect("set");
    amux::tmux::set_alert_count(&session, 1).expect("count");
    assert!(get_alert(&session, 1));

    // Zoom to pane 1 via CLI (simulates Ctrl-2, which calls `amux zoom 1`)
    let status = Command::new(amux_bin())
        .env("AMUX_SESSION", &session)
        .args(["zoom", "1"])
        .status()
        .expect("zoom to pane 1");
    assert!(status.success());

    // Alert should be cleared because focusing pane 1 dismisses it
    assert!(
        !get_alert(&session, 1),
        "alert should clear when pane is focused via zoom"
    );
    assert_eq!(get_alert_count(&session), 0);

    cleanup(&session);
}

#[test]
fn zoom_in_from_birdeye_clears_alert_on_current_pane() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 2);

    // Set to level 1 (bird's eye), alert pane 0
    amux::tmux::set_level(&session, 1).expect("set level");
    amux::tmux::set_alert(&session, 0, true).expect("set");
    amux::tmux::set_alert_count(&session, 1).expect("count");

    // Zoom in (L1 → L2) via CLI — should dismiss alert on current pane
    let status = Command::new(amux_bin())
        .env("AMUX_SESSION", &session)
        .args(["zoom-in"])
        .status()
        .expect("zoom in");
    assert!(status.success());

    assert!(
        !get_alert(&session, 0),
        "zoom-in should clear alert on current pane"
    );
    assert_eq!(get_alert_count(&session), 0);

    cleanup(&session);
}

// ============================================================
// Multi-pane alert lifecycle
// ============================================================

#[test]
fn full_alert_lifecycle_multiple_panes() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 4);

    // Alert panes 1, 2, 3 (pane 0 is active)
    for i in 1..=3 {
        Command::new(amux_bin())
            .env("AMUX_SESSION", &session)
            .args(["alert-pane", &i.to_string()])
            .status()
            .expect("alert");
    }
    assert_eq!(get_alert_count(&session), 3);

    // Dismiss pane 1 by zooming to it
    Command::new(amux_bin())
        .env("AMUX_SESSION", &session)
        .args(["zoom", "1"])
        .status()
        .expect("zoom 1");
    assert!(!get_alert(&session, 1));
    assert_eq!(get_alert_count(&session), 2);

    // Dismiss pane 2
    Command::new(amux_bin())
        .env("AMUX_SESSION", &session)
        .args(["zoom", "2"])
        .status()
        .expect("zoom 2");
    assert!(!get_alert(&session, 2));
    assert_eq!(get_alert_count(&session), 1);

    // Dismiss pane 3
    Command::new(amux_bin())
        .env("AMUX_SESSION", &session)
        .args(["zoom", "3"])
        .status()
        .expect("zoom 3");
    assert!(!get_alert(&session, 3));
    assert_eq!(get_alert_count(&session), 0);

    cleanup(&session);
}

// ============================================================
// pipe-pane setup
// ============================================================

#[test]
fn pipe_pane_active_on_all_panes_after_config() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 3);

    for i in 0..3 {
        let output = Command::new("tmux")
            .args([
                "display-message",
                "-t",
                &format!("{}:.{}", session, i),
                "-p",
                "#{pane_pipe}",
            ])
            .output()
            .expect("check pipe");
        let pipe = String::from_utf8_lossy(&output.stdout).trim().to_string();
        assert_eq!(pipe, "1", "pipe-pane should be active on pane {}", i);
    }

    cleanup(&session);
}

#[test]
fn pipe_pane_active_on_newly_created_pane() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 1);

    // Create a new pane
    amux::tmux::create_pane(&session, None).expect("create pane");

    // Both panes should have pipe-pane active
    for i in 0..2 {
        let output = Command::new("tmux")
            .args([
                "display-message",
                "-t",
                &format!("{}:.{}", session, i),
                "-p",
                "#{pane_pipe}",
            ])
            .output()
            .expect("check pipe");
        let pipe = String::from_utf8_lossy(&output.stdout).trim().to_string();
        assert_eq!(pipe, "1", "pipe-pane should be active on pane {}", i);
    }

    cleanup(&session);
}

// ============================================================
// Config correctness
// ============================================================

#[test]
fn border_format_has_three_states() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 1);

    let output = Command::new("tmux")
        .args(["show-options", "-t", &session, "-v", "pane-border-format"])
        .output()
        .expect("show border format");
    let format = String::from_utf8_lossy(&output.stdout);

    // Must contain all three conditionals
    assert!(format.contains("pane_active"), "should check pane_active");
    assert!(format.contains("@amux-alert"), "should check @amux-alert");
    assert!(format.contains("colour43"), "should have teal for active");
    assert!(format.contains("colour214"), "should have amber for alert");
    assert!(
        format.contains("colour236"),
        "should have dark for inactive"
    );

    cleanup(&session);
}

#[test]
fn status_bar_has_alert_badge() {
    let session = session_name();
    cleanup(&session);
    setup_session(&session, 1);

    let output = Command::new("tmux")
        .args(["show-options", "-t", &session, "-v", "status-right"])
        .output()
        .expect("show status-right");
    let status = String::from_utf8_lossy(&output.stdout);

    assert!(
        status.contains("@amux-alert-count"),
        "should reference alert count"
    );
    assert!(status.contains("⬤"), "should have amber dot character");

    cleanup(&session);
}
