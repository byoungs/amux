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
mod cli;
mod common;

use std::process::Command;

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
    let ts = common::TestSession::new(3);

    // Run alert-pane via CLI binary (how the hook calls it)
    let status = cli::amux_cmd(&ts.name, &["alert-pane", "1"]).status;
    assert!(status.success(), "amux alert-pane should succeed");

    assert!(get_alert(&ts.name, 1), "pane 1 should be alerted");
    assert!(
        !get_alert(&ts.name, 0),
        "pane 0 (active) should not be alerted"
    );
    assert!(!get_alert(&ts.name, 2), "pane 2 should not be alerted");
    assert_eq!(get_alert_count(&ts.name), 1);
}

#[test]
fn cli_alert_pane_skips_active_pane_when_terminal_frontmost() {
    let ts = common::TestSession::new(2);

    // Pane 0 is active. Whether it gets skipped depends on whether
    // the terminal is frontmost (which it usually is during tests).
    let status = cli::amux_cmd(&ts.name, &["alert-pane", "0"]).status;
    assert!(status.success());

    // If terminal is frontmost, active pane should be skipped.
    // If not (user switched apps during test), it would be alerted.
    // We test the common case: terminal is frontmost.
    if amux::notify::is_terminal_frontmost() {
        assert!(
            !get_alert(&ts.name, 0),
            "active pane should not be alerted when terminal is frontmost"
        );
        assert_eq!(get_alert_count(&ts.name), 0);
    }
}

#[test]
fn cli_alert_pane_skips_already_alerted() {
    let ts = common::TestSession::new(2);

    // Alert pane 1 twice
    cli::amux_cmd(&ts.name, &["alert-pane", "1"]);
    cli::amux_cmd(&ts.name, &["alert-pane", "1"]);

    assert!(get_alert(&ts.name, 1));
    assert_eq!(
        get_alert_count(&ts.name),
        1,
        "count should still be 1 after double alert"
    );
}

// ============================================================
// Hook command simulation — tests the EXACT command from settings.json
// ============================================================

#[test]
fn hook_command_alerts_correct_pane_from_subprocess() {
    let ts = common::TestSession::new(3);

    // Select pane 2 as active (simulating user working in pane 2)
    amux::tmux::select_pane(&ts.name, 2).expect("select");

    // Get pane 1's tmux pane ID (like %1576)
    let pane1_id = pane_id(&ts.name, 1);

    // Run the EXACT hook command that Claude Code would run,
    // with $TMUX_PANE set to pane 1's ID (simulating the hook
    // running inside pane 1's shell context)
    let hook_cmd = format!(
        "AMUX_SESSION=$(tmux display-message -t {} -p '#{{session_name}}') {} alert-pane $(tmux display-message -t {} -p '#{{pane_index}}')",
        pane1_id, cli::amux_bin(), pane1_id
    );
    let status = Command::new("sh")
        .args(["-c", &hook_cmd])
        .env("TMUX_PANE", &pane1_id)
        .status()
        .expect("run hook command");
    assert!(status.success(), "hook command should succeed");

    // Pane 1 should be alerted (the hook's pane), NOT pane 2 (active pane)
    assert!(!get_alert(&ts.name, 0), "pane 0 should not be alerted");
    assert!(
        get_alert(&ts.name, 1),
        "pane 1 (hook source) should be alerted"
    );
    assert!(
        !get_alert(&ts.name, 2),
        "pane 2 (active) should not be alerted"
    );
}

#[test]
fn hook_command_skips_active_pane_when_terminal_frontmost() {
    let ts = common::TestSession::new(2);

    // Pane 0 is active. Run hook as if it came from pane 0.
    let pane0_id = pane_id(&ts.name, 0);
    let hook_cmd = format!(
        "AMUX_SESSION=$(tmux display-message -t {} -p '#{{session_name}}') {} alert-pane $(tmux display-message -t {} -p '#{{pane_index}}')",
        pane0_id, cli::amux_bin(), pane0_id
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
            !get_alert(&ts.name, 0),
            "active pane should not be alerted when terminal is frontmost"
        );
    }
}

// ============================================================
// Dismiss via zoom commands — tests the wiring in cmd_zoom
// ============================================================

#[test]
fn zoom_to_alerted_pane_clears_alert() {
    let ts = common::TestSession::new(3);

    // Alert pane 1
    amux::tmux::set_alert(&ts.name, 1, true).expect("set");
    amux::tmux::set_alert_count(&ts.name, 1).expect("count");
    assert!(get_alert(&ts.name, 1));

    // Zoom to pane 1 via CLI (simulates Ctrl-2, which calls `amux zoom 1`)
    let status = cli::amux_cmd(&ts.name, &["zoom", "1"]).status;
    assert!(status.success());

    // Alert should be cleared because focusing pane 1 dismisses it
    assert!(
        !get_alert(&ts.name, 1),
        "alert should clear when pane is focused via zoom"
    );
    assert_eq!(get_alert_count(&ts.name), 0);
}

#[test]
fn zoom_in_clears_alert_on_current_pane() {
    let ts = common::TestSession::new(2);

    // Alert pane 0 (working/unzoomed state)
    amux::tmux::set_alert(&ts.name, 0, true).expect("set");
    amux::tmux::set_alert_count(&ts.name, 1).expect("count");

    // Zoom in (L2 → L3) via CLI — should dismiss alert on current pane
    let status = cli::amux_cmd(&ts.name, &["zoom-in"]).status;
    assert!(status.success());

    assert!(
        !get_alert(&ts.name, 0),
        "zoom-in should clear alert on current pane"
    );
    assert_eq!(get_alert_count(&ts.name), 0);
}

// ============================================================
// Multi-pane alert lifecycle
// ============================================================

#[test]
fn full_alert_lifecycle_multiple_panes() {
    let ts = common::TestSession::new(4);

    // Alert panes 1, 2, 3 (pane 0 is active)
    for i in 1..=3 {
        let status = cli::amux_cmd(&ts.name, &["alert-pane", &i.to_string()]).status;
        assert!(status.success(), "alert pane {} should succeed", i);
    }
    assert_eq!(get_alert_count(&ts.name), 3);

    // Dismiss pane 1 by zooming to it
    cli::amux_cmd(&ts.name, &["zoom", "1"]).status;
    assert!(!get_alert(&ts.name, 1));
    assert_eq!(get_alert_count(&ts.name), 2);

    // Dismiss pane 2
    cli::amux_cmd(&ts.name, &["zoom", "2"]).status;
    assert!(!get_alert(&ts.name, 2));
    assert_eq!(get_alert_count(&ts.name), 1);

    // Dismiss pane 3
    cli::amux_cmd(&ts.name, &["zoom", "3"]).status;
    assert!(!get_alert(&ts.name, 3));
    assert_eq!(get_alert_count(&ts.name), 0);
}

// ============================================================
// pipe-pane setup
// ============================================================

#[test]
fn pipe_pane_active_on_all_panes_after_config() {
    let ts = common::TestSession::new(3);

    for i in 0..3 {
        let output = Command::new("tmux")
            .args([
                "display-message",
                "-t",
                &format!("{}:.{}", ts.name, i),
                "-p",
                "#{pane_pipe}",
            ])
            .output()
            .expect("check pipe");
        let pipe = String::from_utf8_lossy(&output.stdout).trim().to_string();
        assert_eq!(pipe, "1", "pipe-pane should be active on pane {}", i);
    }
}

#[test]
fn pipe_pane_active_on_newly_created_pane() {
    let ts = common::TestSession::new(1);

    // Create a new pane
    amux::tmux::create_pane(&ts.name, None).expect("create pane");

    // Both panes should have pipe-pane active
    for i in 0..2 {
        let output = Command::new("tmux")
            .args([
                "display-message",
                "-t",
                &format!("{}:.{}", ts.name, i),
                "-p",
                "#{pane_pipe}",
            ])
            .output()
            .expect("check pipe");
        let pipe = String::from_utf8_lossy(&output.stdout).trim().to_string();
        assert_eq!(pipe, "1", "pipe-pane should be active on pane {}", i);
    }
}

// ============================================================
// Alert isolation and lifecycle (behavior-driven)
// ============================================================

#[test]
fn alert_on_one_pane_does_not_affect_other_panes() {
    let ts = common::TestSession::new(3);

    amux::tmux::set_alert(&ts.name, 1, true).expect("set alert");
    amux::tmux::set_alert_count(&ts.name, 1).expect("set count");

    assert!(get_alert(&ts.name, 1), "pane 1 should be alerted");
    assert!(!get_alert(&ts.name, 0), "pane 0 should remain clear");
    assert!(!get_alert(&ts.name, 2), "pane 2 should remain clear");
}

#[test]
fn alert_count_tracks_alerted_panes_accurately() {
    let ts = common::TestSession::new(3);

    // Alert two panes
    amux::tmux::set_alert(&ts.name, 0, true).expect("alert 0");
    amux::tmux::set_alert_count(&ts.name, 1).expect("count 1");
    amux::tmux::set_alert(&ts.name, 2, true).expect("alert 2");
    amux::tmux::set_alert_count(&ts.name, 2).expect("count 2");
    assert_eq!(get_alert_count(&ts.name), 2, "two panes alerted");

    // Dismiss one
    amux::tmux::dismiss_alert(&ts.name, 0).expect("dismiss 0");
    assert_eq!(get_alert_count(&ts.name), 1, "one pane dismissed");

    // Dismiss the other
    amux::tmux::dismiss_alert(&ts.name, 2).expect("dismiss 2");
    assert_eq!(get_alert_count(&ts.name), 0, "all panes dismissed");
}

#[test]
fn dismiss_only_clears_the_targeted_pane() {
    let ts = common::TestSession::new(3);

    // Alert panes 0 and 2
    amux::tmux::set_alert(&ts.name, 0, true).expect("alert 0");
    amux::tmux::set_alert(&ts.name, 2, true).expect("alert 2");
    amux::tmux::set_alert_count(&ts.name, 2).expect("count");

    // Dismiss only pane 0
    amux::tmux::dismiss_alert(&ts.name, 0).expect("dismiss 0");

    assert!(!get_alert(&ts.name, 0), "pane 0 should be cleared");
    assert!(!get_alert(&ts.name, 1), "pane 1 was never alerted");
    assert!(get_alert(&ts.name, 2), "pane 2 should still be alerted");
}

#[test]
fn alert_on_already_alerted_pane_is_idempotent() {
    let ts = common::TestSession::new(3);

    amux::tmux::set_alert(&ts.name, 1, true).expect("first alert");
    amux::tmux::set_alert_count(&ts.name, 1).expect("count");

    // Alert the same pane again
    amux::tmux::set_alert(&ts.name, 1, true).expect("second alert");
    // Count should NOT increment — caller must check before incrementing,
    // but the pane flag itself should remain 1
    assert!(get_alert(&ts.name, 1), "pane 1 still alerted");
    assert_eq!(
        get_alert_count(&ts.name),
        1,
        "count should not double from re-alerting same pane"
    );
}

#[test]
fn rapid_alert_dismiss_cycle_returns_to_clean_state() {
    let ts = common::TestSession::new(3);

    // Rapid cycle: alert, dismiss, alert, dismiss
    amux::tmux::set_alert(&ts.name, 0, true).expect("alert 1");
    amux::tmux::set_alert_count(&ts.name, 1).expect("count 1");
    amux::tmux::dismiss_alert(&ts.name, 0).expect("dismiss 1");
    amux::tmux::set_alert(&ts.name, 0, true).expect("alert 2");
    amux::tmux::set_alert_count(&ts.name, 1).expect("count 2");
    amux::tmux::dismiss_alert(&ts.name, 0).expect("dismiss 2");

    assert!(
        !get_alert(&ts.name, 0),
        "pane 0 should be clear after cycle"
    );
    assert_eq!(
        get_alert_count(&ts.name),
        0,
        "count should be zero after full cycle"
    );
}

// ============================================================
// Config correctness
// ============================================================

#[test]
fn border_format_has_three_states() {
    let ts = common::TestSession::new(1);

    let output = Command::new("tmux")
        .args(["show-options", "-t", &ts.name, "-v", "pane-border-format"])
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
}

#[test]
fn status_bar_has_alert_badge() {
    let ts = common::TestSession::new(1);

    let output = Command::new("tmux")
        .args(["show-options", "-t", &ts.name, "-v", "status-right"])
        .output()
        .expect("show status-right");
    let status = String::from_utf8_lossy(&output.stdout);

    assert!(
        status.contains("@amux-alert-count"),
        "should reference alert count"
    );
    // tmux without a real terminal (e.g. Docker) replaces non-ASCII chars
    // with underscores, so check for either the real dot or the sanitized version.
    assert!(
        status.contains("●") || status.contains("colour214"),
        "should have alert indicator styling"
    );
}
