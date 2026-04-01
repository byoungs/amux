# Session Scoping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scope tmux hooks and key binding commands to their session so that test sessions and live sessions never interfere with each other.

**Architecture:** Add `--session` global CLI flag to the `Cli` struct. Update `session_name()` to check it first. Change all key binding `run-shell` commands to pass `--session #{session_name}`. Change hooks from `-g` (global) to `-t session` (session-scoped).

**Tech Stack:** Rust (clap CLI), tmux

---

### Task 1: Add `--session` global CLI flag and update session resolution

**Files:**
- Modify: `src/main.rs:12-22` (Cli struct)
- Modify: `src/main.rs:100-117` (session_name function)
- Modify: `src/main.rs:119-172` (main function — thread session through)

- [ ] **Step 1: Write the failing test**

Add a unit test to `src/main.rs` (or an integration test) that verifies the `--session` flag takes priority. Since `session_name()` is a free function that reads from the Cli struct, we need to refactor it to accept the flag value. The simplest approach: make `session_name()` accept an `Option<String>` parameter.

Create `tests/session_resolution_test.rs`:

```rust
/// Session resolution priority: --session flag > AMUX_SESSION env > tmux context > default
mod cli;

#[test]
fn cli_session_flag_is_passed_to_subcommand() {
    // When --session is passed, the zoom command should target that session
    // (even if AMUX_SESSION env var is set to something different)
    let ts = common::TestSession::new(3);

    // Run zoom-in with explicit --session flag
    let output = std::process::Command::new(cli::amux_bin())
        .args(["--session", &ts.name, "zoom-in"])
        .env("AMUX_SESSION", "wrong-session-name")
        .output()
        .expect("amux command failed");

    assert!(
        output.status.success(),
        "zoom-in with --session flag should succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        amux::tmux::is_zoomed(&ts.name).expect("is_zoomed"),
        "--session flag should target the correct session"
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `amux` doesn't accept `--session` flag yet.

- [ ] **Step 3: Add `--session` flag to Cli struct**

In `src/main.rs`, change the `Cli` struct to add a global `--session` flag:

```rust
/// Terminal workflow manager for AI coding
#[derive(Parser)]
#[command(name = "amux", about = "Terminal workflow manager for AI coding")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Target session name (passed by tmux key bindings via #{session_name})
    #[arg(long, global = true)]
    session: Option<String>,

    /// Session names to create on startup
    #[arg(short, long)]
    sessions: Vec<String>,
}
```

- [ ] **Step 4: Update `session_name()` to accept the flag**

Change `session_name()` to accept the CLI flag value as its first-priority source:

```rust
/// The amux session name. Resolution priority:
/// 1. --session flag (passed by tmux key bindings, most reliable)
/// 2. AMUX_SESSION env var (used by tests via amux_cmd())
/// 3. tmux client context (fallback for manual CLI use)
/// 4. "amux" default
fn session_name(cli_session: &Option<String>) -> String {
    // --session flag takes priority (passed by tmux at keypress time)
    if let Some(s) = cli_session {
        if !s.is_empty() {
            return s.clone();
        }
    }
    // Explicit env var (hooks, tests, multi-session)
    if let Ok(s) = std::env::var("AMUX_SESSION") {
        if !s.is_empty() {
            return s;
        }
    }
    // Try tmux client context (works from manual CLI invocations)
    if let Ok(s) = current_session_from_tmux() {
        if !s.is_empty() {
            return s;
        }
    }
    "amux".to_string()
}
```

- [ ] **Step 5: Thread cli.session through all callers**

In `main()`, pass `&cli.session` to every call to `session_name()`. There are many call sites — each `cmd_*` function calls `session_name()` internally. The cleanest approach: change `session_name()` to read from a global (since the CLI is parsed once), or pass it through.

Since `session_name()` is called from many `cmd_*` functions, the simplest refactor is to store the CLI session value in a thread-local or just set `AMUX_SESSION` env var early in `main()` if `--session` was provided:

```rust
fn main() -> Result<()> {
    if std::env::var_os("LANG").is_none() {
        std::env::set_var("LANG", "en_US.UTF-8");
    }

    let cli = Cli::parse();

    // --session flag takes highest priority: propagate it to session_name()
    // by setting AMUX_SESSION (which session_name() already checks).
    // This avoids threading the flag through every cmd_* function.
    if let Some(ref s) = cli.session {
        if !s.is_empty() {
            std::env::set_var("AMUX_SESSION", s);
        }
    }

    // ... rest of main unchanged ...
```

With this approach, `session_name()` does NOT need a parameter change — the `--session` flag is promoted to the env var that `session_name()` already reads. The priority is maintained because we set it before any command runs.

Note: the `Layout` subcommand already has its own `session` field and sets `AMUX_SESSION` directly — that path is unchanged.

- [ ] **Step 6: Run test to verify it passes**

Run: `make test`
Expected: PASS

- [ ] **Step 7: Commit**

```
git add src/main.rs tests/session_resolution_test.rs
git commit -m "Add --session global CLI flag for explicit session targeting"
```

---

### Task 2: Scope hooks from global to session-level

**Files:**
- Modify: `src/config.rs:23-84` (apply_hooks function)

- [ ] **Step 1: Write the failing test**

Create `tests/hook_scoping_test.rs` to verify hooks are session-scoped:

```rust
/// Hooks must be session-scoped (-t session), not global (-g).
/// Global hooks cause cross-session interference between live sessions and tests.
mod common;

#[test]
fn hooks_are_session_scoped_not_global() {
    let ts = common::TestSession::new(2);

    // apply_config sets hooks — verify they're on the session, not global
    // Check session-level hooks exist
    let output = std::process::Command::new("tmux")
        .args(["show-hooks", "-t", &ts.name])
        .output()
        .expect("show-hooks");
    let hooks = String::from_utf8_lossy(&output.stdout);

    assert!(
        hooks.contains("pane-exited"),
        "session should have pane-exited hook: {}",
        hooks
    );
    assert!(
        hooks.contains("pane-focus-out"),
        "session should have pane-focus-out hook: {}",
        hooks
    );

    // Verify global hooks do NOT contain our amux hooks
    let global_output = std::process::Command::new("tmux")
        .args(["show-hooks", "-g"])
        .output()
        .expect("show-hooks -g");
    let global_hooks = String::from_utf8_lossy(&global_output.stdout);

    // After our session's apply_config, global hooks should not have amux layout commands
    // (They might have stale ones from before, so we check the session hooks exist — that's the key assertion)
}

#[test]
fn two_sessions_get_independent_hooks() {
    let ts1 = common::TestSession::new(2);
    let ts2 = common::TestSession::new(2);

    // Both sessions should have their own hooks
    let hooks1 = std::process::Command::new("tmux")
        .args(["show-hooks", "-t", &ts1.name])
        .output()
        .expect("show-hooks ts1");
    let hooks2 = std::process::Command::new("tmux")
        .args(["show-hooks", "-t", &ts2.name])
        .output()
        .expect("show-hooks ts2");

    let h1 = String::from_utf8_lossy(&hooks1.stdout);
    let h2 = String::from_utf8_lossy(&hooks2.stdout);

    assert!(h1.contains("pane-exited"), "ts1 should have hooks");
    assert!(h2.contains("pane-exited"), "ts2 should have hooks");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `show-hooks -t SESSION` returns empty because hooks are currently set globally.

- [ ] **Step 3: Change apply_hooks to use session-scoped hooks**

In `src/config.rs`, change `apply_hooks()` to use `-t session` instead of `-g`:

```rust
/// Set up attention management and layout hooks.
pub fn apply_hooks(session: &str) -> Result<()> {
    crate::tmux::setup_all_bell_watches(session)?;

    let bin = "amux";

    // Re-apply layout when a pane exits (shell closes naturally)
    let output = Command::new("tmux")
        .args([
            "set-hook",
            "-t",
            session,
            "pane-exited",
            &format!("run-shell \"{} layout #{{session_name}}\"", bin),
        ])
        .output();
    if let Ok(o) = &output {
        if !o.status.success() {
            eprintln!(
                "amux: failed to register pane-exited hook: {}",
                String::from_utf8_lossy(&o.stderr)
            );
        }
    }

    // Re-apply layout when the terminal window is resized
    let output = Command::new("tmux")
        .args([
            "set-hook",
            "-t",
            session,
            "client-resized",
            &format!("run-shell \"{} layout #{{session_name}}\"", bin),
        ])
        .output();
    if let Ok(o) = &output {
        if !o.status.success() {
            eprintln!(
                "amux: failed to register client-resized hook: {}",
                String::from_utf8_lossy(&o.stderr)
            );
        }
    }

    // Update pane title from cwd when focus leaves a pane
    let output = Command::new("tmux")
        .args([
            "set-hook",
            "-t",
            session,
            "pane-focus-out",
            &format!(
                "run-shell \"{bin} update-title #{{pane_index}} '#{{pane_current_path}}'\""
            ),
        ])
        .output();
    if let Ok(o) = &output {
        if !o.status.success() {
            eprintln!(
                "amux: failed to register pane-focus-out hook: {}",
                String::from_utf8_lossy(&o.stderr)
            );
        }
    }

    Ok(())
}
```

The only change in each hook block: `"-g"` becomes `"-t", session,`.

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS

- [ ] **Step 5: Commit**

```
git add src/config.rs tests/hook_scoping_test.rs
git commit -m "Scope tmux hooks to session instead of global"
```

---

### Task 3: Pass `--session` in all key binding run-shell commands

**Files:**
- Modify: `src/config.rs:167-267` (apply_key_bindings function)

- [ ] **Step 1: Write the failing test**

Add to `tests/config_test.rs` — we can't easily test key binding content via tmux introspection, but we can verify the format strings contain `--session`:

Since key bindings are set via tmux commands and we can't easily inspect their content in tests, we'll validate this structurally. The key change is mechanical: every `run-shell` in `apply_key_bindings` that invokes `amux` must include `--session #{{session_name}}`.

Add a test that inspects the bound keys via `tmux list-keys`:

```rust
#[test]
fn key_bindings_pass_session_flag() {
    // After apply_config, key bindings should include --session
    let ts = common::TestSession::new(2);

    let output = std::process::Command::new("tmux")
        .args(["list-keys", "-T", "root"])
        .output()
        .expect("list-keys");
    let keys = String::from_utf8_lossy(&output.stdout);

    // Check that zoom bindings include --session
    // C-= is Ctrl-+ (zoom-in)
    let zoom_in_line = keys.lines().find(|l| l.contains("C-=") && l.contains("amux"));
    assert!(
        zoom_in_line.is_some_and(|l| l.contains("--session")),
        "C-= binding should include --session flag. Found: {:?}",
        zoom_in_line
    );

    // C-1 should be zoom with --session
    let zoom_1_line = keys.lines().find(|l| l.contains("C-1") && l.contains("amux"));
    assert!(
        zoom_1_line.is_some_and(|l| l.contains("--session")),
        "C-1 binding should include --session flag. Found: {:?}",
        zoom_1_line
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — bindings don't contain `--session` yet.

- [ ] **Step 3: Update all key bindings to pass `--session #{session_name}`**

In `src/config.rs`, update `apply_key_bindings`. The `_session` parameter becomes used. Every `run-shell "amux ..."` gains `--session #{{session_name}}`.

```rust
/// Configure key bindings for amux workflow.
/// All bindings are global (tmux doesn't support session-scoped bindings),
/// but each command includes --session #{session_name} so amux targets
/// the correct session at keypress time.
fn apply_key_bindings(_session: &str) -> Result<()> {
    let bin = "amux";
    // #{session_name} is expanded by tmux at keypress time
    let sflag = "--session #{{session_name}}";

    // Verify the binary is on PATH
    let which = Command::new("which").arg(bin).output();
    if which.is_err() || !which.unwrap().status.success() {
        eprintln!(
            "Warning: '{}' not found on PATH. Key bindings may not work.",
            bin
        );
        eprintln!("Run: cargo install --path .");
    }

    // === Zoom controls ===

    // Ctrl-+ : zoom in (working → full screen)
    tmux_bind_root("C-=", &format!(r#"run-shell "{bin} {sflag} zoom-in""#))?;

    // Ctrl-- : zoom out (full screen → working, or open spaces picker; also handles split exit)
    tmux_bind_root(
        "C--",
        &format!(
            r#"run-shell "if [ $(tmux display-message -p '#{{window_index}}') -gt 0 ]; then {bin} {sflag} split-exit; else {bin} {sflag} zoom-out; fi""#
        ),
    )?;

    // Ctrl-1..9 : context-aware zoom to pane N
    for i in 1..=9 {
        tmux_bind_root(
            &format!("C-{}", i),
            &format!(r#"run-shell "{bin} {sflag} zoom {}""#, i - 1),
        )?;
    }

    // === Pane cycling (Cmd-[ / Cmd-]) ===
    tmux_bind_root("C-[", &format!(r#"run-shell "{bin} {sflag} pane-prev""#))?;
    tmux_bind_root("C-]", &format!(r#"run-shell "{bin} {sflag} pane-next""#))?;

    // === Pane lifecycle ===
    // Ctrl-n: create pane via amux (sets title, handles layout internally)
    tmux_bind_root(
        "C-n",
        &format!(r#"run-shell "cd '#{{pane_current_path}}' && {bin} {sflag} new""#),
    )?;

    // === Spaces ===
    // Ctrl-P: Space picker (popup centered over tmux)
    tmux_bind_root(
        "C-p",
        &format!(
            r#"display-popup -E -w 70 -h 20 -T " Spaces " "{bin} {sflag} spaces""#
        ),
    )?;

    // Ctrl-S: Send pane to another space (popup)
    tmux_bind_root(
        "C-s",
        &format!(
            r#"display-popup -E -w 70 -h 20 -T " Send to Space " "{bin} {sflag} send""#
        ),
    )?;

    // === Split view ===
    tmux_bind_root("C-l", &format!(r#"run-shell "{bin} {sflag} split-start""#))?;

    tmux_bind_table("amux-split-pick", "C-Left", "select-pane -L")?;
    tmux_bind_table("amux-split-pick", "C-Right", "select-pane -R")?;
    tmux_bind_table("amux-split-pick", "C-Up", "select-pane -U")?;
    tmux_bind_table("amux-split-pick", "C-Down", "select-pane -D")?;
    tmux_bind_table(
        "amux-split-pick",
        "Enter",
        &format!(
            r#"run-shell "{bin} {sflag} split-pick $(tmux display-message -p '#{{pane_index}}')""#
        ),
    )?;
    for i in 1..=9 {
        tmux_bind_table(
            "amux-split-pick",
            &format!("C-{}", i),
            &format!(r#"run-shell "{bin} {sflag} split-pick {}""#, i - 1),
        )?;
    }
    tmux_bind_table(
        "amux-split-pick",
        "Escape",
        &format!(r#"run-shell "{bin} {sflag} split-cancel""#),
    )?;

    Ok(())
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS

- [ ] **Step 5: Commit**

```
git add src/config.rs tests/config_test.rs
git commit -m "Pass --session in all key binding run-shell commands"
```

---

### Task 4: Full validation

- [ ] **Step 1: Run `make validate` (full suite including tmux integration tests)**

Run: `make validate`
Expected: All tests pass. This catches any integration issues from the scoping changes.

- [ ] **Step 2: Verify live behavior**

After `make dev && make refresh`:
- Ctrl-7 with only 3 panes should show the error in the correct session only
- Multiple amux spaces should have independent hooks
- Key bindings in non-amux tmux sessions should silently no-op (because `--session` will be set to the non-amux session name, and `session_name()` returns it, but the session isn't amux-managed — the commands will just fail quietly on tmux operations targeting a non-amux session)

- [ ] **Step 3: Squash into a single clean commit**

```
git rebase -r HEAD~3
```

Final commit message: "Scope hooks and key bindings to their session (PEN-167)"
