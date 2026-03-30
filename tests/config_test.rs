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
