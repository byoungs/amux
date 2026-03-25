use std::process::Command;

fn session_name() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let id = COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("amux-attn-{}-{}", std::process::id(), id)
}

fn cleanup(session: &str) {
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", session])
        .output();
}

#[test]
fn set_and_get_alert_flag() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");

    assert!(!amux::tmux::get_alert(&session, 0).expect("get"));
    amux::tmux::set_alert(&session, 0, true).expect("set");
    assert!(amux::tmux::get_alert(&session, 0).expect("get"));
    amux::tmux::set_alert(&session, 0, false).expect("clear");
    assert!(!amux::tmux::get_alert(&session, 0).expect("get"));

    cleanup(&session);
}

#[test]
fn list_panes_includes_alert_state() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");

    amux::tmux::set_alert(&session, 1, true).expect("set");

    let panes = amux::tmux::list_panes(&session).expect("list");
    assert_eq!(panes.len(), 2);
    assert!(!panes[0].alert, "pane 0 should not have alert");
    assert!(panes[1].alert, "pane 1 should have alert");

    cleanup(&session);
}

#[test]
fn alert_states_for_session() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");
    amux::tmux::create_pane(&session, None).expect("pane");

    amux::tmux::set_alert(&session, 1, true).expect("set");

    let states = amux::tmux::alert_states(&session).expect("states");
    assert_eq!(states, vec![false, true, false]);

    cleanup(&session);
}

#[test]
fn border_format_includes_alert_conditional() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");

    let output = Command::new("tmux")
        .args(["show-options", "-t", &session, "-v", "pane-border-format"])
        .output()
        .expect("show-options");
    let format = String::from_utf8_lossy(&output.stdout);
    assert!(
        format.contains("@amux-alert"),
        "border format should reference @amux-alert: {}",
        format
    );

    cleanup(&session);
}

#[test]
fn status_bar_includes_alert_badge() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");

    let output = Command::new("tmux")
        .args(["show-options", "-t", &session, "-v", "status-right"])
        .output()
        .expect("show-options");
    let status = String::from_utf8_lossy(&output.stdout);

    assert!(
        status.contains("amux-alert-count") || status.contains("⬤"),
        "status-right should include alert badge logic: {}",
        status
    );

    cleanup(&session);
}

#[test]
fn alert_pane_marks_specific_pane() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane 2");
    amux::tmux::create_pane(&session, None).expect("pane 3");

    // Select pane 0 as active, alert pane 2 only
    amux::tmux::select_pane(&session, 0).expect("select");
    amux::tmux::set_alert(&session, 2, true).expect("set");

    // Only pane 2 should be alerted — not pane 1
    assert!(!amux::tmux::get_alert(&session, 0).expect("get"));
    assert!(!amux::tmux::get_alert(&session, 1).expect("get"));
    assert!(amux::tmux::get_alert(&session, 2).expect("get"));

    cleanup(&session);
}

#[test]
fn alert_pane_updates_count() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");

    amux::tmux::select_pane(&session, 0).expect("select");
    amux::tmux::set_alert(&session, 1, true).expect("set");
    let states = amux::tmux::alert_states(&session).expect("states");
    let count = amux::alert::count_alerts(&states);
    amux::tmux::set_alert_count(&session, count).expect("count");

    assert_eq!(amux::tmux::get_alert_count(&session).expect("count"), 1);

    cleanup(&session);
}

#[test]
fn alert_pane_skips_already_alerted() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");

    // Alert pane 1, then try to alert it again
    amux::tmux::set_alert(&session, 1, true).expect("set");
    assert!(amux::tmux::get_alert(&session, 1).expect("get"));

    // Setting alert again should be a no-op (already alerted)
    amux::tmux::set_alert(&session, 1, true).expect("set again");
    assert!(amux::tmux::get_alert(&session, 1).expect("still set"));

    cleanup(&session);
}

#[test]
fn alert_counts_per_session() {
    let session1 = session_name();
    let session2 = session_name();
    cleanup(&session1);
    cleanup(&session2);

    amux::tmux::create_session(&session1).expect("create");
    amux::config::apply_config(&session1).expect("config");
    amux::tmux::create_pane(&session1, None).expect("pane");

    amux::tmux::create_session(&session2).expect("create");
    amux::config::apply_config(&session2).expect("config");
    amux::tmux::create_pane(&session2, None).expect("pane");

    amux::tmux::set_alert(&session1, 1, true).expect("set");
    amux::tmux::set_alert_count(&session1, 1).expect("count");
    amux::tmux::set_alert_count(&session2, 0).expect("count");

    let count1 = amux::tmux::get_alert_count(&session1).expect("count");
    let count2 = amux::tmux::get_alert_count(&session2).expect("count");

    assert_eq!(count1, 1);
    assert_eq!(count2, 0);

    cleanup(&session1);
    cleanup(&session2);
}

#[test]
fn smart_landing_integration() {
    use amux::alert::{smart_landing, LandingTarget};

    let result = smart_landing(&[false, false, true], 2, 0);
    assert_eq!(result, LandingTarget::FocusPane { index: 2, level: 2 });

    let result = smart_landing(&[false, false], 3, 1);
    assert_eq!(result, LandingTarget::Resume { level: 2, pane: 1 });

    let result = smart_landing(&[true, true, false], 1, 0);
    assert_eq!(result, LandingTarget::Resume { level: 1, pane: 0 });
}

#[test]
fn focusing_pane_clears_alert() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");
    amux::tmux::create_pane(&session, None).expect("pane");

    amux::tmux::set_alert(&session, 1, true).expect("set");
    amux::tmux::set_alert_count(&session, 1).expect("count");

    amux::tmux::select_pane(&session, 1).expect("select");
    amux::tmux::dismiss_alert(&session, 1).expect("dismiss");

    assert!(
        !amux::tmux::get_alert(&session, 1).expect("get"),
        "alert should be cleared after focusing"
    );
    assert_eq!(amux::tmux::get_alert_count(&session).expect("count"), 0);

    cleanup(&session);
}

#[test]
fn notification_timestamp_persists() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");

    amux::tmux::set_last_notification_time(&session).expect("set");

    let elapsed = amux::tmux::get_last_notification_elapsed(&session).expect("get");
    assert!(
        elapsed < 2,
        "timestamp should be recent, got {}s elapsed",
        elapsed
    );

    cleanup(&session);
}

#[test]
fn scenario_targeted_alert_only_marks_one_pane() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");
    amux::tmux::create_pane(&session, None).expect("pane 2");
    amux::tmux::create_pane(&session, None).expect("pane 3");

    // User is in pane 0, pane 2 signals it needs attention
    amux::tmux::select_pane(&session, 0).expect("select");
    amux::tmux::set_alert(&session, 2, true).expect("set");
    let states = amux::tmux::alert_states(&session).expect("states");
    let count = amux::alert::count_alerts(&states);
    amux::tmux::set_alert_count(&session, count).expect("count");

    // Only pane 2 should be amber — panes 0 and 1 stay dark
    assert!(!states[0], "active pane should not alert");
    assert!(!states[1], "pane 1 should not be falsely alerted");
    assert!(states[2], "pane 2 should have alert");
    assert_eq!(count, 1);

    cleanup(&session);
}

#[test]
fn scenario_focus_clears_alert() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");
    amux::tmux::create_pane(&session, None).expect("pane");

    amux::tmux::set_alert(&session, 1, true).expect("set");
    amux::tmux::set_alert_count(&session, 1).expect("count");

    amux::tmux::select_pane(&session, 1).expect("select");
    amux::tmux::dismiss_alert(&session, 1).expect("dismiss");

    assert!(!amux::tmux::get_alert(&session, 1).expect("get"));
    assert_eq!(amux::tmux::get_alert_count(&session).expect("count"), 0);

    cleanup(&session);
}

#[test]
fn scenario_multiple_alerts_partial_dismiss() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane 2");
    amux::tmux::create_pane(&session, None).expect("pane 3");

    amux::tmux::set_alert(&session, 1, true).expect("set");
    amux::tmux::set_alert(&session, 2, true).expect("set");
    amux::tmux::set_alert_count(&session, 2).expect("count");

    amux::tmux::dismiss_alert(&session, 1).expect("dismiss");

    assert!(!amux::tmux::get_alert(&session, 1).expect("get"));
    assert!(amux::tmux::get_alert(&session, 2).expect("get"));
    assert_eq!(amux::tmux::get_alert_count(&session).expect("count"), 1);

    cleanup(&session);
}

#[test]
fn scenario_two_panes_alert_independently() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");
    amux::tmux::create_pane(&session, None).expect("pane 2");
    amux::tmux::create_pane(&session, None).expect("pane 3");

    amux::tmux::select_pane(&session, 0).expect("select");

    // Pane 1 alerts, then pane 2 alerts
    amux::tmux::set_alert(&session, 1, true).expect("set");
    amux::tmux::set_alert(&session, 2, true).expect("set");
    let states = amux::tmux::alert_states(&session).expect("states");
    let count = amux::alert::count_alerts(&states);
    amux::tmux::set_alert_count(&session, count).expect("count");

    assert!(
        !amux::tmux::get_alert(&session, 0).expect("get"),
        "active pane should not be alerted"
    );
    assert!(amux::tmux::get_alert(&session, 1).expect("get"));
    assert!(amux::tmux::get_alert(&session, 2).expect("get"));
    assert_eq!(count, 2);

    cleanup(&session);
}

#[test]
fn scenario_pane_close_updates_alert_count() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane 2");
    amux::tmux::create_pane(&session, None).expect("pane 3");

    amux::tmux::set_alert(&session, 1, true).expect("set");
    amux::tmux::set_alert(&session, 2, true).expect("set");
    amux::tmux::set_alert_count(&session, 2).expect("count");

    amux::tmux::kill_pane(&session, 2).expect("kill");

    let states = amux::tmux::alert_states(&session).expect("states");
    let count = amux::alert::count_alerts(&states);
    amux::tmux::set_alert_count(&session, count).expect("count");

    assert_eq!(count, 1, "count should update after pane close");

    cleanup(&session);
}

#[test]
fn notification_messages() {
    assert_eq!(amux::notify::format_message(0), "All agents are working");
    assert_eq!(amux::notify::format_message(1), "1 agent is ready for you");
    assert_eq!(
        amux::notify::format_message(2),
        "2 agents are ready for you"
    );
    assert_eq!(
        amux::notify::format_message(5),
        "5 agents are ready for you"
    );
}

#[test]
fn bell_watch_pipe_is_set_up_on_refresh() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");

    // Check that pipe-pane was set up on the pane
    let output = Command::new("tmux")
        .args([
            "display-message",
            "-t",
            &format!("{}:.0", session),
            "-p",
            "#{pane_pipe}",
        ])
        .output()
        .expect("display-message");
    let pipe = String::from_utf8_lossy(&output.stdout).trim().to_string();
    assert_eq!(
        pipe, "1",
        "pipe-pane should be active on pane 0 after config"
    );

    cleanup(&session);
}
