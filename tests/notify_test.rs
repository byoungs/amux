#[test]
fn is_frontmost_does_not_panic() {
    // Just verify the function runs without error.
    // The actual result depends on the environment — if the user switches
    // apps during the test run, it might return false.
    let _result = amux::notify::is_terminal_frontmost();
}

#[test]
fn send_notification_does_not_panic() {
    let result = amux::notify::send_notification("amux", "Test: 1 agent ready for you");
    assert!(result.is_ok());
}

// --- is_known_terminal ---

#[test]
fn recognizes_iterm2() {
    assert!(amux::notify::is_known_terminal("iTerm2"));
}

#[test]
fn recognizes_terminal() {
    assert!(amux::notify::is_known_terminal("Terminal"));
}

#[test]
fn recognizes_ghostty() {
    assert!(amux::notify::is_known_terminal("Ghostty"));
}

#[test]
fn recognizes_alacritty() {
    assert!(amux::notify::is_known_terminal("Alacritty"));
}

#[test]
fn recognizes_kitty() {
    assert!(amux::notify::is_known_terminal("kitty"));
}

#[test]
fn recognizes_wezterm() {
    assert!(amux::notify::is_known_terminal("WezTerm"));
}

#[test]
fn rejects_chrome() {
    assert!(!amux::notify::is_known_terminal("Google Chrome"));
}

#[test]
fn rejects_slack() {
    assert!(!amux::notify::is_known_terminal("Slack"));
}

#[test]
fn rejects_empty() {
    assert!(!amux::notify::is_known_terminal(""));
}

// --- message formatting ---

#[test]
fn notification_message_formats_correctly() {
    assert_eq!(
        amux::notify::format_message(1),
        "1 agent is ready for you"
    );
    assert_eq!(
        amux::notify::format_message(3),
        "3 agents are ready for you"
    );
    assert_eq!(
        amux::notify::format_message(0),
        "All agents are working"
    );
}
