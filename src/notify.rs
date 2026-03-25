// src/notify.rs — macOS notification and frontmost-app detection.
//
// System notifications are macOS-only. On other platforms, amux still
// tracks attention state (amber borders, badges, space picker indicators)
// but does not send OS-level notifications.

use anyhow::{Context, Result};
use std::process::Command;

/// Check if a given app name is a known terminal emulator.
pub fn is_known_terminal(app: &str) -> bool {
    let app = app.to_lowercase();
    app.contains("terminal")
        || app.contains("iterm")
        || app.contains("alacritty")
        || app.contains("kitty")
        || app.contains("wezterm")
        || app.contains("ghostty")
}

/// Check if the terminal emulator hosting this tmux session is the
/// frontmost macOS application.
///
/// Uses `lsappinfo` which requires no Automation permissions (unlike
/// osascript + System Events). Returns true (safe default: don't notify)
/// if detection fails or on non-macOS platforms.
pub fn is_terminal_frontmost() -> bool {
    frontmost_app()
        .map(|app| is_known_terminal(&app))
        .unwrap_or(true) // safe default: assume frontmost, don't notify
}

/// Get the name of the frontmost macOS application via lsappinfo.
/// Returns None on non-macOS or if the command fails.
fn frontmost_app() -> Option<String> {
    // Get the ASN (Application Serial Number) of the frontmost app
    let front = Command::new("lsappinfo").arg("front").output().ok()?;
    let asn = String::from_utf8_lossy(&front.stdout).trim().to_string();
    if asn.is_empty() {
        return None;
    }

    // Get the display name for that ASN
    let info = Command::new("lsappinfo")
        .args(["info", "-only", "name", &asn])
        .output()
        .ok()?;
    let output = String::from_utf8_lossy(&info.stdout);

    // Parse: "LSDisplayName"="AppName"
    output
        .trim()
        .strip_prefix("\"LSDisplayName\"=\"")
        .and_then(|s| s.strip_suffix('"'))
        .map(|s| s.to_string())
}

/// Send a macOS notification via osascript.
pub fn send_notification(title: &str, message: &str) -> Result<()> {
    Command::new("osascript")
        .args([
            "-e",
            &format!(
                r#"display notification "{}" with title "{}""#,
                message.replace('"', "\\\""),
                title.replace('"', "\\\""),
            ),
        ])
        .output()
        .context("failed to send macOS notification")?;
    Ok(())
}

/// Format a human-readable notification message from alert count.
pub fn format_message(count: usize) -> String {
    match count {
        0 => "All agents are working".to_string(),
        1 => "1 agent is ready for you".to_string(),
        n => format!("{} agents are ready for you", n),
    }
}
