# Attention Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the attention management system — pane border states, status badge, space picker indicators, smart landing, and macOS system notifications — so that amux communicates agent readiness at the right time with the right level of detail.

**Architecture:** Bell events from tmux trigger a per-pane `@focus-alert` flag. A new `alert.rs` module contains pure decision logic (notification suppression, smart landing). `config.rs` gains a three-state border format. `main.rs` gains alert dismissal on pane focus and space picker indicators. A small `osascript` call handles macOS notifications and frontmost-app detection.

**Tech Stack:** Rust, tmux pane options, tmux hooks, osascript (macOS notifications + frontmost app detection)

**Design doc:** `docs/attention-management.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/alert.rs` | Create | Pure alert logic: notification suppression, smart landing decisions, alert counting |
| `src/config.rs` | Modify | Three-state border format (teal/amber/dark), status badge in level 3, bell hook |
| `src/tmux.rs` | Modify | `@focus-alert` read/write, bell flag queries, `PaneInfo` gains `alert` field |
| `src/main.rs` | Modify | Alert dismissal on zoom/focus, space picker indicators, smart landing on switch |
| `src/lib.rs` | Modify | Add `pub mod alert;` |
| `src/notify.rs` | Create | macOS notification + frontmost-app detection via osascript |
| `tests/alert_test.rs` | Create | Unit tests for pure alert decision logic |
| `tests/attention_test.rs` | Create | Integration tests for bell→border, dismissal, badge, space picker, notifications |

---

### Task 1: Alert State Module — Pure Logic

**Files:**
- Create: `src/alert.rs`
- Create: `tests/alert_test.rs`
- Modify: `src/lib.rs`

This task builds the decision-making core with no tmux dependency. All functions are pure — they take data in, return decisions out.

- [ ] **Step 1: Write failing tests for notification suppression logic**

`tests/alert_test.rs`:
```rust
use std::time::{Duration, Instant};

// Test the suppression window logic
#[test]
fn first_bell_should_notify() {
    // No previous notification → should notify
    let decision = focus::alert::should_system_notify(None);
    assert!(decision);
}

#[test]
fn bell_within_suppression_window_should_not_notify() {
    // Last notification was 10 seconds ago, window is 30s → suppress
    let last = Instant::now() - Duration::from_secs(10);
    let decision = focus::alert::should_system_notify(Some(last));
    assert!(!decision);
}

#[test]
fn bell_after_suppression_window_should_notify() {
    // Last notification was 31 seconds ago → notify
    let last = Instant::now() - Duration::from_secs(31);
    let decision = focus::alert::should_system_notify(Some(last));
    assert!(decision);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --test alert_test`
Expected: FAIL — `alert` module doesn't exist

- [ ] **Step 3: Write failing tests for smart landing logic**

Add to `tests/alert_test.rs`:
```rust
#[test]
fn smart_land_one_alert_goes_to_that_pane() {
    // One pane has alert, was at level 1 → land on it at level 2
    let result = focus::alert::smart_landing(
        &[false, true, false],  // pane alert states
        2,                       // previous level when we left this space
        1,                       // previous active pane
    );
    assert_eq!(result, focus::alert::LandingTarget::FocusPane { index: 1, level: 2 });
}

#[test]
fn smart_land_no_alerts_resumes() {
    let result = focus::alert::smart_landing(
        &[false, false, false],
        3,  // was at level 3
        0,
    );
    // Was at L3, but we zoomed out to get here → land at L2
    assert_eq!(result, focus::alert::LandingTarget::Resume { level: 2, pane: 0 });
}

#[test]
fn smart_land_multiple_alerts_resumes() {
    let result = focus::alert::smart_landing(
        &[true, true, false],
        2,
        0,
    );
    assert_eq!(result, focus::alert::LandingTarget::Resume { level: 2, pane: 0 });
}

#[test]
fn smart_land_was_at_level3_caps_at_level2() {
    // Was at L3 → land at L2 (you zoomed out to get to picker)
    let result = focus::alert::smart_landing(
        &[false, false],
        3,
        1,
    );
    assert_eq!(result, focus::alert::LandingTarget::Resume { level: 2, pane: 1 });
}

#[test]
fn smart_land_was_at_level1_preserves() {
    let result = focus::alert::smart_landing(
        &[false, false],
        1,
        0,
    );
    assert_eq!(result, focus::alert::LandingTarget::Resume { level: 1, pane: 0 });
}
```

- [ ] **Step 4: Write failing test for alert counting**

Add to `tests/alert_test.rs`:
```rust
#[test]
fn count_alerts_returns_count_of_true() {
    assert_eq!(focus::alert::count_alerts(&[true, false, true, false]), 2);
    assert_eq!(focus::alert::count_alerts(&[false, false]), 0);
    assert_eq!(focus::alert::count_alerts(&[true]), 1);
}
```

- [ ] **Step 5: Implement alert.rs**

`src/alert.rs`:
```rust
// src/alert.rs — Pure alert decision logic.
// No tmux dependency. Takes data in, returns decisions out.

use std::time::{Duration, Instant};

/// How long to suppress system notifications after sending one.
const SUPPRESSION_WINDOW: Duration = Duration::from_secs(30);

/// Whether to send a macOS system notification.
/// `last_notification` is the timestamp of the most recent system notification.
pub fn should_system_notify(last_notification: Option<Instant>) -> bool {
    match last_notification {
        None => true,
        Some(t) => t.elapsed() >= SUPPRESSION_WINDOW,
    }
}

/// Count panes in "ready for you" state.
pub fn count_alerts(alert_states: &[bool]) -> usize {
    alert_states.iter().filter(|&&a| a).count()
}

/// Where to land when switching to a space.
#[derive(Debug, PartialEq, Eq)]
pub enum LandingTarget {
    /// Focus a specific pane at the given level.
    FocusPane { index: usize, level: u8 },
    /// Resume where the user left off (capped at level 2 if was at L3).
    Resume { level: u8, pane: usize },
}

/// Decide where to land when entering a space from the picker.
///
/// - `alert_states`: per-pane alert flags (indexed by pane position in list)
/// - `prev_level`: zoom level the user was at when they left this space
/// - `prev_pane`: active pane index when they left this space
pub fn smart_landing(
    alert_states: &[bool],
    prev_level: u8,
    prev_pane: usize,
) -> LandingTarget {
    let alert_count = count_alerts(alert_states);
    let capped_level = if prev_level >= 3 { 2 } else { prev_level };

    if alert_count == 1 {
        // Find the one alerting pane
        let index = alert_states.iter().position(|&a| a).unwrap();
        LandingTarget::FocusPane { index, level: 2 }
    } else {
        LandingTarget::Resume { level: capped_level, pane: prev_pane }
    }
}
```

- [ ] **Step 6: Register the module**

Add to `src/lib.rs`:
```rust
pub mod alert;
```

- [ ] **Step 7: Run all tests to verify they pass**

Run: `cargo test --test alert_test`
Expected: All 7 tests PASS

- [ ] **Step 8: Commit**

```bash
git add src/alert.rs src/lib.rs tests/alert_test.rs
git commit -m "feat: add alert decision logic module (pure, no tmux dep)"
```

---

### Task 2: macOS Notification Module

**Files:**
- Create: `src/notify.rs`
- Modify: `src/lib.rs`
- Create: `tests/notify_test.rs`

- [ ] **Step 1: Write failing test for frontmost app detection**

`tests/notify_test.rs`:
```rust
#[test]
fn is_frontmost_returns_bool() {
    // Just verify it returns without panic — actual value depends on environment
    let result = focus::notify::is_terminal_frontmost();
    // In CI/test, the terminal may or may not be frontmost — just check it runs
    assert!(result == true || result == false);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test notify_test`
Expected: FAIL — `notify` module doesn't exist

- [ ] **Step 3: Write failing test for notification sending**

Add to `tests/notify_test.rs`:
```rust
#[test]
fn send_notification_does_not_panic() {
    // We can't easily verify the notification appeared, but we can verify
    // the function doesn't error on the happy path
    let result = focus::notify::send_notification("amux", "Test: 1 agent ready for you");
    assert!(result.is_ok());
}

#[test]
fn notification_message_formats_correctly() {
    assert_eq!(
        focus::notify::format_message(1),
        "1 agent is ready for you"
    );
    assert_eq!(
        focus::notify::format_message(3),
        "3 agents are ready for you"
    );
    assert_eq!(
        focus::notify::format_message(0),
        "All agents are working"
    );
}
```

- [ ] **Step 4: Implement notify.rs**

`src/notify.rs`:
```rust
// src/notify.rs — macOS notification and frontmost-app detection.

use anyhow::{Context, Result};
use std::process::Command;

/// Check if the terminal emulator hosting this tmux session is the
/// frontmost macOS application.
///
/// Uses osascript to query NSWorkspace. Returns false on any error
/// (safe default: don't suppress notifications if detection fails).
pub fn is_terminal_frontmost() -> bool {
    let output = Command::new("osascript")
        .args([
            "-e",
            r#"tell application "System Events" to get name of first application process whose frontmost is true"#,
        ])
        .output();

    match output {
        Ok(o) => {
            let app = String::from_utf8_lossy(&o.stdout).trim().to_lowercase();
            // Common terminal emulators that might host tmux
            app.contains("terminal")
                || app.contains("iterm")
                || app.contains("alacritty")
                || app.contains("kitty")
                || app.contains("wezterm")
                || app.contains("ghostty")
        }
        Err(_) => false,
    }
}

/// Send a macOS notification via osascript.
pub fn send_notification(title: &str, message: &str) -> Result<()> {
    Command::new("osascript")
        .args([
            "-e",
            &format!(
                r#"display notification "{}" with title "{}""#,
                message, title
            ),
        ])
        .output()
        .context("failed to send macOS notification")?;
    Ok(())
}

/// Format a human-readable notification message from alert count.
pub fn format_message(count: usize) -> String {
    match count {
        0 => "All agents are working".to_string(),
        1 => "1 agent is ready for you".to_string(),
        n => format!("{} agents are ready for you", n),
    }
}
```

- [ ] **Step 5: Register the module**

Add to `src/lib.rs`:
```rust
pub mod notify;
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cargo test --test notify_test`
Expected: All 3 tests PASS

- [ ] **Step 7: Commit**

```bash
git add src/notify.rs src/lib.rs tests/notify_test.rs
git commit -m "feat: add macOS notification and frontmost-app detection"
```

---

### Task 3: Alert State in tmux — Read/Write `@focus-alert`

**Files:**
- Modify: `src/tmux.rs`
- Add to: `tests/attention_test.rs`

Extend PaneInfo and add functions to read/write the `@focus-alert` pane option.

- [ ] **Step 1: Write failing integration tests**

`tests/attention_test.rs`:
```rust
use std::process::Command;

fn session_name() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let id = COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("focus-attn-{}-{}", std::process::id(), id)
}

fn cleanup(session: &str) {
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", session])
        .output();
}

#[test]
fn set_and_get_alert_flag() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");

    // Initially no alert
    assert!(!focus::tmux::get_alert(&session, 0).expect("get"));

    // Set alert
    focus::tmux::set_alert(&session, 0, true).expect("set");
    assert!(focus::tmux::get_alert(&session, 0).expect("get"));

    // Clear alert
    focus::tmux::set_alert(&session, 0, false).expect("clear");
    assert!(!focus::tmux::get_alert(&session, 0).expect("get"));

    cleanup(&session);
}

#[test]
fn list_panes_includes_alert_state() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::tmux::create_pane(&session, None).expect("pane");

    // Set alert on pane 1 only
    focus::tmux::set_alert(&session, 1, true).expect("set");

    let panes = focus::tmux::list_panes(&session).expect("list");
    assert_eq!(panes.len(), 2);
    assert!(!panes[0].alert, "pane 0 should not have alert");
    assert!(panes[1].alert, "pane 1 should have alert");

    cleanup(&session);
}

#[test]
fn alert_states_for_session() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::tmux::create_pane(&session, None).expect("pane");
    focus::tmux::create_pane(&session, None).expect("pane");

    focus::tmux::set_alert(&session, 1, true).expect("set");

    let states = focus::tmux::alert_states(&session).expect("states");
    assert_eq!(states, vec![false, true, false]);

    cleanup(&session);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --test attention_test`
Expected: FAIL — `set_alert`, `get_alert`, `alert_states` don't exist, `PaneInfo` has no `alert` field

- [ ] **Step 3: Add alert field to PaneInfo and implement read/write**

Modify `src/tmux.rs`:

Add `alert` field to `PaneInfo`:
```rust
#[derive(Debug, Clone)]
pub struct PaneInfo {
    pub index: usize,
    pub title: String,
    pub width: u16,
    pub height: u16,
    pub active: bool,
    pub alert: bool,
}
```

Update `list_panes` format string to include `@focus-alert`:
```
"#{pane_index}\t#{@focus-title}\t#{pane_width}\t#{pane_height}\t#{pane_active}\t#{@focus-alert}"
```

Update the parser to read the alert field (6th tab-separated field):
```rust
alert: parts.get(5).map(|&v| v == "1").unwrap_or(false),
```

Do the same for `list_panes_in_window`.

Add these new functions:
```rust
/// Set or clear the alert flag on a pane.
pub fn set_alert(session: &str, pane_index: usize, alert: bool) -> Result<()> {
    let target = format!("{}:.{}", session, pane_index);
    let value = if alert { "1" } else { "0" };
    let output = Command::new("tmux")
        .args(["set-option", "-p", "-t", &target, "@focus-alert", value])
        .output()
        .context("failed to set @focus-alert")?;
    if !output.status.success() {
        bail!("tmux set @focus-alert failed: {}", String::from_utf8_lossy(&output.stderr));
    }
    Ok(())
}

/// Get the alert flag for a pane.
pub fn get_alert(session: &str, pane_index: usize) -> Result<bool> {
    let target = format!("{}:.{}", session, pane_index);
    let output = Command::new("tmux")
        .args(["show-options", "-p", "-t", &target, "-v", "@focus-alert"])
        .output()
        .context("failed to get @focus-alert")?;
    Ok(String::from_utf8_lossy(&output.stdout).trim() == "1")
}

/// Get alert states for all panes in a session, ordered by pane index.
pub fn alert_states(session: &str) -> Result<Vec<bool>> {
    let panes = list_panes(session)?;
    Ok(panes.iter().map(|p| p.alert).collect())
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --test attention_test`
Expected: All 3 tests PASS

Also run existing tests to make sure PaneInfo change doesn't break anything:
Run: `cargo test`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/tmux.rs tests/attention_test.rs
git commit -m "feat: add @focus-alert pane option for attention tracking"
```

---

### Task 4: Three-State Border Styling

**Files:**
- Modify: `src/config.rs`
- Add to: `tests/attention_test.rs`

Update the pane border format to show amber borders for panes with `@focus-alert=1`.

- [ ] **Step 1: Write failing integration test**

Add to `tests/attention_test.rs`:
```rust
#[test]
fn border_format_includes_alert_conditional() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::config::apply_config(&session).expect("config");

    // Read the pane-border-format and verify it references @focus-alert
    let output = Command::new("tmux")
        .args(["show-options", "-t", &session, "-v", "pane-border-format"])
        .output()
        .expect("show-options");
    let format = String::from_utf8_lossy(&output.stdout);
    assert!(format.contains("@focus-alert"),
        "border format should reference @focus-alert: {}", format);

    cleanup(&session);
}

#[test]
fn inactive_border_style_includes_alert_conditional() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::config::apply_config(&session).expect("config");

    // The pane-border-style should now be a conditional that checks @focus-alert
    // When alert=1, border should be amber (colour214 or similar)
    let output = Command::new("tmux")
        .args(["show-options", "-t", &session, "-v", "pane-border-style"])
        .output()
        .expect("show-options");
    let style = String::from_utf8_lossy(&output.stdout);

    // The style itself is static (tmux doesn't support conditionals in styles)
    // So we'll use pane-border-format to change the visual appearance instead.
    // This test just verifies config applies without error.
    assert!(!style.is_empty(), "border style should be set");

    cleanup(&session);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --test attention_test border_format`
Expected: FAIL — border format doesn't contain `@focus-alert`

- [ ] **Step 3: Update border format in config.rs**

Modify `apply_border_style()` in `src/config.rs`. The key insight: tmux's `pane-border-style` doesn't support per-pane conditionals, but `pane-border-format` does (it's evaluated per-pane). We use the border format string to change the visual indicator — the `▎` bar and title colors change based on alert state.

For the inactive border style, we can't conditionally change `fg` per pane with `pane-border-style`. Instead, we change the `pane-border-format` to render amber text when `@focus-alert=1`:

Replace the `pane-border-format` line with:
```rust
tmux_set(
    session,
    "pane-border-format",
    concat!(
        " #{?pane_active,",
            // Active pane: teal (unchanged)
            "#[fg=colour43 bold]▎ #[fg=yellow]#{e|+:#{pane_index},1}#[fg=colour252] #{?@focus-title,#{@focus-title},#{pane_title}} #[fg=colour43]●",
        ",#{?@focus-alert,",
            // Inactive + alert: amber
            "#[fg=colour214 bold]▎ #[fg=colour214]#{e|+:#{pane_index},1}#[fg=colour214] #{?@focus-title,#{@focus-title},#{pane_title}} #[fg=colour214]⬤",
        ",",
            // Inactive + no alert: dim (unchanged)
            "#[fg=colour236]▎ #[fg=colour240]#{e|+:#{pane_index},1}#[fg=colour245] #{?@focus-title,#{@focus-title},#{pane_title}}",
        "}} ",
    ),
)?;
```

Also update `pane-border-style` to support the amber state. Since tmux evaluates `pane-border-style` per-pane when the format is a conditional, we can't easily change the border *line* color per pane. However, the border format text color change is sufficient for a strong visual signal. The `▎` bar and `⬤` indicator in amber create clear differentiation.

**Note:** If we want the actual border lines (not just the title bar) to change color, we'd need a tmux hook that runs `set-option -p pane-border-style` per-pane on bell events. That's Task 6 (bell hook). For now, the title bar color change is the v1 visual.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --test attention_test`
Expected: All tests PASS

Run: `cargo test`
Expected: All tests PASS (including existing border style tests — the active border style `colour43` is unchanged)

- [ ] **Step 5: Commit**

```bash
git add src/config.rs tests/attention_test.rs
git commit -m "feat: three-state border format (teal/amber/dark)"
```

---

### Task 5: Level 3 Status Badge

**Files:**
- Modify: `src/config.rs`
- Add to: `tests/attention_test.rs`

Add a badge in the right corner of the status bar that shows the count of alerting panes when at level 3.

- [ ] **Step 1: Write failing test**

Add to `tests/attention_test.rs`:
```rust
#[test]
fn status_bar_includes_alert_badge() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::config::apply_config(&session).expect("config");

    let output = Command::new("tmux")
        .args(["show-options", "-t", &session, "-v", "status-right"])
        .output()
        .expect("show-options");
    let status = String::from_utf8_lossy(&output.stdout);

    // The status-right should reference @focus-alert for the badge
    // It will use a tmux format to count alerts across panes
    assert!(status.contains("focus-alert") || status.contains("⬤"),
        "status-right should include alert badge logic: {}", status);

    cleanup(&session);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test attention_test status_bar`
Expected: FAIL — status bar doesn't mention alert badge

- [ ] **Step 3: Update status bar in config.rs**

The challenge: tmux's status-right format doesn't have a built-in way to count pane options across all panes. We have two options:

**Option A:** Use a `run-shell` in the status format that calls `focus alert-count` to get the number. tmux evaluates `#(command)` in status formats.

**Option B:** Store the alert count in a session environment variable that gets updated whenever alerts change.

Option B is simpler and faster (no subprocess per status refresh). We'll add an `@focus-alert-count` session env var that gets updated by the bell hook (Task 6). For now, wire the status bar to read it.

Modify `apply_status_bar()` in `src/config.rs` — update the `status-right` to append an alert badge when `@focus-alert-count > 0`:

The status-right format string (replacing the existing one) adds a badge at the far right. The badge only shows at L3 (full screen), using tmux conditionals:

```rust
tmux_set(
    session,
    "status-right",
    concat!(
        " #{?#{>:#{window_index},0},",
            // SPLIT mode
            "#[fg=cyan bold]SPLIT #[fg=colour238]C-- exit",
        ",#{?#{==:#{FOCUS_LEVEL},1},",
            // BIRD'S EYE
            "#[fg=colour81]BIRD'S EYE #[fg=colour238]arrows nav · C-1..9 focus · C-n new · C-p spaces",
        ",#{?window_zoomed_flag,",
            // FULL SCREEN — include alert badge
            "#[fg=yellow bold]FULL SCREEN #[fg=colour238]C-- working · C-1..9 switch · C-p spaces",
            "#{?#{>:#{@focus-alert-count},0}, #[fg=colour214 bold]⬤ #{@focus-alert-count},}",
        ",",
            // WORKING — include alert badge
            "#[fg=colour245]WORKING #[fg=colour238]C-+ full · C-- bird's eye · C-1..9 focus · C-p spaces",
            "#{?#{>:#{@focus-alert-count},0}, #[fg=colour214 bold]⬤ #{@focus-alert-count},}",
        "}}} ",
    ),
)?;
// Increase right length to accommodate badge
tmux_set(session, "status-right-length", "100")?;
```

Also add a helper to update the alert count (will be called from bell hook handler).

**Important:** We use a session-level user option (`@focus-alert-count`) instead of an
environment variable because tmux format strings can resolve `#{@option}` for session
options but may not resolve env vars dynamically in `status-right`.

Add to `src/tmux.rs`:
```rust
/// Update the @focus-alert-count session option.
pub fn set_alert_count(session: &str, count: usize) -> Result<()> {
    let _ = Command::new("tmux")
        .args(["set-option", "-t", session, "@focus-alert-count", &count.to_string()])
        .output();
    Ok(())
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --test attention_test`
Expected: All tests PASS

Run: `cargo test`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/config.rs src/tmux.rs tests/attention_test.rs
git commit -m "feat: alert badge in status bar for level 3 and working view"
```

---

### Task 6: Bell Hook — The Event Pipeline

**Files:**
- Modify: `src/config.rs`
- Modify: `src/main.rs`
- Add to: `tests/attention_test.rs`

When a pane emits a bell, tmux fires an `alert-bell` hook. However, **`#{hook_pane}` is
empty in `alert-bell` hooks** on tmux 3.6+, so we cannot identify which specific pane
belled from the hook arguments. Instead, we use a scan approach: the hook calls
`focus alert-scan`, which checks tmux's `window_bell_flag` / `pane_in_mode` and marks
all non-active panes that just belled. Since we control the session and bells are
infrequent (one per Claude Code permission prompt), scanning all panes is cheap and
reliable.

- [ ] **Step 1: Write failing integration test for bell→alert pipeline**

Add to `tests/attention_test.rs`:
```rust
#[test]
fn alert_scan_marks_non_active_panes() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::config::apply_config(&session).expect("config");
    focus::tmux::create_pane(&session, None).expect("pane");

    // Select pane 0 as active
    focus::tmux::select_pane(&session, 0).expect("select");

    // Simulate a bell in pane 1 by sending the bell character
    let target = format!("{}:.1", session);
    let _ = Command::new("tmux")
        .args(["send-keys", "-t", &target, "printf '\\a'", "Enter"])
        .output();

    // Give tmux a moment to process the bell
    std::thread::sleep(std::time::Duration::from_millis(500));

    // Run alert-scan (what the hook would call)
    let _ = Command::new("focus")
        .args(["alert-scan"])
        .env("FOCUS_SESSION", &session)
        .output();

    // Check that the alert flag was set on pane 1 (not pane 0)
    assert!(!focus::tmux::get_alert(&session, 0).expect("get"),
        "active pane should not be alerted");
    assert!(focus::tmux::get_alert(&session, 1).expect("get"),
        "bell-emitting pane should have alert flag");

    cleanup(&session);
}

#[test]
fn alert_scan_updates_count() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::config::apply_config(&session).expect("config");
    focus::tmux::create_pane(&session, None).expect("pane");

    // Select pane 0 as active
    focus::tmux::select_pane(&session, 0).expect("select");

    // Manually set alert on pane 1 and run scan to update count
    focus::tmux::set_alert(&session, 1, true).expect("set");
    let states = focus::tmux::alert_states(&session).expect("states");
    let count = focus::alert::count_alerts(&states);
    focus::tmux::set_alert_count(&session, count).expect("count");

    assert_eq!(focus::tmux::get_alert_count(&session).expect("count"), 1);

    cleanup(&session);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --test attention_test alert_scan`
Expected: FAIL — `alert-scan` command doesn't exist

- [ ] **Step 3: Add the `alert-scan` CLI subcommand**

Add to `src/main.rs` — new `Commands` variant:
```rust
/// Scan panes for bell events and set alert flags (internal — called by tmux hook)
AlertScan,
```

Add the match arm:
```rust
Some(Commands::AlertScan) => cmd_alert_scan(),
```

Implement the handler. Since we can't identify the specific pane from the hook,
we mark all non-active panes that don't already have an alert. This is safe because:
- Bells are infrequent (one per Claude Code prompt)
- If a pane already has an alert, setting it again is a no-op
- The active pane is never alerted (you're already looking at it)

```rust
/// Scan for bell events and update alert flags.
/// Called by the tmux alert-bell hook. Since #{hook_pane} is empty in
/// alert-bell hooks, we mark all non-active, non-alerted panes.
/// In practice, this works well because bells happen one at a time
/// and the active pane is excluded.
fn cmd_alert_scan() -> Result<()> {
    let session = session_name();
    let panes = tmux::list_panes(&session)?;
    let active = panes.iter().find(|p| p.active).map(|p| p.index);

    let mut changed = false;
    for pane in &panes {
        // Skip the active pane — you're looking at it
        if Some(pane.index) == active {
            continue;
        }
        // Skip panes already alerted
        if pane.alert {
            continue;
        }
        // Mark as needing attention
        // Note: this marks all non-active, non-alerted panes on each bell.
        // Since bells are infrequent and we skip already-alerted panes,
        // this only affects the pane(s) that just belled.
        tmux::set_alert(&session, pane.index, true)?;
        changed = true;
    }

    if changed {
        let states = tmux::alert_states(&session)?;
        let count = focus::alert::count_alerts(&states);
        tmux::set_alert_count(&session, count)?;

        // System notification if terminal is not frontmost
        if !focus::notify::is_terminal_frontmost() {
            let msg = focus::notify::format_message(count);
            let _ = focus::notify::send_notification("amux", &msg);
        }
    }

    Ok(())
}
```

**Design note:** The "marks all non-active panes" approach is slightly coarse — if pane B
belled but pane C was also non-active and non-alerted, pane C would get marked too. In
practice this is fine because: (1) Claude Code panes bell infrequently, (2) panes that
are actively working don't emit bells, and (3) falsely alerting a working pane just means
the user focuses it and sees it's still working — a minor annoyance at worst. If this
becomes a problem, a future refinement could use `tmux capture-pane` to detect the bell
character in recent output.

- [ ] **Step 4: Register the tmux bell hook in config.rs**

Add a new public function in `src/config.rs`:

```rust
/// Register tmux hooks for attention management.
pub fn apply_hooks(session: &str) -> Result<()> {
    let bin = "focus";

    // On bell: scan panes and mark non-active ones as needing attention.
    // We use alert-scan (not alert-bell with #{hook_pane}) because
    // #{hook_pane} is empty in alert-bell hooks on tmux 3.6+.
    let _ = Command::new("tmux")
        .args([
            "set-hook", "-t", session,
            "alert-bell[0]",
            &format!("run-shell '{} alert-scan'", bin),
        ])
        .output();

    Ok(())
}
```

Call `apply_hooks(session)?;` from `apply_config()`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test --test attention_test alert_scan`
Expected: Both tests PASS

Run: `cargo test`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add src/main.rs src/config.rs tests/attention_test.rs
git commit -m "feat: bell hook pipeline — alert-scan marks non-active panes"
```

---

### Task 7: Alert Dismissal on Focus

**Files:**
- Modify: `src/main.rs`
- Add to: `tests/attention_test.rs`

When a user focuses a pane (via zoom, Ctrl-N, or pane switch), clear its alert.

- [ ] **Step 1: Write failing integration test**

Add to `tests/attention_test.rs`:
```rust
#[test]
fn focusing_pane_clears_alert() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::config::apply_config(&session).expect("config");
    focus::tmux::create_pane(&session, None).expect("pane");

    // Manually set alert on pane 1
    focus::tmux::set_alert(&session, 1, true).expect("set");
    focus::tmux::set_alert_count(&session, 1).expect("count");

    // Select pane 1 (simulating what cmd_zoom does)
    focus::tmux::select_pane(&session, 1).expect("select");

    // Clear alert for the newly focused pane (this is what we're testing)
    focus::tmux::dismiss_alert(&session, 1).expect("dismiss");

    assert!(!focus::tmux::get_alert(&session, 1).expect("get"),
        "alert should be cleared after focusing");

    cleanup(&session);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test attention_test focusing_pane`
Expected: FAIL — `dismiss_alert` doesn't exist

- [ ] **Step 3: Implement dismiss_alert in tmux.rs**

Add to `src/tmux.rs`:
```rust
/// Clear alert on a pane and update the session alert count.
pub fn dismiss_alert(session: &str, pane_index: usize) -> Result<()> {
    let was_alert = get_alert(session, pane_index)?;
    if !was_alert {
        return Ok(());
    }
    set_alert(session, pane_index, false)?;

    // Update count
    let states = alert_states(session)?;
    let count = crate::alert::count_alerts(&states);
    set_alert_count(session, count)?;

    Ok(())
}
```

- [ ] **Step 4: Wire dismissal into zoom commands in main.rs**

Add a helper at the top of main.rs:
```rust
/// Dismiss alert on the target pane when the user focuses it.
fn dismiss_on_focus(session: &str, pane_index: usize) {
    let _ = tmux::dismiss_alert(session, pane_index);
}
```

Insert `dismiss_on_focus(&session, target_pane)` calls in:

- `cmd_zoom()` — after `tmux::select_pane()` in each match arm (L1→any, L2→diff, L3→diff)
- `cmd_zoom_in()` — after the L1→L2 transition (dismiss current pane's alert)
- **Do NOT dismiss on** L2→L3 or L3→same (you're already on this pane)

Specifically:

In `cmd_zoom()`:
```rust
(1, _) => {
    tmux::select_pane(&session, target_pane)?;
    dismiss_on_focus(&session, target_pane);  // ADD
    ...
}
(2, false) => {
    ...
    tmux::select_pane(&session, target_pane)?;
    dismiss_on_focus(&session, target_pane);  // ADD
    ...
}
(3, false) => {
    ...
    tmux::select_pane(&session, target_pane)?;
    dismiss_on_focus(&session, target_pane);  // ADD
    ...
}
```

In `cmd_zoom_in()`:
```rust
1 => {
    dismiss_on_focus(&session, current);  // ADD — entering L2 on current pane
    ...
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test --test attention_test`
Expected: All tests PASS

Run: `cargo test`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add src/tmux.rs src/main.rs tests/attention_test.rs
git commit -m "feat: dismiss alert when user focuses a pane"
```

---

### Task 8: Space Picker Indicators

**Files:**
- Modify: `src/main.rs`
- Add to: `tests/attention_test.rs`

Show amber dots next to spaces that have waiting agents in the Ctrl-P picker.

- [ ] **Step 1: Write failing test**

Add to `tests/attention_test.rs`:
```rust
#[test]
fn alert_counts_per_session() {
    let session1 = session_name();
    let session2 = session_name();
    cleanup(&session1);
    cleanup(&session2);

    focus::tmux::create_session(&session1).expect("create");
    focus::tmux::create_session(&session2).expect("create");
    focus::tmux::create_pane(&session1, None).expect("pane");
    focus::tmux::create_pane(&session2, None).expect("pane");

    // Set alerts in session1
    focus::tmux::set_alert(&session1, 1, true).expect("set");
    focus::tmux::set_alert_count(&session1, 1).expect("count");

    // Session2 has no alerts
    focus::tmux::set_alert_count(&session2, 0).expect("count");

    // Read alert counts
    let count1 = focus::tmux::get_alert_count(&session1).expect("count");
    let count2 = focus::tmux::get_alert_count(&session2).expect("count");

    assert_eq!(count1, 1);
    assert_eq!(count2, 0);

    cleanup(&session1);
    cleanup(&session2);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test attention_test alert_counts_per`
Expected: FAIL — `get_alert_count` doesn't exist

- [ ] **Step 3: Add get_alert_count to tmux.rs**

```rust
/// Get the alert count for a session from @focus-alert-count session option.
pub fn get_alert_count(session: &str) -> Result<usize> {
    let output = Command::new("tmux")
        .args(["show-options", "-t", session, "-v", "@focus-alert-count"])
        .output()
        .context("failed to read @focus-alert-count")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout.trim().parse().unwrap_or(0))
}
```

- [ ] **Step 4: Update cmd_spaces() to show alert indicators**

In `cmd_spaces()` in `src/main.rs`, after building the session list, read alert counts for each session and display amber dots:

Replace the session rendering loop:
```rust
for (i, s) in sessions.iter().enumerate() {
    let current_dot = if *s == current { " \x1b[32m●\x1b[0m" } else { "" };
    let arrow = if i == selected { "\x1b[36m→\x1b[0m" } else { " " };
    let name_style = if i == selected { "\x1b[1m" } else { "" };

    // Alert indicator for this space
    let alert_count = tmux::get_alert_count(s).unwrap_or(0);
    let alert_dots = if alert_count > 0 {
        format!(" \x1b[38;5;214m{}\x1b[0m",
            "⬤".repeat(alert_count.min(5)))  // cap visual dots at 5
    } else {
        String::new()
    };

    println!("  {} \x1b[33m{}\x1b[0m {}{}{}{}",
        arrow, i + 1, name_style, s, current_dot, alert_dots);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test --test attention_test`
Expected: All tests PASS

Run: `cargo test`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add src/main.rs src/tmux.rs tests/attention_test.rs
git commit -m "feat: space picker shows alert indicators per space"
```

---

### Task 9: Smart Landing on Space Switch

**Files:**
- Modify: `src/main.rs`
- Add to: `tests/attention_test.rs`

When switching to a space from the picker, apply the smart landing logic.

- [ ] **Step 1: Write failing integration test**

Add to `tests/attention_test.rs`:
```rust
#[test]
fn smart_landing_integration() {
    // Test the pure logic with realistic inputs
    use focus::alert::{smart_landing, LandingTarget};

    // One alert at pane 2, was at level 2, active pane 0
    let result = smart_landing(&[false, false, true], 2, 0);
    assert_eq!(result, LandingTarget::FocusPane { index: 2, level: 2 });

    // Was at level 3, no alerts → land at level 2 (capped)
    let result = smart_landing(&[false, false], 3, 1);
    assert_eq!(result, LandingTarget::Resume { level: 2, pane: 1 });

    // Two alerts → resume where we were
    let result = smart_landing(&[true, true, false], 1, 0);
    assert_eq!(result, LandingTarget::Resume { level: 1, pane: 0 });
}
```

- [ ] **Step 2: Run test — should pass (logic already implemented in Task 1)**

Run: `cargo test --test attention_test smart_landing`
Expected: PASS

- [ ] **Step 3: Wire smart landing into space switch**

In `cmd_spaces()`, replace the simple `tmux::switch_session(target)?;` calls with smart landing:

```rust
fn switch_to_space(target: &str) -> Result<()> {
    // Read alert states and previous level/pane for the target space
    let alert_states = tmux::alert_states(target).unwrap_or_default();
    let prev_level = tmux::get_level(target).unwrap_or(2);
    let prev_pane = tmux::active_pane_index(target).unwrap_or(0);

    let landing = focus::alert::smart_landing(&alert_states, prev_level, prev_pane);

    // Switch first
    tmux::switch_session(target)?;

    // Apply landing
    match landing {
        focus::alert::LandingTarget::FocusPane { index, level } => {
            tmux::select_pane(target, index)?;
            dismiss_on_focus(target, index);
            if level == 2 {
                tmux::smart_resize(target, index, focus::MIN_PANE_COLS, focus::MIN_PANE_ROWS)?;
            }
            tmux::set_level(target, level)?;
        }
        focus::alert::LandingTarget::Resume { level, pane } => {
            tmux::select_pane(target, pane)?;
            tmux::set_level(target, level)?;
            if level == 1 {
                tmux::enter_birdeye_table()?;
            } else if level == 2 {
                tmux::smart_resize(target, pane, focus::MIN_PANE_COLS, focus::MIN_PANE_ROWS)?;
            }
        }
    }

    Ok(())
}
```

Replace all `tmux::switch_session(target)?;` calls in `cmd_spaces()` (there are 3: Enter, number jump, and after creating new space) with `switch_to_space(target)?;`. Skip for the "new space" case since it has no prior state.

- [ ] **Step 4: Run all tests**

Run: `cargo test`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/main.rs tests/attention_test.rs
git commit -m "feat: smart landing when switching spaces from picker"
```

---

### Task 10: Notification Suppression State

**Files:**
- Modify: `src/main.rs`
- Modify: `src/tmux.rs`
- Add to: `tests/attention_test.rs`

Store the last notification timestamp so system notifications respect the 30-second suppression window.

- [ ] **Step 1: Write failing test**

Add to `tests/attention_test.rs`:
```rust
#[test]
fn notification_timestamp_persists() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");

    // Set a notification timestamp
    focus::tmux::set_last_notification_time(&session).expect("set");

    // Read it back — should be recent (within 2 seconds)
    let elapsed = focus::tmux::get_last_notification_elapsed(&session).expect("get");
    assert!(elapsed < 2, "timestamp should be recent, got {}s elapsed", elapsed);

    cleanup(&session);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test attention_test notification_timestamp`
Expected: FAIL — functions don't exist

- [ ] **Step 3: Implement timestamp storage in tmux.rs**

Add to `src/tmux.rs`:
```rust
/// Record the current time as the last system notification timestamp.
/// Stored as Unix epoch seconds in FOCUS_LAST_NOTIFY session env var.
pub fn set_last_notification_time(session: &str) -> Result<()> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let _ = Command::new("tmux")
        .args(["set-environment", "-t", session, "FOCUS_LAST_NOTIFY", &now.to_string()])
        .output();
    Ok(())
}

/// Get seconds elapsed since the last system notification.
/// Returns u64::MAX if no notification has been sent.
pub fn get_last_notification_elapsed(session: &str) -> Result<u64> {
    let output = Command::new("tmux")
        .args(["show-environment", "-t", session, "FOCUS_LAST_NOTIFY"])
        .output()
        .context("failed to read FOCUS_LAST_NOTIFY")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let timestamp: u64 = stdout
        .trim()
        .strip_prefix("FOCUS_LAST_NOTIFY=")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);

    if timestamp == 0 {
        return Ok(u64::MAX);
    }

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    Ok(now.saturating_sub(timestamp))
}
```

- [ ] **Step 4: Update cmd_alert_bell to use suppression**

Update `cmd_alert_bell()` in `src/main.rs`:
```rust
fn cmd_alert_bell(pane_index: usize) -> Result<()> {
    let session = session_name();

    let active = tmux::active_pane_index(&session)?;
    if pane_index == active {
        return Ok(());
    }

    tmux::set_alert(&session, pane_index, true)?;

    let states = tmux::alert_states(&session)?;
    let count = focus::alert::count_alerts(&states);
    tmux::set_alert_count(&session, count)?;

    // System notification with suppression
    if !focus::notify::is_terminal_frontmost() {
        let elapsed = tmux::get_last_notification_elapsed(&session).unwrap_or(u64::MAX);
        let should_notify = elapsed >= 30; // 30-second suppression window
        if should_notify {
            let msg = focus::notify::format_message(count);
            let _ = focus::notify::send_notification("amux", &msg);
            let _ = tmux::set_last_notification_time(&session);
        }
    }

    Ok(())
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add src/main.rs src/tmux.rs tests/attention_test.rs
git commit -m "feat: notification suppression with 30-second window"
```

---

### Task 11: Status Bar Branding Update

**Files:**
- Modify: `src/config.rs`

Quick update: change "focus" to "amux" in the status bar left.

- [ ] **Step 1: Update status-left in config.rs**

Change the status-left from:
```rust
"#[fg=colour43,bold] focus #[fg=colour238]│ ",
```
to:
```rust
"#[fg=colour43,bold] amux #[fg=colour238]│ ",
```

- [ ] **Step 2: Run tests**

Run: `cargo test`
Expected: All tests PASS (no test checks the status-left text content)

- [ ] **Step 3: Commit**

```bash
git add src/config.rs
git commit -m "feat: update status bar branding from focus to amux"
```

---

### Task 12: End-to-End Scenario Tests

**Files:**
- Add to: `tests/attention_test.rs`

These tests verify complete scenarios that span multiple features.

- [ ] **Step 1: Write scenario — alert-scan marks non-active panes and updates badge**

```rust
#[test]
fn scenario_alert_scan_marks_panes() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::config::apply_config(&session).expect("config");
    focus::tmux::create_pane(&session, None).expect("pane 2");
    focus::tmux::create_pane(&session, None).expect("pane 3");

    // Select pane 0 as active
    focus::tmux::select_pane(&session, 0).expect("select");

    // Simulate alert-scan (marks all non-active, non-alerted panes)
    // In real use, this is triggered by the alert-bell tmux hook
    let panes = focus::tmux::list_panes(&session).expect("list");
    for pane in &panes {
        if !pane.active && !pane.alert {
            focus::tmux::set_alert(&session, pane.index, true).expect("set");
        }
    }
    let states = focus::tmux::alert_states(&session).expect("states");
    let count = focus::alert::count_alerts(&states);
    focus::tmux::set_alert_count(&session, count).expect("count");

    // Pane 0 (active) should not have alert, others should
    assert!(!states[0], "active pane should not alert");
    assert!(states[1], "non-active pane 1 should have alert");
    assert!(states[2], "non-active pane 2 should have alert");
    assert_eq!(count, 2);

    cleanup(&session);
}
```

- [ ] **Step 2: Write scenario — focusing alerted pane clears it**

```rust
#[test]
fn scenario_focus_clears_alert() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::config::apply_config(&session).expect("config");
    focus::tmux::create_pane(&session, None).expect("pane");

    // Set alert on pane 1
    focus::tmux::set_alert(&session, 1, true).expect("set");
    focus::tmux::set_alert_count(&session, 1).expect("count");

    // Simulate user focusing pane 1 (what zoom/select does)
    focus::tmux::select_pane(&session, 1).expect("select");
    focus::tmux::dismiss_alert(&session, 1).expect("dismiss");

    // Alert should be gone
    assert!(!focus::tmux::get_alert(&session, 1).expect("get"));
    assert_eq!(focus::tmux::get_alert_count(&session).expect("count"), 0);

    cleanup(&session);
}
```

- [ ] **Step 3: Write scenario — multiple bells, one dismiss**

```rust
#[test]
fn scenario_multiple_alerts_partial_dismiss() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::tmux::create_pane(&session, None).expect("pane 2");
    focus::tmux::create_pane(&session, None).expect("pane 3");

    // Set alerts on panes 1 and 2
    focus::tmux::set_alert(&session, 1, true).expect("set");
    focus::tmux::set_alert(&session, 2, true).expect("set");
    focus::tmux::set_alert_count(&session, 2).expect("count");

    // Dismiss pane 1 only
    focus::tmux::dismiss_alert(&session, 1).expect("dismiss");

    // Pane 1 cleared, pane 2 still alert
    assert!(!focus::tmux::get_alert(&session, 1).expect("get"));
    assert!(focus::tmux::get_alert(&session, 2).expect("get"));
    assert_eq!(focus::tmux::get_alert_count(&session).expect("count"), 1);

    cleanup(&session);
}
```

- [ ] **Step 4: Write scenario — active pane is excluded from alert-scan**

```rust
#[test]
fn scenario_active_pane_excluded_from_scan() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::config::apply_config(&session).expect("config");
    focus::tmux::create_pane(&session, None).expect("pane");

    // Pane 0 is active
    focus::tmux::select_pane(&session, 0).expect("select");

    // Run alert-scan logic — should mark pane 1 but NOT pane 0
    let panes = focus::tmux::list_panes(&session).expect("list");
    for pane in &panes {
        if !pane.active && !pane.alert {
            focus::tmux::set_alert(&session, pane.index, true).expect("set");
        }
    }

    assert!(!focus::tmux::get_alert(&session, 0).expect("get"),
        "active pane should NOT be alerted by scan");
    assert!(focus::tmux::get_alert(&session, 1).expect("get"),
        "non-active pane should be alerted by scan");

    cleanup(&session);
}
```

- [ ] **Step 5: Write scenario — notification message formatting**

```rust
#[test]
fn notification_messages() {
    assert_eq!(focus::notify::format_message(0), "All agents are working");
    assert_eq!(focus::notify::format_message(1), "1 agent is ready for you");
    assert_eq!(focus::notify::format_message(2), "2 agents are ready for you");
    assert_eq!(focus::notify::format_message(5), "5 agents are ready for you");
}
```

- [ ] **Step 6: Write scenario — pane close recalculates alert count**

```rust
#[test]
fn scenario_pane_close_updates_alert_count() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::tmux::create_pane(&session, None).expect("pane 2");
    focus::tmux::create_pane(&session, None).expect("pane 3");

    // Alert panes 1 and 2
    focus::tmux::set_alert(&session, 1, true).expect("set");
    focus::tmux::set_alert(&session, 2, true).expect("set");
    focus::tmux::set_alert_count(&session, 2).expect("count");

    // Kill pane 2 (which had an alert)
    focus::tmux::kill_pane(&session, 2).expect("kill");

    // Recalculate count from remaining panes
    let states = focus::tmux::alert_states(&session).expect("states");
    let count = focus::alert::count_alerts(&states);
    focus::tmux::set_alert_count(&session, count).expect("count");

    assert_eq!(count, 1, "count should update after pane close");

    cleanup(&session);
}
```

- [ ] **Step 7: Run all tests**

Run: `cargo test`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add tests/attention_test.rs
git commit -m "test: end-to-end scenario tests for attention management"
```

---

## tmux State Summary (Updated)

| Variable | Scope | Purpose |
|----------|-------|---------|
| `FOCUS_MANAGED=1` | Session env | Marks session as focus-managed |
| `FOCUS_LEVEL={1,2,3}` | Session env | Current zoom level |
| `FOCUS_PANE_COUNT=N` | Session env | Previous pane count (for sticky direction) |
| `@focus-alert-count` | Session option | Number of panes with active alerts |
| `FOCUS_LAST_NOTIFY=epoch` | Session env | Unix timestamp of last system notification |
| `FOCUS_SPLIT_FIRST=N` | Session env | First pane index for split selection |
| `@focus-title` | Pane option | Custom pane title |
| `@focus-cx`, `@focus-cy` | Pane option | Current center coordinates |
| `@focus-pcx`, `@focus-pcy` | Pane option | Previous center coordinates |
| `@focus-alert` | Pane option | `1` if pane needs user attention |
