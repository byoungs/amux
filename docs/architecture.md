# Architecture

## Overview

amux is a Rust CLI that configures and controls tmux. It doesn't render anything
itself — tmux handles all terminal output. amux manages layout, zoom state, and
pane positioning, then calls tmux commands to apply them.

## Core Concepts

### Zoom Levels

amux maintains a three-level zoom state machine per session, stored as the
`AMUX_LEVEL` tmux environment variable (1, 2, or 3).

**Level 1 — Bird's Eye:** All panes tiled equally via `apply_grid_layout()`.
Arrow keys navigate between panes (via the `amux-birdeye` key table). No pane
receives typed input. Entering this level calls `restore_tiled()` which unzooms
if needed and re-applies the grid layout.

**Level 2 — Working View:** The active pane receives all keystrokes. The grid
layout stays fixed — no resizing happens when switching between panes. Layout
only changes when panes are added, removed, or the terminal window is resized.

**Level 3 — Full Screen:** Uses tmux's native zoom (`resize-pane -Z`). One pane
fills the terminal. Other panes still exist but are hidden.

**Transitions** (in `cmd_zoom`, `cmd_zoom_in`, `cmd_zoom_out`):

```
           Ctrl-+          Ctrl-+
  L1 ──────────────► L2 ──────────────► L3
  ◄──────────────    ◄──────────────
           Ctrl--          Ctrl--
```

Context-aware (`Ctrl-N`):
- L1 + any → select pane, smart resize, go L2
- L2 + same pane → toggle zoom, go L3
- L2 + different pane → restore grid, select pane, smart resize, stay L2
- L3 + same pane → no-op
- L3 + different pane → unzoom, select, smart resize, go L2

### Grid Layout Engine (layout.rs)

`grid_positions(count, width, height)` returns a `Vec<Rect>` of pixel-precise
rectangles for each pane. The layout is deterministic: same pane count and
terminal size always produces the same grid.

| Panes | Grid shape |
|-------|-----------|
| 1 | Full screen |
| 2 | Left/right split (never top/bottom) |
| 3 | Left full-height + right column split into 2 |
| 4 | 2x2 |
| 5 | Left 2-high + right 3-high (interleaved slot order) |
| 6 | 3x2 (3 columns, 2 rows) |
| 7+ | 2 rows, ceil(n/2) columns |

`build_layout_string_direct()` converts these rectangles into tmux's internal
layout string format (e.g., `a1b2,280x80,0,0{...}`) including the correct
checksum. This string is passed to `tmux select-layout`.

### Spatial Stickiness (sticky.rs)

When panes are added or removed, existing panes should stay in their grid
position. The system tracks each pane's center point:

- `@amux-cx`, `@amux-cy` — current center (tmux pane options)
- `@amux-pcx`, `@amux-pcy` — previous center (for snap-back)

On every `apply_grid_layout()` call:

1. Compute new slot centers from `grid_positions()`
2. Read each pane's saved center
3. Match panes to slots by minimum Euclidean distance (greedy nearest-first)
4. If going up in count and panes have previous centers, use those for matching
   (snap-back behavior)
5. Apply layout, then use `swap-pane` to reorder panes into matched slots
6. Save actual positions as new centers (rotating current → previous)

**Why swap-pane?** tmux's `select-layout` ignores pane IDs in layout strings —
it assigns positions to panes in index order. So we apply the layout first,
then swap panes into their matched positions.

### Spaces (tmux sessions)

Each "space" is a separate tmux session marked with `AMUX_MANAGED=1`. The
space picker (`cmd_spaces`) lists all managed sessions and provides a raw
terminal UI for navigation. `send_pane_to_session()` uses `join-pane` to
move a pane between sessions, then re-tiles both.

### Split View (tmux windows)

Split view creates a second tmux window within the same session. Two panes
are moved from the grid (window 0) to the split window via `join-pane`.
Exiting moves them back. Requires 3+ panes (need at least 1 remaining in grid).

### Pane Creation

New panes are created via `new-window -d` (detached temp window) followed by
`join-pane` to move into window 0. This ensures the new pane appends to the
end of the pane list without disrupting existing pane order. `split-window`
was avoided because it inserts adjacent to the active pane.

### Key Bindings (config.rs)

All bindings are in tmux's root key table (no prefix). amux disables the
default `Ctrl-B` prefix entirely to prevent "stuck input" when rapid terminal
output accidentally triggers the prefix wait state.

Bird's Eye mode uses a custom key table (`amux-birdeye`) where arrow keys
navigate between panes and re-enter the same table (allowing multiple moves
without exiting the mode).

### Pane Titles

Titles are stored in `@amux-title` (a tmux pane option). This is used instead
of tmux's built-in `pane_title` because applications running in panes (like
Claude Code) can override `pane_title` via escape sequences. `@amux-title`
is only settable via `tmux set-option`.

Auto-generation (`util.rs`): extracts the project name from `~/src/PROJECT/`
paths and appends the git branch (unless it's main/master).

## tmux State

amux stores all runtime state in tmux itself (no external database):

| Variable | Scope | Purpose |
|----------|-------|---------|
| `AMUX_MANAGED=1` | Session env | Marks session as amux-managed |
| `AMUX_LEVEL={1,2,3}` | Session env | Current zoom level |
| `AMUX_PANE_COUNT=N` | Session env | Previous pane count (for sticky direction) |
| `AMUX_SPLIT_FIRST=N` | Session env | First pane index for split selection |
| `AMUX_LAST_NOTIFY=epoch` | Session env | Unix timestamp of last system notification |
| `@amux-title` | Pane option | Custom pane title |
| `@amux-cx`, `@amux-cy` | Pane option | Current center coordinates |
| `@amux-pcx`, `@amux-pcy` | Pane option | Previous center coordinates |
| `@amux-alert` | Pane option | `1` if pane needs user attention |
| `@amux-alert-count` | Session option | Number of panes with active alerts |

Pane options are attached to the pane object and survive index renumbering.
Session env vars are scoped to the session and disappear when it's killed.
Session options (`@amux-alert-count`) are accessible in tmux format strings,
which is why the alert count uses a session option rather than an env var.

### Attention Management

amux tracks which panes need user attention via `@amux-alert` pane options.
The alert pipeline uses Claude Code's `Notification` hook rather than tmux's
bell monitoring, because tmux's `alert-bell` hook does not identify which pane
emitted the bell.

**Alert flow:** Claude Code's Notification hook fires inside the pane → calls
`amux alert-pane N` → sets `@amux-alert=1` on pane N → updates
`@amux-alert-count` → optionally sends macOS notification (if terminal is not
frontmost, with 30-second suppression).

**Dismissal:** When a pane becomes active (via zoom, Ctrl-N, or pane switch),
`dismiss_alert()` clears `@amux-alert` and decrements the count.

**Visual signals** are progressive along the zoom axis:
- Level 3: status badge (`⬤ N`) in right corner
- Level 2: amber border on alerting panes
- Level 1: all pane borders visible — full team dashboard
- Space picker: amber dots on spaces with waiting agents

**Smart landing:** When switching to a space with exactly one alerting pane,
amux focuses that pane at level 2. Otherwise, it resumes where the user left
off (capping at level 2 if they were at level 3).

See [docs/attention-management.md](attention-management.md) for the full
design specification.

## File State

- `~/.amux/state.json` — Serialized `AmuxState` (pane positions, selected
  pane, view mode). Currently written but not read back — kept for future
  session persistence features.
