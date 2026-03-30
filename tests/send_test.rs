/// Tests for sending panes between spaces.
mod common;

#[test]
fn send_to_new_space_has_one_pane() {
    // Bug: create_session makes a default pane, then join-pane adds the
    // sent pane alongside it. The caller must use kill_phantom_pane to clean up.
    let ts = common::TestSession::new(2);

    // Create the target space (simulating cmd_send "new space" flow)
    let target = format!("{}-target", ts.name);
    amux::tmux::create_session(&target).expect("create target");
    amux::config::apply_config(&target).expect("apply config");
    amux::tmux::set_level(&target, 2).expect("set level");
    amux::tmux::mark_as_managed(&target).expect("mark managed");

    // Capture the pane ID before sending
    let sent_id = amux::tmux::active_pane_id(&ts.name).expect("get pane id");

    // Send active pane to the target space
    amux::tmux::send_pane_to_session(&ts.name, &target).expect("send pane");

    // Kill phantom pane (caller responsibility for new spaces)
    amux::tmux::kill_phantom_pane(&target, &sent_id).expect("kill phantom");

    // Target should have exactly 1 pane (the sent one), not 2
    let count = amux::tmux::pane_count(&target).expect("count panes");
    assert_eq!(
        count, 1,
        "target space should have 1 pane after send, got {}",
        count
    );

    // Clean up
    let _ = std::process::Command::new("tmux")
        .args(["kill-session", "-t", &target])
        .output();
}

// ============================================================
// Bug 2: Phantom pane — "send to new space has 2 panes"
// ============================================================

#[test]
fn send_to_existing_space_preserves_panes() {
    let ts1 = common::TestSession::new(2);
    let ts2 = common::TestSession::new(2);

    // ts2 has 2 panes — send should add 1 more, not kill any
    amux::tmux::send_pane_to_session(&ts1.name, &ts2.name).expect("send");

    let count = amux::tmux::pane_count(&ts2.name).expect("count");
    assert_eq!(
        count, 3,
        "existing space should gain 1 pane: 2 + 1 = 3, got {}",
        count
    );
}

// ============================================================
// Bug 3: Error visibility — relayout propagates errors
// ============================================================

#[test]
fn relayout_on_nonexistent_session_is_graceful_noop() {
    // A nonexistent session produces no panes, so relayout returns Ok (empty early return).
    // The error propagation fix is about select-layout failures being surfaced,
    // not about crashing on missing sessions.
    let result = amux::tmux::relayout("nonexistent-session-xyz", amux::sticky::LayoutEvent::Resize);
    assert!(
        result.is_ok(),
        "relayout on nonexistent session should be a graceful no-op"
    );
}
