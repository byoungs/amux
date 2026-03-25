# Layout Engine & README Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace tmux's unpredictable `select-layout tiled` with a custom layout engine that keeps panes spatially sticky, and write the project README.

**Architecture:** A new `layout.rs` module calculates exact pane positions for any count (1-9) and generates tmux custom layout strings. Panes are assigned to fixed grid slots. Closing a pane causes neighbors to expand (not reshuffle). New panes fill the next logical slot. The layout engine replaces ALL calls to `select-layout tiled` in the codebase.

**Tech Stack:** Rust, tmux custom layout strings

---

## Grid Rules

```
1 pane:     full screen

2 panes:    ALWAYS left/right (never top/bottom)
┌─────┬─────┐
│  1  │  2  │
└─────┴─────┘

3 panes:    left full-height + right column split
┌─────┬─────┐
│     │  2  │
│  1  ├─────┤
│     │  3  │
└─────┴─────┘

4 panes:    2x2
┌─────┬─────┐
│  1  │  2  │
├─────┼─────┤
│  3  │  4  │
└─────┴─────┘

5 panes:    left 2-high + right 3-high
┌─────┬─────┐
│  1  │  2  │
├─────┼─────┤
│     │  4  │
│  3  ├─────┤
│     │  5  │
└─────┴─────┘

6 panes:    3x2
┌───┬───┬───┐
│ 1 │ 2 │ 3 │
├───┼───┼───┤
│ 4 │ 5 │ 6 │
└───┴───┴───┘
```

## tmux Layout String Format

From examining a live 4-pane layout:
```
fd90,281x80,0,0[281x39,0,0{140x39,0,0,5,140x39,141,0,268},281x40,0,40{140x40,0,40,2,140x40,141,40,3}]
```

Format: `checksum,WxH,X,Y` then:
- `[A,B]` = vertical split (top A, bottom B)
- `{A,B}` = horizontal split (left A, right B)
- Leaf: `WxH,X,Y,pane_id` (pane_id is tmux's numeric ID like 5, 268)

Checksum: 4-hex-digit value. tmux calculates it but **accepts any value** — we can use `0000`.

## File Structure

| File | Responsibility |
|------|---------------|
| `src/layout.rs` (new) | Grid logic: slot assignment, layout string generation, gap handling |
| `src/tmux.rs` | Replace `apply_tiled_layout` with `apply_layout`, add `get_pane_ids` |
| `src/main.rs` | Use layout engine in create/close/refresh flows |
| `src/config.rs` | Update Ctrl-n binding to use layout engine |
| `tests/focus_test.rs` | Layout stability tests |
| `README.md` (new) | Project documentation |

---

### Task 1: Create layout engine — grid position calculation

The core module that calculates where each pane goes.

**Files:**
- Create: `src/layout.rs`
- Modify: `src/lib.rs`

- [ ] **Step 1: Write unit tests for grid positions**

```rust
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
/// - 5 panes: 2 left + 3 right (left column 2-high, right column 3-high)
/// - 6 panes: 3x2 (3 columns, 2 rows)
/// - 7+: 2 rows, ceil(n/2) columns
pub fn grid_positions(count: usize, width: u16, height: u16) -> Vec<Rect> {
    // implementation below
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_pane_full_screen() {
        let rects = grid_positions(1, 280, 80);
        assert_eq!(rects.len(), 1);
        assert_eq!(rects[0], Rect { x: 0, y: 0, w: 280, h: 80 });
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
        // Test at various sizes — 2 panes should always be left/right
        for w in [80, 120, 200, 300] {
            for h in [24, 40, 60, 80] {
                let rects = grid_positions(2, w, h);
                assert_eq!(rects[0].y, 0, "pane 1 should be at top for {}x{}", w, h);
                assert_eq!(rects[1].y, 0, "pane 2 should be at top for {}x{}", w, h);
                assert_eq!(rects[0].h, h, "pane 1 should be full height for {}x{}", w, h);
                assert_eq!(rects[1].h, h, "pane 2 should be full height for {}x{}", w, h);
            }
        }
    }
}
```

- [ ] **Step 2: Implement grid_positions**

```rust
pub fn grid_positions(count: usize, width: u16, height: u16) -> Vec<Rect> {
    match count {
        0 => vec![],
        1 => vec![Rect { x: 0, y: 0, w: width, h: height }],
        2 => layout_columns(2, width, height),
        3 => {
            // Left full-height + right column split into 2
            let left_w = (width - 1) / 2;
            let right_w = width - 1 - left_w;
            let right_x = left_w + 1;
            let top_h = (height - 1) / 2;
            let bot_h = height - 1 - top_h;
            vec![
                Rect { x: 0, y: 0, w: left_w, h: height },
                Rect { x: right_x, y: 0, w: right_w, h: top_h },
                Rect { x: right_x, y: top_h + 1, w: right_w, h: bot_h },
            ]
        }
        4 => layout_grid(2, 2, width, height),
        5 => {
            // Left column 2-high, right column 3-high
            let left_w = (width - 1) / 2;
            let right_w = width - 1 - left_w;
            let right_x = left_w + 1;
            // Left: 2 rows
            let left_rects = layout_rows(2, 0, 0, left_w, height);
            // Right: 3 rows
            let right_rects = layout_rows(3, right_x, 0, right_w, height);
            let mut result = Vec::new();
            // Interleave: slot 1=left-top, 2=right-top, 3=left-bot, 4=right-mid, 5=right-bot
            result.push(left_rects[0].clone());   // 1: top-left
            result.push(right_rects[0].clone());  // 2: top-right
            result.push(left_rects[1].clone());   // 3: bottom-left
            result.push(right_rects[1].clone());  // 4: mid-right
            result.push(right_rects[2].clone());  // 5: bottom-right
            result
        }
        6 => layout_grid(2, 3, width, height),
        _ => {
            // 7+: 2 rows, ceil(n/2) columns
            let cols = (count + 1) / 2;
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
        rects.push(Rect { x, y: 0, w, h: height });
        x += w + 1; // +1 for divider
    }
    rects
}

/// Layout N equal rows in a given region.
fn layout_rows(n: usize, x: u16, y: u16, width: u16, height: u16) -> Vec<Rect> {
    let dividers = (n as u16).saturating_sub(1);
    let available = height.saturating_sub(dividers);
    let row_h = available / n as u16;
    let mut rects = Vec::new();
    let mut cy = y;
    for i in 0..n {
        let h = if i == n - 1 { y + height - cy } else { row_h };
        rects.push(Rect { x, y: cy, w: width, h });
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
```

- [ ] **Step 3: Add module to lib.rs**

```rust
pub mod layout;
```

- [ ] **Step 4: Run tests**

Run: `cargo test --lib layout -- --nocapture`
Expected: All pass

- [ ] **Step 5: Commit**

```
feat: add layout engine with grid position calculation
```

---

### Task 2: Generate tmux layout strings

Convert grid positions to tmux's custom layout string format.

**Files:**
- Modify: `src/layout.rs`

- [ ] **Step 1: Write tests for layout string generation**

```rust
#[test]
fn layout_string_one_pane() {
    let s = build_layout_string(280, 80, &[(0, 5)]); // pane_id 5
    // Should be: checksum,280x80,0,0,5
    assert!(s.contains("280x80,0,0,5"));
}

#[test]
fn layout_string_two_panes() {
    let s = build_layout_string(280, 80, &[(0, 5), (1, 6)]);
    // Should contain both pane IDs
    assert!(s.contains(",5"));
    assert!(s.contains(",6"));
    // Should have horizontal split {left,right}
    assert!(s.contains("{") || s.contains("["));
}

#[test]
fn layout_string_applied_to_tmux() {
    // This is tested in integration tests
}
```

- [ ] **Step 2: Implement layout string generation**

```rust
/// Build a tmux layout string for the given panes.
/// `panes` is a list of (slot_index, tmux_pane_id) pairs.
/// The layout string places each pane at the grid position for its slot.
pub fn build_layout_string(width: u16, height: u16, panes: &[(usize, u32)]) -> String {
    let positions = grid_positions(panes.len(), width, height);

    if panes.is_empty() {
        return String::new();
    }

    if panes.len() == 1 {
        let (_, id) = panes[0];
        let body = format!("{}x{},0,0,{}", width, height, id);
        return format!("{},{}", checksum(&body), body);
    }

    // Build the layout tree based on the grid structure
    let body = build_tree(&positions, panes, 0, 0, width, height);
    format!("{},{}", checksum(&body), body)
}

fn build_tree(
    positions: &[Rect],
    panes: &[(usize, u32)],
    x: u16, y: u16, w: u16, h: u16,
) -> String {
    // Find panes within this region
    let contained: Vec<usize> = (0..panes.len())
        .filter(|&i| {
            let r = &positions[i];
            r.x >= x && r.y >= y && r.x + r.w <= x + w && r.y + r.h <= y + h
        })
        .collect();

    if contained.len() == 1 {
        let i = contained[0];
        let (_, id) = panes[i];
        let r = &positions[i];
        return format!("{}x{},{},{},{}", r.w, r.h, r.x, r.y, id);
    }

    // Determine if this region splits horizontally or vertically
    // Check if panes are in different columns (horizontal split) or rows (vertical split)
    let all_ys: Vec<u16> = contained.iter().map(|&i| positions[i].y).collect();
    let all_xs: Vec<u16> = contained.iter().map(|&i| positions[i].x).collect();

    let min_y = *all_ys.iter().min().unwrap();
    let max_y = *all_ys.iter().max().unwrap();
    let min_x = *all_xs.iter().min().unwrap();
    let max_x = *all_xs.iter().max().unwrap();

    if min_y == max_y || (min_x != max_x && contained.len() <= 3) {
        // Horizontal split (side by side) → {left,right}
        // Group by unique x positions
        let mut x_groups: Vec<u16> = contained.iter().map(|&i| positions[i].x).collect();
        x_groups.sort();
        x_groups.dedup();

        let parts: Vec<String> = x_groups.iter().map(|&gx| {
            let group: Vec<usize> = contained.iter()
                .filter(|&&i| positions[i].x == gx)
                .copied()
                .collect();
            if group.len() == 1 {
                let i = group[0];
                let (_, id) = panes[i];
                let r = &positions[i];
                format!("{}x{},{},{},{}", r.w, r.h, r.x, r.y, id)
            } else {
                // These panes share the same x → they're stacked vertically
                let r0 = &positions[group[0]];
                let total_h: u16 = group.iter().map(|&i| positions[i].h).sum::<u16>()
                    + (group.len() as u16 - 1); // dividers
                let sub = build_tree(positions, panes, gx, r0.y, r0.w, total_h);
                format!("{}x{},{},{}{}", r0.w, total_h, gx, r0.y, sub.chars().skip_while(|c| *c != '[' && *c != '{' && *c != ',').collect::<String>())
            }
        }).collect();

        format!("{}x{},{},{}{{{}}}",
            w, h, x, y,
            parts.join(","))
    } else {
        // Vertical split (top/bottom) → [top,bottom]
        let mut y_groups: Vec<u16> = contained.iter().map(|&i| positions[i].y).collect();
        y_groups.sort();
        y_groups.dedup();

        let parts: Vec<String> = y_groups.iter().map(|&gy| {
            let group: Vec<usize> = contained.iter()
                .filter(|&&i| positions[i].y == gy)
                .copied()
                .collect();
            if group.len() == 1 {
                let i = group[0];
                let (_, id) = panes[i];
                let r = &positions[i];
                format!("{}x{},{},{},{}", r.w, r.h, r.x, r.y, id)
            } else {
                // Multiple panes in same row → horizontal split
                let r0 = &positions[group[0]];
                build_tree(positions, panes, x, gy, w, r0.h)
            }
        }).collect();

        format!("{}x{},{},{}[{}]",
            w, h, x, y,
            parts.join(","))
    }
}

/// Calculate tmux layout checksum (simple, tmux accepts 0000).
fn checksum(_layout: &str) -> String {
    // tmux accepts any 4-hex checksum — use 0000 for simplicity
    "0000".to_string()
}
```

Note: The layout string generation is complex. The above is a starting point — it may need debugging against real tmux. The key insight is that tmux accepts `0000` as a checksum, so we don't need to compute the real one.

**Actually, a simpler approach**: instead of generating layout strings (which are fragile), use `tmux resize-pane` to set each pane's exact position and size. This is more reliable:

```rust
/// Apply the grid layout by resizing each pane individually.
pub fn apply_grid(session: &str, pane_ids: &[u32], width: u16, height: u16) -> Result<()> {
    let positions = grid_positions(pane_ids.len(), width, height);

    // First, apply a basic layout to get panes in roughly the right structure
    // Then resize each pane to its exact position
    for (i, &id) in pane_ids.iter().enumerate() {
        if i < positions.len() {
            let r = &positions[i];
            let target = format!("%{}", id);
            let _ = Command::new("tmux")
                .args(["resize-pane", "-t", &target,
                    "-x", &r.w.to_string(), "-y", &r.h.to_string()])
                .output();
        }
    }
    Ok(())
}
```

Actually, `resize-pane` alone can't reposition panes — it can only change their size within the existing split structure. We need the layout string approach OR we need to use `select-layout` with a custom string.

Let me use a **hybrid approach**: generate a simpler layout string by directly describing the split tree, not trying to parse positions back into a tree.

```rust
/// Build a tmux layout string for N panes in the standard grid.
/// This generates the split tree directly rather than trying to
/// decompose grid positions back into a tree.
pub fn build_layout_string_direct(
    width: u16, height: u16, pane_ids: &[u32]
) -> Option<String> {
    let n = pane_ids.len();
    if n == 0 { return None; }

    let body = match n {
        1 => {
            format!("{}x{},0,0,{}", width, height, pane_ids[0])
        }
        2 => {
            // Left/right split
            let lw = (width - 1) / 2;
            let rw = width - 1 - lw;
            let rx = lw + 1;
            format!("{}x{},0,0{{{}x{},0,0,{},{}x{},{},0,{}}}",
                width, height,
                lw, height, pane_ids[0],
                rw, height, rx, pane_ids[1])
        }
        3 => {
            // Left full-height + right split vertically
            let lw = (width - 1) / 2;
            let rw = width - 1 - lw;
            let rx = lw + 1;
            let th = (height - 1) / 2;
            let bh = height - 1 - th;
            let by = th + 1;
            format!("{}x{},0,0{{{}x{},0,0,{},{}x{},{},0[{}x{},{},0,{},{}x{},{},{},{}]}}",
                width, height,
                lw, height, pane_ids[0],
                rw, height, rx,
                rw, th, rx, pane_ids[1],
                rw, bh, rx, by, pane_ids[2])
        }
        4 => {
            // 2x2
            let lw = (width - 1) / 2;
            let rw = width - 1 - lw;
            let rx = lw + 1;
            let th = (height - 1) / 2;
            let bh = height - 1 - th;
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
        _ => {
            // For 5+, use 2 rows with ceil(n/2) columns per row
            let cols = (n + 1) / 2;
            let top_count = cols;
            let bot_count = n - cols;
            let th = (height - 1) / 2;
            let bh = height - 1 - th;
            let by = th + 1;

            let top_row = layout_row_string(&pane_ids[..top_count], 0, 0, width, th);
            let bot_row = layout_row_string(&pane_ids[top_count..], 0, by, width, bh);

            format!("{}x{},0,0[{},{}]", width, height, top_row, bot_row)
        }
    };

    Some(format!("0000,{}", body))
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
        let w = if i == ids.len() - 1 { x + width - cx } else { col_w };
        parts.push(format!("{}x{},{},{},{}", w, height, cx, y, id));
        cx += w + 1;
    }

    format!("{}x{},{},{}{{{}}}",
        width, height, x, y,
        parts.join(","))
}
```

- [ ] **Step 2: Run tests**

Run: `cargo test --lib layout -- --nocapture`

- [ ] **Step 3: Commit**

```
feat: add tmux layout string generation for custom grid layouts
```

---

### Task 3: Integrate layout engine into tmux.rs

Replace `apply_tiled_layout` with the custom layout engine.

**Files:**
- Modify: `src/tmux.rs`
- Modify: `src/layout.rs` (add apply function)

- [ ] **Step 1: Add get_pane_ids function to tmux.rs**

```rust
/// Get ordered list of tmux pane IDs (numeric, like 5, 268).
pub fn get_pane_ids(session: &str) -> Result<Vec<u32>> {
    let output = Command::new("tmux")
        .args([
            "list-panes", "-t", session,
            "-F", "#{pane_id}",
        ])
        .output()
        .context("failed to list pane ids")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout.lines()
        .filter(|l| !l.is_empty())
        .filter_map(|l| l.trim_start_matches('%').parse().ok())
        .collect())
}

/// Get the window dimensions.
pub fn window_size(session: &str) -> Result<(u16, u16)> {
    let output = Command::new("tmux")
        .args(["display-message", "-t", session, "-p", "#{window_width} #{window_height}"])
        .output()
        .context("failed to get window size")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let parts: Vec<&str> = stdout.trim().split(' ').collect();
    let w = parts.get(0).and_then(|s| s.parse().ok()).unwrap_or(80);
    let h = parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(24);
    Ok((w, h))
}
```

- [ ] **Step 2: Add apply_grid_layout function**

```rust
/// Apply the custom grid layout to the session.
/// This replaces select-layout tiled with our own layout engine.
pub fn apply_grid_layout(session: &str) -> Result<()> {
    let ids = get_pane_ids(session)?;
    if ids.is_empty() { return Ok(()); }

    let (w, h) = window_size(session)?;

    if let Some(layout_str) = crate::layout::build_layout_string_direct(w, h, &ids) {
        let output = Command::new("tmux")
            .args(["select-layout", "-t", session, &layout_str])
            .output()
            .context("failed to apply custom layout")?;
        if !output.status.success() {
            // Fallback to tiled if custom layout fails
            let _ = Command::new("tmux")
                .args(["select-layout", "-t", session, "tiled"])
                .output();
        }
    }
    Ok(())
}
```

- [ ] **Step 3: Replace all apply_tiled_layout calls**

In `src/tmux.rs`:
- `create_pane`: replace `select-layout tiled` with `apply_grid_layout`
- `kill_pane`: replace `select-layout tiled` with `apply_grid_layout`
- `apply_tiled_layout`: rename to `apply_grid_layout` (or keep as wrapper)
- `restore_tiled`: use `apply_grid_layout`
- `exit_split`: use `apply_grid_layout`
- `send_pane_to_session`: use `apply_grid_layout`

In `src/main.rs`:
- Replace all `tmux::apply_tiled_layout` calls with `tmux::apply_grid_layout`

In `src/config.rs`:
- The Ctrl-n binding uses `run-shell "focus new"` which calls `create_pane` → already handled

- [ ] **Step 4: Run all tests**

Run: `cargo test -- --test-threads=1 --nocapture`

- [ ] **Step 5: Commit**

```
feat: replace select-layout tiled with custom grid layout engine
```

---

### Task 4: Integration tests for layout stability

**Files:**
- Modify: `tests/focus_test.rs`

- [ ] **Step 1: Add layout stability tests**

```rust
#[test]
fn layout_two_panes_always_left_right() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::tmux::create_pane(&session, None).expect("pane");

    let panes = focus::tmux::list_panes(&session).expect("list");
    assert_eq!(panes.len(), 2);

    // Both panes should be at y=0 (side by side, not stacked)
    // Check via tmux that pane tops are the same
    let output = std::process::Command::new("tmux")
        .args(["list-panes", "-t", &session, "-F", "#{pane_top}"])
        .output().expect("list");
    let tops: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines().map(|l| l.to_string()).collect();
    assert_eq!(tops[0], tops[1], "2 panes should be side-by-side (same top): {:?}", tops);

    cleanup(&session);
}

#[test]
fn layout_close_preserves_positions() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::tmux::create_pane(&session, None).expect("pane 2");
    focus::tmux::create_pane(&session, None).expect("pane 3");
    focus::tmux::create_pane(&session, None).expect("pane 4");

    // 4 panes in 2x2
    let panes_before = focus::tmux::list_panes(&session).expect("list");
    assert_eq!(panes_before.len(), 4);

    // Record positions of pane 0 and pane 3 (top-left and bottom-right)
    let p0_before = (panes_before[0].width, panes_before[0].height);

    // Kill pane 1 (top-right) — pane 0 should expand, panes 2+3 stay
    focus::tmux::kill_pane(&session, 1).expect("kill");

    let panes_after = focus::tmux::list_panes(&session).expect("list");
    assert_eq!(panes_after.len(), 3);

    // Pane 0 should be wider (expanded into slot 1's space)
    assert!(panes_after[0].width > p0_before.0,
        "pane 0 should expand: before_w={}, after_w={}", p0_before.0, panes_after[0].width);

    cleanup(&session);
}

#[test]
fn layout_four_panes_is_2x2() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        focus::tmux::create_pane(&session, None).expect("pane");
    }

    let output = std::process::Command::new("tmux")
        .args(["list-panes", "-t", &session, "-F", "#{pane_left} #{pane_top}"])
        .output().expect("list");
    let positions: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines().filter(|l| !l.is_empty()).map(|l| l.to_string()).collect();

    assert_eq!(positions.len(), 4, "should have 4 panes");

    // Should have 2 unique x positions (2 columns) and 2 unique y positions (2 rows)
    let xs: std::collections::HashSet<&str> = positions.iter()
        .map(|p| p.split(' ').next().unwrap()).collect();
    let ys: std::collections::HashSet<&str> = positions.iter()
        .map(|p| p.split(' ').nth(1).unwrap()).collect();

    assert_eq!(xs.len(), 2, "should have 2 columns: {:?}", positions);
    assert_eq!(ys.len(), 2, "should have 2 rows: {:?}", positions);

    cleanup(&session);
}
```

- [ ] **Step 2: Run all tests**

Run: `cargo test -- --test-threads=1 --nocapture`

- [ ] **Step 3: Commit**

```
test: add layout stability tests for grid positions
```

---

### Task 5: Write README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README**

```markdown
# focus

A terminal workflow manager for AI coding. Focus orchestrates tmux to give you
a grid of live terminal panes with three-level zoom, spatial stability, and
instant workspace switching — so you can monitor multiple AI agents while
staying in flow.

## Quick Start

1. **Install:**
   ```bash
   cargo install --path .
   ```

2. **Launch:**
   ```bash
   focus
   ```

3. **Create panes** with `Ctrl-n`, **zoom in** with `Ctrl-+`, **zoom out** with `Ctrl--`.

That's it. You're running.

## How It Works

Focus is a thin layer on top of tmux. It configures tmux with the right layout,
styles, and key bindings, then gets out of the way. tmux handles all rendering
natively — perfect keystroke fidelity, perfect resize, zero overhead.

### Three-Level Zoom

Think of it like a camera:

| Level | What you see | What you do |
|-------|-------------|-------------|
| **Bird's Eye** | All panes tiled equally | Read and scan across all panes |
| **Working View** | All panes visible, active pane enlarged | Type in the active pane |
| **Full Screen** | One pane fills the screen | Deep focus on one task |

`Ctrl-+` zooms in one level. `Ctrl--` zooms out one level.

`Ctrl-1` through `Ctrl-9` jumps to a specific pane. Press the same number
again to zoom deeper. Press a different number to switch panes.

### Pane Layout

Panes are arranged in a consistent grid that never reshuffles:

- **2 panes:** always left and right (never top/bottom)
- **3 panes:** left full-height + right column split
- **4 panes:** 2×2 grid
- **5-6 panes:** 2 rows, balanced columns

When you close a pane, neighbors expand to fill the gap — other panes
stay in their position. When you create a new pane, it fills the next
logical grid slot. Your mental map of "project-alpha is top-left"
never breaks.

### Spaces

Spaces are independent workspaces, each with their own grid of panes.
Think of them like desks — you swivel your chair to face a different
desk, and everything on the previous desk stays exactly where you left it.

`Ctrl-P` opens the space picker. Press a number to switch, or `n` to
create a new space. `Ctrl-S` sends the current pane to another space.

## Key Bindings

| Key | Action |
|-----|--------|
| `Ctrl-+` | Zoom in (Bird's Eye → Working → Full Screen) |
| `Ctrl--` | Zoom out (Full Screen → Working → Bird's Eye) |
| `Ctrl-1..9` | Jump to pane N (context-aware zoom) |
| `Ctrl-n` | Create new pane |
| `Ctrl-P` | Space picker (switch or create workspaces) |
| `Ctrl-S` | Send current pane to another space |
| `Ctrl-L` | Split view (two panes side by side) |
| Arrow keys | Navigate panes in Bird's Eye mode |

## Configuration

Focus stores its state in `~/.focus/`. The tmux session name defaults to
`focus` — override with the `FOCUS_SESSION` environment variable.

Pane titles are auto-generated from the working directory and git branch:
`project-name/feature-branch`. You can also name panes explicitly:
`focus new "my custom name"`.

## Requirements

- tmux 3.2+
- Rust (for building from source)

## Commands

```
focus              Start or attach to a session
focus start        Start a new session
focus attach       Attach to existing session
focus new [name]   Create a new pane
focus list         List all panes
focus refresh      Re-apply config to existing session
focus spaces       Space picker
focus send         Send pane to another space
```

## Vision

Focus is built for developers who run multiple AI coding agents in parallel.
The core insight: your terminal is a factory floor. You need to monitor all
your agents at a glance, zoom into one when it needs attention, and zoom back
out when you're done. No context switching. No window juggling. Just focus.

**Roadmap:**
- Queue management — park panes, auto-promote when capacity opens
- Alert detection — highlight panes when agents need input
- Session persistence — survive tmux server restarts
```

- [ ] **Step 2: Commit**

```
docs: add README with quick start, key bindings, and vision
```

---

### Task 6: Build, install, and verify

- [ ] **Step 1: Run full test suite**

Run: `cargo test -- --test-threads=1 --nocapture`

- [ ] **Step 2: Install and refresh**

Run: `cargo install --path . && focus refresh`

- [ ] **Step 3: Manual verification**

1. Start with 1 pane → full screen
2. Ctrl-n → 2 panes, left/right (never top/bottom)
3. Ctrl-n → 3 panes, left full + right split
4. Ctrl-n → 4 panes, 2x2 grid
5. Close pane 2 (Ctrl-2 to focus, type `exit`) → pane 1 expands right, 3/4 stay
6. Ctrl-n → new pane fills the gap
7. Verify panes never reshuffle

- [ ] **Step 4: Commit any fixes**

```
fix: tune layout engine based on manual testing
```
