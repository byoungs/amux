use amux::bell::{scan_bytes, ScanState};

/// Count attention signals (bare BEL + OSC 9/777 notifications)
fn bells(data: &[u8]) -> usize {
    let mut state = ScanState::new();
    scan_bytes(&mut state, data)
}

#[test]
fn bare_bel_detected() {
    assert_eq!(bells(b"\x07"), 1);
}

#[test]
fn multiple_bels() {
    assert_eq!(bells(b"\x07\x07\x07"), 3);
}

#[test]
fn osc_bel_terminator_not_detected() {
    assert_eq!(bells(b"\x1b]0;window title\x07"), 0);
}

#[test]
fn osc_st_terminator_no_bells() {
    assert_eq!(bells(b"\x1b]0;title\x1b\\"), 0);
}

#[test]
fn bel_after_osc_detected() {
    assert_eq!(bells(b"\x1b]0;title\x07\x07"), 1);
}

#[test]
fn dcs_bel_terminator_not_detected() {
    assert_eq!(bells(b"\x1bPdata\x07"), 0);
}

#[test]
fn apc_bel_terminator_not_detected() {
    assert_eq!(bells(b"\x1b_data\x07"), 0);
}

#[test]
fn pm_bel_terminator_not_detected() {
    assert_eq!(bells(b"\x1b^data\x07"), 0);
}

#[test]
fn csi_sequence_no_bells() {
    assert_eq!(bells(b"\x1b[31m"), 0);
}

#[test]
fn mixed_content_bare_bel_and_osc9() {
    // bare BEL + OSC 9 notification = 2 alerts
    assert_eq!(bells(b"hello\x07world\x1b]9;notify\x07"), 2);
}

#[test]
fn empty_input() {
    assert_eq!(bells(b""), 0);
}

#[test]
fn bel_in_text() {
    assert_eq!(bells(b"hello\x07world"), 1);
}

#[test]
fn osc9_notification_detected() {
    // OSC 9 is an explicit notification request — should trigger alert
    assert_eq!(bells(b"\x1b]9;Claude Code needs attention\x07"), 1);
}

#[test]
fn state_carries_across_chunks() {
    let mut state = ScanState::new();
    let count1 = scan_bytes(&mut state, b"\x1b]0;ti");
    let count2 = scan_bytes(&mut state, b"tle\x07");
    assert_eq!(count1 + count2, 0, "BEL terminating split OSC should not count");
}

#[test]
fn esc_then_normal_char_then_bel() {
    assert_eq!(bells(b"\x1bX\x07"), 1);
}

#[test]
fn only_text_no_bells() {
    assert_eq!(bells(b"just normal text with no special characters"), 0);
}

// --- OSC 9/777 notification detection ---

#[test]
fn osc9_with_st_terminator_detected() {
    // OSC 9 terminated by ST (ESC \) instead of BEL
    assert_eq!(bells(b"\x1b]9;message\x1b\\"), 1);
}

#[test]
fn osc777_notification_detected() {
    // OSC 777 is another notification sequence (used by some terminals)
    assert_eq!(bells(b"\x1b]777;notify;title;body\x07"), 1);
}

#[test]
fn osc0_title_change_not_detected() {
    // OSC 0 (window title) should NOT trigger alert
    assert_eq!(bells(b"\x1b]0;my window title\x07"), 0);
}

#[test]
fn osc2_title_change_not_detected() {
    // OSC 2 (window title) should NOT trigger alert
    assert_eq!(bells(b"\x1b]2;my window title\x07"), 0);
}

#[test]
fn osc99_not_detected() {
    // OSC 99 is NOT a notification — only 9 and 777 are
    assert_eq!(bells(b"\x1b]99;data\x07"), 0);
}

#[test]
fn osc9_split_across_chunks() {
    // OSC 9 split across two scan_bytes calls
    let mut state = ScanState::new();
    let count1 = scan_bytes(&mut state, b"\x1b]9;need");
    let count2 = scan_bytes(&mut state, b"s attention\x07");
    assert_eq!(count1 + count2, 1, "split OSC 9 should still be detected");
}

#[test]
fn bare_bel_after_osc9() {
    // OSC 9 followed by a bare BEL = 2 alerts
    assert_eq!(bells(b"\x1b]9;notif\x07\x07"), 2);
}

#[test]
fn osc9_no_semicolon_bel() {
    // Malformed: ESC ] 9 BEL (no semicolon, no body)
    // Still OSC 9, should detect
    assert_eq!(bells(b"\x1b]9\x07"), 1);
}
