// src/sticky.rs

use anyhow::{Context, Result};
use std::process::Command;

/// A pane's current and previous center coordinates.
#[derive(Debug, Clone)]
pub struct PaneCenter {
    pub id: u32,
    pub cx: i32,
    pub cy: i32,
    pub prev_cx: Option<i32>,
    pub prev_cy: Option<i32>,
}

/// A grid slot's center coordinates.
#[derive(Debug, Clone)]
pub struct SlotCenter {
    pub cx: i32,
    pub cy: i32,
}

/// Match panes to grid slots by minimum geometric displacement.
///
/// Uses greedy nearest-first assignment (sufficient for <= 9 panes;
/// a Hungarian algorithm would be optimal but unnecessary at this scale).
///
/// - `panes`: existing panes with current (and optional previous) centers
/// - `slots`: new grid slot centers (one per slot in the new layout)
/// - `going_up`: if true, prefer previous centers for matching (snap-back)
///
/// Returns `Vec<Option<u32>>` of length `slots.len()`. Each entry is the pane ID
/// assigned to that slot, or `None` if the slot is unoccupied (for new panes).
pub fn match_panes_to_slots(
    panes: &[PaneCenter],
    slots: &[SlotCenter],
    going_up: bool,
) -> Vec<Option<u32>> {
    let mut result: Vec<Option<u32>> = vec![None; slots.len()];
    let mut used_slots: Vec<bool> = vec![false; slots.len()];
    let mut used_panes: Vec<bool> = vec![false; panes.len()];

    let mut pairs: Vec<(usize, usize, i64)> = Vec::new();
    for (pi, pane) in panes.iter().enumerate() {
        let (px, py) = if going_up {
            (
                pane.prev_cx.unwrap_or(pane.cx),
                pane.prev_cy.unwrap_or(pane.cy),
            )
        } else {
            (pane.cx, pane.cy)
        };
        for (si, slot) in slots.iter().enumerate() {
            let dx = (px - slot.cx) as i64;
            let dy = (py - slot.cy) as i64;
            let dist = dx * dx + dy * dy;
            pairs.push((pi, si, dist));
        }
    }

    pairs.sort_by_key(|&(_, _, d)| d);

    for &(pi, si, _) in &pairs {
        if used_panes[pi] || used_slots[si] {
            continue;
        }
        result[si] = Some(panes[pi].id);
        used_panes[pi] = true;
        used_slots[si] = true;
    }

    result
}

/// Compute the center point of a grid slot rectangle.
pub fn rect_center(x: u16, y: u16, w: u16, h: u16) -> (i32, i32) {
    ((x as i32) + (w as i32) / 2, (y as i32) + (h as i32) / 2)
}

/// Save a pane's current center as tmux pane options.
/// Rotates current -> previous before writing new current.
pub fn save_pane_center(session: &str, pane_index: usize, cx: i32, cy: i32) -> Result<()> {
    let target = format!("{}:.{}", session, pane_index);

    // Read current center (if any) and save as previous
    if let Ok((old_cx, old_cy)) = load_pane_center(session, pane_index) {
        set_pane_option(&target, "@amux-pcx", old_cx)?;
        set_pane_option(&target, "@amux-pcy", old_cy)?;
    }

    set_pane_option(&target, "@amux-cx", cx)?;
    set_pane_option(&target, "@amux-cy", cy)?;
    Ok(())
}

/// Load a pane's current center from tmux pane options.
pub fn load_pane_center(session: &str, pane_index: usize) -> Result<(i32, i32)> {
    let target = format!("{}:.{}", session, pane_index);
    let cx = get_pane_option(&target, "@amux-cx")?;
    let cy = get_pane_option(&target, "@amux-cy")?;
    Ok((cx, cy))
}

/// Load a pane's previous center from tmux pane options.
pub fn load_pane_prev_center(session: &str, pane_index: usize) -> Option<(i32, i32)> {
    let target = format!("{}:.{}", session, pane_index);
    let cx = get_pane_option(&target, "@amux-pcx").ok()?;
    let cy = get_pane_option(&target, "@amux-pcy").ok()?;
    Some((cx, cy))
}

/// Read all pane centers for a session, returning PaneCenters keyed by pane ID.
/// Uses a single tmux list-panes call for efficiency.
pub fn read_all_pane_centers(session: &str) -> Result<Vec<PaneCenter>> {
    let output = Command::new("tmux")
        .args([
            "list-panes",
            "-t",
            session,
            "-F",
            "#{pane_id}\t#{pane_index}\t#{@amux-cx}\t#{@amux-cy}\t#{@amux-pcx}\t#{@amux-pcy}",
        ])
        .output()
        .context("failed to list pane centers")?;
    let stdout = String::from_utf8_lossy(&output.stdout);

    let mut centers = Vec::new();
    for line in stdout.lines().filter(|l| !l.is_empty()) {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() < 6 {
            continue;
        }
        let id: u32 = parts[0].trim_start_matches('%').parse().unwrap_or(0);
        let cx = parts[2].parse().ok();
        let cy = parts[3].parse().ok();
        let pcx = parts[4].parse().ok();
        let pcy = parts[5].parse().ok();

        centers.push(PaneCenter {
            id,
            cx: cx.unwrap_or(0),
            cy: cy.unwrap_or(0),
            prev_cx: pcx,
            prev_cy: pcy,
        });
    }
    Ok(centers)
}

fn set_pane_option(target: &str, key: &str, value: i32) -> Result<()> {
    let output = Command::new("tmux")
        .args(["set-option", "-p", "-t", target, key, &value.to_string()])
        .output()
        .with_context(|| format!("failed to set {} on {}", key, target))?;
    if !output.status.success() {
        anyhow::bail!(
            "tmux set-option {} failed: {}",
            key,
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

fn get_pane_option(target: &str, key: &str) -> Result<i32> {
    let output = Command::new("tmux")
        .args(["show-options", "-p", "-t", target, "-v", key])
        .output()
        .with_context(|| format!("failed to get {} on {}", key, target))?;
    let val = String::from_utf8_lossy(&output.stdout).trim().to_string();
    val.parse()
        .with_context(|| format!("{} not set or invalid: {:?}", key, val))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{grid_positions, Rect};

    fn centers_from_rects(rects: &[Rect]) -> Vec<SlotCenter> {
        rects
            .iter()
            .map(|r| {
                let (cx, cy) = rect_center(r.x, r.y, r.w, r.h);
                SlotCenter { cx, cy }
            })
            .collect()
    }

    fn pane_centers_from_rects(rects: &[Rect], ids: &[u32]) -> Vec<PaneCenter> {
        rects
            .iter()
            .zip(ids.iter())
            .map(|(r, &id)| {
                let (cx, cy) = rect_center(r.x, r.y, r.w, r.h);
                PaneCenter {
                    id,
                    cx,
                    cy,
                    prev_cx: None,
                    prev_cy: None,
                }
            })
            .collect()
    }

    fn pane_centers_with_prev(rects: &[Rect], prev_rects: &[Rect], ids: &[u32]) -> Vec<PaneCenter> {
        rects
            .iter()
            .zip(prev_rects.iter())
            .zip(ids.iter())
            .map(|((r, pr), &id)| {
                let (cx, cy) = rect_center(r.x, r.y, r.w, r.h);
                let (pcx, pcy) = rect_center(pr.x, pr.y, pr.w, pr.h);
                PaneCenter {
                    id,
                    cx,
                    cy,
                    prev_cx: Some(pcx),
                    prev_cy: Some(pcy),
                }
            })
            .collect()
    }

    #[test]
    fn add_fifth_pane_existing_fill_first_four_slots() {
        // When going 4→5, apply_grid_layout reserves the last slot for the
        // new pane by only passing the first 4 slots to match_panes_to_slots.
        // Verify existing panes match correctly to those 4 slots.
        let (w, h) = (280, 80);
        let rects_4 = grid_positions(4, w, h);
        let rects_5 = grid_positions(5, w, h);
        let old_ids: Vec<u32> = vec![10, 11, 12, 13];

        let pane_centers = pane_centers_from_rects(&rects_4, &old_ids);
        // Only first 4 slots (last reserved for new pane by caller)
        let slot_centers = centers_from_rects(&rects_5[..4]);

        let matched = match_panes_to_slots(&pane_centers, &slot_centers, true);

        assert_eq!(matched.len(), 4);
        assert_eq!(matched[0], Some(10), "slot 0 (TL)");
        assert_eq!(matched[1], Some(11), "slot 1 (TR)");
        assert_eq!(matched[2], Some(12), "slot 2 (BL)");
        assert_eq!(matched[3], Some(13), "slot 3 (MR) gets old BR pane");
    }

    #[test]
    fn remove_fifth_pane_preserves_original_positions() {
        // Simulate: had 4 panes in 2x2, added 5th, now removing it.
        // After removal, the original 4 panes should return to their
        // original TL/TR/BL/BR slots — no TR↔BL swap.
        let (w, h) = (280, 80);
        let rects_4 = grid_positions(4, w, h);
        let rects_5 = grid_positions(5, w, h);
        let ids: Vec<u32> = vec![10, 11, 12, 13];

        // The 4 panes are currently in 5-pane layout positions (slots 0-3).
        // Their previous centers are from the 4-pane layout.
        let current_rects: Vec<Rect> = (0..4).map(|i| rects_5[i].clone()).collect();
        let pane_centers = pane_centers_with_prev(&current_rects, &rects_4, &ids);

        // Going down (5→4): use current centers
        let slot_centers = centers_from_rects(&rects_4);
        let matched = match_panes_to_slots(&pane_centers, &slot_centers, false);

        // Each pane should return to its original 2x2 slot
        assert_eq!(matched[0], Some(10), "slot 0 (TL) should have pane 10");
        assert_eq!(matched[1], Some(11), "slot 1 (TR) should have pane 11");
        assert_eq!(matched[2], Some(12), "slot 2 (BL) should have pane 12");
        assert_eq!(matched[3], Some(13), "slot 3 (BR) should have pane 13");
    }
}
