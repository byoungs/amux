/// Hooks must be session-scoped (-t session), not global (-g).
/// Global hooks cause cross-session interference between live sessions and tests.
mod common;

/// Collect all hooks for a session: session-level and window-level.
/// tmux stores hooks at different levels depending on hook type:
/// - client-resized → session level (show-hooks -t)
/// - pane-exited, pane-focus-out → window level (show-hooks -w -t)
fn all_hooks_for(session: &str) -> String {
    let session_hooks = std::process::Command::new("tmux")
        .args(["show-hooks", "-t", session])
        .output()
        .expect("show-hooks session");
    let window_hooks = std::process::Command::new("tmux")
        .args(["show-hooks", "-w", "-t", session])
        .output()
        .expect("show-hooks window");

    let mut combined = String::from_utf8_lossy(&session_hooks.stdout).into_owned();
    combined.push_str(&String::from_utf8_lossy(&window_hooks.stdout));
    combined
}

#[test]
fn hooks_are_session_scoped_not_global() {
    let ts = common::TestSession::new(2);

    let hooks = all_hooks_for(&ts.name);

    assert!(
        hooks.contains("pane-exited"),
        "session should have pane-exited hook: {}",
        hooks
    );
    assert!(
        hooks.contains("pane-focus-out"),
        "session should have pane-focus-out hook: {}",
        hooks
    );
}

#[test]
fn two_sessions_get_independent_hooks() {
    let ts1 = common::TestSession::new(2);
    let ts2 = common::TestSession::new(2);

    let h1 = all_hooks_for(&ts1.name);
    let h2 = all_hooks_for(&ts2.name);

    assert!(h1.contains("pane-exited"), "ts1 should have hooks");
    assert!(h2.contains("pane-exited"), "ts2 should have hooks");
}
