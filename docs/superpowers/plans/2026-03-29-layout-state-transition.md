# Layout State Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dual-computation layout pipeline with a single pure `compute_layout` function that takes current pane positions + event + window dimensions and returns new pane positions.

**Architecture:** Pure state transition function (`compute_layout`) in `src/sticky.rs` handles all layout decisions (ordering + geometry). Thin imperative shell in `src/tmux.rs` reads tmux state, calls the pure function, converts output to a tmux layout string, and applies it. The matching functions (`match_panes_to_slots`, `match_panes_structural`, etc.) are adapted to work with the new `Pane` type instead of `PaneCenter`/`SlotCenter`.

**Tech Stack:** Rust, tmux layout strings, tmux hooks

---

## File Structure

| File | Role | Changes |
|------|------|---------|
| `src/sticky.rs` | Pure layout logic | Replace `PaneCenter`/`SlotCenter`/`PaneLayout` with `Pane`/`LayoutEvent`. Replace `compute_pane_order` with `compute_layout`. Adapt matching functions. Rewrite all tests. |
| `src/layout.rs` | Grid geometry + layout strings | Add `build_layout_string` (takes `Vec<Pane>`, delegates to existing helpers). Keep `grid_positions`, `grid_positions_3_right`, `Rect`, `layout_checksum`, `build_layout_string_direct`, `build_layout_string_3_right` (as internal helpers). |
| `src/tmux.rs` | Imperative shell | Replace `apply_grid_layout` with `relayout`. Add `read_pane_positions`. Delete `save_pane_centers_from_positions`, `get_prev_pane_count`, `set_prev_pane_count`. Update all callers. |
| `src/config.rs` | Hooks | Update hook commands to pass `#{session_name}` explicitly. |
| `src/main.rs` | CLI entry | Update `cmd_refresh`, `switch_to_space` to use `relayout`. Add `layout` subcommand. |
| `tests/amux_test.rs` | Integration tests | Update calls from `apply_grid_layout` to `relayout`. |

---

### Task 1: Add `Pane` and `LayoutEvent` Types

**Files:**
- Modify: `src/sticky.rs` (add new types at top of file, before existing types)

- [ ] **Step 1: Add the new types**

Add these types at the top of `src/sticky.rs`, after the imports:

```rust
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
```

- [ ] **Step 2: Verify it compiles**

Run: `make test`
Expected: All existing tests still pass. The new types are unused for now.

- [ ] **Step 3: Commit**

```bash
git add src/sticky.rs
git commit -m "Add Pane and LayoutEvent types for layout state transition"
```

---

### Task 2: Write `compute_layout` with Resize Support

**Files:**
- Modify: `src/sticky.rs` (add `compute_layout` function and resize tests)

The simplest event to implement first is `Resize` — it doesn't need structural matching, just geometric matching of existing panes to new grid slots.

- [ ] **Step 1: Write failing tests for resize**

Add a NEW test submodule `mod layout_tests` inside `src/sticky.rs`, AFTER the existing `#[cfg(test)] mod tests` block. This avoids name collisions with the old `W`, `H`, and helper functions that will be deleted in Task 8.

```rust
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

#[test]
fn resize_equalizes_uneven_columns() {
    // Simulate the actual bug: panes at wrong sizes, resize to 269x66
    let current = vec![
        Pane { id: 1, x: 0, y: 0, w: 69, h: 32 },
        Pane { id: 2, x: 70, y: 0, w: 126, h: 32 },
        Pane { id: 3, x: 0, y: 33, w: 69, h: 33 },
        Pane { id: 4, x: 70, y: 33, w: 126, h: 33 },
        Pane { id: 5, x: 197, y: 0, w: 72, h: 66 },
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
    let current = panes_at(2, &[10, 11], 80, 24);
    let result = compute_layout(&current, LayoutEvent::Resize, 200, 60);
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].id, 10);
    assert_eq!(result[1].id, 11);
    // Both full height
    assert_eq!(result[0].h, 60);
    assert_eq!(result[1].h, 60);
    // Total width covers terminal (with divider)
    assert_eq!(result[0].w + 1 + result[1].w, 200);
}
```

Note: all tests in Tasks 2-4 go inside this `mod layout_tests` block. The closing `}` for the module is written after the last test in Task 4.

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — `compute_layout` not found.

- [ ] **Step 3: Implement `compute_layout` for Resize**

Add this function in `src/sticky.rs`, after the existing `compute_pane_order` function:

```rust
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
        LayoutEvent::Add(_id) => todo!("Task 3"),
        LayoutEvent::Remove(_id) => todo!("Task 4"),
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: The three new resize tests pass. All existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/sticky.rs
git commit -m "Add compute_layout with Resize event support"
```

---

### Task 3: Add Support for LayoutEvent::Add

**Files:**
- Modify: `src/sticky.rs` (implement Add handling, add tests)

- [ ] **Step 1: Write failing tests for Add**

Add these tests inside the `mod layout_tests` block created in Task 2. These mirror the existing `add_3_to_4` through `add_7_to_8` tests but use `compute_layout` directly:

```rust
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
        Pane { id: 10, x: r5[0].x, y: r5[0].y, w: r5[0].w, h: r5[0].h },
        Pane { id: 11, x: r5[1].x, y: r5[1].y, w: r5[1].w, h: r5[1].h },
        Pane { id: 12, x: r5[2].x, y: r5[2].y, w: r5[2].w, h: r5[2].h },
        Pane { id: 13, x: r5[3].x, y: r5[3].y, w: r5[3].w, h: r5[3].h },
        Pane { id: 14, x: r5[4].x, y: r5[4].y, w: r5[4].w, h: r5[4].h },
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
        Pane { id: 10, x: r7[0].x, y: r7[0].y, w: r7[0].w, h: r7[0].h },
        Pane { id: 11, x: r7[1].x, y: r7[1].y, w: r7[1].w, h: r7[1].h },
        Pane { id: 12, x: r7[2].x, y: r7[2].y, w: r7[2].w, h: r7[2].h },
        Pane { id: 13, x: r7[3].x, y: r7[3].y, w: r7[3].w, h: r7[3].h },
        Pane { id: 14, x: r7[4].x, y: r7[4].y, w: r7[4].w, h: r7[4].h },
        Pane { id: 15, x: r7[5].x, y: r7[5].y, w: r7[5].w, h: r7[5].h },
        Pane { id: 16, x: r7[6].x, y: r7[6].y, w: r7[6].w, h: r7[6].h },
    ];
    let result = compute_layout(&current, LayoutEvent::Add(99), W, H);
    assert_eq!(result.len(), 8);
    // Right column pane (16) should split into its column
    assert_eq!(result[3].id, 16); // top-right in 4x2
    assert_eq!(result[7].id, 99); // new pane fills bottom-right
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — `todo!("Task 3")` panics.

- [ ] **Step 3: Implement Add handling**

Replace the `LayoutEvent::Add` arm in `compute_layout`:

```rust
LayoutEvent::Add(new_id) => compute_add(current, new_id, window_w, window_h),
```

Add this function:

```rust
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
        let id = matched[si].unwrap_or(new_id);
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All new Add tests pass. All existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/sticky.rs
git commit -m "Add LayoutEvent::Add support to compute_layout"
```

---

### Task 4: Add Support for LayoutEvent::Remove

**Files:**
- Modify: `src/sticky.rs` (implement Remove handling, add exhaustive tests)

This is the most complex event — it includes the right-full 3-pane detection and all the sticky matching rules.

- [ ] **Step 1: Write failing tests for Remove**

Add these tests inside the `mod layout_tests` block. Exhaustive tests covering every removal position for 4→3, 5→4, 6→5, 7→6, 8→7. All tests assert on FULL ordering (every pane ID), not just the key pane. The 4→3 tests also check the right-full variant by verifying the right pane is full-height.

After the last test, close the `mod layout_tests` block with `}`.

```rust
// ── 4→3 Remove Tests ──

#[test]
fn layout_remove_4_tl() {
    let current = panes_at(4, &[10, 11, 12, 13], W, H);
    let result = compute_layout(&current, LayoutEvent::Remove(10), W, H);
    assert_eq!(result.len(), 3);
    // C expands full-left (standard 3-pane: left-full + right-split)
    assert_eq!(result[0].id, 12); // left full-height
    assert_eq!(result[0].h, H);   // full height
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — `todo!("Task 4")` panics.

- [ ] **Step 3: Implement Remove handling**

Replace the `LayoutEvent::Remove` arm in `compute_layout`:

```rust
LayoutEvent::Remove(removed_id) => compute_remove(current, removed_id, window_w, window_h),
```

Add this function:

```rust
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All new Remove tests pass. All existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/sticky.rs
git commit -m "Add LayoutEvent::Remove support to compute_layout"
```

---

### Task 5: Add `build_layout_string` That Takes `Vec<Pane>`

**Files:**
- Modify: `src/layout.rs` (add new function)

This function takes the output of `compute_layout` (positioned panes) and generates the tmux layout string. It does NOT recompute geometry — it uses the positions as given.

- [ ] **Step 1: Write failing test**

Add in `src/layout.rs` `#[cfg(test)] mod tests`:

```rust
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — `build_layout_string` not found.

- [ ] **Step 3: Implement `build_layout_string`**

Add this function in `src/layout.rs`, after `build_layout_string_3_right`:

```rust
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/layout.rs
git commit -m "Add build_layout_string that takes positioned panes"
```

---

### Task 6: Add `read_pane_positions` and `relayout` Shell

**Files:**
- Modify: `src/tmux.rs` (add `read_pane_positions`, add `relayout`)

- [ ] **Step 1: Add `read_pane_positions`**

Add this function in `src/tmux.rs`, near `get_pane_ids`:

```rust
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
```

- [ ] **Step 2: Add `relayout`**

Add this function in `src/tmux.rs`, near the existing `apply_grid_layout`:

```rust
/// Apply a layout change to the session. This is the single entry point for
/// all layout operations — add, remove, resize, start, and space-switch.
pub fn relayout(session: &str, event: crate::sticky::LayoutEvent) -> Result<()> {
    let current = read_pane_positions(session)?;
    if current.is_empty() {
        return Ok(());
    }

    let (w, h) = window_size(session)?;
    let border_top = if has_pane_border_status(session) { 1u16 } else { 0 };
    let effective_h = h.saturating_sub(border_top);

    let new_layout = crate::sticky::compute_layout(&current, event, w, effective_h);

    // Build and apply the layout string
    if let Some(ls) = crate::layout::build_layout_string(&new_layout, w, h, border_top) {
        // Reset split tree before applying custom layout
        let _ = Command::new("tmux")
            .args(["select-layout", "-t", session, "tiled"])
            .output();
        let _ = Command::new("tmux")
            .args(["select-layout", "-t", session, &ls])
            .output()
            .context("failed to apply layout")?;
    }

    // Swap panes to match desired ordering.
    // For Resize events, geometric matching should preserve the original order
    // so swaps are a no-op. For Add/Remove, pane counts differ so this block
    // is skipped (tmux handles the new/removed pane via join-pane/kill-pane).
    let current_ids: Vec<u32> = current.iter().map(|p| p.id).collect();
    let desired_ids: Vec<u32> = new_layout.iter().map(|p| p.id).collect();
    if current_ids.len() == desired_ids.len() && desired_ids != current_ids {
        // Re-read IDs after layout application (tmux may have reindexed)
        let fresh_ids = get_pane_ids(session)?;
        if fresh_ids.len() == desired_ids.len() {
            swap_panes_to_order(session, &fresh_ids, &desired_ids)?;
        }
    }

    Ok(())
}
```

- [ ] **Step 3: Verify it compiles**

Run: `make test`
Expected: All tests pass. `relayout` is not yet called by anything.

- [ ] **Step 4: Commit**

```bash
git add src/tmux.rs
git commit -m "Add read_pane_positions and relayout shell function"
```

---

### Task 7: Replace All `apply_grid_layout` Callers with `relayout`

**Files:**
- Modify: `src/tmux.rs` (update callers)
- Modify: `src/main.rs` (update callers)
- Modify: `tests/amux_test.rs` (update test calls)

- [ ] **Step 1: Update `create_pane` in `src/tmux.rs`**

In `create_pane` (line ~77), replace:
```rust
let _ = apply_grid_layout(session);
```
with:
```rust
let _ = relayout(session, crate::sticky::LayoutEvent::Resize);
```

Note: `create_pane` doesn't know the new pane's tmux ID at this point (it uses `join-pane` which changes IDs). Using `Resize` is correct here because the new pane is already joined — we just need to re-equalize positions.

- [ ] **Step 2: Update `kill_pane` in `src/tmux.rs`**

In `kill_pane` (line ~164), replace:
```rust
let _ = apply_grid_layout(session);
```
with:
```rust
let _ = relayout(session, crate::sticky::LayoutEvent::Resize);
```

Note: The pane is already killed when this runs, so `Resize` is appropriate — we're re-laying out the surviving panes.

- [ ] **Step 3: Update remaining callers in `src/tmux.rs`**

Replace all remaining `apply_grid_layout` calls with `relayout(session, crate::sticky::LayoutEvent::Resize)`:

- `enter_split` (line ~719): `let _ = relayout(&grid_window, crate::sticky::LayoutEvent::Resize);`
- `exit_split` (line ~731): `relayout(session, crate::sticky::LayoutEvent::Resize)?;`
- `exit_split` (line ~773): `relayout(session, crate::sticky::LayoutEvent::Resize)?;`
- `restore_tiled` (line ~877): `relayout(session, crate::sticky::LayoutEvent::Resize)?;`
- `send_pane_to_session` (line ~962-963):
  ```rust
  let _ = relayout(from_session, crate::sticky::LayoutEvent::Resize);
  let _ = relayout(to_session, crate::sticky::LayoutEvent::Resize);
  ```

- [ ] **Step 4: Update `cmd_refresh` and `cmd_start` in `src/main.rs`**

In `cmd_refresh` (line ~281), replace:
```rust
tmux::apply_grid_layout(&session)?;
```
with:
```rust
tmux::relayout(&session, amux::sticky::LayoutEvent::Resize)?;
```

In `cmd_start` (line ~195), replace:
```rust
tmux::apply_grid_layout(&session)?;
```
with:
```rust
tmux::relayout(&session, amux::sticky::LayoutEvent::Resize)?;
```

- [ ] **Step 5: Update `tests/amux_test.rs`**

In `pane_titles_survive_layout_changes` (line ~193), replace:
```rust
amux::tmux::apply_grid_layout(&ts.name).expect("tiled");
```
with:
```rust
amux::tmux::relayout(&ts.name, amux::sticky::LayoutEvent::Resize).expect("tiled");
```

- [ ] **Step 6: Delete `apply_grid_layout`**

Remove the entire `apply_grid_layout` function from `src/tmux.rs` (lines ~336-409).

- [ ] **Step 7: Run tests**

Run: `make test`
Expected: All tests pass with the new `relayout` function.

- [ ] **Step 8: Commit**

```bash
git add src/tmux.rs src/main.rs tests/amux_test.rs
git commit -m "Replace apply_grid_layout with relayout everywhere"
```

---

### Task 8: Delete Dead Code

**Files:**
- Modify: `src/sticky.rs` (remove old types and functions)
- Modify: `src/tmux.rs` (remove old helpers)

- [ ] **Step 1: Delete old types and tmux IO from `src/sticky.rs`**

Remove the following from `src/sticky.rs`:
- `PaneLayout` struct
- `compute_pane_order` function
- `save_pane_center` function
- `load_pane_center` function
- `load_pane_prev_center` function
- `read_all_pane_centers` function
- `set_pane_option` helper
- `get_pane_option` helper
- The `use anyhow::{Context, Result};` import (if no IO functions remain)
- The `use std::process::Command;` import (if no IO functions remain)

Keep (but change visibility from `pub` to private — they're now internal to `sticky.rs`):
- `PaneCenter` struct (used internally by matching functions)
- `SlotCenter` struct (used internally by matching functions)
- `rect_center` function
- All `match_*` functions
- All `find_lone_*` functions
- `Pane`, `LayoutEvent`, `compute_layout`, `compute_resize`, `compute_add`, `compute_remove`

- [ ] **Step 2: Delete old helpers and tests from `src/tmux.rs`**

Remove the following from `src/tmux.rs`:
- `save_pane_centers_from_positions` function
- `get_prev_pane_count` function
- `set_prev_pane_count` function
- `save_and_load_pane_centers` test (line ~1217) — it calls the deleted `save_pane_center`/`load_pane_center`

- [ ] **Step 3: Delete old tests from `src/sticky.rs`**

Remove the entire old test block (the one with the old `state()`, `state_with_prev()`, `order()` helpers and all the `add_*`, `remove_*`, `snap_back_*` tests). The new tests from Tasks 2-4 replace these completely.

- [ ] **Step 4: Verify it compiles and tests pass**

Run: `make test`
Expected: All tests pass. No dead code warnings for removed items.

- [ ] **Step 5: Commit**

```bash
git add src/sticky.rs src/tmux.rs
git commit -m "Remove old layout types and functions replaced by compute_layout"
```

---

### Task 9: Update Hooks to Pass Session Name Explicitly

**Files:**
- Modify: `src/config.rs` (update hook format strings)

- [ ] **Step 1: Update `pane-exited` hook**

In `apply_hooks` in `src/config.rs`, change:
```rust
&format!("run-shell \"{} refresh 2>/dev/null\"", bin),
```
to:
```rust
&format!("run-shell \"{} layout #{{session_name}} 2>/dev/null\"", bin),
```

- [ ] **Step 2: Update `client-resized` hook**

Change:
```rust
&format!("run-shell \"{} refresh 2>/dev/null\"", bin),
```
to:
```rust
&format!("run-shell \"{} layout #{{session_name}} 2>/dev/null\"", bin),
```

- [ ] **Step 3: Add `layout` subcommand to `src/main.rs`**

Add to the `Commands` enum:
```rust
/// Re-apply layout to a specific session (called by tmux hooks)
Layout { session: String },
```

Add the handler in the match:
```rust
Some(Commands::Layout { session }) => {
    std::env::set_var("AMUX_SESSION", &session);
    tmux::relayout(&session, amux::sticky::LayoutEvent::Resize)
}
```

- [ ] **Step 4: Verify it compiles**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/config.rs src/main.rs
git commit -m "Pass session name explicitly in tmux hooks via layout subcommand"
```

---

### Task 10: Add Space-Switch Relayout

**Files:**
- Modify: `src/main.rs` (add relayout call after space switch)

- [ ] **Step 1: Add relayout to `switch_to_space`**

In `switch_to_space` in `src/main.rs`, after the `switch-client` command succeeds, add:

```rust
// Re-equalize layout for the target space (window size may have changed)
let _ = tmux::relayout(target, amux::sticky::LayoutEvent::Resize);
```

- [ ] **Step 2: Verify it compiles**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/main.rs
git commit -m "Re-equalize layout on space switch"
```

---

### Task 11: Run Full Validation

**Files:** None (verification only)

- [ ] **Step 1: Run `make validate`**

Run: `make validate`
Expected: All tests pass, including tmux integration tests.

- [ ] **Step 2: Check for dead code warnings**

Review the compiler output for any `unused` warnings related to the old types (`PaneCenter`, `SlotCenter`, etc.). If `PaneCenter` and `SlotCenter` now have unnecessary `pub` visibility, change them to `pub(crate)` or private.

- [ ] **Step 3: Fix any issues found**

If any tests fail or warnings appear, fix them.

- [ ] **Step 4: Commit fixes if needed**

```bash
git add -A
git commit -m "Fix warnings and test issues from layout transition"
```
