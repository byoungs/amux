// src/config.rs

use anyhow::{bail, Context, Result};
use std::process::Command;

/// Apply all amux tmux configuration to a session.
pub fn apply_config(session: &str) -> Result<()> {
    apply_border_style(session)?;
    apply_status_bar(session)?;
    apply_key_bindings(session)?;
    apply_hooks(session)?;
    Ok(())
}

/// Set up attention management and layout hooks.
pub fn apply_hooks(session: &str) -> Result<()> {
    crate::tmux::setup_all_bell_watches(session)?;

    let bin = "amux";

    // Re-apply grid layout when a pane exits (shell closes naturally)
    let _ = Command::new("tmux")
        .args(["set-hook", "-g", "pane-exited",
               &format!("run-shell \"{} refresh 2>/dev/null\"", bin)])
        .output();

    // Re-apply grid layout when the terminal window is resized
    let _ = Command::new("tmux")
        .args(["set-hook", "-g", "client-resized",
               &format!("run-shell \"{} refresh 2>/dev/null\"", bin)])
        .output();

    Ok(())
}

/// Configure pane borders with colored title bars.
fn apply_border_style(session: &str) -> Result<()> {
    // Fix Claude Code flickering + enable Shift-Enter passthrough
    tmux_set_global("allow-passthrough", "on")?;
    tmux_set_global("extended-keys", "always")?;  // force extended key forwarding (Shift-Enter etc.)
    tmux_set_server("escape-time", "0")?;

    // Disable the tmux prefix key entirely. Amux uses root-table bindings
    // (Ctrl-+, Ctrl-1..9, etc.) so the prefix key (Ctrl-B) is unnecessary.
    // Leaving it enabled causes "stuck input" when Claude Code's rapid
    // rendering accidentally triggers the prefix, putting tmux in a state
    // where it waits for a second keypress that never makes sense.
    let _ = Command::new("tmux")
        .args(["set", "-g", "prefix", "None"])
        .output();
    let _ = Command::new("tmux")
        .args(["unbind-key", "-T", "prefix", "C-b"])
        .output();
    // Also unbind C-b in root so it passes through to applications
    let _ = Command::new("tmux")
        .args(["unbind-key", "-n", "C-b"])
        .output();
    // Set terminal-features once (not append) to avoid duplication on refresh
    // sync = synchronized output (prevents flashing)
    // extkeys = extended key sequences (Shift-Enter, etc.)
    let _ = Command::new("tmux")
        .args(["set", "-s", "terminal-features[0]", "xterm*:clipboard:ccolour:cstyle:focus:title:sync:extkeys"])
        .output();
    // True-color support for compatible terminals
    let _ = Command::new("tmux")
        .args(["set", "-sa", "terminal-overrides", ",xterm-256color:RGB"])
        .output();
    // Large scrollback to handle Claude Code's rapid streaming output
    tmux_set_global("history-limit", "250000")?;

    // Active pane: match iTerm2 profile (bg #000000, fg #bbbbbb)
    tmux_set(session, "window-active-style", "bg=colour0 fg=colour250")?;
    // Inactive panes: dimmed background + muted text
    tmux_set(session, "window-style", "bg=colour234 fg=colour245")?;

    // Title bar at top of each pane
    tmux_set(session, "pane-border-status", "top")?;

    // Format: use @amux-title (custom pane option) which Claude Code can't override,
    // falling back to pane_title if @amux-title isn't set
    tmux_set(
        session,
        "pane-border-format",
        " #{?pane_active,#[fg=colour43 bold]▎ #[fg=yellow]#{e|+:#{pane_index},1}#[fg=colour252] #{?@amux-title,#{@amux-title},#{pane_title}} #[fg=colour43]●,#{?@amux-alert,#[fg=colour214 bold]▎ #[fg=colour214]#{e|+:#{pane_index},1}#[fg=colour214] #{?@amux-title,#{@amux-title},#{pane_title}} #[fg=colour214]⬤,#[fg=colour236]▎ #[fg=colour240]#{e|+:#{pane_index},1}#[fg=colour245] #{?@amux-title,#{@amux-title},#{pane_title}}}} ",
    )?;

    // Active border: bright teal, bold — stands out clearly
    tmux_set(session, "pane-active-border-style", "fg=colour43 bold")?;

    // Inactive border: very dark — fades into background
    tmux_set(session, "pane-border-style", "fg=colour235")?;

    Ok(())
}

/// Configure the status bar.
fn apply_status_bar(session: &str) -> Result<()> {
    tmux_set(session, "status-style", "bg=colour235 fg=colour245")?;
    tmux_set(
        session,
        "status-left",
        "#[fg=colour43,bold] amux #[fg=colour238]│ ",
    )?;
    // Status right shows current zoom level
    // AMUX_LEVEL env var: 1=bird's eye, 2=working, 3=full screen
    // Use nested conditionals to display the right mode
    tmux_set(
        session,
        "status-right",
        " #{?#{>:#{window_index},0},#[fg=cyan bold]SPLIT #[fg=colour238]C-- exit,#{?#{==:#{AMUX_LEVEL},1},#[fg=colour81]BIRD'S EYE #[fg=colour238]arrows nav · C-1..9 focus · C-n new · C-p spaces,#{?window_zoomed_flag,#[fg=yellow bold]FULL SCREEN #[fg=colour238]C-- working · C-1..9 switch · C-p spaces#{?#{>:#{@amux-alert-count},0}, #[fg=colour214 bold]⬤ #{@amux-alert-count},},#[fg=colour245]WORKING #[fg=colour238]C-+ full · C-- bird's eye · C-1..9 focus · C-p spaces#{?#{>:#{@amux-alert-count},0}, #[fg=colour214 bold]⬤ #{@amux-alert-count},}}}} ",
    )?;
    tmux_set(session, "status-left-length", "20")?;
    tmux_set(session, "status-right-length", "100")?;

    Ok(())
}

/// Configure key bindings for amux workflow.
/// All bindings are global (tmux doesn't support session-scoped bindings).
/// No "command mode" — each action has its own dedicated key binding.
fn apply_key_bindings(_session: &str) -> Result<()> {
    let bin = "amux";

    // Verify the binary is on PATH
    let which = Command::new("which").arg(bin).output();
    if which.is_err() || !which.unwrap().status.success() {
        eprintln!("Warning: '{}' not found on PATH. Key bindings may not work.", bin);
        eprintln!("Run: cargo install --path .");
    }

    // === Zoom controls (call amux CLI for level-aware logic) ===

    // Ctrl-+ : zoom in one level
    tmux_bind_root("C-=",
        &format!(r#"run-shell "{} zoom-in""#, bin))?;

    // Ctrl-- : zoom out one level (also handles split exit)
    tmux_bind_root("C--",
        &format!(r#"run-shell "if [ $(tmux display-message -p '#{{window_index}}') -gt 0 ]; then {} split-exit; else {} zoom-out; fi""#, bin, bin))?;

    // Ctrl-1..9 : context-aware zoom to pane N
    for i in 1..=9 {
        tmux_bind_root(
            &format!("C-{}", i),
            &format!(r#"run-shell "{} zoom {}""#, bin, i - 1),
        )?;
    }

    // === Bird's Eye key table (Level 1) ===
    // Arrow keys navigate between panes and stay in bird's eye
    tmux_bind_table("amux-birdeye", "Left",
        r#"run-shell "tmux select-pane -L && tmux switch-client -T amux-birdeye""#)?;
    tmux_bind_table("amux-birdeye", "Right",
        r#"run-shell "tmux select-pane -R && tmux switch-client -T amux-birdeye""#)?;
    tmux_bind_table("amux-birdeye", "Up",
        r#"run-shell "tmux select-pane -U && tmux switch-client -T amux-birdeye""#)?;
    tmux_bind_table("amux-birdeye", "Down",
        r#"run-shell "tmux select-pane -D && tmux switch-client -T amux-birdeye""#)?;

    // Ctrl-+ in bird's eye → zoom in (go to L2)
    tmux_bind_table("amux-birdeye", "C-=",
        &format!(r#"run-shell "{} zoom-in""#, bin))?;

    // Ctrl-1..9 in bird's eye → zoom to pane N (go to L2)
    for i in 1..=9 {
        tmux_bind_table("amux-birdeye", &format!("C-{}", i),
            &format!(r#"run-shell "{} zoom {}""#, bin, i - 1))?;
    }

    // Ctrl-n in bird's eye → create new pane
    tmux_bind_table("amux-birdeye", "C-n",
        &format!(r#"run-shell "cd '#{{pane_current_path}}' && {} new""#, bin))?;

    // Any other key in bird's eye exits to L2 (the key is consumed)
    // tmux auto-exits the key table on unbound keys

    // === Pane lifecycle ===
    // Ctrl-n: create pane via amux (sets title), then force layout refresh
    tmux_bind_root("C-n",
        &format!(r#"run-shell "cd '#{{pane_current_path}}' && {} new && {} refresh 2>/dev/null""#, bin, bin))?;

    // === Spaces ===
    // Ctrl-P: Space picker (popup centered over tmux)
    tmux_bind_root("C-p",
        &format!(r#"display-popup -E -w 70 -h 20 -T " Spaces " "{} spaces""#, bin))?;

    // Ctrl-S: Send pane to another space (popup)
    tmux_bind_root("C-s",
        &format!(r#"display-popup -E -w 70 -h 20 -T " Send to Space " "{} send""#, bin))?;

    // === Split view ===
    tmux_bind_root("C-l",
        &format!(r#"run-shell "{} split-start""#, bin))?;

    tmux_bind_table("amux-split-pick", "C-Left", "select-pane -L")?;
    tmux_bind_table("amux-split-pick", "C-Right", "select-pane -R")?;
    tmux_bind_table("amux-split-pick", "C-Up", "select-pane -U")?;
    tmux_bind_table("amux-split-pick", "C-Down", "select-pane -D")?;
    tmux_bind_table("amux-split-pick", "Enter",
        &format!(r#"run-shell "{} split-pick $(tmux display-message -p '#{{pane_index}}')""#, bin))?;
    for i in 1..=9 {
        tmux_bind_table("amux-split-pick", &format!("C-{}", i),
            &format!(r#"run-shell "{} split-pick {}""#, bin, i - 1))?;
    }
    tmux_bind_table("amux-split-pick", "Escape",
        &format!(r#"run-shell "{} split-cancel""#, bin))?;

    Ok(())
}

/// Set a tmux option for a session.
fn tmux_set(session: &str, option: &str, value: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args(["set", "-t", session, option, value])
        .output()
        .with_context(|| format!("failed to set tmux option {}", option))?;
    if !output.status.success() {
        bail!("tmux set {} failed: {}", option, String::from_utf8_lossy(&output.stderr));
    }
    Ok(())
}

/// Set a global tmux option.
fn tmux_set_global(option: &str, value: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args(["set", "-g", option, value])
        .output()
        .with_context(|| format!("failed to set global tmux option {}", option))?;
    if !output.status.success() {
        bail!("tmux set -g {} failed: {}", option, String::from_utf8_lossy(&output.stderr));
    }
    Ok(())
}

/// Set a server-level tmux option.
fn tmux_set_server(option: &str, value: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args(["set", "-sg", option, value])
        .output()
        .with_context(|| format!("failed to set server tmux option {}", option))?;
    if !output.status.success() {
        bail!("tmux set -sg {} failed: {}", option, String::from_utf8_lossy(&output.stderr));
    }
    Ok(())
}

/// Bind a key in the root key table (no prefix needed).
fn tmux_bind_root(key: &str, command: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args(["bind-key", "-n", key, command])
        .output()
        .with_context(|| format!("failed to bind root key {}", key))?;
    if !output.status.success() {
        bail!("tmux bind-key -n {} failed: {}", key, String::from_utf8_lossy(&output.stderr));
    }
    Ok(())
}

/// Bind a key in a named key table.
fn tmux_bind_table(table: &str, key: &str, command: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args(["bind-key", "-T", table, key, command])
        .output()
        .with_context(|| format!("failed to bind {} in table {}", key, table))?;
    if !output.status.success() {
        bail!("tmux bind-key -T {} {} failed: {}", table, key, String::from_utf8_lossy(&output.stderr));
    }
    Ok(())
}
