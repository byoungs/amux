#[test]
fn count_alerts_returns_count_of_true() {
    assert_eq!(amux::alert::count_alerts(&[true, false, true, false]), 2);
    assert_eq!(amux::alert::count_alerts(&[false, false]), 0);
    assert_eq!(amux::alert::count_alerts(&[true]), 1);
}
