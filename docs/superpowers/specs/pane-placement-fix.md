# Pane Placement Bug: Double Layout Application

## Problem
When pressing Ctrl-N (or Cmd-N in amux-term) to create a new pane, existing panes visually jump/reflow before settling into their correct positions.

## Root Cause
The root-table Ctrl-N keybinding in `src/config.rs:236-242` runs:
```
amux new && amux refresh
```

But `amux new` → `create_pane()` → already calls `apply_grid_layout()` internally. The extra `amux refresh` triggers a SECOND layout pass that:
1. Resets to `select-layout tiled` (visual jump)
2. Reapplies the custom grid layout

The bird's-eye Ctrl-N (`config.rs:225-229`) does NOT have this problem — it only runs `amux new`.

## Fix
In `src/config.rs:236-242`, change:
```rust
r#"run-shell "cd '#{{pane_current_path}}' && {} new && {} refresh 2>/dev/null""#
```
to:
```rust
r#"run-shell "cd '#{{pane_current_path}}' && {} new""#
```

## Optional: Also fix `apply_grid_layout`
In `src/tmux.rs:376-378`, skip `select-layout tiled` when `count_changed` is false. This makes `amux refresh` safe to call redundantly without visual disruption.
