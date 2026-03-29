// src/sticky.rs

/// A pane with its ID and position in the terminal.
#[derive(Debug, Clone, PartialEq)]
pub struct Pane {
    pub id: u32,
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
}

/// Events that trigger a layout recomputation.
#[derive(Debug, Clone)]
pub enum LayoutEvent {
    /// A new pane was added with the given ID.
    Add(u32),
    /// A pane with the given ID was removed.
    Remove(u32),
    /// Window dimensions changed. Also used for start, attach, and space-switch.
    Resize,
}

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
fn rect_center(x: u16, y: u16, w: u16, h: u16) -> (i32, i32) {
    ((x as i32) + (w as i32) / 2, (y as i32) + (h as i32) / 2)
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

/// Pure state transition: given current pane positions, an event, and window
/// dimensions, compute the new layout. This is the single source of truth for
/// both pane ordering and geometry.
pub fn compute_layout(
    current: &[Pane],
    event: LayoutEvent,
    window_w: u16,
    window_h: u16,
) -> Vec<Pane> {
    match event {
        LayoutEvent::Resize => compute_resize(current, window_w, window_h),
        LayoutEvent::Add(new_id) => compute_add(current, new_id, window_w, window_h),
        LayoutEvent::Remove(removed_id) => compute_remove(current, removed_id, window_w, window_h),
    }
}

/// Resize: recompute the grid at new dimensions, match panes by position.
fn compute_resize(current: &[Pane], window_w: u16, window_h: u16) -> Vec<Pane> {
    let count = current.len();
    if count == 0 {
        return vec![];
    }

    let rects = crate::layout::grid_positions(count, window_w, window_h);
    let slots: Vec<SlotCenter> = rects
        .iter()
        .map(|r| {
            let (cx, cy) = rect_center(r.x, r.y, r.w, r.h);
            SlotCenter { cx, cy }
        })
        .collect();

    // Convert current panes to PaneCenters for matching
    let pane_centers: Vec<PaneCenter> = current
        .iter()
        .map(|p| {
            let (cx, cy) = rect_center(p.x, p.y, p.w, p.h);
            PaneCenter {
                id: p.id,
                cx,
                cy,
                prev_cx: None,
                prev_cy: None,
            }
        })
        .collect();

    let matched = match_panes_to_slots(&pane_centers, &slots, false);

    // Build output: matched panes get new positions from grid
    let matched_ids: Vec<u32> = matched.iter().filter_map(|&id| id).collect();
    let mut unmatched: Vec<u32> = current
        .iter()
        .filter(|p| !matched_ids.contains(&p.id))
        .map(|p| p.id)
        .collect();

    let mut result = Vec::new();
    for (si, rect) in rects.iter().enumerate() {
        let id = matched[si].unwrap_or_else(|| unmatched.pop().unwrap_or(0));
        result.push(Pane {
            id,
            x: rect.x,
            y: rect.y,
            w: rect.w,
            h: rect.h,
        });
    }
    result
}

/// Add: compute grid for N+1 panes, match existing panes, new pane gets leftover slot.
fn compute_add(current: &[Pane], new_id: u32, window_w: u16, window_h: u16) -> Vec<Pane> {
    let new_count = current.len() + 1;
    let rects = crate::layout::grid_positions(new_count, window_w, window_h);
    let slots: Vec<SlotCenter> = rects
        .iter()
        .map(|r| {
            let (cx, cy) = rect_center(r.x, r.y, r.w, r.h);
            SlotCenter { cx, cy }
        })
        .collect();

    let pane_centers: Vec<PaneCenter> = current
        .iter()
        .map(|p| {
            let (cx, cy) = rect_center(p.x, p.y, p.w, p.h);
            PaneCenter {
                id: p.id,
                cx,
                cy,
                prev_cx: None,
                prev_cy: None,
            }
        })
        .collect();

    // Use structural matching for add transitions
    let matched = match_panes_structural(&pane_centers, &slots, current.len(), new_count);

    // Build output: matched panes get new positions, new pane fills empty slot
    let mut result = Vec::new();
    for (si, rect) in rects.iter().enumerate() {
        let id = if si < matched.len() {
            matched[si].unwrap_or(new_id)
        } else {
            new_id
        };
        result.push(Pane {
            id,
            x: rect.x,
            y: rect.y,
            w: rect.w,
            h: rect.h,
        });
    }
    result
}

/// Remove: filter out the removed pane, compute grid for N-1 panes,
/// match surviving panes using structural rules.
fn compute_remove(current: &[Pane], removed_id: u32, window_w: u16, window_h: u16) -> Vec<Pane> {
    let surviving: Vec<&Pane> = current.iter().filter(|p| p.id != removed_id).collect();
    let new_count = surviving.len();
    if new_count == 0 {
        return vec![];
    }

    let prev_count = current.len();

    // Detect 4→3 right-column removal for right-full layout variant
    let pane_centers: Vec<PaneCenter> = surviving
        .iter()
        .map(|p| {
            let (cx, cy) = rect_center(p.x, p.y, p.w, p.h);
            PaneCenter {
                id: p.id,
                cx,
                cy,
                prev_cx: None,
                prev_cy: None,
            }
        })
        .collect();

    let right_full_3 = new_count == 3
        && prev_count == 4
        && find_lone_column_pane(&pane_centers)
            .map(|i| {
                let lone_cx = pane_centers[i].cx;
                let avg_cx = pane_centers.iter().map(|p| p.cx as i64).sum::<i64>()
                    / pane_centers.len() as i64;
                lone_cx as i64 > avg_cx
            })
            .unwrap_or(false);

    let rects = if right_full_3 {
        crate::layout::grid_positions_3_right(window_w, window_h)
    } else {
        crate::layout::grid_positions(new_count, window_w, window_h)
    };

    let slots: Vec<SlotCenter> = rects
        .iter()
        .map(|r| {
            let (cx, cy) = rect_center(r.x, r.y, r.w, r.h);
            SlotCenter { cx, cy }
        })
        .collect();

    let matched = match_panes_structural(&pane_centers, &slots, prev_count, new_count);

    let matched_ids: Vec<u32> = matched.iter().filter_map(|&id| id).collect();
    let mut unmatched: Vec<u32> = surviving
        .iter()
        .filter(|p| !matched_ids.contains(&p.id))
        .map(|p| p.id)
        .collect();

    let mut result = Vec::new();
    for (si, rect) in rects.iter().enumerate() {
        let id = matched[si].unwrap_or_else(|| unmatched.pop().unwrap_or(0));
        result.push(Pane {
            id,
            x: rect.x,
            y: rect.y,
            w: rect.w,
            h: rect.h,
        });
    }
    result
}

#[cfg(test)]
mod layout_tests {
    use super::*;
    use crate::layout::grid_positions;

    const W: u16 = 280;
    const H: u16 = 80;

    /// Build Vec<Pane> from grid_positions — simulates panes sitting in an N-pane layout.
    fn panes_at(count: usize, ids: &[u32], w: u16, h: u16) -> Vec<Pane> {
        let rects = grid_positions(count, w, h);
        rects
            .iter()
            .zip(ids.iter())
            .map(|(r, &id)| Pane {
                id,
                x: r.x,
                y: r.y,
                w: r.w,
                h: r.h,
            })
            .collect()
    }

    // ── Resize Tests ──

    #[test]
    fn resize_equalizes_uneven_columns() {
        // Simulate the actual bug: panes at wrong sizes, resize to 269x66
        let current = vec![
            Pane {
                id: 1,
                x: 0,
                y: 0,
                w: 69,
                h: 32,
            },
            Pane {
                id: 2,
                x: 70,
                y: 0,
                w: 126,
                h: 32,
            },
            Pane {
                id: 3,
                x: 0,
                y: 33,
                w: 69,
                h: 33,
            },
            Pane {
                id: 4,
                x: 70,
                y: 33,
                w: 126,
                h: 33,
            },
            Pane {
                id: 5,
                x: 197,
                y: 0,
                w: 72,
                h: 66,
            },
        ];
        let result = compute_layout(&current, LayoutEvent::Resize, 269, 66);
        assert_eq!(result.len(), 5);
        // All three columns should be approximately equal (within 2px)
        let col_widths: Vec<u16> = vec![result[0].w, result[1].w, result[4].w];
        let max_w = *col_widths.iter().max().unwrap();
        let min_w = *col_widths.iter().min().unwrap();
        assert!(
            max_w - min_w <= 2,
            "columns should be roughly equal: {:?}",
            col_widths
        );
    }

    #[test]
    fn resize_identity_preserves_positions() {
        // Resize to the same dimensions should produce the same layout
        let current = panes_at(4, &[10, 11, 12, 13], W, H);
        let result = compute_layout(&current, LayoutEvent::Resize, W, H);
        assert_eq!(result.len(), 4);
        for (c, r) in current.iter().zip(result.iter()) {
            assert_eq!(c.id, r.id);
            assert_eq!(c.x, r.x);
            assert_eq!(c.y, r.y);
            assert_eq!(c.w, r.w);
            assert_eq!(c.h, r.h);
        }
    }

    #[test]
    fn resize_preserves_pane_order() {
        // After resize, leftmost pane stays leftmost
        let current = panes_at(4, &[10, 11, 12, 13], W, H);
        let result = compute_layout(&current, LayoutEvent::Resize, 200, 60);
        assert_eq!(result.len(), 4);
        assert_eq!(result[0].id, 10); // top-left stays top-left
        assert_eq!(result[1].id, 11); // top-right stays top-right
        assert_eq!(result[2].id, 12); // bottom-left stays bottom-left
        assert_eq!(result[3].id, 13); // bottom-right stays bottom-right
    }

    #[test]
    fn resize_one_pane() {
        let current = panes_at(1, &[10], 80, 24);
        let result = compute_layout(&current, LayoutEvent::Resize, 200, 60);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[0].w, 200);
        assert_eq!(result[0].h, 60);
    }

    #[test]
    fn resize_two_panes() {
        let current = panes_at(2, &[10, 11], 200, 60);
        let result = compute_layout(&current, LayoutEvent::Resize, 300, 80);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 11);
        // Both full height
        assert_eq!(result[0].h, 80);
        assert_eq!(result[1].h, 80);
        // Total width covers terminal (with divider)
        assert_eq!(result[0].w + 1 + result[1].w, 300);
    }

    // ── Add Tests ──

    #[test]
    fn layout_add_3_to_4() {
        //  [A][B]    [A][B]
        //  [_][C] →  [N][C]
        let current = panes_at(3, &[10, 11, 12], W, H);
        let result = compute_layout(&current, LayoutEvent::Add(99), W, H);
        assert_eq!(result.len(), 4);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 11);
        assert_eq!(result[2].id, 99); // new pane fills bottom-left
        assert_eq!(result[3].id, 12);
        // Verify geometry matches grid_positions(4)
        let expected = grid_positions(4, W, H);
        for (r, e) in result.iter().zip(expected.iter()) {
            assert_eq!(r.x, e.x);
            assert_eq!(r.y, e.y);
            assert_eq!(r.w, e.w);
            assert_eq!(r.h, e.h);
        }
    }

    #[test]
    fn layout_add_4_to_5() {
        let current = panes_at(4, &[10, 11, 12, 13], W, H);
        let result = compute_layout(&current, LayoutEvent::Add(99), W, H);
        assert_eq!(result.len(), 5);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 11);
        assert_eq!(result[2].id, 12);
        assert_eq!(result[3].id, 13);
        assert_eq!(result[4].id, 99); // new pane takes right column
    }

    #[test]
    fn layout_add_5_to_6() {
        let r5 = grid_positions(5, W, H);
        let current = vec![
            Pane {
                id: 10,
                x: r5[0].x,
                y: r5[0].y,
                w: r5[0].w,
                h: r5[0].h,
            },
            Pane {
                id: 11,
                x: r5[1].x,
                y: r5[1].y,
                w: r5[1].w,
                h: r5[1].h,
            },
            Pane {
                id: 12,
                x: r5[2].x,
                y: r5[2].y,
                w: r5[2].w,
                h: r5[2].h,
            },
            Pane {
                id: 13,
                x: r5[3].x,
                y: r5[3].y,
                w: r5[3].w,
                h: r5[3].h,
            },
            Pane {
                id: 14,
                x: r5[4].x,
                y: r5[4].y,
                w: r5[4].w,
                h: r5[4].h,
            },
        ];
        let result = compute_layout(&current, LayoutEvent::Add(99), W, H);
        assert_eq!(result.len(), 6);
        // Right column pane (14) should go to top of its column
        assert_eq!(result[2].id, 14); // top-right in 3x2
        assert_eq!(result[5].id, 99); // new pane fills bottom-right
    }

    #[test]
    fn layout_add_6_to_7() {
        let current = panes_at(6, &[10, 11, 12, 13, 14, 15], W, H);
        let result = compute_layout(&current, LayoutEvent::Add(99), W, H);
        assert_eq!(result.len(), 7);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 11);
        assert_eq!(result[2].id, 12);
        assert_eq!(result[3].id, 13);
        assert_eq!(result[4].id, 14);
        assert_eq!(result[5].id, 15);
        assert_eq!(result[6].id, 99); // new pane takes right column
    }

    #[test]
    fn layout_add_7_to_8() {
        let r7 = grid_positions(7, W, H);
        let current = vec![
            Pane {
                id: 10,
                x: r7[0].x,
                y: r7[0].y,
                w: r7[0].w,
                h: r7[0].h,
            },
            Pane {
                id: 11,
                x: r7[1].x,
                y: r7[1].y,
                w: r7[1].w,
                h: r7[1].h,
            },
            Pane {
                id: 12,
                x: r7[2].x,
                y: r7[2].y,
                w: r7[2].w,
                h: r7[2].h,
            },
            Pane {
                id: 13,
                x: r7[3].x,
                y: r7[3].y,
                w: r7[3].w,
                h: r7[3].h,
            },
            Pane {
                id: 14,
                x: r7[4].x,
                y: r7[4].y,
                w: r7[4].w,
                h: r7[4].h,
            },
            Pane {
                id: 15,
                x: r7[5].x,
                y: r7[5].y,
                w: r7[5].w,
                h: r7[5].h,
            },
            Pane {
                id: 16,
                x: r7[6].x,
                y: r7[6].y,
                w: r7[6].w,
                h: r7[6].h,
            },
        ];
        let result = compute_layout(&current, LayoutEvent::Add(99), W, H);
        assert_eq!(result.len(), 8);
        // Right column pane (16) should split into its column
        assert_eq!(result[3].id, 16); // top-right in 4x2
        assert_eq!(result[7].id, 99); // new pane fills bottom-right
    }

    // ── 4→3 Remove Tests ──

    #[test]
    fn layout_remove_4_tl() {
        let current = panes_at(4, &[10, 11, 12, 13], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(10), W, H);
        assert_eq!(result.len(), 3);
        // C expands full-left (standard 3-pane: left-full + right-split)
        assert_eq!(result[0].id, 12); // left full-height
        assert_eq!(result[0].h, H); // full height
        assert_eq!(result[1].id, 11);
        assert_eq!(result[2].id, 13);
    }

    #[test]
    fn layout_remove_4_tr() {
        let current = panes_at(4, &[10, 11, 12, 13], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(11), W, H);
        assert_eq!(result.len(), 3);
        // D expands full-right (right-full variant)
        assert_eq!(result[2].id, 13); // right full-height
        assert_eq!(result[2].h, H);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 12);
    }

    #[test]
    fn layout_remove_4_bl() {
        let current = panes_at(4, &[10, 11, 12, 13], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(12), W, H);
        assert_eq!(result.len(), 3);
        // A expands full-left (standard 3-pane)
        assert_eq!(result[0].id, 10); // left full-height
        assert_eq!(result[0].h, H);
        assert_eq!(result[1].id, 11);
        assert_eq!(result[2].id, 13);
    }

    #[test]
    fn layout_remove_4_br() {
        let current = panes_at(4, &[10, 11, 12, 13], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(13), W, H);
        assert_eq!(result.len(), 3);
        // B expands full-right (right-full variant)
        assert_eq!(result[2].id, 11); // right full-height
        assert_eq!(result[2].h, H);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 12);
    }

    // ── 5→4 Remove Tests ──

    #[test]
    fn layout_remove_5_tl() {
        let current = panes_at(5, &[10, 11, 12, 13, 14], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(10), W, H);
        assert_eq!(result.len(), 4);
        assert_eq!(result[0].id, 14); // right-col fills gap
        assert_eq!(result[1].id, 11);
        assert_eq!(result[2].id, 12);
        assert_eq!(result[3].id, 13);
    }

    #[test]
    fn layout_remove_5_tr() {
        let current = panes_at(5, &[10, 11, 12, 13, 14], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(11), W, H);
        assert_eq!(result.len(), 4);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 14); // right-col fills gap
        assert_eq!(result[2].id, 12);
        assert_eq!(result[3].id, 13);
    }

    #[test]
    fn layout_remove_5_bl() {
        let current = panes_at(5, &[10, 11, 12, 13, 14], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(12), W, H);
        assert_eq!(result.len(), 4);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 11);
        assert_eq!(result[2].id, 14); // right-col fills gap
        assert_eq!(result[3].id, 13);
    }

    #[test]
    fn layout_remove_5_br() {
        let current = panes_at(5, &[10, 11, 12, 13, 14], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(13), W, H);
        assert_eq!(result.len(), 4);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 11);
        assert_eq!(result[2].id, 12);
        assert_eq!(result[3].id, 14); // right-col fills gap
    }

    #[test]
    fn layout_remove_5_rcol() {
        let current = panes_at(5, &[10, 11, 12, 13, 14], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(14), W, H);
        assert_eq!(result.len(), 4);
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 11);
        assert_eq!(result[2].id, 12);
        assert_eq!(result[3].id, 13);
    }

    // ── 6→5 Remove Tests ──

    #[test]
    fn layout_remove_6_tl() {
        let current = panes_at(6, &[10, 11, 12, 13, 14, 15], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(10), W, H);
        assert_eq!(result.len(), 5);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        // D(13)=column-mate→right col. Others fill 2x2.
        assert_eq!(ids, [12, 11, 15, 14, 13]);
    }

    #[test]
    fn layout_remove_6_tm() {
        let current = panes_at(6, &[10, 11, 12, 13, 14, 15], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(11), W, H);
        assert_eq!(result.len(), 5);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [10, 12, 13, 15, 14]);
    }

    #[test]
    fn layout_remove_6_tr() {
        let current = panes_at(6, &[10, 11, 12, 13, 14, 15], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(12), W, H);
        assert_eq!(result.len(), 5);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [10, 11, 13, 14, 15]);
    }

    #[test]
    fn layout_remove_6_bl() {
        let current = panes_at(6, &[10, 11, 12, 13, 14, 15], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(13), W, H);
        assert_eq!(result.len(), 5);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [12, 11, 15, 14, 10]);
    }

    #[test]
    fn layout_remove_6_bm() {
        let current = panes_at(6, &[10, 11, 12, 13, 14, 15], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(14), W, H);
        assert_eq!(result.len(), 5);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [10, 12, 13, 15, 11]);
    }

    #[test]
    fn layout_remove_6_br() {
        let current = panes_at(6, &[10, 11, 12, 13, 14, 15], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(15), W, H);
        assert_eq!(result.len(), 5);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [10, 11, 13, 14, 12]);
    }

    // ── 7→6 Remove Tests ──

    #[test]
    fn layout_remove_7_tl() {
        let current = panes_at(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(10), W, H);
        assert_eq!(result.len(), 6);
        assert_eq!(result[0].id, 16); // right-col fills gap
    }

    #[test]
    fn layout_remove_7_tm() {
        let current = panes_at(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(11), W, H);
        assert_eq!(result.len(), 6);
        assert_eq!(result[1].id, 16); // right-col fills gap
    }

    #[test]
    fn layout_remove_7_tr() {
        let current = panes_at(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(12), W, H);
        assert_eq!(result.len(), 6);
        assert_eq!(result[2].id, 16); // right-col fills gap
    }

    #[test]
    fn layout_remove_7_bl() {
        let current = panes_at(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(13), W, H);
        assert_eq!(result.len(), 6);
        assert_eq!(result[3].id, 16); // right-col fills gap
    }

    #[test]
    fn layout_remove_7_bm() {
        let current = panes_at(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(14), W, H);
        assert_eq!(result.len(), 6);
        assert_eq!(result[4].id, 16); // right-col fills gap
    }

    #[test]
    fn layout_remove_7_br() {
        let current = panes_at(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(15), W, H);
        assert_eq!(result.len(), 6);
        assert_eq!(result[5].id, 16); // right-col fills gap
    }

    #[test]
    fn layout_remove_7_rcol() {
        let current = panes_at(7, &[10, 11, 12, 13, 14, 15, 16], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(16), W, H);
        assert_eq!(result.len(), 6);
        // All stay in place
        assert_eq!(result[0].id, 10);
        assert_eq!(result[1].id, 11);
        assert_eq!(result[2].id, 12);
        assert_eq!(result[3].id, 13);
        assert_eq!(result[4].id, 14);
        assert_eq!(result[5].id, 15);
    }

    // ── 8→7 Remove Tests ──

    #[test]
    fn layout_remove_8_tl() {
        let current = panes_at(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(10), W, H);
        assert_eq!(result.len(), 7);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [13, 11, 12, 17, 15, 16, 14]);
    }

    #[test]
    fn layout_remove_8_tml() {
        let current = panes_at(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(11), W, H);
        assert_eq!(result.len(), 7);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [10, 13, 12, 14, 17, 16, 15]);
    }

    #[test]
    fn layout_remove_8_tmr() {
        let current = panes_at(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(12), W, H);
        assert_eq!(result.len(), 7);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [10, 11, 13, 14, 15, 17, 16]);
    }

    #[test]
    fn layout_remove_8_tr() {
        let current = panes_at(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(13), W, H);
        assert_eq!(result.len(), 7);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [10, 11, 12, 14, 15, 16, 17]);
    }

    #[test]
    fn layout_remove_8_bl() {
        let current = panes_at(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(14), W, H);
        assert_eq!(result.len(), 7);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [13, 11, 12, 17, 15, 16, 10]);
    }

    #[test]
    fn layout_remove_8_bml() {
        let current = panes_at(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(15), W, H);
        assert_eq!(result.len(), 7);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [10, 13, 12, 14, 17, 16, 11]);
    }

    #[test]
    fn layout_remove_8_bmr() {
        let current = panes_at(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(16), W, H);
        assert_eq!(result.len(), 7);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [10, 11, 13, 14, 15, 17, 12]);
    }

    #[test]
    fn layout_remove_8_br() {
        let current = panes_at(8, &[10, 11, 12, 13, 14, 15, 16, 17], W, H);
        let result = compute_layout(&current, LayoutEvent::Remove(17), W, H);
        assert_eq!(result.len(), 7);
        let ids: Vec<u32> = result.iter().map(|p| p.id).collect();
        assert_eq!(ids, [10, 11, 12, 14, 15, 16, 13]);
    }
} // close mod layout_tests
