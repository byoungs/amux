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
///
/// Pass `pane_count = 0` for a bare session (no config, single pane).
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
    /// Create a test session.
    ///
    /// - `pane_count >= 1`: creates session with config applied and that many panes.
    /// - `pane_count == 0`: bare session (no config, single pane) for low-level tests.
    pub fn new(pane_count: usize) -> Self {
        cleanup_stale_sessions();
        let name = unique_session_name();

        amux::tmux::create_session(&name).expect("create test session");
        if pane_count > 0 {
            amux::config::apply_config(&name).expect("apply config");
            for _ in 1..pane_count {
                amux::tmux::create_pane(&name, None).expect("create pane");
            }
            amux::tmux::relayout(&name, amux::sticky::LayoutEvent::Resize).expect("layout");
            amux::tmux::select_pane(&name, 0).expect("select pane 0");
        }

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
