# pipe-pane BEL Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect which pane emitted a terminal bell using tmux's `pipe-pane`, eliminating the need for users to configure a Claude Code hook.

**Architecture:** Each pane gets a `pipe-pane` that feeds its raw output to `focus bell-watch --session S N`, a long-running process with a byte-level state machine that distinguishes bare BEL characters from BEL-as-OSC-terminator. On detection, it calls the existing `trigger_alert` logic. Pipes are set up automatically on pane creation and refresh.

**Tech Stack:** Rust, tmux pipe-pane

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/bell.rs` | Create | Pure BEL scanner state machine — no I/O, no tmux |
| `tests/bell_test.rs` | Create | Unit tests for scanner (16+ test cases) |
| `src/main.rs` | Modify | Add `BellWatch` command, extract `trigger_alert` from `cmd_alert_pane` |
| `src/tmux.rs` | Modify | Add `setup_bell_watch` and `setup_all_bell_watches` |
| `src/config.rs` | Modify | Call `setup_all_bell_watches` from `apply_hooks` |
| `src/lib.rs` | Modify | Add `pub mod bell;` |
| `tests/attention_test.rs` | Modify | Add pipe-pane integration test |

---

### Task 1: BEL Scanner State Machine

**Files:**
- Create: `src/bell.rs`
- Create: `tests/bell_test.rs`
- Modify: `src/lib.rs`

The scanner must distinguish bare BEL (0x07) from BEL used as a terminator
in OSC (`\x1b]...\x07`), DCS (`\x1bP...\x07`), APC (`\x1b_...\x07`), and
PM (`\x1b^...\x07`) sequences.

- [ ] **Step 1: Write all scanner tests**

`tests/bell_test.rs`:
```rust
use focus::bell::{scan_bytes, ScanState};

/// Helper: scan a byte slice, return number of bells detected
fn bells(data: &[u8]) -> usize {
    let mut state = ScanState::new();
    scan_bytes(&mut state, data)
}

#[test]
fn bare_bel_detected() {
    assert_eq!(bells(b"\x07"), 1);
}

#[test]
fn multiple_bels() {
    assert_eq!(bells(b"\x07\x07\x07"), 3);
}

#[test]
fn osc_bel_terminator_not_detected() {
    // OSC: ESC ] ... BEL
    assert_eq!(bells(b"\x1b]0;window title\x07"), 0);
}

#[test]
fn osc_st_terminator_no_bells() {
    // OSC terminated by ST (ESC \) instead of BEL
    assert_eq!(bells(b"\x1b]0;title\x1b\\"), 0);
}

#[test]
fn bel_after_osc_detected() {
    // First BEL terminates OSC, second is a real bell
    assert_eq!(bells(b"\x1b]0;title\x07\x07"), 1);
}

#[test]
fn dcs_bel_terminator_not_detected() {
    assert_eq!(bells(b"\x1bPdata\x07"), 0);
}

#[test]
fn apc_bel_terminator_not_detected() {
    assert_eq!(bells(b"\x1b_data\x07"), 0);
}

#[test]
fn pm_bel_terminator_not_detected() {
    assert_eq!(bells(b"\x1b^data\x07"), 0);
}

#[test]
fn csi_sequence_no_bells() {
    // CSI (ESC [) sequences don't use BEL as terminator
    assert_eq!(bells(b"\x1b[31m"), 0);
}

#[test]
fn mixed_content_only_bare_bels() {
    // Normal text, then BEL, then OSC, then BEL
    assert_eq!(bells(b"hello\x07world\x1b]9;notify\x07"), 1);
}

#[test]
fn empty_input() {
    assert_eq!(bells(b""), 0);
}

#[test]
fn bel_in_text() {
    assert_eq!(bells(b"hello\x07world"), 1);
}

#[test]
fn osc9_notification_not_detected() {
    // This is what Claude Code sends — OSC 9 with message
    assert_eq!(bells(b"\x1b]9;Claude Code needs attention\x07"), 0);
}

#[test]
fn state_carries_across_chunks() {
    // OSC split across two scan_bytes calls
    let mut state = ScanState::new();
    let count1 = scan_bytes(&mut state, b"\x1b]0;ti");
    let count2 = scan_bytes(&mut state, b"tle\x07");
    assert_eq!(count1 + count2, 0, "BEL terminating split OSC should not count");
}

#[test]
fn esc_then_normal_char_then_bel() {
    // ESC followed by a char that doesn't start a string sequence
    // exits ESC state, so subsequent BEL is bare
    assert_eq!(bells(b"\x1bX\x07"), 1);
}

#[test]
fn only_text_no_bells() {
    assert_eq!(bells(b"just normal text with no special characters"), 0);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --test bell_test`
Expected: FAIL — `bell` module doesn't exist

- [ ] **Step 3: Implement bell.rs**

`src/bell.rs`:
```rust
// src/bell.rs — BEL character scanner for tmux pipe-pane output.
//
// Distinguishes bare BEL (0x07) from BEL used as a terminator in
// string sequences (OSC, DCS, APC, PM). Pure logic — no I/O.

/// Scanner state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanState {
    /// Default state — processing normal output.
    Normal,
    /// Just saw ESC (0x1B). Next byte determines sequence type.
    Esc,
    /// Inside a string sequence (OSC/DCS/APC/PM). BEL here is a terminator.
    StringSeq,
    /// Saw ESC inside a string sequence — checking for ST (ESC \).
    StringEsc,
}

impl ScanState {
    pub fn new() -> Self {
        ScanState::Normal
    }
}

/// Process a single byte through the state machine.
/// Returns true if a bare BEL was detected.
fn scan_byte(state: &mut ScanState, byte: u8) -> bool {
    match (*state, byte) {
        // Normal: BEL is a real bell
        (ScanState::Normal, 0x07) => true,
        // Normal: ESC starts an escape sequence
        (ScanState::Normal, 0x1B) => { *state = ScanState::Esc; false }
        // Normal: anything else
        (ScanState::Normal, _) => false,

        // Esc: ] P _ ^ start string sequences (OSC, DCS, APC, PM)
        (ScanState::Esc, b']' | b'P' | b'_' | b'^') => {
            *state = ScanState::StringSeq; false
        }
        // Esc: anything else — not a string sequence, back to normal
        (ScanState::Esc, _) => { *state = ScanState::Normal; false }

        // StringSeq: BEL terminates the sequence (not a real bell)
        (ScanState::StringSeq, 0x07) => { *state = ScanState::Normal; false }
        // StringSeq: ESC might be start of ST (ESC \)
        (ScanState::StringSeq, 0x1B) => { *state = ScanState::StringEsc; false }
        // StringSeq: anything else — still in the sequence
        (ScanState::StringSeq, _) => false,

        // StringEsc: \ completes ST, ending the sequence
        (ScanState::StringEsc, b'\\') => { *state = ScanState::Normal; false }
        // StringEsc: anything else — wasn't ST, still in sequence
        (ScanState::StringEsc, _) => { *state = ScanState::StringSeq; false }
    }
}

/// Scan a buffer of bytes, returning the number of bare BEL characters found.
/// State is maintained across calls for chunked input.
pub fn scan_bytes(state: &mut ScanState, data: &[u8]) -> usize {
    let mut count = 0;
    for &byte in data {
        if scan_byte(state, byte) {
            count += 1;
        }
    }
    count
}
```

- [ ] **Step 4: Register the module**

Add to `src/lib.rs`: `pub mod bell;`

- [ ] **Step 5: Run tests**

Run: `cargo test --test bell_test`
Expected: All 16 tests PASS

- [ ] **Step 6: Commit**

```
git add src/bell.rs src/lib.rs tests/bell_test.rs
git commit -m "feat: add BEL scanner state machine for pipe-pane detection"
```

---

### Task 2: BellWatch Command and trigger_alert Extraction

**Files:**
- Modify: `src/main.rs`

Extract the alert logic from `cmd_alert_pane` into a shared `trigger_alert`
function. Add a `BellWatch` command that reads stdin, runs the scanner, and
calls `trigger_alert` on each detected bell.

- [ ] **Step 1: Add BellWatch to Commands enum**

After `AlertPane`:
```rust
/// Watch pane output for BEL characters (started by pipe-pane, internal)
BellWatch {
    /// Pane index to alert on bell
    pane: usize,
    /// Session name
    #[arg(long)]
    session: String,
},
```

Add match arm:
```rust
Some(Commands::BellWatch { pane, session }) => cmd_bell_watch(session, pane),
```

- [ ] **Step 2: Extract trigger_alert from cmd_alert_pane**

Create a shared function:
```rust
/// Core alert logic: mark a pane, update count, optionally notify.
/// Used by both alert-pane (Claude Code hook) and bell-watch (pipe-pane).
fn trigger_alert(session: &str, pane_index: usize) -> Result<()> {
    let active = tmux::active_pane_index(session)?;
    if pane_index == active {
        return Ok(());
    }
    if tmux::get_alert(session, pane_index)? {
        return Ok(());
    }

    tmux::set_alert(session, pane_index, true)?;

    let states = tmux::alert_states(session)?;
    let count = focus::alert::count_alerts(&states);
    tmux::set_alert_count(session, count)?;

    if !focus::notify::is_terminal_frontmost() {
        let elapsed = tmux::get_last_notification_elapsed(session).unwrap_or(u64::MAX);
        if elapsed >= 30 {
            let msg = focus::notify::format_message(count);
            let _ = focus::notify::send_notification("amux", &msg);
            let _ = tmux::set_last_notification_time(session);
        }
    }

    Ok(())
}
```

Simplify `cmd_alert_pane`:
```rust
fn cmd_alert_pane(pane_index: usize) -> Result<()> {
    trigger_alert(&session_name(), pane_index)
}
```

- [ ] **Step 3: Implement cmd_bell_watch**

```rust
/// Watch stdin for BEL characters and alert the pane.
/// Started by tmux pipe-pane — runs until the pane closes (EOF on stdin).
fn cmd_bell_watch(session: String, pane_index: usize) -> Result<()> {
    use std::io::Read;
    let mut state = focus::bell::ScanState::new();
    let mut buf = [0u8; 4096];

    loop {
        let n = std::io::stdin().read(&mut buf)?;
        if n == 0 { break; }

        let bells = focus::bell::scan_bytes(&mut state, &buf[..n]);
        if bells > 0 {
            let _ = trigger_alert(&session, pane_index);
        }
    }

    Ok(())
}
```

- [ ] **Step 4: Verify compilation and existing tests pass**

Run: `cargo test --test attention_test --test alert_test`
Expected: All pass (no behavioral change yet)

- [ ] **Step 5: Commit**

```
git add src/main.rs
git commit -m "feat: add bell-watch command with trigger_alert extraction"
```

---

### Task 3: Wire pipe-pane into Pane Lifecycle

**Files:**
- Modify: `src/tmux.rs`
- Modify: `src/config.rs`

Set up `pipe-pane` automatically on pane creation and refresh.

- [ ] **Step 1: Add setup_bell_watch to tmux.rs**

```rust
/// Set up pipe-pane on a pane to watch for BEL characters.
pub fn setup_bell_watch(session: &str, pane_index: usize) -> Result<()> {
    let bin = "focus";
    let target = format!("{}:.{}", session, pane_index);
    let _ = Command::new("tmux")
        .args([
            "pipe-pane", "-t", &target,
            &format!("exec {} bell-watch --session {} {}", bin, session, pane_index),
        ])
        .output();
    Ok(())
}

/// Set up bell watchers on all panes in a session.
pub fn setup_all_bell_watches(session: &str) -> Result<()> {
    let panes = list_panes(session)?;
    for pane in &panes {
        setup_bell_watch(session, pane.index)?;
    }
    Ok(())
}
```

- [ ] **Step 2: Call setup_bell_watch after pane creation**

In `create_pane`, after `apply_grid_layout` and before returning, add:
```rust
let _ = setup_bell_watch(session, active);
```

- [ ] **Step 3: Call setup_all_bell_watches from apply_hooks**

Update `apply_hooks` in `src/config.rs`:
```rust
pub fn apply_hooks(session: &str) -> Result<()> {
    crate::tmux::setup_all_bell_watches(session)?;
    Ok(())
}
```

- [ ] **Step 4: Add integration test**

Add to `tests/attention_test.rs`:
```rust
#[test]
fn bell_watch_pipe_is_set_up_on_refresh() {
    let session = session_name();
    cleanup(&session);
    focus::tmux::create_session(&session).expect("create");
    focus::config::apply_config(&session).expect("config");

    // Check that pipe-pane was set up on the pane
    let output = Command::new("tmux")
        .args(["display-message", "-t", &format!("{}:.0", session), "-p", "#{pane_pipe}"])
        .output()
        .expect("display-message");
    let pipe = String::from_utf8_lossy(&output.stdout).trim().to_string();
    assert_eq!(pipe, "1", "pipe-pane should be active on pane 0 after config");

    cleanup(&session);
}
```

- [ ] **Step 5: Run all tests**

Run: `cargo test --test bell_test --test attention_test --test focus_test --test alert_test --test notify_test --test sticky_test`
Expected: All pass

- [ ] **Step 6: Commit**

```
git add src/tmux.rs src/config.rs tests/attention_test.rs
git commit -m "feat: auto-setup pipe-pane bell watchers on create and refresh"
```

---

### Task 4: Update Documentation

**Files:**
- Modify: `docs/attention-management.md`
- Modify: `README.md`

- [ ] **Step 1: Update attention-management.md**

Replace the "Claude Code Notification Hook" section with a "pipe-pane BEL Detection"
section explaining the automatic approach. Remove the hook configuration instructions.

- [ ] **Step 2: Update README.md**

Remove the "Claude Code Notification Hook" setup section. Replace with a note
that attention management works automatically — no configuration needed.
Keep `alert-pane` documented as an alternative for non-bell applications.

- [ ] **Step 3: Commit**

```
git add docs/attention-management.md README.md
git commit -m "docs: update for automatic pipe-pane bell detection"
```
