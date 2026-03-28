#[test]
fn smart_land_one_alert_goes_to_that_pane() {
    let result = amux::alert::smart_landing(&[false, true, false], 2, 1);
    assert_eq!(
        result,
        amux::alert::LandingTarget::FocusPane { index: 1, level: 2 }
    );
}

#[test]
fn smart_land_no_alerts_resumes() {
    let result = amux::alert::smart_landing(&[false, false, false], 3, 0);
    assert_eq!(
        result,
        amux::alert::LandingTarget::Resume { level: 2, pane: 0 }
    );
}

#[test]
fn smart_land_multiple_alerts_resumes() {
    let result = amux::alert::smart_landing(&[true, true, false], 2, 0);
    assert_eq!(
        result,
        amux::alert::LandingTarget::Resume { level: 2, pane: 0 }
    );
}

#[test]
fn smart_land_was_at_level3_caps_at_level2() {
    let result = amux::alert::smart_landing(&[false, false], 3, 1);
    assert_eq!(
        result,
        amux::alert::LandingTarget::Resume { level: 2, pane: 1 }
    );
}

#[test]
fn smart_land_was_at_level1_caps_to_level2() {
    let result = amux::alert::smart_landing(&[false, false], 1, 0);
    assert_eq!(
        result,
        amux::alert::LandingTarget::Resume { level: 2, pane: 0 }
    );
}

#[test]
fn count_alerts_returns_count_of_true() {
    assert_eq!(amux::alert::count_alerts(&[true, false, true, false]), 2);
    assert_eq!(amux::alert::count_alerts(&[false, false]), 0);
    assert_eq!(amux::alert::count_alerts(&[true]), 1);
}
