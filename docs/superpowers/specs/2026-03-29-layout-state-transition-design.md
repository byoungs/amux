# Layout as Pure State Transition

## Problem

Pane layout is only recalculated on add/remove. Window resize causes tmux to
proportionally scale the existing split tree, drifting columns from equal width.
Additionally, geometry is computed twice independently (once for matching, once
for the layout string), creating divergence risk.

## Design

### Core Function

A single pure function owns both pane ordering and geometry:

```rust
pub struct Pane {
    pub id: u32,
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
}

pub enum LayoutEvent {
    Add(u32),       // new pane ID
    Remove(u32),    // removed pane ID
    Resize,         // window dimensions changed (also used for start/attach/space-switch)
}

pub fn compute_layout(
    current: &[Pane],
    event: LayoutEvent,
    window_w: u16,
    window_h: u16,
) -> Vec<Pane>
```

### Event Handling

- **Resize**: Compute ideal grid for `current.len()` panes at new dimensions.
  Match existing panes to slots by relative position (leftmost stays leftmost).
- **Add**: Compute ideal grid for `current.len() + 1` panes. Match existing
  panes to slots. New pane gets the leftover slot (last/rightmost).
- **Remove**: Compute ideal grid for `current.len() - 1` panes. Match surviving
  panes using sticky rules (column-mate expands, substitute fills gap).
- **Start/attach/space-switch** are all `Resize` — panes exist, recompute
  positions at current window dimensions.

### Sticky Matching Rules (Preserved)

The existing structural matching rules carry forward unchanged:

- **Balanced+column to balanced (3->4, 5->6, 7->8)**: lone column pane splits
  into its nearest column. New pane fills the other half.
- **Balanced to balanced+column (4->5, 6->7)**: existing panes stay in balanced
  part. New pane takes the right column.
- **Balanced+column to balanced (5->4, 7->6)**: right-column pane fills the gap
  left by the removed pane.
- **Balanced to balanced+column (6->5, 8->7)**: column-mate of removed pane
  takes the full-height right column.
- **4->3 right-column removal**: right-full layout variant (column-mate expands
  on the right side).

For resize, matching is purely positional — panes map to the nearest slot in
the new grid.

### Grid Geometry Rules (Preserved)

The alternating balanced / balanced+column pattern is unchanged:

| Count | Layout |
|-------|--------|
| 1 | Full screen |
| 2 | Left/right split |
| 3 | Left full-height + right split (or right-full variant) |
| 4 | 2x2 |
| 5 | 2x2 + full-height right column |
| 6 | 3x2 |
| 7 | 3x2 + full-height right column |
| 8 | 4x2 |

`grid_positions()` continues to compute these.

### Triggers

| Trigger | Event | Resolution |
|---------|-------|------------|
| Create pane | `Add(id)` | `amux create-pane` — session is explicit |
| Close pane | `Remove(id)` | `pane-exited` hook with `#{session_name}` |
| Window resize | `Resize` | `client-resized` hook with `#{session_name}` |
| Start/attach | `Resize` | `amux start` / `amux refresh` |
| Switch space | `Resize` | `switch_to_space()` after switching |

Hooks pass `#{session_name}` explicitly instead of relying on `session_name()`
guessing. Only the active space is re-laid out.

### Imperative Shell

```rust
pub fn relayout(session: &str, event: LayoutEvent) -> Result<()> {
    // 1. Read current state from tmux
    let current_panes = read_pane_positions(session)?;
    let (w, h) = window_size(session)?;
    let border_top = if has_pane_border_status(session) { 1 } else { 0 };
    let effective_h = h.saturating_sub(border_top);

    // 2. Pure function
    let new_layout = compute_layout(&current_panes, event, w, effective_h);

    // 3. Convert output to layout string and apply
    let layout_str = build_layout_string(&new_layout, w, h, border_top);
    apply_layout_string(session, &layout_str)?;

    Ok(())
}
```

`build_layout_string` takes `Vec<Pane>` directly — no re-derivation of geometry.
One source of truth flows from `compute_layout` through to tmux.

### What Gets Replaced

**Deleted:**
- `compute_pane_order` — merged into `compute_layout`
- `build_layout_string_direct` geometry re-computation — replaced by
  `build_layout_string` that takes `Vec<Pane>`
- `build_layout_string_3_right` — right-full variant is just a different
  `Vec<Pane>` from `compute_layout`
- `PaneLayout` struct — replaced by `Vec<Pane>`
- `save_pane_center` / `load_pane_center` / `read_all_pane_centers` — current
  positions come from tmux directly via `read_pane_positions`
- `PaneCenter` struct — replaced by `Pane`
- `SlotCenter` struct — slot centers derived inline from `grid_positions` output
- `count_changed` / `prev_count` tracking — the event enum makes this explicit
- `apply_grid_layout` — replaced by `relayout`

**Kept:**
- `grid_positions` — computes ideal geometry for N panes
- `match_panes_to_slots` — geometric matching (greedy nearest-first)
- `match_panes_structural` — column-aware structural matching
- Helper functions: `find_lone_column_pane`, `find_lone_column_slot`,
  `match_column_pane_splits`, `match_substitute_fills_gap`,
  `match_column_mate_expands`
- `Rect` struct
- `layout_checksum`
- All grid rules

**Modified:**
- Matching functions adapted to take `Pane` instead of `PaneCenter`
- `build_layout_string` rewritten to accept positioned panes instead of
  computing positions

### Testing

Tests are pure input/output assertions on `compute_layout`:

```rust
#[test]
fn resize_equalizes_uneven_columns() {
    let current = vec![
        Pane { id: 1, x: 0, y: 0, w: 69, h: 32 },
        Pane { id: 2, x: 70, y: 0, w: 126, h: 32 },
        Pane { id: 3, x: 0, y: 33, w: 69, h: 33 },
        Pane { id: 4, x: 70, y: 33, w: 126, h: 33 },
        Pane { id: 5, x: 197, y: 0, w: 72, h: 66 },
    ];
    let result = compute_layout(&current, LayoutEvent::Resize, 269, 66);
    // All three columns should be ~89 wide
    assert_eq!(result.len(), 5);
    assert_eq!(result[0].w, result[2].w);  // left col equal
    assert_eq!(result[0].w, result[1].w);  // left == middle
}
```

Existing 36 add/remove tests migrate: instead of asserting ordered IDs, they
assert on full `Vec<Pane>` output (both positions and ID assignments). The test
helpers `state()` and `state_with_prev()` are replaced by constructing `Vec<Pane>`
directly from `grid_positions` output.

New test categories:
- **Resize**: uneven input produces equal output
- **Add at various sizes**: existing panes keep positions, new pane gets last slot
- **Remove at various sizes**: sticky rules produce correct layout
- **Identity**: resize with correct dimensions is a no-op (positions unchanged)
- **All transitions up to 8 panes**: same exhaustive coverage as before
