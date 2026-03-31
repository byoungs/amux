//! Debug logging for the layout engine.
//! Appends to ~/.amux/layout.log on every compute_layout call.

use super::{LayoutAction, LayoutEvent, LayoutState};
use std::fs::OpenOptions;
use std::io::Write;

pub fn log_transition(
    session: &str,
    state: &LayoutState,
    event: &LayoutEvent,
    action: &LayoutAction,
) {
    let path = match std::env::var_os("HOME") {
        Some(h) => std::path::PathBuf::from(h).join(".amux").join("layout.log"),
        None => return,
    };
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    let entry = format_entry(session, state, event, action);
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{}", entry);
    }
}

fn format_entry(
    session: &str,
    state: &LayoutState,
    event: &LayoutEvent,
    action: &LayoutAction,
) -> String {
    let zoom_action = match action.zoom {
        Some(true) => "zoom",
        Some(false) => "unzoom",
        None => "none",
    };
    let layout_action = if action.layout_string.is_some() {
        "apply"
    } else {
        "skip"
    };
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
        "[{}] session={} event={:?}\n  \
         state: zoomed={} panes={} active={} window={}x{} border={}\n  \
         action: layout={} zoom={} select={:?} spaces={}",
        now,
        session,
        event,
        state.zoomed,
        state.panes.len(),
        state.active_pane,
        state.window_w,
        state.window_h,
        state.border_top,
        layout_action,
        zoom_action,
        action.select_pane,
        action.open_spaces,
    )
}
