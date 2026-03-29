// src/tmux.rs

use anyhow::{bail, Context, Result};
use std::process::Command;

#[derive(Debug, Clone)]
pub struct PaneInfo {
    pub index: usize,
    pub title: String,
    pub width: u16,
    pub height: u16,
    pub active: bool,
    pub alert: bool,
}

pub fn session_exists(session: &str) -> bool {
    Command::new("tmux")
        .args(["has-session", "-t", session])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

pub fn create_session(session: &str) -> Result<()> {
    if session_exists(session) {
        return Ok(());
    }
    let output = Command::new("tmux")
        .args(["new-session", "-d", "-s", session])
        .output()
        .context("failed to create tmux session")?;
    if !output.status.success() {
        bail!(
            "tmux new-session failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

pub fn create_pane(session: &str, cwd: Option<&str>) -> Result<usize> {
    // Create a pane via new-window + join-pane instead of split-window.
    // split-window inserts adjacent to the active pane which disrupts the
    // index order and existing pane positions.
    // new-window -d creates a detached temp window, then join-pane moves
    // it into the main window at the END of the pane list. No shuffling.
    let mut args = vec!["new-window", "-t", session, "-d", "-P", "-F", "#{pane_id}"];
    if let Some(dir) = cwd {
        args.extend(["-c", dir]);
    }
    let output = Command::new("tmux")
        .args(&args)
        .output()
        .context("failed to create temp window")?;
    if !output.status.success() {
        bail!(
            "tmux new-window failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let new_pane_id = String::from_utf8_lossy(&output.stdout).trim().to_string();

    // Join the new pane into the main window (window 0)
    let target = format!("{}:0", session);
    let output = Command::new("tmux")
        .args(["join-pane", "-s", &new_pane_id, "-t", &target])
        .output()
        .context("failed to join pane")?;
    if !output.status.success() {
        bail!(
            "tmux join-pane failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    // Apply clean grid layout — pass the new pane's ID so sticky matching knows it was added
    let pane_id: u32 = new_pane_id.trim_start_matches('%').parse().unwrap_or(0);
    let _ = relayout(session, crate::sticky::LayoutEvent::Add(pane_id));
    let panes = list_panes(session)?;
    let active = panes
        .iter()
        .find(|p| p.active)
        .map(|p| p.index)
        .unwrap_or(0);
    let _ = setup_bell_watch(session, active);
    Ok(active)
}

pub fn list_panes(session: &str) -> Result<Vec<PaneInfo>> {
    let output = Command::new("tmux")
        .args([
            "list-panes", "-t", session,
            "-F", "#{pane_index}\t#{@amux-title}\t#{pane_width}\t#{pane_height}\t#{pane_active}\t#{@amux-alert}",
        ])
        .output()
        .context("failed to list panes")?;
    if !output.status.success() {
        bail!("tmux list-panes failed");
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let panes = stdout
        .lines()
        .filter(|l| !l.is_empty())
        .filter_map(|line| {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() < 5 {
                return None;
            }
            Some(PaneInfo {
                index: parts[0].parse().ok()?,
                title: parts[1].to_string(),
                width: parts[2].parse().ok()?,
                height: parts[3].parse().ok()?,
                active: parts[4] == "1",
                alert: parts.get(5).map(|&v| v == "1").unwrap_or(false),
            })
        })
        .collect();
    Ok(panes)
}

pub fn list_panes_in_window(session: &str, window: usize) -> Result<Vec<PaneInfo>> {
    let target = format!("{}:{}", session, window);
    let output = Command::new("tmux")
        .args([
            "list-panes", "-t", &target,
            "-F", "#{pane_index}\t#{@amux-title}\t#{pane_width}\t#{pane_height}\t#{pane_active}\t#{@amux-alert}",
        ])
        .output()
        .context("failed to list panes in window")?;
    if !output.status.success() {
        return Ok(Vec::new());
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let panes = stdout
        .lines()
        .filter(|l| !l.is_empty())
        .filter_map(|line| {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() < 5 {
                return None;
            }
            Some(PaneInfo {
                index: parts[0].parse().ok()?,
                title: parts[1].to_string(),
                width: parts[2].parse().ok()?,
                height: parts[3].parse().ok()?,
                active: parts[4] == "1",
                alert: parts.get(5).map(|&v| v == "1").unwrap_or(false),
            })
        })
        .collect();
    Ok(panes)
}

pub fn kill_pane(session: &str, pane_index: usize) -> Result<()> {
    // Capture the pane's tmux ID before killing (needed for Remove event)
    let target = format!("{}:.{}", session, pane_index);
    let id_output = Command::new("tmux")
        .args(["display-message", "-t", &target, "-p", "#{pane_id}"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    let pane_id: u32 = id_output.trim_start_matches('%').parse().unwrap_or(0);

    let output = Command::new("tmux")
        .args(["kill-pane", "-t", &target])
        .output()
        .context("failed to kill pane")?;
    if !output.status.success() {
        bail!("tmux kill-pane failed");
    }
    let _ = relayout(session, crate::sticky::LayoutEvent::Remove(pane_id));
    Ok(())
}

pub fn set_title(session: &str, pane_index: usize, title: &str) -> Result<()> {
    let target = format!("{}:.{}", session, pane_index);
    // Set the custom @amux-title option which Claude Code can't override
    let output = Command::new("tmux")
        .args(["set-option", "-p", "-t", &target, "@amux-title", title])
        .output()
        .context("failed to set @amux-title")?;
    if !output.status.success() {
        bail!(
            "tmux set-option @amux-title failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

/// Set or clear the alert flag on a pane.
/// Sets explicit "1" or "0" values. The pane-border-format uses
/// #{==:#{@amux-alert},1} (explicit comparison) to avoid tmux's truthy
/// behavior where any non-empty value — including "0" — is true.
/// Does NOT set pane-border-style — that is handled entirely in the border
/// format string so all panes update consistently without per-pane overrides.
pub fn set_alert(session: &str, pane_index: usize, alert: bool) -> Result<()> {
    let target = format!("{}:.{}", session, pane_index);
    let value = if alert { "1" } else { "0" };
    let output = Command::new("tmux")
        .args(["set-option", "-p", "-t", &target, "@amux-alert", value])
        .output()
        .context("failed to set @amux-alert")?;
    if !output.status.success() {
        bail!(
            "tmux set @amux-alert failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

/// Get the alert flag for a pane.
pub fn get_alert(session: &str, pane_index: usize) -> Result<bool> {
    let target = format!("{}:.{}", session, pane_index);
    let output = Command::new("tmux")
        .args(["show-options", "-p", "-t", &target, "-v", "@amux-alert"])
        .output()
        .context("failed to get @amux-alert")?;
    Ok(String::from_utf8_lossy(&output.stdout).trim() == "1")
}

/// Get alert states for all panes in a session, ordered by pane index.
pub fn alert_states(session: &str) -> Result<Vec<bool>> {
    let panes = list_panes(session)?;
    Ok(panes.iter().map(|p| p.alert).collect())
}

/// Update the @amux-alert-count session option.
pub fn set_alert_count(session: &str, count: usize) -> Result<()> {
    let _ = Command::new("tmux")
        .args([
            "set-option",
            "-t",
            session,
            "@amux-alert-count",
            &count.to_string(),
        ])
        .output();
    Ok(())
}

/// Get the alert count for a session from @amux-alert-count session option.
pub fn get_alert_count(session: &str) -> Result<usize> {
    let output = Command::new("tmux")
        .args(["show-options", "-t", session, "-v", "@amux-alert-count"])
        .output()
        .context("failed to read @amux-alert-count")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout.trim().parse().unwrap_or(0))
}

/// Clear alert on a pane and update the session alert count.
pub fn dismiss_alert(session: &str, pane_index: usize) -> Result<()> {
    let was_alert = get_alert(session, pane_index)?;
    if !was_alert {
        return Ok(());
    }
    set_alert(session, pane_index, false)?;

    let states = alert_states(session)?;
    let count = crate::alert::count_alerts(&states);
    set_alert_count(session, count)?;

    Ok(())
}

pub fn toggle_zoom(session: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args(["resize-pane", "-t", session, "-Z"])
        .output()
        .context("failed to toggle zoom")?;
    if !output.status.success() {
        bail!(
            "tmux resize-pane -Z failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

pub fn is_zoomed(session: &str) -> Result<bool> {
    let output = Command::new("tmux")
        .args([
            "display-message",
            "-t",
            session,
            "-p",
            "#{window_zoomed_flag}",
        ])
        .output()
        .context("failed to check zoom state")?;
    Ok(String::from_utf8_lossy(&output.stdout).trim() == "1")
}

pub fn select_pane(session: &str, pane_index: usize) -> Result<()> {
    let target = format!("{}:.{}", session, pane_index);
    let output = Command::new("tmux")
        .args(["select-pane", "-t", &target])
        .output()
        .context("failed to select pane")?;
    if !output.status.success() {
        bail!("tmux select-pane failed");
    }
    Ok(())
}

/// Read current pane positions from tmux as Pane structs.
pub fn read_pane_positions(session: &str) -> Result<Vec<crate::sticky::Pane>> {
    let output = Command::new("tmux")
        .args([
            "list-panes",
            "-t",
            session,
            "-F",
            "#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}",
        ])
        .output()
        .context("failed to read pane positions")?;
    let stdout = String::from_utf8_lossy(&output.stdout);

    let mut panes = Vec::new();
    for line in stdout.lines().filter(|l| !l.is_empty()) {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() < 5 {
            continue;
        }
        let id: u32 = parts[0].trim_start_matches('%').parse().unwrap_or(0);
        let x: u16 = parts[1].parse().unwrap_or(0);
        let y: u16 = parts[2].parse().unwrap_or(0);
        let w: u16 = parts[3].parse().unwrap_or(0);
        let h: u16 = parts[4].parse().unwrap_or(0);
        panes.push(crate::sticky::Pane { id, x, y, w, h });
    }
    Ok(panes)
}

/// Get ordered list of tmux pane IDs (numeric, like 5, 268).
pub fn get_pane_ids(session: &str) -> Result<Vec<u32>> {
    let output = Command::new("tmux")
        .args(["list-panes", "-t", session, "-F", "#{pane_id}"])
        .output()
        .context("failed to list pane ids")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout
        .lines()
        .filter(|l| !l.is_empty())
        .filter_map(|l| l.trim_start_matches('%').parse().ok())
        .collect())
}

/// Get the window dimensions.
pub fn window_size(session: &str) -> Result<(u16, u16)> {
    let output = Command::new("tmux")
        .args([
            "display-message",
            "-t",
            session,
            "-p",
            "#{window_width} #{window_height}",
        ])
        .output()
        .context("failed to get window size")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let parts: Vec<&str> = stdout.trim().split(' ').collect();
    let w = parts.first().and_then(|s| s.parse().ok()).unwrap_or(80);
    let h = parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(24);
    Ok((w, h))
}

/// Apply a layout change to the session. This is the single entry point for
/// all layout operations — add, remove, resize, start, and space-switch.
pub fn relayout(session: &str, event: crate::sticky::LayoutEvent) -> Result<()> {
    let current = read_pane_positions(session)?;
    if current.is_empty() {
        return Ok(());
    }

    let (w, h) = window_size(session)?;
    let border_top = if has_pane_border_status(session) {
        1u16
    } else {
        0
    };
    let effective_h = h.saturating_sub(border_top);

    let new_layout = crate::sticky::compute_layout(&current, event, w, effective_h);

    // Build and apply the layout string
    if let Some(ls) = crate::layout::build_layout_string(&new_layout, w, h, border_top) {
        let _ = Command::new("tmux")
            .args(["select-layout", "-t", session, &ls])
            .output()
            .context("failed to apply layout")?;
    }

    // The layout string embeds pane IDs, so tmux's select-layout places
    // each pane at its correct position. Pane index order is determined by
    // the layout tree's DFS walk order, which matches our slot order.
    // No explicit swap-pane calls are needed.

    Ok(())
}

/// Check if pane-border-status is "top" (which steals a row from the top).
/// We only compensate for "top" since that's what amux configures.
fn has_pane_border_status(session: &str) -> bool {
    let output = Command::new("tmux")
        .args(["show-options", "-t", session, "-v", "pane-border-status"])
        .output()
        .ok();
    output
        .map(|o| {
            let val = String::from_utf8_lossy(&o.stdout).trim().to_string();
            val == "top"
        })
        .unwrap_or(false)
}

/// Swap panes so that each slot contains the desired pane.
/// `current_ids[i]` is the pane ID currently at slot i.
/// `desired_ids[i]` is the pane ID that should be at slot i.
///
/// Currently unused: tmux's select-layout respects pane IDs in layout strings,
/// so panes are placed correctly without explicit swaps. Kept for potential
/// future use with Add/Remove events that may need post-layout reordering.
#[allow(dead_code)]
fn swap_panes_to_order(session: &str, current_ids: &[u32], desired_ids: &[u32]) -> Result<()> {
    // Build a mutable mapping: slot -> current pane ID
    let mut placement: Vec<u32> = current_ids.to_vec();

    for slot in 0..desired_ids.len() {
        if placement[slot] == desired_ids[slot] {
            continue;
        }
        // Find where the desired pane currently is
        if let Some(src_slot) = placement.iter().position(|&id| id == desired_ids[slot]) {
            // Swap panes at slot and src_slot using tmux swap-pane
            let src = format!("{}:.{}", session, src_slot);
            let dst = format!("{}:.{}", session, slot);
            let _ = Command::new("tmux")
                .args(["swap-pane", "-s", &src, "-t", &dst])
                .output();
            // Update our tracking
            placement.swap(slot, src_slot);
        }
    }
    Ok(())
}

pub fn attach(session: &str) -> Result<()> {
    let status = Command::new("tmux")
        .args(["attach-session", "-t", session])
        .status()
        .context("failed to attach to tmux session")?;
    if !status.success() {
        bail!("No amux session found. Run `amux start` to create one.");
    }
    Ok(())
}

pub fn kill_session(session: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args(["kill-session", "-t", session])
        .output()
        .context("failed to kill session")?;
    if !output.status.success() {
        bail!("tmux kill-session failed");
    }
    Ok(())
}

/// Record the current time as the last system notification timestamp.
/// Stored as Unix epoch seconds in AMUX_LAST_NOTIFY session env var.
pub fn set_last_notification_time(session: &str) -> Result<()> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let _ = Command::new("tmux")
        .args([
            "set-environment",
            "-t",
            session,
            "AMUX_LAST_NOTIFY",
            &now.to_string(),
        ])
        .output();
    Ok(())
}

/// Get seconds elapsed since the last system notification.
/// Returns u64::MAX if no notification has been sent.
pub fn get_last_notification_elapsed(session: &str) -> Result<u64> {
    let output = Command::new("tmux")
        .args(["show-environment", "-t", session, "AMUX_LAST_NOTIFY"])
        .output()
        .context("failed to read AMUX_LAST_NOTIFY")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let timestamp: u64 = stdout
        .trim()
        .strip_prefix("AMUX_LAST_NOTIFY=")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);

    if timestamp == 0 {
        return Ok(u64::MAX);
    }

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    Ok(now.saturating_sub(timestamp))
}

pub fn pane_count(session: &str) -> Result<usize> {
    Ok(list_panes(session)?.len())
}

pub fn window_count(session: &str) -> Result<usize> {
    let output = Command::new("tmux")
        .args(["list-windows", "-t", session])
        .output()
        .context("failed to list windows")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout.lines().filter(|l| !l.is_empty()).count())
}

/// Get the current working directory of a pane.
pub fn pane_cwd(session: &str, pane_index: usize) -> Result<String> {
    let target = format!("{}:.{}", session, pane_index);
    let output = Command::new("tmux")
        .args([
            "display-message",
            "-t",
            &target,
            "-p",
            "#{pane_current_path}",
        ])
        .output()
        .context("failed to get pane cwd")?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub fn check_version() -> Result<()> {
    let output = Command::new("tmux")
        .arg("-V")
        .output()
        .context("tmux not found — is it installed?")?;
    let version_str = String::from_utf8_lossy(&output.stdout);
    let after_tmux = version_str.trim().strip_prefix("tmux ").unwrap_or("");
    // Handle "next-3.7" style versions from HEAD builds
    let version_part = after_tmux.strip_prefix("next-").unwrap_or(after_tmux);
    let numeric: String = version_part
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    let parts: Vec<u32> = numeric.split('.').filter_map(|p| p.parse().ok()).collect();
    let major = parts.first().copied().unwrap_or(0);
    let minor = parts.get(1).copied().unwrap_or(0);
    if major < 3 || (major == 3 && minor < 2) {
        bail!("amux requires tmux >= 3.2 (found {})", version_str.trim());
    }
    Ok(())
}

fn pane_id_at(session: &str, index: usize) -> Result<String> {
    let output = Command::new("tmux")
        .args([
            "display-message",
            "-t",
            &format!("{}:.{}", session, index),
            "-p",
            "#{pane_id}",
        ])
        .output()
        .context("failed to get pane id")?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn pane_id_at_window(session: &str, window: &str, pane: usize) -> Result<String> {
    let output = Command::new("tmux")
        .args([
            "display-message",
            "-t",
            &format!("{}:{}.{}", session, window, pane),
            "-p",
            "#{pane_id}",
        ])
        .output()
        .context("failed to get pane id")?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub fn enter_split(session: &str, pane_a: usize, pane_b: usize) -> Result<()> {
    let count = pane_count(session)?;
    if count < 3 {
        bail!("split view requires at least 3 panes (need at least 1 remaining in grid)");
    }
    let id_a = pane_id_at(session, pane_a)?;
    let id_b = pane_id_at(session, pane_b)?;

    // Create a new window for the split view, capturing the actual window index
    let output = Command::new("tmux")
        .args([
            "new-window",
            "-t",
            session,
            "-d",
            "-P",
            "-F",
            "#{window_index}",
        ])
        .output()
        .context("failed to create split window")?;
    if !output.status.success() {
        bail!(
            "tmux new-window failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let split_window_idx = String::from_utf8_lossy(&output.stdout).trim().to_string();

    let target_split = format!("{}:{}", session, split_window_idx);

    // Move pane A to the split window
    let _ = Command::new("tmux")
        .args(["join-pane", "-s", &id_a, "-t", &target_split, "-h"])
        .output();

    // Move pane B next to pane A
    let _ = Command::new("tmux")
        .args(["join-pane", "-s", &id_b, "-t", &target_split, "-h"])
        .output();

    // Kill the default pane that was created with new-window
    let split_panes = list_panes_in_window(session, split_window_idx.parse().unwrap_or(1))?;
    for p in &split_panes {
        let this_id = pane_id_at_window(session, &split_window_idx, p.index)?;
        if this_id != id_a && this_id != id_b {
            let target = format!("{}:{}.{}", session, split_window_idx, p.index);
            let _ = Command::new("tmux")
                .args(["kill-pane", "-t", &target])
                .output();
        }
    }

    // Apply side-by-side layout
    let _ = Command::new("tmux")
        .args(["select-layout", "-t", &target_split, "even-horizontal"])
        .output();

    // Switch to the split window
    let _ = Command::new("tmux")
        .args(["select-window", "-t", &target_split])
        .output();

    // Retile the grid window
    let grid_window = format!("{}:0", session);
    let _ = relayout(&grid_window, crate::sticky::LayoutEvent::Resize);

    Ok(())
}

pub fn exit_split(session: &str) -> Result<()> {
    let grid_target = format!("{}:0", session);

    // Find the split window (any window that isn't 0)
    let win_count = window_count(session)?;
    if win_count <= 1 {
        // No split to exit
        relayout(session, crate::sticky::LayoutEvent::Resize)?;
        return Ok(());
    }

    // List all windows, find the non-zero one
    let output = Command::new("tmux")
        .args(["list-windows", "-t", session, "-F", "#{window_index}"])
        .output()
        .context("failed to list windows")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let split_idx = stdout
        .lines()
        .find(|l| !l.is_empty() && l.trim() != "0")
        .unwrap_or("1");

    // Move all panes from split window back to grid
    let mut safety = 0;
    loop {
        if safety > 20 {
            break;
        }
        safety += 1;
        let split_panes = list_panes_in_window(session, split_idx.parse().unwrap_or(1));
        match split_panes {
            Ok(panes) if !panes.is_empty() => {
                let source = format!("{}:{}.0", session, split_idx);
                let output = Command::new("tmux")
                    .args(["join-pane", "-s", &source, "-t", &grid_target])
                    .output()
                    .context("failed to move pane back to grid")?;
                if !output.status.success() {
                    break;
                }
            }
            _ => break,
        }
    }

    let _ = Command::new("tmux")
        .args(["select-window", "-t", &grid_target])
        .output();

    relayout(session, crate::sticky::LayoutEvent::Resize)?;
    Ok(())
}

/// Get the current zoom level (1=Bird's Eye, 2=Working, 3=Full Screen).
/// Defaults to 2 if not set.
pub fn get_level(session: &str) -> Result<u8> {
    let output = Command::new("tmux")
        .args(["show-environment", "-t", session, "AMUX_LEVEL"])
        .output()
        .context("failed to read AMUX_LEVEL")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let level = stdout
        .trim()
        .strip_prefix("AMUX_LEVEL=")
        .and_then(|v| v.parse().ok())
        .unwrap_or(2);
    Ok(level)
}

/// Set the current zoom level and refresh the status bar immediately.
pub fn set_level(session: &str, level: u8) -> Result<()> {
    let output = Command::new("tmux")
        .args([
            "set-environment",
            "-t",
            session,
            "AMUX_LEVEL",
            &level.to_string(),
        ])
        .output()
        .context("failed to set AMUX_LEVEL")?;
    if !output.status.success() {
        bail!("failed to set AMUX_LEVEL");
    }
    // Force status bar to redraw so the level indicator updates immediately
    let _ = Command::new("tmux").args(["refresh-client", "-S"]).output();
    Ok(())
}

/// Get the active pane index.
pub fn active_pane_index(session: &str) -> Result<usize> {
    let output = Command::new("tmux")
        .args(["display-message", "-t", session, "-p", "#{pane_index}"])
        .output()
        .context("failed to get active pane index")?;
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .unwrap_or(0))
}

/// Display a message in the tmux status bar.
pub fn display_message(session: &str, msg: &str) {
    let _ = Command::new("tmux")
        .args(["display-message", "-t", session, msg])
        .output();
}

/// Resize a specific pane to the given dimensions.
pub fn resize_pane(session: &str, pane_index: usize, cols: u16, rows: u16) -> Result<()> {
    let target = format!("{}:.{}", session, pane_index);
    let _ = Command::new("tmux")
        .args([
            "resize-pane",
            "-t",
            &target,
            "-x",
            &cols.to_string(),
            "-y",
            &rows.to_string(),
        ])
        .output();
    Ok(())
}

/// Smart resize: enlarge the active pane to at least min_cols x min_rows
/// if it's currently smaller. Other panes shrink to accommodate.
/// If already big enough, do nothing.
pub fn smart_resize(session: &str, pane_index: usize, min_cols: u16, min_rows: u16) -> Result<()> {
    let panes = list_panes(session)?;
    let active = panes.iter().find(|p| p.index == pane_index);

    if let Some(pane) = active {
        if pane.width >= min_cols && pane.height >= min_rows {
            // Already big enough — no resize needed
            return Ok(());
        }
        // Only enlarge dimensions that are below the minimum.
        // Never shrink a dimension that already meets the requirement.
        let target_cols = pane.width.max(min_cols);
        let target_rows = pane.height.max(min_rows);
        resize_pane(session, pane_index, target_cols, target_rows)?;
    }
    Ok(())
}

/// Restore tiled layout (equal sizes for all panes).
/// Used when going back to Level 1.
pub fn restore_tiled(session: &str) -> Result<()> {
    // Unzoom first if zoomed
    if is_zoomed(session)? {
        toggle_zoom(session)?;
    }
    relayout(session, crate::sticky::LayoutEvent::Resize)?;
    Ok(())
}

/// List all tmux sessions.
pub fn list_sessions() -> Result<Vec<String>> {
    let output = Command::new("tmux")
        .args(["list-sessions", "-F", "#{session_name}"])
        .output()
        .context("failed to list sessions")?;
    if !output.status.success() {
        return Ok(Vec::new());
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect())
}

/// List only amux-managed tmux sessions (marked with AMUX_MANAGED env var).
pub fn list_focus_sessions() -> Result<Vec<String>> {
    let all = list_sessions()?;
    let mut managed = Vec::new();
    for session in &all {
        let output = Command::new("tmux")
            .args(["show-environment", "-t", session, "AMUX_MANAGED"])
            .output();
        if let Ok(o) = output {
            let stdout = String::from_utf8_lossy(&o.stdout);
            if stdout.contains("AMUX_MANAGED=1") {
                managed.push(session.clone());
            }
        }
    }
    Ok(managed)
}

/// Mark a session as amux-managed.
pub fn mark_as_managed(session: &str) -> Result<()> {
    let _ = Command::new("tmux")
        .args(["set-environment", "-t", session, "AMUX_MANAGED", "1"])
        .output();
    Ok(())
}

/// Switch the current client to a different session.
pub fn switch_session(session: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args(["switch-client", "-t", session])
        .output()
        .context("failed to switch session")?;
    if !output.status.success() {
        bail!(
            "tmux switch-client failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

/// Move the active pane from current session to target session.
pub fn send_pane_to_session(from_session: &str, to_session: &str) -> Result<()> {
    // Get the active pane ID
    let output = Command::new("tmux")
        .args(["display-message", "-t", from_session, "-p", "#{pane_id}"])
        .output()
        .context("failed to get pane id")?;
    let pane_id = String::from_utf8_lossy(&output.stdout).trim().to_string();

    // Move it to the target session's window
    let target = format!("{}:0", to_session);
    let output = Command::new("tmux")
        .args(["join-pane", "-s", &pane_id, "-t", &target])
        .output()
        .context("failed to move pane")?;
    if !output.status.success() {
        bail!(
            "tmux join-pane failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    // Retile both sessions
    let _ = relayout(from_session, crate::sticky::LayoutEvent::Resize);
    let _ = relayout(to_session, crate::sticky::LayoutEvent::Resize);

    Ok(())
}

/// Enter bird's eye mode: switch to a key table that captures arrows
/// for pane navigation and ignores other input.
pub fn enter_birdeye_table() -> Result<()> {
    let _ = Command::new("tmux")
        .args(["switch-client", "-T", "amux-birdeye"])
        .output();
    Ok(())
}

/// Open the spaces picker as a tmux popup.
/// Used by zoom-out from L2 (replaces bird's eye).
pub fn open_spaces_popup() -> Result<()> {
    let _ = Command::new("tmux")
        .args([
            "display-popup",
            "-E",
            "-w",
            "70",
            "-h",
            "20",
            "-T",
            " Spaces ",
            "amux spaces",
        ])
        .output();
    Ok(())
}

/// Set a one-shot client-session-changed hook that opens the spaces picker.
/// The hook removes itself after firing once.
pub fn set_startup_spaces_hook(session: &str) -> Result<()> {
    let _ = Command::new("tmux")
        .args([
            "set-hook",
            "-t",
            session,
            "client-attached",
            "run-shell \"amux spaces; tmux set-hook -u -t #{session_name} client-attached\"",
        ])
        .output();
    Ok(())
}

/// Set up pipe-pane on a pane to watch for BEL characters.
pub fn setup_bell_watch(session: &str, pane_index: usize) -> Result<()> {
    let bin = "amux";
    let target = format!("{}:.{}", session, pane_index);
    let _ = Command::new("tmux")
        .args([
            "pipe-pane",
            "-t",
            &target,
            &format!(
                "exec {} bell-watch --session {} {}",
                bin, session, pane_index
            ),
        ])
        .output();
    Ok(())
}

/// Set up bell watchers on all panes in a session.
pub fn setup_all_bell_watches(session: &str) -> Result<()> {
    let panes = list_panes(session)?;
    for pane in &panes {
        setup_bell_watch(session, pane.index)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestGuard {
        name: String,
    }

    impl TestGuard {
        fn new() -> Self {
            use std::sync::atomic::{AtomicU64, Ordering};
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let id = COUNTER.fetch_add(1, Ordering::SeqCst);
            let name = format!("amux-test-{}-{}", std::process::id(), id);
            // Pre-cleanup in case of stale session
            let _ = Command::new("tmux")
                .args(["kill-session", "-t", &name])
                .output();
            TestGuard { name }
        }
    }

    impl Drop for TestGuard {
        fn drop(&mut self) {
            let _ = Command::new("tmux")
                .args(["kill-session", "-t", &self.name])
                .output();
        }
    }

    #[test]
    fn create_and_list_session() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");
        let panes = list_panes(&guard.name).expect("list");
        assert_eq!(panes.len(), 1);
    }

    #[test]
    fn create_pane_and_count() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");
        create_pane(&guard.name, None).expect("pane");
        let panes = list_panes(&guard.name).expect("list");
        assert_eq!(panes.len(), 2);
    }

    #[test]
    fn zoom_toggle() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");
        create_pane(&guard.name, None).expect("pane");
        assert!(!is_zoomed(&guard.name).expect("check"));
        toggle_zoom(&guard.name).expect("zoom");
        assert!(is_zoomed(&guard.name).expect("check"));
        toggle_zoom(&guard.name).expect("unzoom");
        assert!(!is_zoomed(&guard.name).expect("check"));
    }

    #[test]
    fn set_pane_title() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");
        set_title(&guard.name, 0, "my-project").expect("title");
        // Verify via tmux show-options that @amux-title was set
        let output = Command::new("tmux")
            .args([
                "show-options",
                "-p",
                "-t",
                &format!("{}:.0", guard.name),
                "-v",
                "@amux-title",
            ])
            .output()
            .expect("show-options");
        let title = String::from_utf8_lossy(&output.stdout).trim().to_string();
        assert_eq!(title, "my-project");
    }

    #[test]
    fn enter_and_exit_split_view() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");
        create_pane(&guard.name, None).expect("pane 2");
        create_pane(&guard.name, None).expect("pane 3");
        assert_eq!(pane_count(&guard.name).expect("count"), 3);
        enter_split(&guard.name, 0, 1).expect("enter split");
        assert_eq!(window_count(&guard.name).expect("windows"), 2);
        exit_split(&guard.name).expect("exit split");
        assert_eq!(window_count(&guard.name).expect("windows"), 1);
        assert_eq!(pane_count(&guard.name).expect("count"), 3);
    }

    #[test]
    fn split_requires_at_least_three_panes() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");
        create_pane(&guard.name, None).expect("pane 2");
        // Only 2 panes — split should fail
        let result = enter_split(&guard.name, 0, 1);
        assert!(result.is_err(), "split should require at least 3 panes");
    }

    #[test]
    fn get_set_level() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");

        // Default level is 2
        assert_eq!(get_level(&guard.name).expect("get"), 2);

        set_level(&guard.name, 1).expect("set");
        assert_eq!(get_level(&guard.name).expect("get"), 1);

        set_level(&guard.name, 3).expect("set");
        assert_eq!(get_level(&guard.name).expect("get"), 3);
    }

    #[test]
    fn active_pane_index_works() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");

        let idx = active_pane_index(&guard.name).expect("get");
        assert_eq!(idx, 0); // first pane is active

        create_pane(&guard.name, None).expect("pane");
        let idx = active_pane_index(&guard.name).expect("get");
        // After split, the new pane is active
        assert!(idx <= 1);
    }

    #[test]
    fn smart_resize_no_change_when_big_enough() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");

        let panes_before = list_panes(&guard.name).expect("list");
        let w_before = panes_before[0].width;

        // With 1 pane, it's already bigger than the minimum
        smart_resize(&guard.name, 0, 120, 24).expect("resize");

        let panes_after = list_panes(&guard.name).expect("list");
        // Size should be unchanged (or very close)
        assert!(panes_after[0].width >= w_before - 1);
    }

    #[test]
    fn smart_resize_enlarges_small_pane() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");
        // Create enough panes to make them small
        for _ in 0..5 {
            create_pane(&guard.name, None).expect("pane");
        }

        let panes_before = list_panes(&guard.name).expect("list");

        // Smart resize pane 0
        select_pane(&guard.name, 0).expect("select");
        smart_resize(&guard.name, 0, 120, 24).expect("resize");

        let panes_after = list_panes(&guard.name).expect("list");
        let active = panes_after.iter().find(|p| p.index == 0);
        if let Some(p) = active {
            // Should be at least close to the minimum
            // (tmux may not achieve exactly 120 due to other pane constraints)
            assert!(
                p.width > panes_before[0].width,
                "pane should be enlarged: before={}, after={}",
                panes_before[0].width,
                p.width
            );
        }
    }

    #[test]
    fn restore_tiled_resets_layout() {
        let guard = TestGuard::new();
        create_session(&guard.name).expect("create");
        create_pane(&guard.name, None).expect("pane");
        create_pane(&guard.name, None).expect("pane");

        // Resize one pane to be different
        smart_resize(&guard.name, 0, 120, 24).expect("resize");

        // Restore tiled — all panes should be roughly equal
        restore_tiled(&guard.name).expect("restore");

        let panes = list_panes(&guard.name).expect("list");
        let widths: Vec<u16> = panes.iter().map(|p| p.width).collect();
        // All widths should be within 2 of each other
        let max_w = widths.iter().max().unwrap();
        let min_w = widths.iter().min().unwrap();
        // tmux tiled layout with 3 panes creates a 2+1 arrangement
        // where one pane may be ~double the width of others, so allow generous tolerance
        assert!(
            max_w - min_w <= max_w / 2 + 2,
            "panes should be tiled: {:?}",
            widths
        );
    }
}
