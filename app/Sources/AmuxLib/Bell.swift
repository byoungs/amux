// Bell.swift -- Terminal notification scanner for tmux pipe-pane output.
//
// Detects two types of "needs attention" signals:
// 1. Bare BEL (0x07) -- traditional terminal bell
// 2. OSC 9 / OSC 777 sequences -- explicit notification requests
//    (ESC ] 9 ; message BEL  or  ESC ] 777 ; ... BEL)
//
// Ignores BEL used as terminator in other string sequences (OSC with
// different numbers, DCS, APC, PM). Pure logic -- no I/O.

/// Scanner state machine for detecting bell/notification sequences.
public class BellScanState {
    public enum State: Equatable {
        /// Default state -- processing normal output.
        case normal
        /// Just saw ESC (0x1B). Next byte determines sequence type.
        case esc
        /// Inside an OSC sequence -- collecting the numeric prefix to check for 9/777.
        case oscNum([UInt8])
        /// Inside an OSC body (after the semicolon). `isNotif` tracks whether
        /// the OSC number was 9 or 777.
        case oscBody(isNotif: Bool)
        /// Saw ESC inside an OSC body -- checking for ST (ESC \).
        case oscBodyEsc(isNotif: Bool)
        /// Inside a non-OSC string sequence (DCS/APC/PM). BEL is just a terminator.
        case stringSeq
        /// Saw ESC inside a non-OSC string sequence.
        case stringEsc
    }

    public var state: State = .normal

    public init() {}
}

/// Check if an OSC number buffer represents a notification sequence (9 or 777).
private func isNotificationOsc(_ num: [UInt8]) -> Bool {
    num == [UInt8(ascii: "9")] || num == Array("777".utf8)
}

/// Process a single byte through the state machine.
/// Returns true if an attention signal was detected.
private func scanByte(state: inout BellScanState.State, byte: UInt8) -> Bool {
    let current = state
    state = .normal

    switch (current, byte) {
    // Normal: BEL is a real bell
    case (.normal, 0x07):
        return true
    // Normal: ESC starts an escape sequence
    case (.normal, 0x1B):
        state = .esc
        return false
    // Normal: anything else
    case (.normal, _):
        return false

    // Esc: ] starts OSC -- need to collect the number
    case (.esc, UInt8(ascii: "]")):
        state = .oscNum([])
        return false
    // Esc: P _ ^ start non-OSC string sequences
    case (.esc, UInt8(ascii: "P")), (.esc, UInt8(ascii: "_")), (.esc, UInt8(ascii: "^")):
        state = .stringSeq
        return false
    // Esc: anything else -- not a string sequence
    case (.esc, _):
        return false // state already set to .normal

    // OscNum: semicolon ends the number, body begins
    case (.oscNum(let num), UInt8(ascii: ";")):
        state = .oscBody(isNotif: isNotificationOsc(num))
        return false
    // OscNum: BEL terminates OSC before any semicolon (e.g. ESC ] 9 BEL)
    case (.oscNum(let num), 0x07):
        return isNotificationOsc(num)
    // OscNum: ESC might start ST
    case (.oscNum(let num), 0x1B):
        state = .oscBodyEsc(isNotif: isNotificationOsc(num))
        return false
    // OscNum: digit -- accumulate
    case (.oscNum(var num), let b) where b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"):
        num.append(b)
        state = .oscNum(num)
        return false
    // OscNum: non-digit, non-semicolon -- treat as body start (malformed but safe)
    case (.oscNum(let num), _):
        state = .oscBody(isNotif: isNotificationOsc(num))
        return false

    // OscBody: BEL terminates -- alert if this was OSC 9/777
    case (.oscBody(let isNotif), 0x07):
        return isNotif
    // OscBody: ESC might be ST
    case (.oscBody(let isNotif), 0x1B):
        state = .oscBodyEsc(isNotif: isNotif)
        return false
    // OscBody: anything else -- still in body
    case (.oscBody(let isNotif), _):
        state = .oscBody(isNotif: isNotif)
        return false

    // OscBodyEsc: \ completes ST -- alert if this was OSC 9/777
    case (.oscBodyEsc(let isNotif), UInt8(ascii: "\\")):
        return isNotif
    // OscBodyEsc: anything else -- wasn't ST, still in body
    case (.oscBodyEsc(let isNotif), _):
        state = .oscBody(isNotif: isNotif)
        return false

    // StringSeq: BEL terminates (never an alert for DCS/APC/PM)
    case (.stringSeq, 0x07):
        return false // state already .normal
    // StringSeq: ESC might be ST
    case (.stringSeq, 0x1B):
        state = .stringEsc
        return false
    // StringSeq: anything else
    case (.stringSeq, _):
        state = .stringSeq
        return false

    // StringEsc: \ completes ST
    case (.stringEsc, UInt8(ascii: "\\")):
        return false // state already .normal
    // StringEsc: anything else -- still in sequence
    case (.stringEsc, _):
        state = .stringSeq
        return false

    default:
        return false
    }
}

/// Scan a buffer of bytes, returning the number of attention signals found.
/// Detects bare BEL characters and OSC 9/777 notification sequences.
/// State is maintained across calls for chunked input.
public func scanBytes(state: BellScanState, buf: [UInt8]) -> Int {
    var count = 0
    for byte in buf {
        if scanByte(state: &state.state, byte: byte) {
            count += 1
        }
    }
    return count
}

// MARK: - Tests

#if DEBUG
public enum BellTests {
    public static func runAll() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " -- \(message)")") }
        }

        // Test: bare BEL detected
        do {
            let s = BellScanState()
            let count = scanBytes(state: s, buf: [0x07])
            check("bare BEL detected", count == 1)
        }

        // Test: multiple bare BELs
        do {
            let s = BellScanState()
            let count = scanBytes(state: s, buf: [0x07, 0x07, 0x07])
            check("multiple bare BELs", count == 3)
        }

        // Test: no BEL in normal text
        do {
            let s = BellScanState()
            let count = scanBytes(state: s, buf: Array("hello world".utf8))
            check("no BEL in normal text", count == 0)
        }

        // Test: OSC 9 with BEL terminator
        do {
            let s = BellScanState()
            // ESC ] 9 ; message BEL
            let buf: [UInt8] = [0x1B, UInt8(ascii: "]"), UInt8(ascii: "9"),
                                UInt8(ascii: ";"), UInt8(ascii: "h"), UInt8(ascii: "i"), 0x07]
            let count = scanBytes(state: s, buf: buf)
            check("OSC 9 with BEL terminator", count == 1)
        }

        // Test: OSC 777 with BEL terminator
        do {
            let s = BellScanState()
            // ESC ] 777 ; message BEL
            let buf: [UInt8] = [0x1B, UInt8(ascii: "]"), UInt8(ascii: "7"),
                                UInt8(ascii: "7"), UInt8(ascii: "7"),
                                UInt8(ascii: ";"), UInt8(ascii: "x"), 0x07]
            let count = scanBytes(state: s, buf: buf)
            check("OSC 777 with BEL terminator", count == 1)
        }

        // Test: OSC 9 with ST terminator
        do {
            let s = BellScanState()
            // ESC ] 9 ; message ESC backslash
            let buf: [UInt8] = [0x1B, UInt8(ascii: "]"), UInt8(ascii: "9"),
                                UInt8(ascii: ";"), UInt8(ascii: "m"), 0x1B, UInt8(ascii: "\\")]
            let count = scanBytes(state: s, buf: buf)
            check("OSC 9 with ST terminator", count == 1)
        }

        // Test: non-notification OSC (e.g. OSC 0 title set) does not trigger
        do {
            let s = BellScanState()
            // ESC ] 0 ; title BEL
            let buf: [UInt8] = [0x1B, UInt8(ascii: "]"), UInt8(ascii: "0"),
                                UInt8(ascii: ";"), UInt8(ascii: "t"), 0x07]
            let count = scanBytes(state: s, buf: buf)
            check("non-notification OSC ignored", count == 0)
        }

        // Test: DCS sequence BEL is ignored
        do {
            let s = BellScanState()
            // ESC P ... BEL
            let buf: [UInt8] = [0x1B, UInt8(ascii: "P"), UInt8(ascii: "x"), 0x07]
            let count = scanBytes(state: s, buf: buf)
            check("DCS BEL ignored", count == 0)
        }

        // Test: APC sequence BEL is ignored
        do {
            let s = BellScanState()
            // ESC _ ... BEL
            let buf: [UInt8] = [0x1B, UInt8(ascii: "_"), UInt8(ascii: "x"), 0x07]
            let count = scanBytes(state: s, buf: buf)
            check("APC BEL ignored", count == 0)
        }

        // Test: PM sequence BEL is ignored
        do {
            let s = BellScanState()
            // ESC ^ ... BEL
            let buf: [UInt8] = [0x1B, UInt8(ascii: "^"), UInt8(ascii: "x"), 0x07]
            let count = scanBytes(state: s, buf: buf)
            check("PM BEL ignored", count == 0)
        }

        // Test: chunked input across calls
        do {
            let s = BellScanState()
            // Send ESC ] 9 ; in first chunk
            let chunk1: [UInt8] = [0x1B, UInt8(ascii: "]"), UInt8(ascii: "9"), UInt8(ascii: ";")]
            let c1 = scanBytes(state: s, buf: chunk1)
            check("chunked input part 1 no alert yet", c1 == 0)
            // Send message BEL in second chunk
            let chunk2: [UInt8] = [UInt8(ascii: "m"), 0x07]
            let c2 = scanBytes(state: s, buf: chunk2)
            check("chunked input part 2 alert detected", c2 == 1)
        }

        // Test: mixed content - BEL + OSC 9 + normal text
        do {
            let s = BellScanState()
            var buf: [UInt8] = [0x07] // bare BEL
            buf.append(contentsOf: [UInt8(ascii: "A"), UInt8(ascii: "B")]) // normal
            buf.append(contentsOf: [0x1B, UInt8(ascii: "]"), UInt8(ascii: "9"),
                                    UInt8(ascii: ";"), UInt8(ascii: "x"), 0x07]) // OSC 9
            let count = scanBytes(state: s, buf: buf)
            check("mixed content detects both", count == 2)
        }

        // Test: OSC 9 BEL without semicolon
        do {
            let s = BellScanState()
            // ESC ] 9 BEL (no semicolon)
            let buf: [UInt8] = [0x1B, UInt8(ascii: "]"), UInt8(ascii: "9"), 0x07]
            let count = scanBytes(state: s, buf: buf)
            check("OSC 9 BEL without semicolon", count == 1)
        }

        // Test: string sequence ST terminator is not an alert
        do {
            let s = BellScanState()
            // ESC P ... ESC backslash
            let buf: [UInt8] = [0x1B, UInt8(ascii: "P"), UInt8(ascii: "x"), 0x1B, UInt8(ascii: "\\")]
            let count = scanBytes(state: s, buf: buf)
            check("string sequence ST not alert", count == 0)
        }

        print("Bell tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("Bell tests failed") }
    }
}
#endif
