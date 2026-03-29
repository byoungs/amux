// src/layout.rs

/// A rectangular region in the terminal.
#[derive(Debug, Clone, PartialEq)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
}

/// Calculate grid positions for N panes in a WxH terminal.
/// Returns a Vec of Rect, one per pane, in slot order.
///
/// Grid rules (alternating balanced / balanced+column):
/// - 1 pane: full screen
/// - 2 panes: left/right split (never top/bottom)
/// - 3 panes: left full-height + right split vertically
/// - 4 panes: 2x2 (balanced)
/// - 5 panes: 2x2 + full-height right column
/// - 6 panes: 3x2 (balanced)
/// - 7 panes: 3x2 + full-height right column
/// - 8 panes: 4x2 (balanced)
/// - 9 panes: 4x2 + full-height right column
///
/// See docs/sticky-panes.md for the design rationale.
pub fn grid_positions(count: usize, width: u16, height: u16) -> Vec<Rect> {
    match count {
        0 => vec![],
        1 => vec![Rect {
            x: 0,
            y: 0,
            w: width,
            h: height,
        }],
        2 => layout_columns(2, width, height),
        3 => {
            // Left full-height + right column split into 2
            let left_w = (width - 1) / 2;
            let right_w = width - 1 - left_w;
            let right_x = left_w + 1;
            let top_h = (height - 1) / 2;
            let bot_h = height - 1 - top_h;
            vec![
                Rect {
                    x: 0,
                    y: 0,
                    w: left_w,
                    h: height,
                },
                Rect {
                    x: right_x,
                    y: 0,
                    w: right_w,
                    h: top_h,
                },
                Rect {
                    x: right_x,
                    y: top_h + 1,
                    w: right_w,
                    h: bot_h,
                },
            ]
        }
        4 => layout_grid(2, 2, width, height),
        _ if count.is_multiple_of(2) => {
            // Even counts >= 6: balanced grid (2 rows, count/2 columns)
            layout_grid(2, count / 2, width, height)
        }
        _ => {
            // Odd counts >= 5: balanced grid + full-height right column
            // 5 = 2x2 + col, 7 = 3x2 + col, 9 = 4x2 + col
            let balanced_cols = (count - 1) / 2;
            layout_balanced_plus_column(balanced_cols, width, height)
        }
    }
}

/// 3-pane layout with full-height RIGHT column (mirrored variant).
/// Slot order: left-top, left-bottom, full-right.
/// Used when removing from the right column of a 2x2.
pub fn grid_positions_3_right(width: u16, height: u16) -> Vec<Rect> {
    layout_balanced_plus_column(1, width, height)
}

/// Layout a balanced grid (cols x 2) plus a full-height right column.
/// Slot order: top row L→R, bottom row L→R, then right column.
fn layout_balanced_plus_column(balanced_cols: usize, width: u16, height: u16) -> Vec<Rect> {
    let total_cols = balanced_cols + 1;
    let col_dividers = (total_cols as u16).saturating_sub(1);
    let available_w = width.saturating_sub(col_dividers);
    let col_w = available_w / total_cols as u16;

    let row_available = height.saturating_sub(1);
    let top_h = row_available / 2;
    let bot_h = row_available - top_h;
    let bot_y = top_h + 1;

    let mut rects = Vec::new();

    // Top row of balanced grid
    let mut cx = 0u16;
    for _ in 0..balanced_cols {
        rects.push(Rect {
            x: cx,
            y: 0,
            w: col_w,
            h: top_h,
        });
        cx += col_w + 1;
    }

    // Bottom row of balanced grid
    cx = 0;
    for _ in 0..balanced_cols {
        rects.push(Rect {
            x: cx,
            y: bot_y,
            w: col_w,
            h: bot_h,
        });
        cx += col_w + 1;
    }

    // Full-height right column
    let right_x = (col_w + 1) * balanced_cols as u16;
    let right_w = width - right_x;
    rects.push(Rect {
        x: right_x,
        y: 0,
        w: right_w,
        h: height,
    });

    rects
}

/// Layout N equal columns, each full height.
fn layout_columns(n: usize, width: u16, height: u16) -> Vec<Rect> {
    let dividers = (n as u16).saturating_sub(1);
    let available = width.saturating_sub(dividers);
    let col_w = available / n as u16;
    let mut rects = Vec::new();
    let mut x = 0u16;
    for i in 0..n {
        let w = if i == n - 1 { width - x } else { col_w };
        rects.push(Rect {
            x,
            y: 0,
            w,
            h: height,
        });
        x += w + 1; // +1 for divider
    }
    rects
}

/// Layout N equal rows in a given region.
#[allow(dead_code)]
fn layout_rows(n: usize, x: u16, y: u16, width: u16, height: u16) -> Vec<Rect> {
    let dividers = (n as u16).saturating_sub(1);
    let available = height.saturating_sub(dividers);
    let row_h = available / n as u16;
    let mut rects = Vec::new();
    let mut cy = y;
    for i in 0..n {
        let h = if i == n - 1 { y + height - cy } else { row_h };
        rects.push(Rect {
            x,
            y: cy,
            w: width,
            h,
        });
        cy += h + 1; // +1 for divider
    }
    rects
}

/// Layout a rows x cols grid.
fn layout_grid(rows: usize, cols: usize, width: u16, height: u16) -> Vec<Rect> {
    let col_dividers = (cols as u16).saturating_sub(1);
    let row_dividers = (rows as u16).saturating_sub(1);
    let col_available = width.saturating_sub(col_dividers);
    let row_available = height.saturating_sub(row_dividers);
    let col_w = col_available / cols as u16;
    let row_h = row_available / rows as u16;

    let mut rects = Vec::new();
    let mut cy = 0u16;
    for r in 0..rows {
        let h = if r == rows - 1 { height - cy } else { row_h };
        let mut cx = 0u16;
        for c in 0..cols {
            let w = if c == cols - 1 { width - cx } else { col_w };
            rects.push(Rect { x: cx, y: cy, w, h });
            cx += w + 1;
        }
        cy += h + 1;
    }
    rects
}

/// Build a tmux layout string for N panes in the standard grid.
/// This generates the split tree directly rather than trying to
/// decompose grid positions back into a tree.
///
/// `border_top` compensates for `pane-border-status top`: the top row of
/// panes loses `border_top` rows to the border title bar, so we make the
/// first row that many rows taller in the layout string.
pub fn build_layout_string_direct(
    width: u16,
    height: u16,
    pane_ids: &[u32],
    border_top: u16,
) -> Option<String> {
    let n = pane_ids.len();
    if n == 0 {
        return None;
    }

    let body = match n {
        1 => {
            format!("{}x{},0,0,{}", width, height, pane_ids[0])
        }
        2 => {
            // Left/right split (no vertical split, no border compensation needed)
            let lw = (width - 1) / 2;
            let rw = width - 1 - lw;
            let rx = lw + 1;
            format!(
                "{}x{},0,0{{{}x{},0,0,{},{}x{},{},0,{}}}",
                width, height, lw, height, pane_ids[0], rw, height, rx, pane_ids[1]
            )
        }
        3 => {
            // Left full-height + right split vertically
            let lw = (width - 1) / 2;
            let rw = width - 1 - lw;
            let rx = lw + 1;
            let (th, bh) = split_two_rows(height, border_top);
            let by = th + 1;
            format!(
                "{}x{},0,0{{{}x{},0,0,{},{}x{},{},0[{}x{},{},0,{},{}x{},{},{},{}]}}",
                width,
                height,
                lw,
                height,
                pane_ids[0],
                rw,
                height,
                rx,
                rw,
                th,
                rx,
                pane_ids[1],
                rw,
                bh,
                rx,
                by,
                pane_ids[2]
            )
        }
        4 => {
            // 2x2
            let lw = (width - 1) / 2;
            let rw = width - 1 - lw;
            let rx = lw + 1;
            let (th, bh) = split_two_rows(height, border_top);
            let by = th + 1;
            format!("{}x{},0,0[{}x{},0,0{{{}x{},0,0,{},{}x{},{},0,{}}},{}x{},0,{}{{{}x{},0,{},{},{}x{},{},{},{}}}]",
                width, height,
                width, th,
                lw, th, pane_ids[0],
                rw, th, rx, pane_ids[1],
                width, bh, by,
                lw, bh, by, pane_ids[2],
                rw, bh, rx, by, pane_ids[3])
        }
        _ if n.is_multiple_of(2) => {
            // Even counts >= 6: balanced grid (2 rows, n/2 columns per row)
            let cols = n / 2;
            let (th, bh) = split_two_rows(height, border_top);
            let by = th + 1;

            let top_row = layout_row_string(&pane_ids[..cols], 0, 0, width, th);
            let bot_row = layout_row_string(&pane_ids[cols..], 0, by, width, bh);

            format!("{}x{},0,0[{},{}]", width, height, top_row, bot_row)
        }
        _ => {
            // Odd counts >= 5: balanced grid + full-height right column
            let balanced_cols = (n - 1) / 2;
            let total_cols = balanced_cols + 1;
            let col_dividers = (total_cols as u16) - 1;
            let available = width - col_dividers;
            let col_w = available / total_cols as u16;

            let left_w = col_w * balanced_cols as u16 + (balanced_cols as u16).saturating_sub(1);
            let right_x = left_w + 1;
            let right_w = width - right_x;

            let (th, bh) = split_two_rows(height, border_top);
            let by = th + 1;

            let top_ids = &pane_ids[..balanced_cols];
            let bot_ids = &pane_ids[balanced_cols..2 * balanced_cols];
            let right_id = pane_ids[2 * balanced_cols];

            let top_row = layout_row_string(top_ids, 0, 0, left_w, th);
            let bot_row = layout_row_string(bot_ids, 0, by, left_w, bh);

            format!(
                "{}x{},0,0{{{}x{},0,0[{},{}],{}x{},{},0,{}}}",
                width, height, left_w, height, top_row, bot_row, right_w, height, right_x, right_id
            )
        }
    };

    let csum = layout_checksum(&body);
    Some(format!("{:04x},{}", csum, body))
}

/// Build tmux layout string for 3-pane right-full variant.
/// Slot order: left-top, left-bottom, full-right.
pub fn build_layout_string_3_right(
    width: u16,
    height: u16,
    pane_ids: &[u32],
    border_top: u16,
) -> Option<String> {
    if pane_ids.len() != 3 {
        return None;
    }

    // Same geometry as odd >= 5 path but with balanced_cols = 1
    let total_cols = 2u16;
    let available = width - (total_cols - 1);
    let col_w = available / total_cols;

    let left_w = col_w;
    let right_x = left_w + 1;
    let right_w = width - right_x;

    let (th, bh) = split_two_rows(height, border_top);
    let by = th + 1;

    // left-top, left-bottom, full-right
    let body = format!(
        "{}x{},0,0{{{}x{},0,0[{}x{},0,0,{},{}x{},0,{},{}],{}x{},{},0,{}}}",
        width,
        height,
        left_w,
        height,
        left_w,
        th,
        pane_ids[0],
        left_w,
        bh,
        by,
        pane_ids[1],
        right_w,
        height,
        right_x,
        pane_ids[2]
    );

    let csum = layout_checksum(&body);
    Some(format!("{:04x},{}", csum, body))
}

/// Build a tmux layout string from positioned panes.
///
/// This function takes the output of `compute_layout` — panes with their
/// exact positions — and generates the tmux layout string. It delegates to
/// `build_layout_string_direct` or `build_layout_string_3_right` based on
/// the pane positions (detecting the right-full variant by checking if the
/// rightmost pane is full-height).
///
/// `border_top` is applied to the layout string to compensate for
/// pane-border-status. `window_w` and `window_h` are the raw window
/// dimensions (before border subtraction).
pub fn build_layout_string(
    panes: &[crate::sticky::Pane],
    window_w: u16,
    window_h: u16,
    border_top: u16,
) -> Option<String> {
    if panes.is_empty() {
        return None;
    }

    // Extract ordered IDs (panes are already in slot order from compute_layout)
    let ids: Vec<u32> = panes.iter().map(|p| p.id).collect();

    // Detect 3-pane right-full variant: rightmost pane is full height
    if panes.len() == 3 {
        let rightmost = panes.iter().max_by_key(|p| p.x).unwrap();
        let effective_h = window_h.saturating_sub(border_top);
        if rightmost.h == effective_h {
            return build_layout_string_3_right(window_w, window_h, &ids, border_top);
        }
    }

    build_layout_string_direct(window_w, window_h, &ids, border_top)
}

/// Split height into two rows, compensating for border_top.
///
/// With pane-border-status top, the first row of panes loses `border_top`
/// rows to the title bar. To make visible content equal, the first row gets
/// `border_top` extra rows in the layout string.
fn split_two_rows(height: u16, border_top: u16) -> (u16, u16) {
    let effective = height.saturating_sub(border_top);
    let bh_base = effective.saturating_sub(1) / 2;
    let th_base = effective.saturating_sub(1).saturating_sub(bh_base);
    let th = th_base + border_top;
    let bh = bh_base;
    // th + 1 (divider) + bh == height
    (th, bh)
}

/// Split height into three rows, compensating for border_top.
#[allow(dead_code)]
fn split_three_rows(height: u16, border_top: u16) -> (u16, u16, u16) {
    let effective = height.saturating_sub(border_top);
    let content = effective.saturating_sub(2); // minus 2 dividers
    let per_row = content / 3;
    let remainder = content - per_row * 3;
    let h1 = per_row + border_top + if remainder >= 1 { 1 } else { 0 };
    let h2 = per_row + if remainder >= 2 { 1 } else { 0 };
    let h3 = height
        .saturating_sub(2)
        .saturating_sub(h1)
        .saturating_sub(h2);
    (h1, h2, h3)
}

/// Compute tmux layout checksum — matches tmux's layout_checksum() exactly.
/// Algorithm: rotate right 1 bit, then add each byte.
fn layout_checksum(layout: &str) -> u16 {
    let mut csum: u16 = 0;
    for &b in layout.as_bytes() {
        csum = (csum >> 1) | ((csum & 1) << 15);
        csum = csum.wrapping_add(b as u16);
    }
    csum
}

fn layout_row_string(ids: &[u32], x: u16, y: u16, width: u16, height: u16) -> String {
    if ids.len() == 1 {
        return format!("{}x{},{},{},{}", width, height, x, y, ids[0]);
    }
    let dividers = (ids.len() as u16) - 1;
    let available = width - dividers;
    let col_w = available / ids.len() as u16;

    let mut parts = Vec::new();
    let mut cx = x;
    for (i, &id) in ids.iter().enumerate() {
        let w = if i == ids.len() - 1 {
            x + width - cx
        } else {
            col_w
        };
        parts.push(format!("{}x{},{},{},{}", w, height, cx, y, id));
        cx += w + 1;
    }

    format!("{}x{},{},{}{{{}}}", width, height, x, y, parts.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_pane_full_screen() {
        let rects = grid_positions(1, 280, 80);
        assert_eq!(rects.len(), 1);
        assert_eq!(
            rects[0],
            Rect {
                x: 0,
                y: 0,
                w: 280,
                h: 80
            }
        );
    }

    #[test]
    fn two_panes_left_right() {
        let rects = grid_positions(2, 280, 80);
        assert_eq!(rects.len(), 2);
        // Left half
        assert_eq!(rects[0].x, 0);
        assert_eq!(rects[0].y, 0);
        // Right half
        assert!(rects[1].x > 0);
        assert_eq!(rects[1].y, 0);
        // Both full height
        assert_eq!(rects[0].h, 80);
        assert_eq!(rects[1].h, 80);
        // Total width covers the terminal (accounting for 1-char divider)
        assert_eq!(rects[0].w + 1 + rects[1].w, 280);
    }

    #[test]
    fn three_panes_left_full_right_split() {
        let rects = grid_positions(3, 280, 80);
        assert_eq!(rects.len(), 3);
        // Pane 1: left, full height
        assert_eq!(rects[0].x, 0);
        assert_eq!(rects[0].h, 80);
        // Pane 2: top-right
        assert!(rects[1].x > 0);
        assert_eq!(rects[1].y, 0);
        // Pane 3: bottom-right
        assert!(rects[2].x > 0);
        assert!(rects[2].y > 0);
        // Right panes stack vertically
        assert_eq!(rects[1].x, rects[2].x);
    }

    #[test]
    fn three_panes_right_full_left_split() {
        let rects = grid_positions_3_right(280, 80);
        assert_eq!(rects.len(), 3);
        // Pane 1: top-left
        assert_eq!(rects[0].x, 0);
        assert_eq!(rects[0].y, 0);
        assert!(rects[0].h < 80);
        // Pane 2: bottom-left
        assert_eq!(rects[1].x, 0);
        assert!(rects[1].y > 0);
        assert!(rects[1].h < 80);
        // Pane 3: right, full height
        assert!(rects[2].x > 0);
        assert_eq!(rects[2].y, 0);
        assert_eq!(rects[2].h, 80);
        // Left panes stack vertically
        assert_eq!(rects[0].x, rects[1].x);
        // Left and right columns don't overlap
        assert!(rects[2].x > rects[0].w);
        // Left panes cover full height (with divider)
        assert_eq!(rects[0].h + 1 + rects[1].h, 80);
    }

    #[test]
    fn four_panes_2x2() {
        let rects = grid_positions(4, 280, 80);
        assert_eq!(rects.len(), 4);
        // Top-left
        assert_eq!(rects[0].x, 0);
        assert_eq!(rects[0].y, 0);
        // Top-right
        assert!(rects[1].x > 0);
        assert_eq!(rects[1].y, 0);
        // Bottom-left
        assert_eq!(rects[2].x, 0);
        assert!(rects[2].y > 0);
        // Bottom-right
        assert!(rects[3].x > 0);
        assert!(rects[3].y > 0);
    }

    #[test]
    fn five_panes_2x2_plus_column() {
        let rects = grid_positions(5, 280, 80);
        assert_eq!(rects.len(), 5);
        // 2x2 part: slots 0-3
        assert_eq!(rects[0].y, 0); // TL
        assert_eq!(rects[1].y, 0); // TR
        assert!(rects[2].y > 0); // BL
        assert!(rects[3].y > 0); // BR
                                 // TL and BL share x=0
        assert_eq!(rects[0].x, 0);
        assert_eq!(rects[2].x, 0);
        // TR and BR share same x
        assert_eq!(rects[1].x, rects[3].x);
        // Right column: slot 4, full height
        assert_eq!(rects[4].y, 0);
        assert_eq!(rects[4].h, 80);
        assert!(rects[4].x > rects[1].x);
    }

    #[test]
    fn six_panes_3x2() {
        let rects = grid_positions(6, 282, 80);
        assert_eq!(rects.len(), 6);
        // Row 1: panes 0,1,2 at y=0
        assert_eq!(rects[0].y, 0);
        assert_eq!(rects[1].y, 0);
        assert_eq!(rects[2].y, 0);
        // Row 2: panes 3,4,5 at y>0
        assert!(rects[3].y > 0);
        assert!(rects[4].y > 0);
        assert!(rects[5].y > 0);
        // 3 columns
        assert!(rects[0].x < rects[1].x);
        assert!(rects[1].x < rects[2].x);
    }

    #[test]
    fn seven_panes_3x2_plus_column() {
        let rects = grid_positions(7, 280, 80);
        assert_eq!(rects.len(), 7);
        // 3x2 part: slots 0-5
        // Top row: 0,1,2
        assert_eq!(rects[0].y, 0);
        assert_eq!(rects[1].y, 0);
        assert_eq!(rects[2].y, 0);
        // Bottom row: 3,4,5
        assert!(rects[3].y > 0);
        assert!(rects[4].y > 0);
        assert!(rects[5].y > 0);
        // Right column: slot 6, full height
        assert_eq!(rects[6].y, 0);
        assert_eq!(rects[6].h, 80);
        assert!(rects[6].x > rects[2].x);
    }

    #[test]
    fn two_panes_never_top_bottom() {
        // Test at various sizes -- 2 panes should always be left/right
        for w in [80, 120, 200, 300] {
            for h in [24, 40, 60, 80] {
                let rects = grid_positions(2, w, h);
                assert_eq!(rects[0].y, 0, "pane 1 should be at top for {}x{}", w, h);
                assert_eq!(rects[1].y, 0, "pane 2 should be at top for {}x{}", w, h);
                assert_eq!(
                    rects[0].h, h,
                    "pane 1 should be full height for {}x{}",
                    w, h
                );
                assert_eq!(
                    rects[1].h, h,
                    "pane 2 should be full height for {}x{}",
                    w, h
                );
            }
        }
    }

    #[test]
    fn layout_string_one_pane() {
        let s = build_layout_string_direct(280, 80, &[5], 0).unwrap();
        assert!(s.contains("280x80,0,0,5"));
    }

    #[test]
    fn layout_string_two_panes() {
        let s = build_layout_string_direct(280, 80, &[5, 6], 0).unwrap();
        assert!(s.contains(",5"));
        assert!(s.contains(",6"));
        // Should have horizontal split {left,right}
        assert!(s.contains("{"));
    }

    #[test]
    fn layout_string_four_panes() {
        let s = build_layout_string_direct(280, 80, &[5, 6, 7, 8], 0).unwrap();
        assert!(s.contains(",5"));
        assert!(s.contains(",6"));
        assert!(s.contains(",7"));
        assert!(s.contains(",8"));
    }

    #[test]
    fn layout_string_empty() {
        assert!(build_layout_string_direct(280, 80, &[], 0).is_none());
    }

    #[test]
    fn split_two_rows_invariant() {
        // th + 1 (divider) + bh == height for various heights and border values
        for h in [24, 40, 60, 80, 81] {
            for bt in [0, 1] {
                let (th, bh) = split_two_rows(h, bt);
                assert_eq!(
                    th + 1 + bh,
                    h,
                    "split_two_rows({}, {}): {} + 1 + {} != {}",
                    h,
                    bt,
                    th,
                    bh,
                    h
                );
                if bt > 0 {
                    // With border, visible content should be equal (±1)
                    let visible_top = th - bt;
                    assert!(
                        (visible_top as i32 - bh as i32).unsigned_abs() <= 1,
                        "split_two_rows({}, {}): visible {} vs {} differ by >1",
                        h,
                        bt,
                        visible_top,
                        bh
                    );
                }
            }
        }
    }

    #[test]
    fn split_three_rows_invariant() {
        for h in [24, 40, 60, 80, 81] {
            for bt in [0, 1] {
                let (h1, h2, h3) = split_three_rows(h, bt);
                assert_eq!(
                    h1 + 1 + h2 + 1 + h3,
                    h,
                    "split_three_rows({}, {}): {} + 1 + {} + 1 + {} != {}",
                    h,
                    bt,
                    h1,
                    h2,
                    h3,
                    h
                );
                if bt > 0 {
                    let v1 = h1 - bt;
                    let vals = [v1, h2, h3];
                    let max = *vals.iter().max().unwrap();
                    let min = *vals.iter().min().unwrap();
                    assert!(
                        max - min <= 1,
                        "split_three_rows({}, {}): visible {:?} spread > 1",
                        h,
                        bt,
                        vals
                    );
                }
            }
        }
    }

    /// Extract pane IDs from a layout string in tree-walk order.
    /// Uses IDs >= 1000 to distinguish from coordinates (which are < 1000
    /// for any reasonable terminal size).
    fn extract_pane_ids_in_order(layout: &str) -> Vec<u32> {
        let mut ids = Vec::new();
        let bytes = layout.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b',' {
                let start = i + 1;
                let mut end = start;
                while end < bytes.len() && bytes[end].is_ascii_digit() {
                    end += 1;
                }
                if end > start {
                    if let Ok(n) = layout[start..end].parse::<u32>() {
                        if n >= 1000 {
                            ids.push(n);
                        }
                    }
                }
            }
            i += 1;
        }
        ids
    }

    #[test]
    fn layout_string_pane_order_matches_grid_positions() {
        // The layout string's tree-walk order must match grid_positions slot
        // order for all pane counts, because tmux assigns indices sequentially
        // in tree-walk order (ignoring the pane IDs in the string).
        // If these diverge, spatial matching uses the wrong slot↔index mapping.
        for count in 1..=9 {
            let ids: Vec<u32> = (1000..1000 + count as u32).collect();
            let layout = build_layout_string_direct(280, 80, &ids, 0).unwrap();
            let found = extract_pane_ids_in_order(&layout);
            assert_eq!(
                found, ids,
                "layout string pane order != sequential for {} panes.\n\
                 Expected (grid_positions order): {:?}\n\
                 Got (layout tree-walk order):    {:?}\n\
                 Layout: {}",
                count, ids, found, layout
            );
        }
    }

    #[test]
    fn four_pane_columns_equal_width() {
        // In a 2x2 grid, left and right columns should differ by at most 1 pixel.
        for w in [80, 120, 200, 280, 281] {
            let rects = grid_positions(4, w, 80);
            let left_w = rects[0].w;
            let right_w = rects[1].w;
            assert!(
                (left_w as i32 - right_w as i32).abs() <= 1,
                "4-pane columns unequal at width={}: left={}, right={} (diff={})",
                w,
                left_w,
                right_w,
                (right_w as i32 - left_w as i32).abs()
            );
        }
    }

    #[test]
    fn layout_string_four_panes_with_border() {
        let s = build_layout_string_direct(80, 24, &[1, 2, 3, 4], 1).unwrap();
        // Should contain all pane IDs
        assert!(s.contains(",1"));
        assert!(s.contains(",2"));
        assert!(s.contains(",3"));
        assert!(s.contains(",4"));
        // With border_top=1, top row should be 12 (not 11) to compensate
        assert!(s.contains("80x12,0,0"), "top row should be 12 high: {}", s);
        assert!(
            s.contains("80x11,0,13"),
            "bottom row should be 11 high at y=13: {}",
            s
        );
    }

    #[test]
    fn build_layout_string_from_panes_4() {
        use crate::sticky::Pane;
        let rects = grid_positions(4, 280, 80);
        let panes: Vec<Pane> = rects
            .iter()
            .enumerate()
            .map(|(i, r)| Pane {
                id: 100 + i as u32,
                x: r.x,
                y: r.y,
                w: r.w,
                h: r.h,
            })
            .collect();
        let s = build_layout_string(&panes, 280, 80, 0).unwrap();
        // Should contain all pane IDs
        assert!(s.contains(",100"), "missing pane 100: {}", s);
        assert!(s.contains(",101"), "missing pane 101: {}", s);
        assert!(s.contains(",102"), "missing pane 102: {}", s);
        assert!(s.contains(",103"), "missing pane 103: {}", s);
        // Should have checksum prefix
        assert!(s.len() > 5);
        assert_eq!(&s[4..5], ",");
    }

    #[test]
    fn build_layout_string_from_panes_matches_direct() {
        use crate::sticky::Pane;
        // For standard layouts, build_layout_string should produce the same
        // result as build_layout_string_direct when given matching positions
        for count in 1..=8 {
            let ids: Vec<u32> = (100..100 + count as u32).collect();
            let rects = grid_positions(count, 280, 80);
            let panes: Vec<Pane> = rects
                .iter()
                .zip(ids.iter())
                .map(|(r, &id)| Pane {
                    id,
                    x: r.x,
                    y: r.y,
                    w: r.w,
                    h: r.h,
                })
                .collect();
            let from_panes = build_layout_string(&panes, 280, 80, 0);
            let from_direct = build_layout_string_direct(280, 80, &ids, 0);
            assert_eq!(
                from_panes, from_direct,
                "mismatch for {} panes:\n  panes:  {:?}\n  direct: {:?}",
                count, from_panes, from_direct
            );
        }
    }
}
