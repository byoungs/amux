# Session Scoping Design

## Problem

amux hooks and key bindings are globally scoped in tmux, causing cross-session
interference between live sessions and integration tests.

**Symptoms:**
- "Pane 7 does not exist" error flashes on live session even when not in focus (PEN-167)
- Tests call `apply_config()` which overwrites global hooks, last writer wins
- Key bindings fire in all tmux sessions, and session resolution can be ambiguous

## Design

### 1. Scope hooks to their session

**Current:** `set-hook -g pane-exited "run-shell ..."`
**New:** `set-hook -t SESSION pane-exited "run-shell ..."`

Change `apply_hooks(session)` to use `-t session` instead of `-g` for all three hooks:
- `pane-exited` → `amux layout #{session_name}`
- `client-resized` → `amux layout #{session_name}`
- `pane-focus-out` → `amux update-title #{pane_index} '#{pane_current_path}'`

Each space gets its own hooks. Test sessions get their own hooks. No overwriting.

### 2. Pass session context in key bindings

**Current:** `bind-key -n C-7 run-shell "amux zoom 6"`
**New:** `bind-key -n C-7 run-shell "amux --session #{session_name} zoom 6"`

tmux expands `#{session_name}` at keypress time, capturing the correct session.
The amux binary uses this instead of guessing via `tmux display-message`.

Key bindings remain global (tmux limitation), but every command knows which
session triggered it.

### 3. Add --session global CLI flag

Add `--session` as a global flag on the `Cli` struct (before the subcommand).
Priority order for session resolution:

1. `--session` flag (most reliable — captured at point of action)
2. `AMUX_SESSION` env var (used by tests via `amux_cmd()`)
3. tmux client context via `tmux display-message -p #{session_name}`
4. `"amux"` default

### 4. Pane titles (PEN-168)

No code changes. Wait and see if scoping fixes resolve the issue. The
`pane-focus-out` hook becoming session-scoped may have been the root cause
(wrong session's hook firing, wrong pane_current_path context).

## Files Changed

- `src/main.rs` — Add `--session` global flag to `Cli` struct, update `session_name()`
- `src/config.rs` — Change `apply_hooks()` to use `-t session`, update all key binding
  `run-shell` commands to include `--session #{session_name}`

## What This Does NOT Change

- Key bindings are still global (tmux limitation). They just route correctly now.
- Test infrastructure (`tests/common/mod.rs`, `tests/cli/mod.rs`) continues to
  use `AMUX_SESSION` env var — still works, just lower priority than `--session`.
- No changes to layout engine, zoom state machine, or alert system.
