// src/alert.rs — Pure alert decision logic.
// No tmux dependency. Takes data in, returns decisions out.

/// Count panes in "ready for you" state.
pub fn count_alerts(alert_states: &[bool]) -> usize {
    alert_states.iter().filter(|&&a| a).count()
}

/// Where to land when switching to a space.
#[derive(Debug, PartialEq, Eq)]
pub enum LandingTarget {
    FocusPane { index: usize, level: u8 },
    Resume { level: u8, pane: usize },
}

/// Decide where to land when entering a space from the picker.
pub fn smart_landing(
    alert_states: &[bool],
    prev_level: u8,
    prev_pane: usize,
) -> LandingTarget {
    let alert_count = count_alerts(alert_states);

    if alert_count == 1 {
        let index = alert_states.iter().position(|&a| a).unwrap();
        LandingTarget::FocusPane { index, level: 2 }
    } else {
        let capped_level = if prev_level >= 3 { 2 } else { prev_level };
        LandingTarget::Resume { level: capped_level, pane: prev_pane }
    }
}
