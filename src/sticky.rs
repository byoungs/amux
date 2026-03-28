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

/// Structural matching for layout transitions.
///
/// When the layout shape changes (balanced ↔ balanced+column), pure geometric
/// matching can misplace panes that need to jump columns. This function uses
/// structural rules instead:
///
/// - **Balanced+column → balanced (adding: 3→4, 5→6, 7→8)**: the lone column
///   pane takes the top of its nearest column. New pane fills the bottom.
///
/// - **Balanced → balanced+column (adding: 4→5, 6→7)**: existing panes stay
///   in the balanced part. New pane takes the right column.
///
/// - **Balanced+column → balanced (removing: 5→4, 7→6)**: the right-column
///   pane fills the slot vacated by the removed pane. Others stay.
///
/// - **Balanced → balanced+column (removing: 6→5, 8→7)**: the removed pane's
///   column-mate takes the full-height right column. Others fill the balanced part.
///
/// Falls back to geometric matching for cases that don't match these patterns.
pub fn match_panes_structural(
    panes: &[PaneCenter],
    slots: &[SlotCenter],
    prev_count: usize,
    new_count: usize,
) -> Vec<Option<u32>> {
    let prev_balanced = prev_count >= 4 && prev_count.is_multiple_of(2);
    let new_balanced = new_count >= 4 && new_count.is_multiple_of(2);
    let prev_has_column = prev_count >= 3 && prev_count % 2 == 1;
    let new_has_column = new_count >= 3 && new_count % 2 == 1;

    // Adding: balanced+column → balanced (3→4, 5→6, 7→8)
    // The lone column pane goes to top of its column, new pane fills bottom.
    if prev_has_column && new_balanced && new_count == prev_count + 1 {
        return match_column_pane_splits(panes, slots, true);
    }

    // Adding: balanced → balanced+column (4→5, 6→7)
    // Existing panes stay in balanced part, new pane takes right column.
    if prev_balanced && new_has_column && new_count == prev_count + 1 {
        // Match existing to first N slots (balanced part only)
        return match_panes_to_slots(panes, &slots[..panes.len()], false);
    }

    // Removing: balanced+column → balanced (5→4, 7→6)
    // Right-column pane (substitute) fills the gap left by removed pane.
    if prev_has_column && new_balanced && new_count == prev_count - 1 {
        return match_substitute_fills_gap(panes, slots, prev_count);
    }

    // Removing: balanced → balanced+column (6→5, 8→7)
    // Column-mate of removed pane takes the right column.
    if prev_balanced && new_has_column && new_count == prev_count - 1 {
        return match_column_mate_expands(panes, slots, prev_count);
    }

    // Default: geometric matching
    match_panes_to_slots(panes, slots, false)
}

/// When adding a pane to a balanced+column layout to make it balanced,
/// the lone column pane goes to the nearest slot in its nearest column,
/// using prev_cy (when going_up) to pick the correct vertical position
/// for snap-back scenarios (e.g., 4→3→4 where the pane was originally
/// at the bottom).
fn match_column_pane_splits(
    panes: &[PaneCenter],
    slots: &[SlotCenter],
    going_up: bool,
) -> Vec<Option<u32>> {
    let lone_idx = find_lone_column_pane(panes);

    if let Some(idx) = lone_idx {
        let lone = &panes[idx];

        // Use prev_cy when available (snap-back), otherwise default to top.
        // The lone pane goes to the top of its column by default; prev_cy
        // allows it to return to its original row in snap-back scenarios.
        let lone_cy = if going_up {
            lone.prev_cy.unwrap_or(0)
        } else {
            lone.cy
        };

        // Group slots by column (cluster by cx within 10px)
        let mut slot_columns: Vec<(i32, Vec<(usize, &SlotCenter)>)> = Vec::new();
        for (si, s) in slots.iter().enumerate() {
            if let Some(col) = slot_columns
                .iter_mut()
                .find(|(cx, _)| (s.cx - *cx).abs() < 10)
            {
                col.1.push((si, s));
            } else {
                slot_columns.push((s.cx, vec![(si, s)]));
            }
        }

        // Find the column closest to the lone pane's cx
        let nearest_col = slot_columns
            .iter()
            .min_by_key(|(cx, _)| (lone.cx - *cx).abs());

        if let Some((_, col_slots)) = nearest_col {
            // In that column, find the slot closest to the pane's vertical position
            let best_slot = col_slots
                .iter()
                .min_by_key(|(_, s)| (lone_cy - s.cy).abs())
                .map(|(i, _)| *i);

            if let Some(best_si) = best_slot {
                // Match other panes to other slots
                let others: Vec<PaneCenter> = panes
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| *i != idx)
                    .map(|(_, p)| p.clone())
                    .collect();

                let other_slots: Vec<SlotCenter> = slots
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| *i != best_si)
                    .map(|(_, s)| s.clone())
                    .collect();

                let other_matched = match_panes_to_slots(&others, &other_slots, false);

                // Reconstruct full result
                let mut result: Vec<Option<u32>> = vec![None; slots.len()];
                result[best_si] = Some(lone.id);

                let mut other_idx = 0;
                for (si, slot) in result.iter_mut().enumerate() {
                    if si == best_si {
                        continue;
                    }
                    if other_idx < other_matched.len() {
                        *slot = other_matched[other_idx];
                        other_idx += 1;
                    }
                }
                return result;
            }
        }
    }

    match_panes_to_slots(panes, slots, false)
}

/// The right-column pane from the previous layout fills the gap left by the
/// removed pane. All other panes stay in their relative positions.
///
/// Strategy: group non-substitute panes by column (cx clustering), map columns
/// to target columns by horizontal order, assign within each column by cy.
/// The substitute fills whichever slot is left.
fn match_substitute_fills_gap(
    panes: &[PaneCenter],
    slots: &[SlotCenter],
    _prev_count: usize,
) -> Vec<Option<u32>> {
    // The right-column pane is the one with the largest cx (rightmost).
    let substitute_idx = panes
        .iter()
        .enumerate()
        .max_by_key(|(_, p)| p.cx)
        .map(|(i, _)| i);

    if let Some(sub_idx) = substitute_idx {
        let others: Vec<&PaneCenter> = panes
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != sub_idx)
            .map(|(_, p)| p)
            .collect();

        // Group others by column (cluster by cx within 10px)
        let mut columns: Vec<(i32, Vec<&PaneCenter>)> = Vec::new();
        for p in &others {
            if let Some(col) = columns.iter_mut().find(|(cx, _)| (p.cx - *cx).abs() < 10) {
                col.1.push(p);
            } else {
                columns.push((p.cx, vec![p]));
            }
        }
        columns.sort_by_key(|(cx, _)| *cx);

        // Group target slots by column (cluster by cx within 10px)
        let mut slot_columns: Vec<(i32, Vec<(usize, &SlotCenter)>)> = Vec::new();
        for (si, s) in slots.iter().enumerate() {
            if let Some(col) = slot_columns
                .iter_mut()
                .find(|(cx, _)| (s.cx - *cx).abs() < 10)
            {
                col.1.push((si, s));
            } else {
                slot_columns.push((s.cx, vec![(si, s)]));
            }
        }
        slot_columns.sort_by_key(|(cx, _)| *cx);

        // Sort panes within each column by cy, and slots within each column by cy
        for col in &mut columns {
            col.1.sort_by_key(|p| p.cy);
        }
        for col in &mut slot_columns {
            col.1.sort_by_key(|(_, s)| s.cy);
        }

        // Map pane columns to slot columns by horizontal order.
        // Within each column pair, match panes to slots by nearest cy.
        let mut result: Vec<Option<u32>> = vec![None; slots.len()];
        for (pane_col, slot_col) in columns.iter().zip(slot_columns.iter()) {
            let col_panes: Vec<PaneCenter> = pane_col.1.iter().map(|p| (*p).clone()).collect();
            let col_slots: Vec<SlotCenter> = slot_col.1.iter().map(|(_, s)| (*s).clone()).collect();
            let col_matched = match_panes_to_slots(&col_panes, &col_slots, false);
            for (col_si, pane_id) in col_matched.iter().enumerate() {
                if let Some(id) = pane_id {
                    let actual_si = slot_col.1[col_si].0;
                    result[actual_si] = Some(*id);
                }
            }
        }

        // Fill the unoccupied slot with the substitute
        for slot in result.iter_mut() {
            if slot.is_none() {
                *slot = Some(panes[sub_idx].id);
                break;
            }
        }
        result
    } else {
        match_panes_to_slots(panes, slots, false)
    }
}

/// The column-mate of the removed pane takes the full-height column slot.
/// The remaining panes fill the split slots.
///
/// The full-height slot is identified by finding the slot that is alone in
/// its column (no other slot shares a similar cx). This works for both
/// 3-pane (full-height LEFT) and 5+pane (full-height RIGHT) layouts.
fn match_column_mate_expands(
    panes: &[PaneCenter],
    slots: &[SlotCenter],
    _prev_count: usize,
) -> Vec<Option<u32>> {
    let column_mate_idx = find_lone_column_pane(panes);

    // Find the full-height slot — the one alone in its column
    let full_height_slot = find_lone_column_slot(slots);

    if let (Some(mate_idx), Some(fh_slot)) = (column_mate_idx, full_height_slot) {
        let others: Vec<PaneCenter> = panes
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != mate_idx)
            .map(|(_, p)| p.clone())
            .collect();

        let other_slots: Vec<SlotCenter> = slots
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != fh_slot)
            .map(|(_, s)| s.clone())
            .collect();

        let other_matched = match_panes_to_slots(&others, &other_slots, false);

        // Reconstruct full result with column-mate at the full-height slot
        let mut result: Vec<Option<u32>> = vec![None; slots.len()];
        result[fh_slot] = Some(panes[mate_idx].id);

        let mut other_idx = 0;
        for (si, slot) in result.iter_mut().enumerate() {
            if si == fh_slot {
                continue;
            }
            if other_idx < other_matched.len() {
                *slot = other_matched[other_idx];
                other_idx += 1;
            }
        }
        result
    } else {
        match_panes_to_slots(panes, slots, false)
    }
}

/// Find the slot that is alone in its column (no other slot shares a similar cx).
fn find_lone_column_slot(slots: &[SlotCenter]) -> Option<usize> {
    for (i, s) in slots.iter().enumerate() {
        let has_partner = slots
            .iter()
            .enumerate()
            .any(|(j, other)| j != i && (s.cx - other.cx).abs() < 10);
        if !has_partner {
            return Some(i);
        }
    }
    None
}

/// Find the pane that is alone in its column (no other pane shares a similar cx).
fn find_lone_column_pane(panes: &[PaneCenter]) -> Option<usize> {
    for (i, p) in panes.iter().enumerate() {
        let has_partner = panes
            .iter()
            .enumerate()
            .any(|(j, other)| j != i && (p.cx - other.cx).abs() < 10);
        if !has_partner {
            return Some(i);
        }
    }
    None
}

/// Result of compute_pane_order: the desired pane ordering plus which
/// layout variant to use for the tmux layout string.
pub struct PaneLayout {
    pub ordered_ids: Vec<u32>,
    /// True when the 3-pane layout should use full-height RIGHT column
    /// instead of the standard full-height LEFT.
    pub three_pane_right_full: bool,
}

/// Pure state transformation: given the current pane IDs, their saved centers,
/// the previous pane count, and window dimensions, compute the desired pane
/// ordering. This is the functional core extracted from apply_grid_layout —
/// both production and tests call this same function.
pub fn compute_pane_order(
    ids: &[u32],
    pane_centers: &[PaneCenter],
    prev_count: usize,
    w: u16,
    h: u16,
) -> PaneLayout {
    // Build matching input — only include panes that have saved center data.
    // New panes (no center data) are excluded and fill leftover slots.
    let match_input: Vec<PaneCenter> = ids
        .iter()
        .filter_map(|&id| {
            pane_centers
                .iter()
                .find(|p| p.id == id)
                .filter(|p| p.cx != 0 || p.cy != 0 || p.prev_cx.is_some())
                .cloned()
        })
        .collect();

    // For 4→3 transitions, detect which side the lone pane is on.
    // If the lone pane (column-mate) is on the right, use a right-full layout
    // so it expands in place instead of jumping to the left side.
    let right_full_3 = ids.len() == 3
        && prev_count == 4
        && find_lone_column_pane(&match_input)
            .map(|i| {
                let lone_cx = match_input[i].cx;
                let avg_cx =
                    match_input.iter().map(|p| p.cx as i64).sum::<i64>() / match_input.len() as i64;
                lone_cx as i64 > avg_cx
            })
            .unwrap_or(false);

    let rects = if right_full_3 {
        crate::layout::grid_positions_3_right(w, h)
    } else {
        crate::layout::grid_positions(ids.len(), w, h)
    };

    let slot_centers: Vec<SlotCenter> = rects
        .iter()
        .map(|r| {
            let (cx, cy) = rect_center(r.x, r.y, r.w, r.h);
            SlotCenter { cx, cy }
        })
        .collect();

    // Structural matching handles both adding and removing transitions.
    // It detects layout shape changes (balanced ↔ balanced+column) and
    // uses column-aware rules. Falls back to geometric matching for
    // unrecognized patterns.
    let matched = match_panes_structural(&match_input, &slot_centers, prev_count, ids.len());

    let matched_ids: Vec<u32> = matched.iter().filter_map(|&id| id).collect();
    let mut unmatched_iter = ids.iter().filter(|id| !matched_ids.contains(id));
    let mut ordered: Vec<u32> = matched
        .iter()
        .map(|opt| match opt {
            Some(id) => *id,
            None => *unmatched_iter.next().unwrap_or(&ids[0]),
        })
        .collect();
    for &id in unmatched_iter {
        ordered.push(id);
    }

    PaneLayout {
        ordered_ids: ordered,
        three_pane_right_full: right_full_3,
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Tests: Sticky Pane Behavior
//
// These tests define the desired behavior for pane placement when adding
// and removing panes. The layout alternates between balanced grids and
// balanced+column layouts:
//
//   1    2       3         4       5          6        7            8
//  [A] [A][B] [A][B] [AB][AB] [AB  ][AB] [ABC][ABC] [ABC  ][ABC] [ABCD][ABCD]
//              [  C] [CD][CD] [CD E][CD] [DEF][DEF] [DEF G][DEF]
//
// Two principles govern placement:
// 1. New panes always go to the last slot (rightmost/bottommost)
// 2. Existing panes move as little as possible
//
// See docs/sticky-panes.md for the full design rationale.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::grid_positions;

    // ── Helpers ──────────────────────────────────────────────────────

    /// Build PaneCenter state from grid_positions — simulates what tmux
    /// would report for panes sitting in an N-pane layout.
    fn state(count: usize, ids: &[u32], w: u16, h: u16) -> Vec<PaneCenter> {
        let rects = grid_positions(count, w, h);
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

    /// Build PaneCenter state with prev centers — simulates panes that
    /// transitioned from one layout to another (prev = where they were).
    fn state_with_prev(
        current_count: usize,
        prev_count: usize,
        ids: &[u32],
        w: u16,
        h: u16,
    ) -> Vec<PaneCenter> {
        let cur = grid_positions(current_count, w, h);
        let prev = grid_positions(prev_count, w, h);
        cur.iter()
            .zip(prev.iter())
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

    /// Shorthand: compute_pane_order → ordered_ids
    fn order(ids: &[u32], centers: &[PaneCenter], prev: usize, w: u16, h: u16) -> Vec<u32> {
        compute_pane_order(ids, centers, prev, w, h).ordered_ids
    }

    const W: u16 = 280;
    const H: u16 = 80;

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ADDING PANES
    //
    // New pane always goes to the last slot. Existing panes stay put.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #[test]
    fn add_3_to_4() {
        //  [A][B]    [A][B]
        //  [_][C] →  [N][C]
        let c = state(3, &[10, 11, 12], W, H);
        let o = order(&[10, 11, 12, 99], &c, 3, W, H);
        assert_eq!(o, [10, 11, 99, 12]);
    }

    #[test]
    fn add_4_to_5() {
        //  [A][B]    [A][B][ ]
        //  [C][D] →  [C][D][N]
        let c = state(4, &[10, 11, 12, 13], W, H);
        let o = order(&[10, 11, 12, 13, 99], &c, 4, W, H);
        assert_eq!(o, [10, 11, 12, 13, 99]);
    }

    #[test]
    fn add_5_to_6() {
        //  [A][B][_]    [A][B][E]
        //  [C][D][E] →  [C][D][N]
        let mut c = state_with_prev(5, 4, &[10, 11, 12, 13], W, H);
        let r5 = grid_positions(5, W, H);
        let (cx, cy) = rect_center(r5[4].x, r5[4].y, r5[4].w, r5[4].h);
        c.push(PaneCenter {
            id: 14,
            cx,
            cy,
            prev_cx: None,
            prev_cy: None,
        });
        let o = order(&[10, 11, 12, 13, 14, 99], &c, 5, W, H);
        assert_eq!(o, [10, 11, 14, 12, 13, 99]);
    }

    #[test]
    fn add_6_to_7() {
        //  [A][B][C]    [A][B][C][ ]
        //  [D][E][F] →  [D][E][F][N]
        let c = state(6, &[10, 11, 12, 13, 14, 15], W, H);
        let o = order(&[10, 11, 12, 13, 14, 15, 99], &c, 6, W, H);
        assert_eq!(o, [10, 11, 12, 13, 14, 15, 99]);
    }

    #[test]
    fn add_7_to_8() {
        //  [A][B][C][_]    [A][B][C][G]
        //  [D][E][F][G] →  [D][E][F][N]
        let mut c = state_with_prev(7, 6, &[10, 11, 12, 13, 14, 15], W, H);
        let r7 = grid_positions(7, W, H);
        let (cx, cy) = rect_center(r7[6].x, r7[6].y, r7[6].w, r7[6].h);
        c.push(PaneCenter {
            id: 16,
            cx,
            cy,
            prev_cx: None,
            prev_cy: None,
        });
        let o = order(&[10, 11, 12, 13, 14, 15, 16, 99], &c, 7, W, H);
        assert_eq!(o, [10, 11, 12, 16, 13, 14, 15, 99]);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // REMOVING FROM 4-PANE (4→3) — Column-Mate Expands
    //
    // Left-column removal → left-full layout (standard)
    // Right-column removal → right-full layout (mirrored)
    // Column-mate expands on its own side. Other column stays split.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #[test]
    fn remove_4_tl() {
        //  [x][B]    [ ][B]
        //  [C][D] →  [C][D]    C expands full-left
        let c = state(4, &[10, 11, 12, 13], W, H);
        let pl = compute_pane_order(&[11, 12, 13], &c, 4, W, H);
        assert!(!pl.three_pane_right_full);
        assert_eq!(pl.ordered_ids, [12, 11, 13]);
    }

    #[test]
    fn remove_4_tr() {
        //  [A][x]    [A][ ]
        //  [C][D] →  [C][D]    D expands full-right
        let c = state(4, &[10, 11, 12, 13], W, H);
        let pl = compute_pane_order(&[10, 12, 13], &c, 4, W, H);
        assert!(pl.three_pane_right_full);
        assert_eq!(pl.ordered_ids, [10, 12, 13]);
    }

    #[test]
    fn remove_4_bl() {
        //  [A][B]    [A][B]
        //  [x][D] →  [ ][D]    A expands full-left
        let c = state(4, &[10, 11, 12, 13], W, H);
        let pl = compute_pane_order(&[10, 11, 13], &c, 4, W, H);
        assert!(!pl.three_pane_right_full);
        assert_eq!(pl.ordered_ids, [10, 11, 13]);
    }

    #[test]
    fn remove_4_br() {
        //  [A][B]    [A][ ]
        //  [C][x] →  [C][B]    B expands full-right
        let c = state(4, &[10, 11, 12, 13], W, H);
        let pl = compute_pane_order(&[10, 11, 12], &c, 4, W, H);
        assert!(pl.three_pane_right_full);
        assert_eq!(pl.ordered_ids, [10, 12, 11]);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // REMOVING FROM 5-PANE (5→4) — Substitute Fills Gap
    //
    // 5-pane: [TL TR BL BR | R]
    // Remove from 2x2 part → right-col pane fills the gap.
    // Remove right-col → 2x2 stays unchanged.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #[test]
    fn remove_5_tl() {
        let c = state(5, &[10, 11, 12, 13, 14], W, H);
        assert_eq!(order(&[11, 12, 13, 14], &c, 5, W, H), [14, 11, 12, 13]);
    }
    #[test]
    fn remove_5_tr() {
        let c = state(5, &[10, 11, 12, 13, 14], W, H);
        assert_eq!(order(&[10, 12, 13, 14], &c, 5, W, H), [10, 14, 12, 13]);
    }
    #[test]
    fn remove_5_bl() {
        let c = state(5, &[10, 11, 12, 13, 14], W, H);
        assert_eq!(order(&[10, 11, 13, 14], &c, 5, W, H), [10, 11, 14, 13]);
    }
    #[test]
    fn remove_5_br() {
        let c = state(5, &[10, 11, 12, 13, 14], W, H);
        assert_eq!(order(&[10, 11, 12, 14], &c, 5, W, H), [10, 11, 12, 14]);
    }
    #[test]
    fn remove_5_rcol() {
        let c = state(5, &[10, 11, 12, 13, 14], W, H);
        assert_eq!(order(&[10, 11, 12, 13], &c, 5, W, H), [10, 11, 12, 13]);
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // REMOVING FROM 6-PANE (6→5) — Column-Mate to Right Column
    //
    // 6-pane 3x2: [TL TM TR | BL BM BR]
    // Column-mate of removed pane takes the full-height right column.
    // Other 4 panes fill the 2x2 part.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #[test]
    fn remove_6_tl() {
        //  [x][B][C]    [B][C][ ]
        //  [D][E][F] →  [E][F][D]   D=column-mate→R
        let c = state(6, &[10, 11, 12, 13, 14, 15], W, H);
        assert_eq!(
            order(&[11, 12, 13, 14, 15], &c, 6, W, H),
            [12, 11, 15, 14, 13]
        );
    }
    #[test]
    fn remove_6_tm() {
        //  [A][x][C]    [A][C][ ]
        //  [D][E][F] →  [D][F][E]   E=column-mate→R
        let c = state(6, &[10, 11, 12, 13, 14, 15], W, H);
        assert_eq!(
            order(&[10, 12, 13, 14, 15], &c, 6, W, H),
            [10, 12, 13, 15, 14]
        );
    }
    #[test]
    fn remove_6_tr() {
        //  [A][B][x]    [A][B][ ]
        //  [D][E][F] →  [D][E][F]   F=column-mate→R
        let c = state(6, &[10, 11, 12, 13, 14, 15], W, H);
        assert_eq!(
            order(&[10, 11, 13, 14, 15], &c, 6, W, H),
            [10, 11, 13, 14, 15]
        );
    }
    #[test]
    fn remove_6_bl() {
        //  [A][B][C]    [B][C][ ]
        //  [x][E][F] →  [E][F][A]   A=column-mate→R
        let c = state(6, &[10, 11, 12, 13, 14, 15], W, H);
        assert_eq!(
            order(&[10, 11, 12, 14, 15], &c, 6, W, H),
            [12, 11, 15, 14, 10]
        );
    }
    #[test]
    fn remove_6_bm() {
        //  [A][B][C]    [A][C][ ]
        //  [D][x][F] →  [D][F][B]   B=column-mate→R
        let c = state(6, &[10, 11, 12, 13, 14, 15], W, H);
        assert_eq!(
            order(&[10, 11, 12, 13, 15], &c, 6, W, H),
            [10, 12, 13, 15, 11]
        );
    }
    #[test]
    fn remove_6_br() {
        //  [A][B][C]    [A][B][ ]
        //  [D][E][x] →  [D][E][C]   C=column-mate→R
        let c = state(6, &[10, 11, 12, 13, 14, 15], W, H);
        assert_eq!(
            order(&[10, 11, 12, 13, 14], &c, 6, W, H),
            [10, 11, 13, 14, 12]
        );
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // REMOVING FROM 7-PANE (7→6) — Substitute Fills Gap
    //
    // 7-pane: [TL TM TR | BL BM BR | R]
    // Remove from 3x2 part → right-col pane fills the gap.
    // Remove right-col → 3x2 stays unchanged.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #[test]
    fn remove_7_tl() {
        let c = state(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        assert_eq!(
            order(&[11, 12, 13, 14, 15, 16], &c, 7, W, H),
            [16, 11, 12, 13, 14, 15]
        );
    }
    #[test]
    fn remove_7_tm() {
        let c = state(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        assert_eq!(
            order(&[10, 12, 13, 14, 15, 16], &c, 7, W, H),
            [10, 16, 12, 13, 14, 15]
        );
    }
    #[test]
    fn remove_7_tr() {
        let c = state(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        assert_eq!(
            order(&[10, 11, 13, 14, 15, 16], &c, 7, W, H),
            [10, 11, 16, 13, 14, 15]
        );
    }
    #[test]
    fn remove_7_bl() {
        let c = state(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        assert_eq!(
            order(&[10, 11, 12, 14, 15, 16], &c, 7, W, H),
            [10, 11, 12, 16, 14, 15]
        );
    }
    #[test]
    fn remove_7_bm() {
        let c = state(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        assert_eq!(
            order(&[10, 11, 12, 13, 15, 16], &c, 7, W, H),
            [10, 11, 12, 13, 16, 15]
        );
    }
    #[test]
    fn remove_7_br() {
        let c = state(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        assert_eq!(
            order(&[10, 11, 12, 13, 14, 16], &c, 7, W, H),
            [10, 11, 12, 13, 14, 16]
        );
    }
    #[test]
    fn remove_7_rcol() {
        let c = state(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        assert_eq!(
            order(&[10, 11, 12, 13, 14, 15], &c, 7, W, H),
            [10, 11, 12, 13, 14, 15]
        );
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // REMOVING FROM 8-PANE (8→7) — Column-Mate to Right Column
    //
    // 8-pane 4x2: [TL TML TMR TR | BL BML BMR BR]
    // Column-mate of removed pane takes the full-height right column.
    // Other 6 panes fill the 3x2 part.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #[test]
    fn remove_8_tl() {
        // BL=column-mate→R, others→3x2
        let c = state(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        assert_eq!(
            order(&[11, 12, 13, 14, 15, 16, 17], &c, 8, W, H),
            [13, 11, 12, 17, 15, 16, 14]
        );
    }
    #[test]
    fn remove_8_tml() {
        let c = state(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        assert_eq!(
            order(&[10, 12, 13, 14, 15, 16, 17], &c, 8, W, H),
            [10, 13, 12, 14, 17, 16, 15]
        );
    }
    #[test]
    fn remove_8_tmr() {
        let c = state(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        assert_eq!(
            order(&[10, 11, 13, 14, 15, 16, 17], &c, 8, W, H),
            [10, 11, 13, 14, 15, 17, 16]
        );
    }
    #[test]
    fn remove_8_tr() {
        let c = state(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        assert_eq!(
            order(&[10, 11, 12, 14, 15, 16, 17], &c, 8, W, H),
            [10, 11, 12, 14, 15, 16, 17]
        );
    }
    #[test]
    fn remove_8_bl() {
        // TL=column-mate→R
        let c = state(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        assert_eq!(
            order(&[10, 11, 12, 13, 15, 16, 17], &c, 8, W, H),
            [13, 11, 12, 17, 15, 16, 10]
        );
    }
    #[test]
    fn remove_8_bml() {
        let c = state(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        assert_eq!(
            order(&[10, 11, 12, 13, 14, 16, 17], &c, 8, W, H),
            [10, 13, 12, 14, 17, 16, 11]
        );
    }
    #[test]
    fn remove_8_bmr() {
        let c = state(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        assert_eq!(
            order(&[10, 11, 12, 13, 14, 15, 17], &c, 8, W, H),
            [10, 11, 13, 14, 15, 17, 12]
        );
    }
    #[test]
    fn remove_8_br() {
        // TR=column-mate→R
        let c = state(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        assert_eq!(
            order(&[10, 11, 12, 13, 14, 15, 16], &c, 8, W, H),
            [10, 11, 12, 14, 15, 16, 13]
        );
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // SNAP-BACK — Removing the last-added pane reverses the add
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #[test]
    fn snap_back_5_to_4() {
        let c = state_with_prev(5, 4, &[10, 11, 12, 13], W, H);
        assert_eq!(order(&[10, 11, 12, 13], &c, 5, W, H), [10, 11, 12, 13]);
    }
}
