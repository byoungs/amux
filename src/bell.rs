// src/bell.rs — Terminal notification scanner for tmux pipe-pane output.
//
// Detects two types of "needs attention" signals:
// 1. Bare BEL (0x07) — traditional terminal bell
// 2. OSC 9 / OSC 777 sequences — explicit notification requests
//    (ESC ] 9 ; message BEL  or  ESC ] 777 ; ... BEL)
//
// Ignores BEL used as terminator in other string sequences (OSC with
// different numbers, DCS, APC, PM). Pure logic — no I/O.

/// Scanner state machine.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum ScanState {
    /// Default state — processing normal output.
    #[default]
    Normal,
    /// Just saw ESC (0x1B). Next byte determines sequence type.
    Esc,
    /// Inside an OSC sequence — collecting the numeric prefix to check for 9/777.
    OscNum(Vec<u8>),
    /// Inside an OSC body (after the semicolon). `is_notif` tracks whether
    /// the OSC number was 9 or 777.
    OscBody { is_notif: bool },
    /// Saw ESC inside an OSC body — checking for ST (ESC \).
    OscBodyEsc { is_notif: bool },
    /// Inside a non-OSC string sequence (DCS/APC/PM). BEL is just a terminator.
    StringSeq,
    /// Saw ESC inside a non-OSC string sequence.
    StringEsc,
}

impl ScanState {
    pub fn new() -> Self {
        Self::default()
    }
}

/// Check if an OSC number buffer represents a notification sequence (9 or 777).
fn is_notification_osc(num: &[u8]) -> bool {
    num == b"9" || num == b"777"
}

/// Process a single byte through the state machine.
/// Returns true if an attention signal was detected.
fn scan_byte(state: &mut ScanState, byte: u8) -> bool {
    // Take ownership of state to allow moving out of enum variants
    let current = std::mem::replace(state, ScanState::Normal);

    match (current, byte) {
        // Normal: BEL is a real bell
        (ScanState::Normal, 0x07) => true,
        // Normal: ESC starts an escape sequence
        (ScanState::Normal, 0x1B) => {
            *state = ScanState::Esc;
            false
        }
        // Normal: anything else
        (ScanState::Normal, _) => false,

        // Esc: ] starts OSC — need to collect the number
        (ScanState::Esc, b']') => {
            *state = ScanState::OscNum(Vec::new());
            false
        }
        // Esc: P _ ^ start non-OSC string sequences
        (ScanState::Esc, b'P' | b'_' | b'^') => {
            *state = ScanState::StringSeq;
            false
        }
        // Esc: anything else — not a string sequence
        (ScanState::Esc, _) => false, // state already set to Normal

        // OscNum: semicolon ends the number, body begins
        (ScanState::OscNum(num), b';') => {
            let is_notif = is_notification_osc(&num);
            *state = ScanState::OscBody { is_notif };
            false
        }
        // OscNum: BEL terminates OSC before any semicolon (e.g. ESC ] 9 BEL)
        (ScanState::OscNum(num), 0x07) => is_notification_osc(&num),
        // OscNum: ESC might start ST
        (ScanState::OscNum(num), 0x1B) => {
            let is_notif = is_notification_osc(&num);
            *state = ScanState::OscBodyEsc { is_notif };
            false
        }
        // OscNum: digit — accumulate
        (ScanState::OscNum(mut num), b) if b.is_ascii_digit() => {
            num.push(b);
            *state = ScanState::OscNum(num);
            false
        }
        // OscNum: non-digit, non-semicolon — treat as body start (malformed but safe)
        (ScanState::OscNum(num), _) => {
            let is_notif = is_notification_osc(&num);
            *state = ScanState::OscBody { is_notif };
            false
        }

        // OscBody: BEL terminates — alert if this was OSC 9/777
        (ScanState::OscBody { is_notif }, 0x07) => is_notif,
        // OscBody: ESC might be ST
        (ScanState::OscBody { is_notif }, 0x1B) => {
            *state = ScanState::OscBodyEsc { is_notif };
            false
        }
        // OscBody: anything else — still in body
        (ScanState::OscBody { is_notif }, _) => {
            *state = ScanState::OscBody { is_notif };
            false
        }

        // OscBodyEsc: \ completes ST — alert if this was OSC 9/777
        (ScanState::OscBodyEsc { is_notif }, b'\\') => is_notif,
        // OscBodyEsc: anything else — wasn't ST, still in body
        (ScanState::OscBodyEsc { is_notif }, _) => {
            *state = ScanState::OscBody { is_notif };
            false
        }

        // StringSeq: BEL terminates (never an alert for DCS/APC/PM)
        (ScanState::StringSeq, 0x07) => false, // state already Normal
        // StringSeq: ESC might be ST
        (ScanState::StringSeq, 0x1B) => {
            *state = ScanState::StringEsc;
            false
        }
        // StringSeq: anything else
        (ScanState::StringSeq, _) => {
            *state = ScanState::StringSeq;
            false
        }

        // StringEsc: \ completes ST
        (ScanState::StringEsc, b'\\') => false, // state already Normal
        // StringEsc: anything else — still in sequence
        (ScanState::StringEsc, _) => {
            *state = ScanState::StringSeq;
            false
        }
    }
}

/// Scan a buffer of bytes, returning the number of attention signals found.
/// Detects bare BEL characters and OSC 9/777 notification sequences.
/// State is maintained across calls for chunked input.
pub fn scan_bytes(state: &mut ScanState, data: &[u8]) -> usize {
    let mut count = 0;
    for &byte in data {
        if scan_byte(state, byte) {
            count += 1;
        }
    }
    count
}
