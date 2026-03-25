# Rename focus → amux Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the project from "focus" to "amux" across all code, config, tests, and docs — without renaming the parent directory (`~/src/focus` stays).

**Architecture:** Pure mechanical rename using `replace_all` edits. No logic changes. The rename covers: Cargo.toml package name, Rust identifiers (`FocusState` → `AmuxState`, `use focus::` → `use amux::`), string literals (env vars `FOCUS_*` → `AMUX_*`, tmux options `@focus-*` → `@amux-*`, key tables `focus-*` → `amux-*`), file paths (`~/.focus/` → `~/.amux/`), test session prefixes, binary name, and documentation.

**Tech Stack:** Rust, tmux

**Important constraints:**
- Do NOT rename the parent directory (`~/src/focus` stays as-is)
- Do NOT touch `focus:title` in tmux terminal-features string (line ~49 of config.rs) — that's a tmux capability flag, not our namespace
- Do NOT touch running tmux sessions — env vars and pane options with old names are harmless metadata
- The old `focus` binary stays on PATH alongside the new `amux` binary after install

---

## File Structure

All modifications, no new files (except renaming `tests/focus_test.rs` → `tests/amux_test.rs`).

| File | Action | What changes |
|------|--------|-------------|
| `Cargo.toml` | Modify | Package name, repository URL |
| `src/lib.rs` | No change | Module exports don't reference "focus" |
| `src/state.rs` | Modify | `FocusState` → `AmuxState`, `~/.focus` → `~/.amux` |
| `src/main.rs` | Modify | `use focus::` → `use amux::`, `FocusState` → `AmuxState`, `FOCUS_SESSION` → `AMUX_SESSION`, default session name, comments |
| `src/config.rs` | Modify | `let bin = "focus"` → `let bin = "amux"`, key table names, status bar branding, comments |
| `src/tmux.rs` | Modify | `FOCUS_LEVEL` → `AMUX_LEVEL`, `FOCUS_MANAGED` → `AMUX_MANAGED`, `FOCUS_PANE_COUNT` → `AMUX_PANE_COUNT`, `FOCUS_LAST_NOTIFY` → `AMUX_LAST_NOTIFY`, `@focus-title` → `@amux-title`, `@focus-alert` → `@amux-alert`, `@focus-alert-count` → `@amux-alert-count`, `focus-birdeye` → `amux-birdeye`, `focus-split-pick` → `amux-split-pick`, test session prefix, comments |
| `src/sticky.rs` | Modify | `@focus-cx` → `@amux-cx`, `@focus-cy` → `@amux-cy`, `@focus-pcx` → `@amux-pcx`, `@focus-pcy` → `@amux-pcy` |
| `src/notify.rs` | Modify | Any "focus"/"Focus" references in notification text (if present) |
| `src/alert.rs` | Modify | Any "focus" references (if present) |
| `src/util.rs` | No change | No "focus" references |
| `tests/focus_test.rs` | Rename → `tests/amux_test.rs` | `use focus::` → `use amux::`, `focus-integ-` → `amux-integ-`, `@focus-title` → `@amux-title` |
| `tests/sticky_test.rs` | Modify | `use focus::` → `use amux::` |
| `tests/alert_test.rs` | Modify | `use focus::` → `use amux::` (if exists) |
| `README.md` | Modify | Already mostly renamed by user — verify no remaining "focus" references |
| `docs/architecture.md` | Modify | Already partially updated by user — verify and fix remaining references |

---

### Task 1: Rename Cargo.toml and state.rs

**Files:**
- Modify: `Cargo.toml`
- Modify: `src/state.rs`

- [ ] **Step 1: Rename package in Cargo.toml**

```
name = "focus"  →  name = "amux"
```

Also update the repository URL if it references "focus".

- [ ] **Step 2: Rename FocusState → AmuxState in state.rs**

Use `replace_all` for these replacements in `src/state.rs`:
- `FocusState` → `AmuxState`
- `.focus` → `.amux` (in the path `home.join(".focus")`)

- [ ] **Step 3: Verify it compiles**

Run: `cargo check 2>&1`
Expected: errors in other files referencing `focus::` and `FocusState` — that's expected, we'll fix those next.

- [ ] **Step 4: Commit**

```bash
git add Cargo.toml src/state.rs
git commit -m "chore: rename package focus → amux, FocusState → AmuxState"
```

---

### Task 2: Rename main.rs references

**Files:**
- Modify: `src/main.rs`

- [ ] **Step 1: Replace all module imports and identifiers**

Use `replace_all` for each:
- `use focus::` → `use amux::` (covers config, state, tmux, util, alert, notify imports)
- `FocusState` → `AmuxState`
- `focus::state::` → `amux::state::` (if any fully-qualified paths)
- `focus::alert::` → `amux::alert::`
- `focus::notify::` → `amux::notify::`
- `focus::MIN_PANE_COLS` → `amux::MIN_PANE_COLS`
- `focus::MIN_PANE_ROWS` → `amux::MIN_PANE_ROWS`

- [ ] **Step 2: Replace string literals**

- `"FOCUS_SESSION"` → `"AMUX_SESSION"`
- `"FOCUS_SPLIT_FIRST"` → `"AMUX_SPLIT_FIRST"`
- Default session name: `"focus"` → `"amux"` (in the `unwrap_or_else` fallback — be careful to only change the session name string, not other occurrences)
- `"No focus session"` → `"No amux session"` (error messages)

- [ ] **Step 3: Update comments**

Replace "focus" with "amux" in comments where it refers to the project name (not the English word "focus").

- [ ] **Step 4: Verify it compiles**

Run: `cargo check 2>&1`

- [ ] **Step 5: Commit**

```bash
git add src/main.rs
git commit -m "chore: rename focus → amux in main.rs"
```

---

### Task 3: Rename config.rs references

**Files:**
- Modify: `src/config.rs`

- [ ] **Step 1: Replace binary name**

```rust
let bin = "focus";  →  let bin = "amux";
```

- [ ] **Step 2: Replace key table names**

Use `replace_all`:
- `"focus-birdeye"` → `"amux-birdeye"`
- `"focus-split-pick"` → `"amux-split-pick"`

- [ ] **Step 3: Replace tmux option references in format strings**

Use `replace_all`:
- `@focus-title` → `@amux-title`
- `@focus-alert` → `@amux-alert`
- `@focus-alert-count` → `@amux-alert-count`

**WARNING:** Do NOT change `focus:title` in the terminal-features string (line ~49). That's a tmux capability, not our namespace. The string is `xterm*:clipboard:ccolour:cstyle:focus:title:sync:extkeys` — leave it alone.

- [ ] **Step 4: Replace env var references in comments/format strings**

- `FOCUS_LEVEL` → `AMUX_LEVEL` (in status-right format string and comments)

- [ ] **Step 5: Update comments**

Replace "focus" with "amux" in comments referring to the project. E.g., `"Apply all focus tmux configuration"` → `"Apply all amux tmux configuration"`.

- [ ] **Step 6: Verify it compiles**

Run: `cargo check 2>&1`

- [ ] **Step 7: Commit**

```bash
git add src/config.rs
git commit -m "chore: rename focus → amux in config.rs"
```

---

### Task 4: Rename tmux.rs references

**Files:**
- Modify: `src/tmux.rs`

This file has the most string literal changes.

- [ ] **Step 1: Replace env var names**

Use `replace_all` for each:
- `"FOCUS_LEVEL"` → `"AMUX_LEVEL"`
- `"FOCUS_MANAGED"` → `"AMUX_MANAGED"`
- `"FOCUS_PANE_COUNT"` → `"AMUX_PANE_COUNT"`
- `"FOCUS_LAST_NOTIFY"` → `"AMUX_LAST_NOTIFY"`

- [ ] **Step 2: Replace tmux option names**

Use `replace_all`:
- `@focus-title` → `@amux-title`
- `@focus-alert-count` → `@amux-alert-count`
- `@focus-alert` → `@amux-alert` (do this AFTER alert-count to avoid partial match)

- [ ] **Step 3: Replace key table names**

Use `replace_all`:
- `"focus-birdeye"` → `"amux-birdeye"`
- `"focus-split-pick"` → `"amux-split-pick"`

- [ ] **Step 4: Replace test session prefix**

- `"focus-unit-"` → `"amux-unit-"`

- [ ] **Step 5: Update comments**

Replace "focus-managed" and other project-name references in comments.

- [ ] **Step 6: Verify it compiles**

Run: `cargo check 2>&1`

- [ ] **Step 7: Commit**

```bash
git add src/tmux.rs
git commit -m "chore: rename focus → amux in tmux.rs"
```

---

### Task 5: Rename sticky.rs references

**Files:**
- Modify: `src/sticky.rs`

- [ ] **Step 1: Replace tmux pane option names**

Use `replace_all`:
- `@focus-cx` → `@amux-cx`
- `@focus-cy` → `@amux-cy`
- `@focus-pcx` → `@amux-pcx`
- `@focus-pcy` → `@amux-pcy`

- [ ] **Step 2: Verify it compiles**

Run: `cargo check 2>&1`

- [ ] **Step 3: Commit**

```bash
git add src/sticky.rs
git commit -m "chore: rename focus → amux in sticky.rs"
```

---

### Task 6: Rename notify.rs and alert.rs references (if any)

**Files:**
- Modify: `src/notify.rs` (if it exists and has "focus" references)
- Modify: `src/alert.rs` (if it exists and has "focus" references)

- [ ] **Step 1: Check for and replace any "focus"/"Focus" references**

Search for "focus" (case-insensitive) in both files. Replace project-name references but not the English word.

- [ ] **Step 2: Verify it compiles**

Run: `cargo check 2>&1`

- [ ] **Step 3: Commit (if changes were made)**

```bash
git add src/notify.rs src/alert.rs
git commit -m "chore: rename focus → amux in notify.rs and alert.rs"
```

---

### Task 7: Rename test files

**Files:**
- Rename: `tests/focus_test.rs` → `tests/amux_test.rs`
- Modify: `tests/amux_test.rs` (after rename)
- Modify: `tests/sticky_test.rs`
- Modify: `tests/alert_test.rs` (if exists)

- [ ] **Step 1: Rename the integration test file**

```bash
git mv tests/focus_test.rs tests/amux_test.rs
```

- [ ] **Step 2: Replace references in tests/amux_test.rs**

Use `replace_all`:
- `use focus::` → `use amux::` (covers `focus::tmux::`, `focus::config::`, etc.)
- `focus::` → `amux::` (any remaining fully-qualified paths)
- `"focus-integ-"` → `"amux-integ-"`
- `@focus-title` → `@amux-title`
- `@focus-alert` → `@amux-alert` (if referenced)

- [ ] **Step 3: Replace references in tests/sticky_test.rs**

Use `replace_all`:
- `use focus::` → `use amux::`

- [ ] **Step 4: Replace references in tests/alert_test.rs (if exists)**

Use `replace_all`:
- `use focus::` → `use amux::`
- `focus::alert::` → `amux::alert::`

- [ ] **Step 5: Verify all tests compile and pass**

Run: `cargo test --test amux_test --test sticky_test 2>&1`
Expected: all tests PASS

- [ ] **Step 6: Commit**

```bash
git add tests/
git commit -m "chore: rename focus → amux in test files"
```

---

### Task 8: Verify docs and full build

**Files:**
- Modify: `README.md` (verify — user may have already updated)
- Modify: `docs/architecture.md` (verify — user may have already updated)

- [ ] **Step 1: Check README.md for remaining "focus" references**

Search for "focus" in README.md. The user has already partially renamed it. Fix any remaining references that refer to the project (not the English word or the tmux capability).

- [ ] **Step 2: Check docs/architecture.md for remaining "focus" references**

Same — search and fix. Pay attention to:
- `@focus-*` option names → `@amux-*`
- `FOCUS_*` env var names → `AMUX_*`
- `~/.focus/` → `~/.amux/`
- `focus-birdeye` → `amux-birdeye`
- `FocusState` → `AmuxState`

- [ ] **Step 3: Run full test suite**

Run: `cargo test 2>&1`
Expected: all tests PASS

- [ ] **Step 4: Build release binary**

Run: `cargo build --release 2>&1`
Expected: binary at `target/release/amux`

- [ ] **Step 5: Install**

Run: `cargo install --path . 2>&1`
Expected: installs `~/.cargo/bin/amux`

- [ ] **Step 6: Verify binary works**

Run: `amux --help 2>&1`
Expected: shows help with "amux" in the output

- [ ] **Step 7: Commit docs changes**

```bash
git add README.md docs/
git commit -m "docs: update remaining focus → amux references"
```

---

### Task 9: Migrate live tmux session (manual, after all code changes)

This task is done by the user, not by a subagent. It migrates the running tmux session.

- [ ] **Step 1: Kill stale test sessions**

```bash
tmux list-sessions -F '#{session_name}' | grep -E '^focus-(integ|attn|sizedbg|unit)' | xargs -I{} tmux kill-session -t {}
```

- [ ] **Step 2: Rename live session**

```bash
tmux rename-session -t focus amux
```

All panes, processes, and Claude Code sessions survive this — it's just a name change.

- [ ] **Step 3: Refresh config**

```bash
amux refresh
```

This applies new key bindings (calling `amux` binary), new status bar branding, and new pane option names in border format strings.

- [ ] **Step 4: Move state directory**

```bash
mv ~/.focus ~/.amux
```

- [ ] **Step 5: Verify**

- Key bindings work (`Ctrl-+`, `Ctrl--`, `Ctrl-n`)
- Status bar shows "amux"
- Pane borders display correctly
- `amux list` shows all panes
