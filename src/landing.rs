// src/landing.rs — Pure navigation logic for space switching.
// Decides where to land when entering a space from the picker.

/// Where to land when switching to a space.
#[derive(Debug, PartialEq, Eq)]
pub enum LandingTarget {
    FocusPane { index: usize },
    Resume { pane: usize },
}

/// Decide where to land when entering a space from the picker.
///
/// If any pane has an alert, focus the first alerted pane.
/// Otherwise resume on the previously active pane.
pub fn smart_landing(alert_states: &[bool], prev_pane: usize) -> LandingTarget {
    match alert_states.iter().position(|&a| a) {
        Some(index) => LandingTarget::FocusPane { index },
        None => LandingTarget::Resume { pane: prev_pane },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_alerts_resumes_previous_pane() {
        let result = smart_landing(&[false, false, false], 2);
        assert_eq!(result, LandingTarget::Resume { pane: 2 });
    }

    #[test]
    fn single_alert_focuses_that_pane() {
        let result = smart_landing(&[false, true, false], 0);
        assert_eq!(result, LandingTarget::FocusPane { index: 1 });
    }

    #[test]
    fn multiple_alerts_focuses_first() {
        let result = smart_landing(&[false, true, true], 0);
        assert_eq!(result, LandingTarget::FocusPane { index: 1 });
    }

    #[test]
    fn all_alerted_focuses_first() {
        let result = smart_landing(&[true, true, true], 2);
        assert_eq!(result, LandingTarget::FocusPane { index: 0 });
    }

    #[test]
    fn empty_alert_states_resumes() {
        let result = smart_landing(&[], 0);
        assert_eq!(result, LandingTarget::Resume { pane: 0 });
    }
}
