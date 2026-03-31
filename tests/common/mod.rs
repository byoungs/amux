/// Shared test utilities for tmux integration tests.
///
/// Provides `TestSession` — a RAII guard that creates a uniquely-named tmux
/// session and kills it on drop (even on panic).
///
/// ## Why concurrency is limited
///
/// tmux is a single-threaded server built on a libevent event loop. All
/// sessions, windows, and panes live in one process. Each `tmux` CLI
/// invocation connects as a **separate client** — so when a test does:
///
///   create_session(&name);     // client connection 1
///   apply_config(&name);       // client connection 2 (many set-option calls)
///   create_pane(&name, None);  // client connection 3
///
/// ...each is a separate client connection. The server round-robins through
/// client queues. When 36+ test processes do this simultaneously, the server
/// interleaves their commands. A test's "set-option -t session" may execute
/// while the server is processing another test's "kill-session", and deferred
/// destruction timers can interfere with pane lookups — producing "can't find
/// pane" errors even though the session was just created successfully.
///
/// The fix: a cross-process counting semaphore (file locks in /tmp) limits
/// concurrent test sessions to MAX_CONCURRENT. This keeps enough parallelism
/// for speed while preventing the server from being overwhelmed.
///
/// A deeper fix would batch multiple tmux operations into single client
/// connections using `tmux new-session \; set-option ... \; ...` chains,
/// which execute atomically within one server pass. That's a future refactor.
///
/// References:
///   - tmux#2438: race condition loading config on rapid connections
///   - tmux#3378: session-created hook race with 100ms workaround
///   - claude-code#23513: send-keys race after pane creation
use std::process::Command;
use std::sync::Once;

static CLEANUP_STALE: Once = Once::new();

/// Max concurrent tmux test sessions across all test binaries.
/// File locks in /tmp serve as a cross-process counting semaphore.
const MAX_CONCURRENT: usize = 4;

/// Acquire a slot by creating a lock file. Spins until a slot is available.
fn acquire_session_slot() -> usize {
    use std::fs::OpenOptions;
    loop {
        for i in 0..MAX_CONCURRENT {
            let path = format!("/tmp/amux-test-slot-{}", i);
            if OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
                .is_ok()
            {
                return i;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

fn release_session_slot(slot: usize) {
    let _ = std::fs::remove_file(format!("/tmp/amux-test-slot-{}", slot));
}

/// Kill leftover test sessions from PREVIOUS crashed runs (different PID).
/// Also cleans up stale slot files from previous crashes.
fn cleanup_stale_sessions() {
    CLEANUP_STALE.call_once(|| {
        // Clean up stale slot files
        for i in 0..MAX_CONCURRENT {
            let _ = std::fs::remove_file(format!("/tmp/amux-test-slot-{}", i));
        }

        let my_pid = std::process::id().to_string();
        let output = Command::new("tmux")
            .args(["list-sessions", "-F", "#{session_name}"])
            .output();
        if let Ok(output) = output {
            let stdout = String::from_utf8_lossy(&output.stdout);
            for session in stdout.lines() {
                if session.starts_with("amux-test-") && !session.contains(&my_pid) {
                    let _ = Command::new("tmux")
                        .args(["kill-session", "-t", session])
                        .output();
                }
            }
        }
    });
}

/// A tmux session that cleans up after itself.
pub struct TestSession {
    pub name: String,
    slot: usize,
}

/// Generate a unique session name.
fn unique_session_name() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let id = COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("amux-test-{}-{}", std::process::id(), id)
}

impl TestSession {
    pub fn new(pane_count: usize) -> Self {
        cleanup_stale_sessions();
        let slot = acquire_session_slot();
        let name = unique_session_name();

        amux::tmux::create_session(&name).expect("create test session");
        if pane_count > 0 {
            amux::config::apply_config(&name).expect("apply config");
            for _ in 1..pane_count {
                amux::tmux::create_pane(&name, None).expect("create pane");
            }
            amux::tmux::apply_layout(&name, amux::layout_engine::LayoutEvent::Resize)
                .expect("layout");
            amux::tmux::select_pane(&name, 0).expect("select pane 0");
        }

        TestSession { name, slot }
    }
}

impl Drop for TestSession {
    fn drop(&mut self) {
        let _ = Command::new("tmux")
            .args(["kill-session", "-t", &self.name])
            .output();
        release_session_slot(self.slot);
    }
}
