/// Shared test utilities for tmux integration tests.
///
/// Provides `TestSession` — a RAII guard that creates a uniquely-named tmux
/// session and kills it on drop (even on panic). Sessions use UUID-based names
/// so tests can run in parallel without collisions.
use std::process::Command;
use std::sync::Once;

static CLEANUP_STALE: Once = Once::new();

/// Kill any leftover test sessions from previous crashed runs.
/// Called once per test process.
fn cleanup_stale_sessions() {
    CLEANUP_STALE.call_once(|| {
        let output = Command::new("tmux")
            .args(["list-sessions", "-F", "#{session_name}"])
            .output();
        if let Ok(output) = output {
            let stdout = String::from_utf8_lossy(&output.stdout);
            for session in stdout.lines() {
                if session.starts_with("amux-test-") {
                    let _ = Command::new("tmux")
                        .args(["kill-session", "-t", session])
                        .output();
                }
            }
        }
    });
}

/// A tmux session that cleans up after itself.
/// Create with `TestSession::new(pane_count)` — it generates a unique
/// session name, creates the session with config applied, and kills
/// the session when dropped.
pub struct TestSession {
    pub name: String,
}

/// Generate a unique session name. Single shared counter across all test types.
fn unique_session_name() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let id = COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("amux-test-{}-{}", std::process::id(), id)
}

impl TestSession {
    /// Create a new test session with the given number of panes.
    pub fn new(pane_count: usize) -> Self {
        cleanup_stale_sessions();
        let name = unique_session_name();

        amux::tmux::create_session(&name).expect("create test session");
        amux::config::apply_config(&name).expect("apply config");
        for _ in 1..pane_count {
            amux::tmux::create_pane(&name, None).expect("create pane");
        }
        amux::tmux::apply_grid_layout(&name).expect("layout");
        amux::tmux::select_pane(&name, 0).expect("select pane 0");

        TestSession { name }
    }

    /// Create a bare session (no config applied, no extra panes).
    /// Useful for low-level tmux tests.
    pub fn bare() -> Self {
        cleanup_stale_sessions();
        let name = unique_session_name();

        amux::tmux::create_session(&name).expect("create test session");

        TestSession { name }
    }
}

impl Drop for TestSession {
    fn drop(&mut self) {
        let _ = Command::new("tmux")
            .args(["kill-session", "-t", &self.name])
            .output();
    }
}

/// Get the amux binary path (debug build from cargo).
/// Respects CARGO_TARGET_DIR if set (used by Makefile for shared target dir).
pub fn amux_bin() -> String {
    if let Ok(target_dir) = std::env::var("CARGO_TARGET_DIR") {
        format!("{}/debug/amux", target_dir)
    } else {
        let manifest = env!("CARGO_MANIFEST_DIR");
        format!("{}/target/debug/amux", manifest)
    }
}

/// Run an amux subcommand against a test session.
pub fn amux_cmd(session: &str, args: &[&str]) -> std::process::Output {
    Command::new(amux_bin())
        .args(args)
        .env("AMUX_SESSION", session)
        .output()
        .expect("amux command failed")
}
