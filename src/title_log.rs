//! Debug logging for title changes.
//! Appends to ~/.amux/title.log on every set_title call.
//! Helps diagnose pane title mismatches by recording the full
//! history of who set what title on which pane and why.

use std::fs::OpenOptions;
use std::io::Write;

/// Format a title change log entry. Public for testing.
pub fn format_entry(
    session: &str,
    pane_index: usize,
    old_title: &str,
    new_title: &str,
    caller: &str,
    cwd: &str,
) -> String {
    let now = {
        use std::time::SystemTime;
        let secs = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        format!(
            "{:02}:{:02}:{:02}",
            (secs % 86400) / 3600,
            (secs % 3600) / 60,
            secs % 60
        )
    };
    format!(
        "[{}] session={} pane={} old=\"{}\" new=\"{}\" caller={} cwd={}",
        now, session, pane_index, old_title, new_title, caller, cwd
    )
}

/// Append a title change entry to ~/.amux/title.log.
pub fn log_change(
    session: &str,
    pane_index: usize,
    old_title: &str,
    new_title: &str,
    caller: &str,
    cwd: &str,
) {
    // Skip logging when title hasn't changed
    if old_title == new_title {
        return;
    }

    let path = match std::env::var_os("HOME") {
        Some(h) => std::path::PathBuf::from(h).join(".amux").join("title.log"),
        None => return,
    };
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    let entry = format_entry(session, pane_index, old_title, new_title, caller, cwd);
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{}", entry);
    }
}
