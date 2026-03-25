// src/hooks.rs — Claude Code hook installation for attention management.
//
// Ensures the Notification hook is configured in ~/.claude/settings.json
// so that Claude Code calls `amux alert-pane` when it needs user attention.

use anyhow::{Context, Result};
use std::path::PathBuf;

/// Path to Claude Code's global settings.
fn claude_settings_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".claude")
        .join("settings.json")
}

/// The hook command that Claude Code should run on notifications.
/// Uses $TMUX_PANE to target the specific pane (not the active pane).
/// Passes AMUX_SESSION because the hook runs as a child process of Claude Code,
/// which may not have tmux client context to resolve the session name.
const HOOK_COMMAND: &str = "AMUX_SESSION=$(tmux display-message -t $TMUX_PANE -p '#{session_name}') amux alert-pane $(tmux display-message -t $TMUX_PANE -p '#{pane_index}')";

/// Ensure the Claude Code Notification hook is installed.
/// Reads existing settings, adds the hook if missing, writes back.
/// Does nothing if the hook is already present.
pub fn ensure_claude_hook() -> Result<()> {
    let path = claude_settings_path();

    // Read existing settings or start with empty object
    let mut settings: serde_json::Value = if path.exists() {
        let content =
            std::fs::read_to_string(&path).context("failed to read ~/.claude/settings.json")?;
        serde_json::from_str(&content).context("failed to parse ~/.claude/settings.json")?
    } else {
        serde_json::json!({})
    };

    // Check if our hook is already installed
    if has_amux_hook(&settings) {
        return Ok(());
    }

    // Build the hook entry
    let hook_entry = serde_json::json!({
        "matcher": "",
        "hooks": [{
            "type": "command",
            "command": HOOK_COMMAND
        }]
    });

    // Add to existing Notification hooks (or create the array)
    let hooks = settings
        .as_object_mut()
        .context("settings is not an object")?
        .entry("hooks")
        .or_insert_with(|| serde_json::json!({}));
    let notification = hooks
        .as_object_mut()
        .context("hooks is not an object")?
        .entry("Notification")
        .or_insert_with(|| serde_json::json!([]));
    let arr = notification
        .as_array_mut()
        .context("Notification is not an array")?;
    arr.push(hook_entry);

    // Write back with pretty formatting
    let content =
        serde_json::to_string_pretty(&settings).context("failed to serialize settings")?;
    std::fs::write(&path, content).context("failed to write ~/.claude/settings.json")?;

    eprintln!("Installed amux notification hook in ~/.claude/settings.json");

    Ok(())
}

/// Check if the amux alert-pane hook is already installed.
fn has_amux_hook(settings: &serde_json::Value) -> bool {
    settings
        .get("hooks")
        .and_then(|h| h.get("Notification"))
        .and_then(|n| n.as_array())
        .map(|arr| {
            arr.iter().any(|entry| {
                entry
                    .get("hooks")
                    .and_then(|h| h.as_array())
                    .map(|hooks| {
                        hooks.iter().any(|hook| {
                            hook.get("command")
                                .and_then(|c| c.as_str())
                                .map(|cmd| cmd.contains("amux alert-pane"))
                                .unwrap_or(false)
                        })
                    })
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}
