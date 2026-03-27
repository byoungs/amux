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
    let new_has_column = new_count >= 5 && new_count % 2 == 1;

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

/// The column-mate of the removed pane takes the full-height right column.
/// The remaining panes fill the balanced part.
fn match_column_mate_expands(
    panes: &[PaneCenter],
    slots: &[SlotCenter],
    _prev_count: usize,
) -> Vec<Option<u32>> {
    let column_mate_idx = find_lone_column_pane(panes);
    let right_col_slot = slots.len() - 1;

    if let Some(mate_idx) = column_mate_idx {
        let others: Vec<PaneCenter> = panes
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != mate_idx)
            .map(|(_, p)| p.clone())
            .collect();

        let other_slots = &slots[..right_col_slot];
        let mut result = match_panes_to_slots(&others, other_slots, false);
        result.push(Some(panes[mate_idx].id));
        result
    } else {
        match_panes_to_slots(panes, slots, false)
    }
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
    use crate::layout::{grid_positions, Rect};

    // ── Helpers ──────────────────────────────────────────────────────

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

    /// Simulate what apply_grid_layout does when adding a pane.
    /// Returns the final ordered pane IDs (existing + new_pane_id).
    fn simulate_add_pane(
        existing: &[PaneCenter],
        new_pane_id: u32,
        new_total: usize,
        w: u16,
        h: u16,
    ) -> Vec<u32> {
        let rects = grid_positions(new_total, w, h);
        let slot_centers = centers_from_rects(&rects);

        // Option A: match existing panes to ALL slots.
        // Use structural matching when a lone column pane exists
        // (balanced+column → balanced transitions like 3→4, 5→6, 7→8).
        let matched = match_panes_structural(existing, &slot_centers, existing.len(), new_total);

        let matched_ids: Vec<u32> = matched.iter().filter_map(|&id| id).collect();
        let all_ids: Vec<u32> = existing
            .iter()
            .map(|p| p.id)
            .chain(std::iter::once(new_pane_id))
            .collect();
        let mut unmatched = all_ids.iter().filter(|id| !matched_ids.contains(id));
        let mut ordered: Vec<u32> = matched
            .iter()
            .map(|opt| match opt {
                Some(id) => *id,
                None => *unmatched.next().unwrap(),
            })
            .collect();
        for &id in unmatched {
            ordered.push(id);
        }
        ordered
    }

    /// Simulate what apply_grid_layout does when a pane is removed.
    /// Takes explicit target slot rects (since the layout variant may differ
    /// from what grid_positions returns — e.g., full-height right vs left).
    fn simulate_remove_pane(
        panes_before: &[PaneCenter],
        removed_id: u32,
        target_rects: &[Rect],
    ) -> Vec<u32> {
        let remaining: Vec<PaneCenter> = panes_before
            .iter()
            .filter(|p| p.id != removed_id)
            .cloned()
            .collect();
        let slots = centers_from_rects(target_rects);
        let matched =
            match_panes_structural(&remaining, &slots, panes_before.len(), target_rects.len());
        matched.iter().map(|opt| opt.unwrap()).collect()
    }

    /// 3-pane layout: split left column + full-height right column.
    /// (Mirror of the standard 3-pane layout which has full-height LEFT.)
    fn layout_3_full_right(w: u16, h: u16) -> Vec<Rect> {
        let right_w = (w - 1) / 2;
        let left_w = w - 1 - right_w;
        let top_h = (h - 1) / 2;
        let bot_h = h - 1 - top_h;
        vec![
            Rect {
                x: 0,
                y: 0,
                w: left_w,
                h: top_h,
            }, // left-top
            Rect {
                x: 0,
                y: top_h + 1,
                w: left_w,
                h: bot_h,
            }, // left-bottom
            Rect {
                x: left_w + 1,
                y: 0,
                w: right_w,
                h: h,
            }, // right full
        ]
    }

    const W: u16 = 280;
    const H: u16 = 80;

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ADDING PANES
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // ── 3→4: unbalanced → balanced ──────────────────────────────────
    //
    //  BEFORE (3 panes):          AFTER (4 panes):
    //  ┌──────┬──────┐            ┌──────┬──────┐
    //  │      │  B   │            │  A   │  B   │
    //  │  A   ├──────┤    →       ├──────┼──────┤
    //  │      │  C   │            │ NEW  │  C   │
    //  └──────┴──────┘            └──────┴──────┘
    //
    //  Right column untouched. Left pane shrinks to TL. New pane fills BL.

    #[test]
    fn add_pane_3_to_4() {
        let rects_3 = grid_positions(3, W, H);
        let panes = pane_centers_from_rects(&rects_3, &[10, 11, 12]);

        let ordered = simulate_add_pane(&panes, 99, 4, W, H);

        assert_eq!(ordered[0], 10, "TL: left pane stays left");
        assert_eq!(ordered[1], 11, "TR: right-top stays");
        assert_eq!(ordered[2], 99, "BL: new pane fills the gap");
        assert_eq!(ordered[3], 12, "BR: right-bottom stays");
    }

    // ── 4→5: balanced → balanced+column ─────────────────────────────
    //
    //  BEFORE (4 panes):          AFTER (5 panes):
    //  ┌──────┬──────┐            ┌───┬───┬─────┐
    //  │  A   │  B   │            │ A │ B │     │
    //  ├──────┼──────┤    →       ├───┼───┤ NEW │
    //  │  C   │  D   │            │ C │ D │     │
    //  └──────┴──────┘            └───┴───┴─────┘
    //
    //  2x2 shifts slightly narrower but stays in position.
    //  New pane is a full-height column on the right.

    #[test]
    fn add_pane_4_to_5() {
        let rects_4 = grid_positions(4, W, H);
        let panes = pane_centers_from_rects(&rects_4, &[10, 11, 12, 13]);

        let ordered = simulate_add_pane(&panes, 99, 5, W, H);

        assert_eq!(ordered[0], 10, "TL: stays top-left");
        assert_eq!(ordered[1], 11, "TR: stays top-right");
        assert_eq!(ordered[2], 12, "BL: stays bottom-left");
        assert_eq!(ordered[3], 13, "BR: stays bottom-right");
        assert_eq!(ordered[4], 99, "R: new pane is right column");
    }

    // ── 5→6: balanced+column → balanced ─────────────────────────────
    //
    //  BEFORE (5 panes):          AFTER (6 panes):
    //  ┌───┬───┬─────┐            ┌───┬───┬───┐
    //  │ A │ B │     │            │ A │ B │ E │
    //  ├───┼───┤  E  │    →       ├───┼───┼───┤
    //  │ C │ D │     │            │ C │ D │NEW│
    //  └───┴───┴─────┘            └───┴───┴───┘
    //
    //  Right column (E) shrinks to top-right. New pane fills bottom-right.
    //  2x2 block (A,B,C,D) completely untouched.

    #[test]
    fn add_pane_5_to_6() {
        let rects_5 = grid_positions(5, W, H);
        let rects_4 = grid_positions(4, W, H);

        // Panes 10-13 have prev centers from the 4-pane layout.
        // Pane 14 was new in 4→5, so no prev center.
        let mut panes = pane_centers_with_prev(&rects_5[..4], &rects_4, &[10, 11, 12, 13]);
        let (cx, cy) = rect_center(rects_5[4].x, rects_5[4].y, rects_5[4].w, rects_5[4].h);
        panes.push(PaneCenter {
            id: 14,
            cx,
            cy,
            prev_cx: None,
            prev_cy: None,
        });

        let ordered = simulate_add_pane(&panes, 99, 6, W, H);

        assert_eq!(ordered[0], 10, "TL: stays top-left");
        assert_eq!(ordered[1], 11, "TM: stays (was TR of 2x2)");
        assert_eq!(ordered[2], 14, "TR: right column pane moves to top-right");
        assert_eq!(ordered[3], 12, "BL: stays bottom-left");
        assert_eq!(ordered[4], 13, "BM: stays (was BR of 2x2)");
        assert_eq!(ordered[5], 99, "BR: new pane fills bottom-right");
    }

    // ── 6→7: balanced → balanced+column ─────────────────────────────
    //
    //  BEFORE (6 panes):          AFTER (7 panes):
    //  ┌───┬───┬───┐              ┌──┬──┬──┬────┐
    //  │ A │ B │ C │              │A │B │C │    │
    //  ├───┼───┼───┤    →         ├──┼──┼──┤NEW │
    //  │ D │ E │ F │              │D │E │F │    │
    //  └───┴───┴───┘              └──┴──┴──┴────┘
    //
    //  3x2 shifts narrower but stays in position. New column on right.

    #[test]
    fn add_pane_6_to_7() {
        let rects_6 = grid_positions(6, W, H);
        let panes = pane_centers_from_rects(&rects_6, &[10, 11, 12, 13, 14, 15]);

        let ordered = simulate_add_pane(&panes, 99, 7, W, H);

        assert_eq!(ordered[0], 10, "TL");
        assert_eq!(ordered[1], 11, "TM");
        assert_eq!(ordered[2], 12, "TR");
        assert_eq!(ordered[3], 13, "BL");
        assert_eq!(ordered[4], 14, "BM");
        assert_eq!(ordered[5], 15, "BR");
        assert_eq!(ordered[6], 99, "R: new right column");
    }

    // ── 7→8: balanced+column → balanced ─────────────────────────────
    //
    //  BEFORE (7 panes):          AFTER (8 panes):
    //  ┌──┬──┬──┬────┐            ┌──┬──┬──┬──┐
    //  │A │B │C │    │            │A │B │C │G │
    //  ├──┼──┼──┤ G  │    →       ├──┼──┼──┼──┤
    //  │D │E │F │    │            │D │E │F │NW│
    //  └──┴──┴──┴────┘            └──┴──┴──┴──┘
    //
    //  G shrinks to top-right. New pane fills bottom-right.

    #[test]
    fn add_pane_7_to_8() {
        let rects_7 = grid_positions(7, W, H);
        let rects_6 = grid_positions(6, W, H);

        let mut panes = pane_centers_with_prev(&rects_7[..6], &rects_6, &[10, 11, 12, 13, 14, 15]);
        let (cx, cy) = rect_center(rects_7[6].x, rects_7[6].y, rects_7[6].w, rects_7[6].h);
        panes.push(PaneCenter {
            id: 16,
            cx,
            cy,
            prev_cx: None,
            prev_cy: None,
        });

        let ordered = simulate_add_pane(&panes, 99, 8, W, H);

        assert_eq!(ordered[0], 10, "TL");
        assert_eq!(ordered[1], 11, "TM-left");
        assert_eq!(ordered[2], 12, "TM-right");
        assert_eq!(ordered[3], 16, "TR: right column pane moves to top-right");
        assert_eq!(ordered[4], 13, "BL");
        assert_eq!(ordered[5], 14, "BM-left");
        assert_eq!(ordered[6], 15, "BM-right");
        assert_eq!(ordered[7], 99, "BR: new pane fills bottom-right");
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // REMOVING PANES — Column-Mate Expands (balanced → unbalanced)
    //
    // When a pane is removed from a balanced grid, its column-mate expands
    // to full height. The other columns stay split.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // ── 4→3: remove TL ──────────────────────────────────────────────
    //
    //  ┌───┬───┐     ┌───┬───┐
    //  │ x │ B │     │   │ B │
    //  ├───┼───┤  →  │ C ├───┤    C (column-mate of removed TL) expands.
    //  │ C │ D │     │   │ D │    B and D stay on right.
    //  └───┴───┘     └───┴───┘

    #[test]
    fn remove_tl_from_2x2() {
        let rects_4 = grid_positions(4, W, H);
        let panes = pane_centers_from_rects(&rects_4, &[10, 11, 12, 13]);

        // Target: 3-pane with full-height LEFT (standard orientation)
        let target = grid_positions(3, W, H);
        let ordered = simulate_remove_pane(&panes, 10, &target);

        assert_eq!(ordered[0], 12, "full-left: BL expands (column-mate)");
        assert_eq!(ordered[1], 11, "right-top: TR stays");
        assert_eq!(ordered[2], 13, "right-bottom: BR stays");
    }

    // ── 4→3: remove TR ──────────────────────────────────────────────
    //
    //  ┌───┬───┐     ┌───┬───┐
    //  │ A │ x │     │ A │   │
    //  ├───┼───┤  →  ├───┤ D │    D (column-mate of removed TR) expands.
    //  │ C │ D │     │ C │   │    A and C stay on left.
    //  └───┴───┘     └───┴───┘

    #[test]
    fn remove_tr_from_2x2() {
        let rects_4 = grid_positions(4, W, H);
        let panes = pane_centers_from_rects(&rects_4, &[10, 11, 12, 13]);

        // Target: 3-pane with full-height RIGHT (mirrored orientation)
        let target = layout_3_full_right(W, H);
        let ordered = simulate_remove_pane(&panes, 11, &target);

        assert_eq!(ordered[0], 10, "left-top: TL stays");
        assert_eq!(ordered[1], 12, "left-bottom: BL stays");
        assert_eq!(ordered[2], 13, "full-right: BR expands (column-mate)");
    }

    // ── 4→3: remove BL ──────────────────────────────────────────────
    //
    //  ┌───┬───┐     ┌───┬───┐
    //  │ A │ B │     │   │ B │
    //  ├───┼───┤  →  │ A ├───┤    A (column-mate of removed BL) expands.
    //  │ x │ D │     │   │ D │
    //  └───┴───┘     └───┴───┘

    #[test]
    fn remove_bl_from_2x2() {
        let rects_4 = grid_positions(4, W, H);
        let panes = pane_centers_from_rects(&rects_4, &[10, 11, 12, 13]);

        let target = grid_positions(3, W, H);
        let ordered = simulate_remove_pane(&panes, 12, &target);

        assert_eq!(ordered[0], 10, "full-left: TL expands (column-mate)");
        assert_eq!(ordered[1], 11, "right-top: TR stays");
        assert_eq!(ordered[2], 13, "right-bottom: BR stays");
    }

    // ── 4→3: remove BR ──────────────────────────────────────────────
    //
    //  ┌───┬───┐     ┌───┬───┐
    //  │ A │ B │     │ A │   │
    //  ├───┼───┤  →  ├───┤ B │    B (column-mate of removed BR) expands.
    //  │ C │ x │     │ C │   │
    //  └───┴───┘     └───┴───┘

    #[test]
    fn remove_br_from_2x2() {
        let rects_4 = grid_positions(4, W, H);
        let panes = pane_centers_from_rects(&rects_4, &[10, 11, 12, 13]);

        let target = layout_3_full_right(W, H);
        let ordered = simulate_remove_pane(&panes, 13, &target);

        assert_eq!(ordered[0], 10, "left-top: TL stays");
        assert_eq!(ordered[1], 12, "left-bottom: BL stays");
        assert_eq!(ordered[2], 11, "full-right: TR expands (column-mate)");
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // REMOVING PANES — Substitute Fills Gap (unbalanced → balanced)
    //
    // When a pane is removed from the balanced part of a balanced+column
    // layout, the right column pane fills the gap. Everyone else stays.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // ── 5→4: remove right column ────────────────────────────────────
    //
    //  ┌───┬───┬─────┐     ┌───┬───┐
    //  │ A │ B │     │     │ A │ B │
    //  ├───┼───┤  x  │  →  ├───┼───┤    2x2 stays. Zero movement.
    //  │ C │ D │     │     │ C │ D │
    //  └───┴───┴─────┘     └───┴───┘

    #[test]
    fn remove_right_column_from_5() {
        let rects_5 = grid_positions(5, W, H);
        let panes = pane_centers_from_rects(&rects_5, &[10, 11, 12, 13, 14]);

        let target = grid_positions(4, W, H);
        let ordered = simulate_remove_pane(&panes, 14, &target);

        assert_eq!(ordered[0], 10, "TL: stays");
        assert_eq!(ordered[1], 11, "TR: stays");
        assert_eq!(ordered[2], 12, "BL: stays");
        assert_eq!(ordered[3], 13, "BR: stays");
    }

    // ── 5→4: remove from 2x2 part ──────────────────────────────────
    //
    //  ┌───┬───┬─────┐     ┌───┬───┐
    //  │ x │ B │     │     │ E │ B │
    //  ├───┼───┤  E  │  →  ├───┼───┤    E fills the gap. Others stay.
    //  │ C │ D │     │     │ C │ D │
    //  └───┴───┴─────┘     └───┴───┘

    #[test]
    fn remove_tl_from_5_substitute_fills() {
        let rects_5 = grid_positions(5, W, H);
        let panes = pane_centers_from_rects(&rects_5, &[10, 11, 12, 13, 14]);

        let target = grid_positions(4, W, H);
        let ordered = simulate_remove_pane(&panes, 10, &target);

        assert_eq!(ordered[0], 14, "TL: right column pane fills the gap");
        assert_eq!(ordered[1], 11, "TR: stays");
        assert_eq!(ordered[2], 12, "BL: stays");
        assert_eq!(ordered[3], 13, "BR: stays");
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // REMOVING PANES — Column-Mate from 3x2 (balanced → unbalanced)
    //
    // When a pane is removed from a 3x2 grid, its column-mate takes the
    // full-height right column. The other two columns form the 2x2.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // ── 6→5: remove TM ──────────────────────────────────────────────
    //
    //  ┌───┬───┬───┐     ┌───┬───┬─────┐
    //  │ A │ x │ C │     │ A │ C │     │
    //  ├───┼───┼───┤  →  ├───┼───┤  E  │    E = column-mate of removed B
    //  │ D │ E │ F │     │ D │ F │     │    C and F shift left.
    //  └───┴───┴───┘     └───┴───┴─────┘

    #[test]
    fn remove_tm_from_3x2() {
        let rects_6 = grid_positions(6, W, H);
        let panes = pane_centers_from_rects(&rects_6, &[10, 11, 12, 13, 14, 15]);

        let target = grid_positions(5, W, H); // 2x2 + right column
        let ordered = simulate_remove_pane(&panes, 11, &target);

        assert_eq!(ordered[0], 10, "TL: stays");
        assert_eq!(ordered[1], 12, "TR: old TR shifts to 2x2 TR");
        assert_eq!(ordered[2], 13, "BL: stays");
        assert_eq!(ordered[3], 15, "BR: old BR shifts to 2x2 BR");
        assert_eq!(ordered[4], 14, "R: column-mate takes right column");
    }

    // ── 6→5: remove BR ──────────────────────────────────────────────
    //
    //  ┌───┬───┬───┐     ┌───┬───┬─────┐
    //  │ A │ B │ C │     │ A │ B │     │
    //  ├───┼───┼───┤  →  ├───┼───┤  C  │    C = column-mate of removed F
    //  │ D │ E │ x │     │ D │ E │     │    A,B,D,E stay as 2x2.
    //  └───┴───┴───┘     └───┴───┴─────┘

    #[test]
    fn remove_br_from_3x2() {
        let rects_6 = grid_positions(6, W, H);
        let panes = pane_centers_from_rects(&rects_6, &[10, 11, 12, 13, 14, 15]);

        let target = grid_positions(5, W, H);
        let ordered = simulate_remove_pane(&panes, 15, &target);

        assert_eq!(ordered[0], 10, "TL: stays");
        assert_eq!(ordered[1], 11, "TR: stays");
        assert_eq!(ordered[2], 13, "BL: stays");
        assert_eq!(ordered[3], 14, "BR: stays");
        assert_eq!(ordered[4], 12, "R: column-mate takes right column");
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // SNAP-BACK — Removing the last-added pane reverses the add
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // ── 5→4: remove right column (undo of 4→5) ─────────────────────

    #[test]
    fn snap_back_5_to_4() {
        let rects_4 = grid_positions(4, W, H);
        let rects_5 = grid_positions(5, W, H);
        let ids: Vec<u32> = vec![10, 11, 12, 13];

        let current_rects: Vec<Rect> = (0..4).map(|i| rects_5[i].clone()).collect();
        let panes = pane_centers_with_prev(&current_rects, &rects_4, &ids);

        let slot_centers = centers_from_rects(&rects_4);
        let matched = match_panes_to_slots(&panes, &slot_centers, false);

        assert_eq!(matched[0], Some(10), "TL: snaps back");
        assert_eq!(matched[1], Some(11), "TR: snaps back");
        assert_eq!(matched[2], Some(12), "BL: snaps back");
        assert_eq!(matched[3], Some(13), "BR: snaps back");
    }
}
