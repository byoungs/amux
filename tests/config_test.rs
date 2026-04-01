mod common;

/// The pane-border-format must use explicit value comparison (#{==:#{@amux-alert},1})
/// not truthy checks (#{?@amux-alert,...}). Tmux's #{?...} treats any non-empty
/// string — including "0" — as true, which causes dismissed alerts to stay amber.

#[test]
fn border_format_uses_explicit_alert_comparison() {
    let fmt = amux::config::PANE_BORDER_FORMAT;
    // Must NOT contain #{?@amux-alert — that's the truthy check
    assert!(
        !fmt.contains("#{?@amux-alert"),
        "border format must not use truthy check on @amux-alert, found: {}",
        fmt
    );
    // Must contain explicit comparison #{==:#{@amux-alert},1}
    assert!(
        fmt.contains("#{==:#{@amux-alert},1}"),
        "border format must use explicit ==1 comparison for @amux-alert, found: {}",
        fmt
    );
}

#[test]
fn border_format_contains_unicode_characters() {
    let fmt = amux::config::PANE_BORDER_FORMAT;
    assert!(
        fmt.contains('▎'),
        "border format must contain ▎ (LEFT ONE QUARTER BLOCK): {}",
        fmt
    );
    assert!(
        fmt.contains('●'),
        "border format must contain ● (BLACK CIRCLE): {}",
        fmt
    );
}

#[test]
fn status_right_does_not_use_truthy_alert_check() {
    let fmt = amux::config::STATUS_RIGHT_FORMAT;
    // The alert-count check already uses #{>:#{@amux-alert-count},0} which is fine.
    // Just make sure there's no bare truthy #{?@amux-alert anywhere.
    assert!(
        !fmt.contains("#{?@amux-alert,"),
        "status-right must not use truthy check on @amux-alert, found: {}",
        fmt
    );
}

#[test]
fn key_bindings_pass_session_flag() {
    let _ts = common::TestSession::new(2);

    let output = std::process::Command::new("tmux")
        .args(["list-keys", "-T", "root"])
        .output()
        .expect("list-keys");
    let keys = String::from_utf8_lossy(&output.stdout);

    // C-= is Ctrl-+ (zoom-in)
    let zoom_in_line = keys
        .lines()
        .find(|l| l.contains("C-=") && l.contains("amux"));
    assert!(
        zoom_in_line.is_some_and(|l| l.contains("--session")),
        "C-= binding should include --session flag. Found: {:?}",
        zoom_in_line
    );

    // C-1 should be zoom with --session
    let zoom_1_line = keys
        .lines()
        .find(|l| l.contains("C-1") && l.contains("amux"));
    assert!(
        zoom_1_line.is_some_and(|l| l.contains("--session")),
        "C-1 binding should include --session flag. Found: {:?}",
        zoom_1_line
    );
}

/// The apply_hooks function must register after-select-pane (not pane-focus-out)
/// because pane-focus-out is silently ignored in tmux next-3.7.
#[test]
fn apply_hooks_source_uses_after_select_pane() {
    let source = std::fs::read_to_string("src/config.rs").unwrap();
    assert!(
        source.contains("\"after-select-pane\""),
        "config.rs must use after-select-pane hook (pane-focus-out is silently ignored in tmux next-3.7)"
    );
}
