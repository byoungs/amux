// src/alert.rs — Pure alert decision logic.
// No tmux dependency. Takes data in, returns decisions out.

/// Count panes in "ready for you" state.
pub fn count_alerts(alert_states: &[bool]) -> usize {
    alert_states.iter().filter(|&&a| a).count()
}
