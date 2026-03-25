# Spatial Stickiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When panes are added or removed, existing panes stay as close to their current grid position as possible, and snap back to previous positions when the pane count returns.

**Architecture:** Each pane stores its current grid-slot center as a tmux pane option (`@focus-cx`, `@focus-cy`) and its previous center (`@focus-pcx`, `@focus-pcy`). When `apply_grid_layout` runs, it computes new grid slots, matches existing panes to slots by minimum geometric distance (preferring previous centers when going up in count), and passes the matched pane-to-slot ordering to `build_layout_string_direct`. New panes get whatever slot is unmatched. All matching logic lives in a new `src/sticky.rs` module.

**Tech Stack:** Rust, tmux pane options (`set-option -p`), existing layout engine in `src/layout.rs`

**Design notes:**
- Snap-back is one level deep per pane (current + previous center). This is intentional — each transition is always +1 or -1 pane, and previous center gives the snap-back behavior naturally.
- The greedy nearest-first matching algorithm is sufficient for 1-9 panes. A comment notes that a Hungarian algorithm would be optimal but unnecessary at this scale.
- Tmux pane options (`@focus-cx` etc.) are attached to the pane object, not the index. They survive index renumbering when panes are killed.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/sticky.rs` | Create | Spatial matching: read/write pane centers, match panes to slots by min displacement |
| `src/lib.rs` | Modify | Add `pub mod sticky;` |
| `src/tmux.rs` | Modify | `apply_grid_layout` calls sticky matching instead of raw `get_pane_ids` ordering |
| `src/layout.rs` | None | Unchanged — `grid_positions` and `build_layout_string_direct` already do what we need |
| `tests/sticky_test.rs` | Create | Unit tests for matching algorithm (no tmux needed) |
| `tests/focus_test.rs` | Modify | Integration test: kill middle pane + recreate, verify positions snap back |

---

### Task 1: Spatial matching algorithm (pure logic, no tmux)

**Files:**
- Create: `src/sticky.rs`
- Create: `tests/sticky_test.rs`
- Modify: `src/lib.rs`

This task builds the core matching function as a pure function with no tmux dependency. It takes pane IDs with their centers (current + optional previous), a list of new grid slot centers, and a direction (up/down in count), and returns the pane-to-slot assignment.

- [ ] **Step 1: Write the failing test — basic 4->3 matching**

In `tests/sticky_test.rs`:

```rust
use focus::sticky::{match_panes_to_slots, PaneCenter, SlotCenter};

#[test]
fn four_to_three_keeps_corners() {
    // 2x2 grid: panes at (70,20), (210,20), (70,60), (210,60)
    // Kill top-right -> 3-pane layout: slots at (70,40), (210,20), (210,60)
    // Pane A (was top-left) should match left slot (70,40) — closest
    // Pane C (was bottom-left) should also want left, but A is closer — C gets (210,20) or (210,60)
    // Pane D (was bottom-right) should match (210,60) — closest
    let panes = vec![
        PaneCenter { id: 1, cx: 70, cy: 20, prev_cx: None, prev_cy: None },  // was top-left
        PaneCenter { id: 3, cx: 70, cy: 60, prev_cx: None, prev_cy: None },  // was bottom-left
        PaneCenter { id: 4, cx: 210, cy: 60, prev_cx: None, prev_cy: None }, // was bottom-right
    ];
    let slots = vec![
        SlotCenter { cx: 70, cy: 40 },   // left (full height)
        SlotCenter { cx: 210, cy: 20 },  // top-right
        SlotCenter { cx: 210, cy: 60 },  // bottom-right
    ];

    let result = match_panes_to_slots(&panes, &slots, false);

    // result is Vec<Option<u32>> — pane IDs in slot order, None for empty slots
    assert_eq!(result[0], Some(1), "top-left pane should take left slot");
    assert_eq!(result[2], Some(4), "bottom-right pane should keep bottom-right");
    // Pane 3 gets whatever is left (top-right)
    assert_eq!(result[1], Some(3));
}
```

- [ ] **Step 2: Write the failing test — snap-back on 4->3->4**

```rust
#[test]
fn snap_back_on_recreate() {
    // After 4->3, panes remember where they were at count=4
    // When going 3->4, they should snap back using previous centers
    let panes = vec![
        PaneCenter { id: 1, cx: 70, cy: 40, prev_cx: Some(70), prev_cy: Some(20) },   // was top-left in 2x2
        PaneCenter { id: 3, cx: 210, cy: 20, prev_cx: Some(70), prev_cy: Some(60) },   // was bottom-left in 2x2
        PaneCenter { id: 4, cx: 210, cy: 60, prev_cx: Some(210), prev_cy: Some(60) },  // was bottom-right in 2x2
    ];
    // New 2x2 slots: (70,20), (210,20), (70,60), (210,60)
    let slots = vec![
        SlotCenter { cx: 70, cy: 20 },
        SlotCenter { cx: 210, cy: 20 },
        SlotCenter { cx: 70, cy: 60 },
        SlotCenter { cx: 210, cy: 60 },
    ];

    // going_up=true: use previous centers for matching
    let result = match_panes_to_slots(&panes, &slots, true);

    // Pane 1 prev was (70,20) -> slot 0 (70,20)
    // Pane 3 prev was (70,60) -> slot 2 (70,60)
    // Pane 4 prev was (210,60) -> slot 3 (210,60)
    assert_eq!(result[0], Some(1), "pane 1 snaps back to top-left");
    assert_eq!(result[2], Some(3), "pane 3 snaps back to bottom-left");
    assert_eq!(result[3], Some(4), "pane 4 snaps back to bottom-right");
    // Slot 1 (210,20) is unmatched — that's where new pane goes
    assert_eq!(result[1], None, "top-right slot is empty for new pane");
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cargo test --test sticky_test 2>&1`
Expected: compilation error — `sticky` module doesn't exist

- [ ] **Step 4: Add module declaration**

In `src/lib.rs`, add:
```rust
pub mod sticky;
```

- [ ] **Step 5: Implement the matching algorithm**

Create `src/sticky.rs`:

```rust
// src/sticky.rs

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

    // Build (pane_idx, slot_idx, distance) pairs and sort by distance
    let mut pairs: Vec<(usize, usize, i64)> = Vec::new();
    for (pi, pane) in panes.iter().enumerate() {
        let (px, py) = if going_up {
            // Prefer previous center if available
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

    // Sort by distance (greedy nearest-first assignment)
    pairs.sort_by_key(|&(_, _, d)| d);

    // Assign greedily: shortest distance first, skip already-used panes/slots
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
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cargo test --test sticky_test 2>&1`
Expected: both tests PASS

- [ ] **Step 7: Write test — new pane with no history appends naturally**

Add to `tests/sticky_test.rs`:

```rust
#[test]
fn new_pane_no_history_gets_unmatched_slot() {
    // 2 existing panes at left/right, adding a third
    // 3-pane layout: left full, top-right, bottom-right
    let panes = vec![
        PaneCenter { id: 1, cx: 70, cy: 40, prev_cx: None, prev_cy: None },  // was left
        PaneCenter { id: 2, cx: 210, cy: 40, prev_cx: None, prev_cy: None }, // was right
    ];
    let slots = vec![
        SlotCenter { cx: 70, cy: 40 },   // left (full height)
        SlotCenter { cx: 210, cy: 20 },  // top-right
        SlotCenter { cx: 210, cy: 60 },  // bottom-right
    ];

    let result = match_panes_to_slots(&panes, &slots, true);

    assert_eq!(result[0], Some(1), "left pane stays left");
    // Pane 2 was at (210,40) — top-right (210,20) and bottom-right (210,60) are equidistant
    // Either is fine, but one slot should be None (for new pane)
    let assigned_count = result.iter().filter(|id| id.is_some()).count();
    assert_eq!(assigned_count, 2, "only 2 panes assigned");
    assert!(result.contains(&None), "one slot should be empty for new pane");
}
```

- [ ] **Step 8: Run all sticky tests**

Run: `cargo test --test sticky_test 2>&1`
Expected: all 3 tests PASS

- [ ] **Step 9: Commit**

```bash
git add src/sticky.rs src/lib.rs tests/sticky_test.rs
git commit -m "feat: spatial matching algorithm for pane-to-slot assignment"
```

---

### Task 2: Read/write pane centers via tmux

**Files:**
- Modify: `src/sticky.rs`
- Modify: `src/tmux.rs`

Wire the matching algorithm to tmux by reading/writing `@focus-cx`, `@focus-cy`, `@focus-pcx`, `@focus-pcy` pane options. These options are attached to the pane object itself (not the index), so they survive index renumbering when panes are killed.

- [ ] **Step 1: Write the failing test — save and load centers**

Add to `src/tmux.rs` tests:

```rust
#[test]
fn save_and_load_pane_centers() {
    let name = test_session_name();
    cleanup(&name);
    create_session(&name).expect("create");

    crate::sticky::save_pane_center(&name, 0, 100, 50).expect("save");
    let (cx, cy) = crate::sticky::load_pane_center(&name, 0).expect("load");
    assert_eq!((cx, cy), (100, 50));

    cleanup(&name);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --lib tmux::tests::save_and_load_pane_centers 2>&1`
Expected: FAIL — functions don't exist

- [ ] **Step 3: Implement save/load functions**

Add to `src/sticky.rs`:

```rust
use anyhow::{Context, Result};
use std::process::Command;

/// Save a pane's current center as tmux pane options.
/// Rotates current -> previous before writing new current.
pub fn save_pane_center(session: &str, pane_index: usize, cx: i32, cy: i32) -> Result<()> {
    let target = format!("{}:.{}", session, pane_index);

    // Read current center (if any) and save as previous
    if let Ok((old_cx, old_cy)) = load_pane_center(session, pane_index) {
        set_pane_option(&target, "@focus-pcx", old_cx)?;
        set_pane_option(&target, "@focus-pcy", old_cy)?;
    }

    set_pane_option(&target, "@focus-cx", cx)?;
    set_pane_option(&target, "@focus-cy", cy)?;
    Ok(())
}

/// Load a pane's current center from tmux pane options.
pub fn load_pane_center(session: &str, pane_index: usize) -> Result<(i32, i32)> {
    let target = format!("{}:.{}", session, pane_index);
    let cx = get_pane_option(&target, "@focus-cx")?;
    let cy = get_pane_option(&target, "@focus-cy")?;
    Ok((cx, cy))
}

/// Load a pane's previous center from tmux pane options.
pub fn load_pane_prev_center(session: &str, pane_index: usize) -> Option<(i32, i32)> {
    let target = format!("{}:.{}", session, pane_index);
    let cx = get_pane_option(&target, "@focus-pcx").ok()?;
    let cy = get_pane_option(&target, "@focus-pcy").ok()?;
    Some((cx, cy))
}

/// Read all pane centers for a session, returning PaneCenters keyed by pane ID.
/// Uses a single tmux list-panes call for efficiency.
pub fn read_all_pane_centers(session: &str) -> Result<Vec<PaneCenter>> {
    let output = Command::new("tmux")
        .args([
            "list-panes", "-t", session,
            "-F", "#{pane_id}\t#{pane_index}\t#{@focus-cx}\t#{@focus-cy}\t#{@focus-pcx}\t#{@focus-pcy}",
        ])
        .output()
        .context("failed to list pane centers")?;
    let stdout = String::from_utf8_lossy(&output.stdout);

    let mut centers = Vec::new();
    for line in stdout.lines().filter(|l| !l.is_empty()) {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() < 6 { continue; }
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
        anyhow::bail!("tmux set-option {} failed: {}", key, String::from_utf8_lossy(&output.stderr));
    }
    Ok(())
}

fn get_pane_option(target: &str, key: &str) -> Result<i32> {
    let output = Command::new("tmux")
        .args(["show-options", "-p", "-t", target, "-v", key])
        .output()
        .with_context(|| format!("failed to get {} on {}", key, target))?;
    let val = String::from_utf8_lossy(&output.stdout).trim().to_string();
    val.parse().with_context(|| format!("{} not set or invalid: {:?}", key, val))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test --lib tmux::tests::save_and_load_pane_centers 2>&1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/sticky.rs src/tmux.rs
git commit -m "feat: read/write pane center coordinates via tmux pane options"
```

---

### Task 3: Wire matching into apply_grid_layout

**Files:**
- Modify: `src/tmux.rs` (the `apply_grid_layout` function and new helper)

This is the key integration point. Instead of passing `get_pane_ids()` directly to `build_layout_string_direct`, we read each pane's saved center, compute new slot centers from `grid_positions`, run `match_panes_to_slots`, and pass the matched ordering. After applying the layout, read actual pane positions from tmux and save as centers.

**Important:** `apply_grid_layout` is called with bare session names (`"focus"`) from most callers, but `enter_split` passes `"focus:0"`. The function must handle both — strip any `:N` window suffix when constructing pane targets for sticky operations.

- [ ] **Step 1: Write the failing integration test**

Add to `tests/focus_test.rs`:

```rust
#[test]
fn spatial_stickiness_kill_and_recreate() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        focus::tmux::create_pane(&session, None).expect("pane");
    }
    // 4 panes in 2x2. Record pane IDs and positions.
    let ids_before = focus::tmux::get_pane_ids(&session).expect("ids");
    let positions_before = pane_positions(&session);

    // Kill pane at index 1 (top-right in 2x2)
    focus::tmux::kill_pane(&session, 1).expect("kill");

    // Pane 0 (was top-left) should still be on the left side
    let positions_after_kill = pane_positions(&session);
    assert!(positions_after_kill[0].0 < 10,
        "pane 0 should stay on left after kill: {:?}", positions_after_kill);

    // Create a new pane — back to 4
    focus::tmux::create_pane(&session, None).expect("new");

    // The 3 surviving panes should be back near their original positions
    let positions_after_create = pane_positions(&session);
    let ids_after = focus::tmux::get_pane_ids(&session).expect("ids");

    // Find surviving pane IDs (those in both before and after)
    let survivors: Vec<u32> = ids_before.iter()
        .filter(|id| ids_after.contains(id))
        .copied()
        .collect();

    // Each survivor's position should be close to where it started
    for &surv_id in &survivors {
        let before_idx = ids_before.iter().position(|&id| id == surv_id).unwrap();
        let after_idx = ids_after.iter().position(|&id| id == surv_id).unwrap();
        let (bx, by) = positions_before[before_idx];
        let (ax, ay) = positions_after_create[after_idx];
        let dist = ((bx - ax).abs() + (by - ay).abs()) as u32;
        assert!(dist < 20,
            "pane %{} moved too far: ({},{}) -> ({},{}), dist={}",
            surv_id, bx, by, ax, ay, dist);
    }

    cleanup(&session);
}

/// Helper: get (pane_left, pane_top) for each pane in index order.
fn pane_positions(session: &str) -> Vec<(i32, i32)> {
    let output = std::process::Command::new("tmux")
        .args(["list-panes", "-t", session, "-F", "#{pane_left} #{pane_top}"])
        .output().expect("list");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let parts: Vec<&str> = l.split(' ').collect();
            (parts[0].parse().unwrap_or(0), parts[1].parse().unwrap_or(0))
        })
        .collect()
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test focus_test spatial_stickiness 2>&1`
Expected: FAIL — panes shift positions without matching

- [ ] **Step 3: Modify apply_grid_layout to use spatial matching**

Replace the body of `apply_grid_layout` in `src/tmux.rs`:

```rust
pub fn apply_grid_layout(session: &str) -> Result<()> {
    let ids = get_pane_ids(session)?;
    if ids.is_empty() { return Ok(()); }

    let (w, h) = window_size(session)?;
    let rects = crate::layout::grid_positions(ids.len(), w, h);

    // Compute new slot centers
    let slot_centers: Vec<crate::sticky::SlotCenter> = rects.iter()
        .map(|r| {
            let (cx, cy) = crate::sticky::rect_center(r.x, r.y, r.w, r.h);
            crate::sticky::SlotCenter { cx, cy }
        })
        .collect();

    // Read existing pane centers (if any)
    let pane_centers = crate::sticky::read_all_pane_centers(session).unwrap_or_default();

    // Detect direction by comparing to previous pane count
    let prev_count = get_prev_pane_count(session);
    let going_up = (ids.len() as i32) > prev_count && prev_count > 0;

    // Build matching input — only include panes that are in the current window
    let match_input: Vec<crate::sticky::PaneCenter> = ids.iter()
        .map(|&id| {
            pane_centers.iter()
                .find(|p| p.id == id)
                .cloned()
                .unwrap_or(crate::sticky::PaneCenter {
                    id, cx: 0, cy: 0, prev_cx: None, prev_cy: None,
                })
        })
        .collect();

    // Match panes to slots
    let matched = crate::sticky::match_panes_to_slots(&match_input, &slot_centers, going_up);

    // Build the ordered pane ID list for the layout string.
    // Fill None slots with unmatched pane IDs (new panes).
    let matched_ids: Vec<u32> = matched.iter().filter_map(|&id| id).collect();
    let mut unmatched_iter = ids.iter().filter(|id| !matched_ids.contains(id));
    let ordered_ids: Vec<u32> = matched.iter()
        .map(|opt| match opt {
            Some(id) => *id,
            None => *unmatched_iter.next().unwrap_or(&ids[0]),
        })
        .collect();

    // Reset split tree first
    let _ = Command::new("tmux")
        .args(["select-layout", "-t", session, "tiled"])
        .output();

    if let Some(layout_str) = crate::layout::build_layout_string_direct(w, h, &ordered_ids) {
        let _ = Command::new("tmux")
            .args(["select-layout", "-t", session, &layout_str])
            .output()
            .context("failed to apply custom layout")?;
    }

    // After layout is applied, save each pane's actual position as its center
    save_pane_centers_from_positions(session)?;

    // Track pane count for going_up detection
    set_prev_pane_count(session, ids.len());

    Ok(())
}

/// Read each pane's actual position from tmux and save as center coordinates.
fn save_pane_centers_from_positions(session: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args([
            "list-panes", "-t", session,
            "-F", "#{pane_index}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}",
        ])
        .output()
        .context("failed to read pane positions")?;
    let stdout = String::from_utf8_lossy(&output.stdout);

    for line in stdout.lines().filter(|l| !l.is_empty()) {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() < 5 { continue; }
        let idx: usize = parts[0].parse().unwrap_or(0);
        let x: u16 = parts[1].parse().unwrap_or(0);
        let y: u16 = parts[2].parse().unwrap_or(0);
        let w: u16 = parts[3].parse().unwrap_or(0);
        let h: u16 = parts[4].parse().unwrap_or(0);
        let (cx, cy) = crate::sticky::rect_center(x, y, w, h);
        let _ = crate::sticky::save_pane_center(session, idx, cx, cy);
    }
    Ok(())
}

fn get_prev_pane_count(session: &str) -> i32 {
    let output = Command::new("tmux")
        .args(["show-environment", "-t", session, "FOCUS_PANE_COUNT"])
        .output()
        .ok();
    output.and_then(|o| {
        String::from_utf8_lossy(&o.stdout)
            .trim()
            .strip_prefix("FOCUS_PANE_COUNT=")
            .and_then(|v| v.parse().ok())
    }).unwrap_or(0)
}

fn set_prev_pane_count(session: &str, count: usize) {
    let _ = Command::new("tmux")
        .args(["set-environment", "-t", session, "FOCUS_PANE_COUNT", &count.to_string()])
        .output();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test --test focus_test spatial_stickiness 2>&1`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cargo test 2>&1`
Expected: all tests PASS (no regressions)

- [ ] **Step 6: Commit**

```bash
git add src/tmux.rs src/sticky.rs tests/focus_test.rs
git commit -m "feat: wire spatial matching into apply_grid_layout"
```

---

### Task 4: Edge cases and cleanup

**Files:**
- Modify: `tests/sticky_test.rs`
- Modify: `tests/focus_test.rs`

- [ ] **Step 1: Test — single pane (no matching needed)**

```rust
#[test]
fn single_pane_no_crash() {
    let panes = vec![
        PaneCenter { id: 1, cx: 140, cy: 40, prev_cx: None, prev_cy: None },
    ];
    let slots = vec![
        SlotCenter { cx: 140, cy: 40 },
    ];
    let result = match_panes_to_slots(&panes, &slots, false);
    assert_eq!(result, vec![Some(1)]);
}
```

- [ ] **Step 2: Test — first layout (no saved centers)**

```rust
#[test]
fn first_layout_no_saved_centers() {
    // All panes have (0,0) — should still assign without panic
    let panes = vec![
        PaneCenter { id: 1, cx: 0, cy: 0, prev_cx: None, prev_cy: None },
        PaneCenter { id: 2, cx: 0, cy: 0, prev_cx: None, prev_cy: None },
    ];
    let slots = vec![
        SlotCenter { cx: 70, cy: 40 },
        SlotCenter { cx: 210, cy: 40 },
    ];
    let result = match_panes_to_slots(&panes, &slots, false);
    // Both should be assigned (order doesn't matter for equal distances)
    let mut sorted: Vec<u32> = result.iter().filter_map(|&id| id).collect();
    sorted.sort();
    assert_eq!(sorted, vec![1, 2]);
}
```

- [ ] **Step 3: Test — idempotent apply (no pane changes)**

Add to `tests/focus_test.rs`:

```rust
#[test]
fn apply_layout_twice_preserves_centers() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        focus::tmux::create_pane(&session, None).expect("pane");
    }

    focus::tmux::apply_grid_layout(&session).expect("layout 1");
    let positions_1 = pane_positions(&session);

    focus::tmux::apply_grid_layout(&session).expect("layout 2");
    let positions_2 = pane_positions(&session);

    assert_eq!(positions_1, positions_2, "layout should be stable on reapply");

    cleanup(&session);
}
```

- [ ] **Step 4: Integration test — rapid kill/create cycles**

Add to `tests/focus_test.rs`:

```rust
#[test]
fn stickiness_survives_rapid_changes() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        focus::tmux::create_pane(&session, None).expect("pane");
    }

    // Rapid kill/create cycles
    for _ in 0..3 {
        focus::tmux::kill_pane(&session, 1).expect("kill");
        focus::tmux::create_pane(&session, None).expect("new");
    }

    assert_eq!(focus::tmux::pane_count(&session).expect("count"), 4);

    // Should still be a valid 2x2 layout
    let positions = pane_positions(&session);
    let xs: std::collections::HashSet<i32> = positions.iter().map(|p| p.0).collect();
    let ys: std::collections::HashSet<i32> = positions.iter().map(|p| p.1).collect();
    assert_eq!(xs.len(), 2, "should have 2 columns: {:?}", positions);
    assert_eq!(ys.len(), 2, "should have 2 rows: {:?}", positions);

    cleanup(&session);
}
```

- [ ] **Step 5: Run all tests**

Run: `cargo test 2>&1`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add tests/sticky_test.rs tests/focus_test.rs
git commit -m "test: edge cases for spatial stickiness"
```
