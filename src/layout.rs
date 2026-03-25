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
/// Grid rules:
/// - 1 pane: full screen
/// - 2 panes: left/right split (never top/bottom)
/// - 3 panes: left full + right split vertically
/// - 4 panes: 2x2
/// - 5 panes: 2 top + 3 bottom
/// - 6 panes: 3x2 (3 columns, 2 rows)
/// - 7+: 2 rows, ceil(n/2) columns
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
        5 => {
            // 2 top, 3 bottom
            let th = (height - 1) / 2;
            let bh = height - 1 - th;
            let bot_y = th + 1;
            // Top: 2 columns
            let top_rects = layout_columns(2, width, th);
            // Bottom: 3 columns
            let bot_rects = layout_columns(3, width, bh);
            vec![
                top_rects[0].clone(), // 1: top-left
                top_rects[1].clone(), // 2: top-right
                Rect {
                    x: bot_rects[0].x,
                    y: bot_y,
                    w: bot_rects[0].w,
                    h: bh,
                }, // 3: bottom-left
                Rect {
                    x: bot_rects[1].x,
                    y: bot_y,
                    w: bot_rects[1].w,
                    h: bh,
                }, // 4: bottom-mid
                Rect {
                    x: bot_rects[2].x,
                    y: bot_y,
                    w: bot_rects[2].w,
                    h: bh,
                }, // 5: bottom-right
            ]
        }
        6 => layout_grid(2, 3, width, height),
        _ => {
            // 7+: 2 rows, ceil(n/2) columns
            let cols = count.div_ceil(2);
            layout_grid(2, cols, width, height)
                .into_iter()
                .take(count)
                .collect()
        }
    }
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
        5 => {
            // 2 top, 3 bottom
            let (th, bh) = split_two_rows(height, border_top);
            let by = th + 1;

            let top_row = layout_row_string(&pane_ids[..2], 0, 0, width, th);
            let bot_row = layout_row_string(&pane_ids[2..], 0, by, width, bh);

            format!("{}x{},0,0[{},{}]", width, height, top_row, bot_row)
        }
        _ => {
            // For 6+, use 2 rows with ceil(n/2) columns per row
            let cols = n.div_ceil(2);
            let top_count = cols;
            let (th, bh) = split_two_rows(height, border_top);
            let by = th + 1;

            let top_row = layout_row_string(&pane_ids[..top_count], 0, 0, width, th);
            let bot_row = layout_row_string(&pane_ids[top_count..], 0, by, width, bh);

            format!("{}x{},0,0[{},{}]", width, height, top_row, bot_row)
        }
    };

    let csum = layout_checksum(&body);
    Some(format!("{:04x},{}", csum, body))
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
}
