# Three-Level Zoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the three-level zoom model (Bird's Eye → Working View → Full Screen) with context-aware Ctrl-N navigation and smart pane resizing.

**Architecture:** Add a `focus zoom <pane>` CLI subcommand that handles all zoom-level logic. Store current level in a tmux environment variable (`FOCUS_LEVEL`). Level 1 uses a tmux key table for arrow navigation. Level 2 uses `tmux resize-pane` for smart resize. Level 3 uses tmux's native `resize-pane -Z`. Key bindings call the `focus` binary which reads state and takes the right action.

**Tech Stack:** Rust (CLI), tmux 3.2+ (rendering, state via environment variables)

**Design reference:** `docs/zoom-levels.md`

---

## Constants

```rust
pub const MIN_PANE_COLS: u16 = 120;
pub const MIN_PANE_ROWS: u16 = 24;
```

## State Tracking

Zoom level stored as tmux session environment variable:
- `FOCUS_LEVEL=1` — Bird's Eye
- `FOCUS_LEVEL=2` — Working View
- `FOCUS_LEVEL=3` — Full Screen
- Not set → treated as Level 2 (backward compat with existing sessions)

Active pane index derived from tmux (`#{pane_index}` of the active pane).

## File Structure

| File | Changes |
|------|---------|
| `src/tmux.rs` | Add `get_level`, `set_level`, `active_pane_index`, `resize_pane`, `smart_resize`, `restore_tiled` |
| `src/main.rs` | Add `Zoom { pane: usize }`, `ZoomIn`, `ZoomOut`, `BirdEye` subcommands + handlers |
| `src/config.rs` | Rewrite key bindings for three levels, update status bar |
| `src/lib.rs` | Add constants `MIN_PANE_COLS`, `MIN_PANE_ROWS` |
| `tests/focus_test.rs` | Add zoom level transition tests |

---

### Task 1: Add zoom level state functions to tmux.rs

**Files:**
- Modify: `src/tmux.rs`
- Modify: `src/lib.rs`

- [ ] **Step 1: Add constants to lib.rs**

```rust
// src/lib.rs
pub mod config;
pub mod state;
pub mod tmux;
pub mod util;

/// Minimum pane size for Working View (Level 2).
/// If the active pane is smaller than this, it gets enlarged.
pub const MIN_PANE_COLS: u16 = 120;
pub const MIN_PANE_ROWS: u16 = 24;
```

- [ ] **Step 2: Add state and resize functions to tmux.rs**

Add these functions to `src/tmux.rs`:

```rust
/// Get the current zoom level (1=Bird's Eye, 2=Working, 3=Full Screen).
/// Defaults to 2 if not set.
pub fn get_level(session: &str) -> Result<u8> {
    let output = Command::new("tmux")
        .args(["show-environment", "-t", session, "FOCUS_LEVEL"])
        .output()
        .context("failed to read FOCUS_LEVEL")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let level = stdout
        .trim()
        .strip_prefix("FOCUS_LEVEL=")
        .and_then(|v| v.parse().ok())
        .unwrap_or(2);
    Ok(level)
}

/// Set the current zoom level.
pub fn set_level(session: &str, level: u8) -> Result<()> {
    let output = Command::new("tmux")
        .args(["set-environment", "-t", session, "FOCUS_LEVEL", &level.to_string()])
        .output()
        .context("failed to set FOCUS_LEVEL")?;
    if !output.status.success() {
        bail!("failed to set FOCUS_LEVEL");
    }
    Ok(())
}

/// Get the active pane index.
pub fn active_pane_index(session: &str) -> Result<usize> {
    let output = Command::new("tmux")
        .args(["display-message", "-t", session, "-p", "#{pane_index}"])
        .output()
        .context("failed to get active pane index")?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().parse().unwrap_or(0))
}

/// Resize a specific pane to the given dimensions.
pub fn resize_pane(session: &str, pane_index: usize, cols: u16, rows: u16) -> Result<()> {
    let target = format!("{}:.{}", session, pane_index);
    let _ = Command::new("tmux")
        .args(["resize-pane", "-t", &target, "-x", &cols.to_string(), "-y", &rows.to_string()])
        .output();
    Ok(())
}

/// Smart resize: enlarge the active pane to at least min_cols x min_rows
/// if it's currently smaller. Other panes shrink to accommodate.
/// If already big enough, do nothing.
pub fn smart_resize(session: &str, pane_index: usize, min_cols: u16, min_rows: u16) -> Result<()> {
    let panes = list_panes(session)?;
    let active = panes.iter().find(|p| p.index == pane_index);

    if let Some(pane) = active {
        if pane.width >= min_cols && pane.height >= min_rows {
            // Already big enough — no resize needed
            return Ok(());
        }
        // Enlarge the active pane
        resize_pane(session, pane_index, min_cols, min_rows)?;
    }
    Ok(())
}

/// Restore tiled layout (equal sizes for all panes).
/// Used when going back to Level 1.
pub fn restore_tiled(session: &str) -> Result<()> {
    // Unzoom first if zoomed
    if is_zoomed(session)? {
        toggle_zoom(session)?;
    }
    apply_tiled_layout(session)?;
    Ok(())
}

/// Enter bird's eye mode: switch to a key table that captures arrows
/// for pane navigation and ignores other input.
pub fn enter_birdeye_table() -> Result<()> {
    let _ = Command::new("tmux")
        .args(["switch-client", "-T", "focus-birdeye"])
        .output();
    Ok(())
}
```

- [ ] **Step 3: Write unit tests**

Add to the `#[cfg(test)]` module in `src/tmux.rs`:

```rust
#[test]
fn get_set_level() {
    let name = test_session_name();
    cleanup(&name);
    create_session(&name).expect("create");

    // Default level is 2
    assert_eq!(get_level(&name).expect("get"), 2);

    set_level(&name, 1).expect("set");
    assert_eq!(get_level(&name).expect("get"), 1);

    set_level(&name, 3).expect("set");
    assert_eq!(get_level(&name).expect("get"), 3);

    cleanup(&name);
}

#[test]
fn active_pane_index_works() {
    let name = test_session_name();
    cleanup(&name);
    create_session(&name).expect("create");

    let idx = active_pane_index(&name).expect("get");
    assert_eq!(idx, 0);  // first pane is active

    create_pane(&name, None).expect("pane");
    let idx = active_pane_index(&name).expect("get");
    // After split, the new pane is active
    assert!(idx <= 1);

    cleanup(&name);
}

#[test]
fn smart_resize_no_change_when_big_enough() {
    let name = test_session_name();
    cleanup(&name);
    create_session(&name).expect("create");

    let panes_before = list_panes(&name).expect("list");
    let w_before = panes_before[0].width;
    let h_before = panes_before[0].height;

    // With 1 pane, it's already bigger than the minimum
    smart_resize(&name, 0, 120, 24).expect("resize");

    let panes_after = list_panes(&name).expect("list");
    // Size should be unchanged (or very close)
    assert!(panes_after[0].width >= w_before - 1);

    cleanup(&name);
}

#[test]
fn smart_resize_enlarges_small_pane() {
    let name = test_session_name();
    cleanup(&name);
    create_session(&name).expect("create");
    // Create enough panes to make them small
    for _ in 0..5 {
        create_pane(&name, None).expect("pane");
    }

    let panes_before = list_panes(&name).expect("list");
    // With 6 panes, each should be well under 120 cols

    // Smart resize pane 0
    select_pane(&name, 0).expect("select");
    smart_resize(&name, 0, 120, 24).expect("resize");

    let panes_after = list_panes(&name).expect("list");
    let active = panes_after.iter().find(|p| p.index == 0);
    if let Some(p) = active {
        // Should be at least close to the minimum
        // (tmux may not achieve exactly 120 due to other pane constraints)
        assert!(p.width > panes_before[0].width,
            "pane should be enlarged: before={}, after={}", panes_before[0].width, p.width);
    }

    cleanup(&name);
}

#[test]
fn restore_tiled_resets_layout() {
    let name = test_session_name();
    cleanup(&name);
    create_session(&name).expect("create");
    create_pane(&name, None).expect("pane");
    create_pane(&name, None).expect("pane");

    // Resize one pane to be different
    smart_resize(&name, 0, 120, 24).expect("resize");

    // Restore tiled — all panes should be roughly equal
    restore_tiled(&name).expect("restore");

    let panes = list_panes(&name).expect("list");
    let widths: Vec<u16> = panes.iter().map(|p| p.width).collect();
    // All widths should be within 2 of each other
    let max_w = widths.iter().max().unwrap();
    let min_w = widths.iter().min().unwrap();
    assert!(max_w - min_w <= 2, "panes should be roughly equal: {:?}", widths);

    cleanup(&name);
}
```

- [ ] **Step 4: Run tests**

Run: `cargo test --lib -- --test-threads=1 --nocapture`
Expected: All pass

- [ ] **Step 5: Commit**

```
feat: add zoom level state tracking and smart resize functions
```

---

### Task 2: Add zoom CLI subcommands

The `focus zoom <pane>` command implements the context-aware Ctrl-N logic.

**Files:**
- Modify: `src/main.rs`

- [ ] **Step 1: Add subcommands to Commands enum**

```rust
/// Context-aware zoom to pane N (handles level transitions)
Zoom {
    /// Pane index to zoom to
    pane: usize,
},
/// Zoom in one level (Ctrl-+)
ZoomIn,
/// Zoom out one level (Ctrl--)
ZoomOut,
/// Enter bird's eye mode explicitly
BirdEye,
```

- [ ] **Step 2: Add match arms in main()**

```rust
Some(Commands::Zoom { pane }) => cmd_zoom(pane),
Some(Commands::ZoomIn) => cmd_zoom_in(),
Some(Commands::ZoomOut) => cmd_zoom_out(),
Some(Commands::BirdEye) => cmd_birdeye(),
```

- [ ] **Step 3: Implement cmd_zoom**

```rust
/// Context-aware zoom: Ctrl-N behavior
fn cmd_zoom(target_pane: usize) -> Result<()> {
    let session = session_name();
    let level = tmux::get_level(&session)?;
    let current = tmux::active_pane_index(&session)?;
    let same_pane = current == target_pane;

    match (level, same_pane) {
        // L1 + any → select pane, go to L2
        (1, _) => {
            tmux::select_pane(&session, target_pane)?;
            tmux::smart_resize(&session, target_pane, focus::MIN_PANE_COLS, focus::MIN_PANE_ROWS)?;
            tmux::set_level(&session, 2)?;
        }
        // L2 + same pane → go to L3
        (2, true) => {
            tmux::toggle_zoom(&session)?;
            tmux::set_level(&session, 3)?;
        }
        // L2 + different pane → switch pane, stay L2
        (2, false) => {
            // Restore tiled first, then select and smart resize
            tmux::apply_tiled_layout(&session)?;
            tmux::select_pane(&session, target_pane)?;
            tmux::smart_resize(&session, target_pane, focus::MIN_PANE_COLS, focus::MIN_PANE_ROWS)?;
        }
        // L3 + same pane → stay L3
        (3, true) => {
            // Already here, do nothing
        }
        // L3 + different pane → unzoom, select pane, go to L2
        (3, false) => {
            tmux::toggle_zoom(&session)?; // unzoom
            tmux::select_pane(&session, target_pane)?;
            tmux::smart_resize(&session, target_pane, focus::MIN_PANE_COLS, focus::MIN_PANE_ROWS)?;
            tmux::set_level(&session, 2)?;
        }
        _ => {}
    }

    Ok(())
}
```

- [ ] **Step 4: Implement cmd_zoom_in**

```rust
/// Ctrl-+ : zoom in one level
fn cmd_zoom_in() -> Result<()> {
    let session = session_name();
    let level = tmux::get_level(&session)?;
    let current = tmux::active_pane_index(&session)?;

    match level {
        1 => {
            // L1 → L2: activate the highlighted pane
            tmux::smart_resize(&session, current, focus::MIN_PANE_COLS, focus::MIN_PANE_ROWS)?;
            tmux::set_level(&session, 2)?;
        }
        2 => {
            // L2 → L3: full screen
            tmux::toggle_zoom(&session)?;
            tmux::set_level(&session, 3)?;
        }
        3 => {
            // Already at L3, do nothing
        }
        _ => {}
    }

    Ok(())
}
```

- [ ] **Step 5: Implement cmd_zoom_out**

```rust
/// Ctrl-- : zoom out one level
fn cmd_zoom_out() -> Result<()> {
    let session = session_name();
    let level = tmux::get_level(&session)?;

    match level {
        1 => {
            // Already at L1, do nothing
        }
        2 => {
            // L2 → L1: restore tiled, enter bird's eye key table
            tmux::restore_tiled(&session)?;
            tmux::set_level(&session, 1)?;
            tmux::enter_birdeye_table()?;
        }
        3 => {
            // L3 → L2: unzoom, smart resize
            tmux::toggle_zoom(&session)?;
            let current = tmux::active_pane_index(&session)?;
            tmux::smart_resize(&session, current, focus::MIN_PANE_COLS, focus::MIN_PANE_ROWS)?;
            tmux::set_level(&session, 2)?;
        }
        _ => {}
    }

    Ok(())
}
```

- [ ] **Step 6: Implement cmd_birdeye**

```rust
/// Enter bird's eye mode explicitly
fn cmd_birdeye() -> Result<()> {
    let session = session_name();
    tmux::restore_tiled(&session)?;
    tmux::set_level(&session, 1)?;
    tmux::enter_birdeye_table()?;
    Ok(())
}
```

- [ ] **Step 7: Verify compilation**

Run: `cargo check`

- [ ] **Step 8: Commit**

```
feat: add zoom/zoom-in/zoom-out/birdeye CLI subcommands
```

---

### Task 3: Update key bindings for three-level zoom

Replace the current flat key bindings with ones that call the `focus` CLI for zoom logic.

**Files:**
- Modify: `src/config.rs`

- [ ] **Step 1: Rewrite apply_key_bindings**

Replace the entire `apply_key_bindings` function:

```rust
fn apply_key_bindings(_session: &str) -> Result<()> {
    let bin = "focus";

    // Verify the binary is on PATH
    let which = Command::new("which").arg(bin).output();
    if which.is_err() || !which.unwrap().status.success() {
        eprintln!("Warning: '{}' not found on PATH. Key bindings may not work.", bin);
        eprintln!("Run: cargo install --path .");
    }

    // === Zoom controls (call focus CLI for level-aware logic) ===

    // Ctrl-+ : zoom in one level
    tmux_bind_root("C-=",
        &format!(r#"run-shell "{} zoom-in""#, bin))?;

    // Ctrl-- : zoom out one level (also handles split exit)
    tmux_bind_root("C--",
        &format!(r#"run-shell "if [ $(tmux display-message -p '#{{window_index}}') -gt 0 ]; then {} split-exit; else {} zoom-out; fi""#, bin, bin))?;

    // Ctrl-1..9 : context-aware zoom to pane N
    for i in 1..=9 {
        tmux_bind_root(
            &format!("C-{}", i),
            &format!(r#"run-shell "{} zoom {}""#, bin, i - 1),
        )?;
    }

    // === Bird's Eye key table (Level 1) ===
    // Arrow keys navigate between panes and stay in bird's eye
    tmux_bind_table("focus-birdeye", "Left",
        r#"run-shell "tmux select-pane -L && tmux switch-client -T focus-birdeye""#)?;
    tmux_bind_table("focus-birdeye", "Right",
        r#"run-shell "tmux select-pane -R && tmux switch-client -T focus-birdeye""#)?;
    tmux_bind_table("focus-birdeye", "Up",
        r#"run-shell "tmux select-pane -U && tmux switch-client -T focus-birdeye""#)?;
    tmux_bind_table("focus-birdeye", "Down",
        r#"run-shell "tmux select-pane -D && tmux switch-client -T focus-birdeye""#)?;

    // Ctrl-+ in bird's eye → zoom in (go to L2)
    tmux_bind_table("focus-birdeye", "C-=",
        &format!(r#"run-shell "{} zoom-in""#, bin))?;

    // Ctrl-1..9 in bird's eye → zoom to pane N (go to L2)
    for i in 1..=9 {
        tmux_bind_table("focus-birdeye", &format!("C-{}", i),
            &format!(r#"run-shell "{} zoom {}""#, bin, i - 1))?;
    }

    // Ctrl-n in bird's eye → create new pane
    tmux_bind_table("focus-birdeye", "C-n",
        &format!(r#"run-shell "cd '#{{pane_current_path}}' && {} new""#, bin))?;

    // Any other key in bird's eye exits to L2 (the key is consumed)
    // tmux auto-exits the key table on unbound keys

    // === Pane lifecycle ===
    tmux_bind_root("C-n",
        &format!(r#"run-shell "cd '#{{pane_current_path}}' && {} new""#, bin))?;

    // === Split view ===
    tmux_bind_root("C-l",
        &format!(r#"run-shell "{} split-start""#, bin))?;

    tmux_bind_table("focus-split-pick", "C-Left", "select-pane -L")?;
    tmux_bind_table("focus-split-pick", "C-Right", "select-pane -R")?;
    tmux_bind_table("focus-split-pick", "C-Up", "select-pane -U")?;
    tmux_bind_table("focus-split-pick", "C-Down", "select-pane -D")?;
    tmux_bind_table("focus-split-pick", "Enter",
        &format!(r#"run-shell "{} split-pick $(tmux display-message -p '#{{pane_index}}')""#, bin))?;
    for i in 1..=9 {
        tmux_bind_table("focus-split-pick", &format!("C-{}", i),
            &format!(r#"run-shell "{} split-pick {}""#, bin, i - 1))?;
    }
    tmux_bind_table("focus-split-pick", "Escape",
        &format!(r#"run-shell "{} split-cancel""#, bin))?;

    Ok(())
}
```

- [ ] **Step 2: Update status bar for three levels**

Replace `apply_status_bar`:

```rust
fn apply_status_bar(session: &str) -> Result<()> {
    tmux_set(session, "status-style", "bg=colour235 fg=colour245")?;
    tmux_set(
        session,
        "status-left",
        "#[fg=colour43,bold] focus #[fg=colour238]│ ",
    )?;
    // Status right shows current zoom level
    // FOCUS_LEVEL env var: 1=bird's eye, 2=working, 3=full screen
    // Use nested conditionals to display the right mode
    tmux_set(
        session,
        "status-right",
        " #{?#{>:#{window_index},0},#[fg=cyan bold]SPLIT #[fg=colour238]C-- exit,#{?#{==:#{FOCUS_LEVEL},1},#[fg=colour81]BIRD'S EYE #[fg=colour238]arrows nav · C-1..9 focus · C-n new,#{?window_zoomed_flag,#[fg=yellow bold]FULL SCREEN #[fg=colour238]C-- working · C-1..9 switch,#[fg=colour245]WORKING #[fg=colour238]C-+ full · C-- bird's eye · C-1..9 focus}}} ",
    )?;
    tmux_set(session, "status-left-length", "20")?;
    tmux_set(session, "status-right-length", "70")?;

    Ok(())
}
```

Note: `#{FOCUS_LEVEL}` in tmux format strings reads from the session environment.

- [ ] **Step 3: Verify compilation**

Run: `cargo check`

- [ ] **Step 4: Commit**

```
feat: update key bindings and status bar for three-level zoom
```

---

### Task 4: Set initial zoom level on start and refresh

**Files:**
- Modify: `src/main.rs`

- [ ] **Step 1: Set Level 1 on start**

In `cmd_start`, before `tmux::attach`:

```rust
// Start in bird's eye mode
tmux::set_level(&session, 1)?;
```

- [ ] **Step 2: Handle level on refresh**

In `cmd_refresh`, after applying config, enter the bird's eye table if at Level 1:

```rust
// If at level 1, re-enter the bird's eye key table
let level = tmux::get_level(&session).unwrap_or(2);
if level == 1 {
    tmux::enter_birdeye_table()?;
}
```

- [ ] **Step 3: Verify compilation and run tests**

Run: `cargo test -- --test-threads=1 --nocapture`

- [ ] **Step 4: Commit**

```
feat: set initial zoom level on start, preserve level on refresh
```

---

### Task 5: Integration tests for zoom level transitions

**Files:**
- Modify: `tests/focus_test.rs`

- [ ] **Step 1: Add zoom level transition tests**

```rust
#[test]
fn zoom_level_starts_at_default() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    // Default level is 2 when not explicitly set
    let level = focus::tmux::get_level(&session).expect("get");
    assert_eq!(level, 2);
    cleanup(&session);
}

#[test]
fn zoom_level_transitions() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::tmux::create_pane(&session, None).expect("pane");

    // Set to L1
    focus::tmux::set_level(&session, 1).expect("set");
    assert_eq!(focus::tmux::get_level(&session).expect("get"), 1);

    // L1 → L2 via smart_resize
    focus::tmux::smart_resize(&session, 0, focus::MIN_PANE_COLS, focus::MIN_PANE_ROWS).expect("resize");
    focus::tmux::set_level(&session, 2).expect("set");
    assert_eq!(focus::tmux::get_level(&session).expect("get"), 2);

    // L2 → L3 via zoom
    focus::tmux::toggle_zoom(&session).expect("zoom");
    focus::tmux::set_level(&session, 3).expect("set");
    assert_eq!(focus::tmux::get_level(&session).expect("get"), 3);
    assert!(focus::tmux::is_zoomed(&session).expect("check"));

    // L3 → L2 via unzoom
    focus::tmux::toggle_zoom(&session).expect("unzoom");
    focus::tmux::set_level(&session, 2).expect("set");
    assert!(!focus::tmux::is_zoomed(&session).expect("check"));

    // L2 → L1 via restore_tiled
    focus::tmux::restore_tiled(&session).expect("restore");
    focus::tmux::set_level(&session, 1).expect("set");
    assert_eq!(focus::tmux::get_level(&session).expect("get"), 1);

    cleanup(&session);
}

#[test]
fn smart_resize_with_many_panes() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        focus::tmux::create_pane(&session, None).expect("pane");
    }

    // Select pane 0 and smart resize
    focus::tmux::select_pane(&session, 0).expect("select");
    focus::tmux::smart_resize(&session, 0, focus::MIN_PANE_COLS, focus::MIN_PANE_ROWS).expect("resize");

    // Verify pane 0 is at least close to minimum
    let panes = focus::tmux::list_panes(&session).expect("list");
    let p0 = panes.iter().find(|p| p.index == 0).expect("pane 0");
    // tmux may not achieve exact size due to constraints, but it should be bigger
    assert!(p0.width > 60, "pane 0 should be enlarged, got {}x{}", p0.width, p0.height);

    // Restore tiled — all should be equal again
    focus::tmux::restore_tiled(&session).expect("restore");
    let panes = focus::tmux::list_panes(&session).expect("list");
    let widths: Vec<u16> = panes.iter().map(|p| p.width).collect();
    let max_w = widths.iter().max().unwrap();
    let min_w = widths.iter().min().unwrap();
    assert!(max_w - min_w <= 2, "should be roughly equal after restore: {:?}", widths);

    cleanup(&session);
}

#[test]
fn restore_tiled_unzooms_first() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::tmux::create_pane(&session, None).expect("pane");

    // Zoom in
    focus::tmux::toggle_zoom(&session).expect("zoom");
    assert!(focus::tmux::is_zoomed(&session).expect("check"));

    // Restore tiled should unzoom first
    focus::tmux::restore_tiled(&session).expect("restore");
    assert!(!focus::tmux::is_zoomed(&session).expect("check"));

    cleanup(&session);
}
```

- [ ] **Step 2: Run all tests**

Run: `cargo test -- --test-threads=1 --nocapture`
Expected: All pass

- [ ] **Step 3: Commit**

```
test: add zoom level transition and smart resize tests
```

---

### Task 6: Build, install, and manual verification

- [ ] **Step 1: Build and install**

Run: `cargo install --path .`

- [ ] **Step 2: Refresh live session**

Run: `focus refresh`

- [ ] **Step 3: Test Level 1 (Bird's Eye)**

- Press Ctrl-- to zoom out to Level 1
- Status bar should show "BIRD'S EYE"
- Arrow keys should navigate between panes (change highlight)
- Typing should be ignored (no input goes to any pane)
- Press Ctrl-2 → should go to Level 2 on pane 2

- [ ] **Step 4: Test Level 2 (Working View)**

- Status bar should show "WORKING"
- Active pane receives keystrokes — type something
- If active pane was small, it should be enlarged
- Press Ctrl-3 → should switch to pane 3 (still Level 2)
- Press Ctrl-3 again (same pane) → should go to Level 3

- [ ] **Step 5: Test Level 3 (Full Screen)**

- One pane fills entire screen
- Status bar shows "FULL SCREEN"
- Ctrl-- → back to Level 2 (working view with smart resize)
- Ctrl-- again → back to Level 1 (bird's eye with arrow nav)

- [ ] **Step 6: Test rapid transitions**

- Ctrl-2 Ctrl-2 from L1 → should go to L3 on pane 2
- Ctrl-- Ctrl-- from L3 → should go to L1
- Ctrl-1 then Ctrl-3 at L2 → should switch panes
- Ctrl-1 then Ctrl-1 at L2 → should zoom to L3

- [ ] **Step 7: Commit any fixes**

```
fix: tune three-level zoom based on manual testing
```
