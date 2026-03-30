pub mod alert;
pub mod bell;
pub mod config;
pub mod hooks;
pub mod layout;
pub mod layout_engine;
pub mod notify;
pub mod state;
pub mod sticky;
pub mod tmux;
pub mod util;

/// Minimum pane size for Working View (Level 2).
/// If the active pane is smaller than this, it gets enlarged.
pub const MIN_PANE_COLS: u16 = 120;
pub const MIN_PANE_ROWS: u16 = 24;
