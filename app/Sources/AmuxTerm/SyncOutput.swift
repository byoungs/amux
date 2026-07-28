// SyncOutput.swift -- DEC 2026 synchronized output (BSU/ESU) tracking.
//
// amux advertises `sync` in tmux's terminal-features (Config.swift), so tmux
// brackets every screen update it sends us in
//     ESC [ ? 2026 h   … update …   ESC [ ? 2026 l
// meaning "do not paint anything between these; the screen is inconsistent."
//
// libvterm has no DEC 2026 support at all, so nothing downstream honors that
// contract. It matters because the kernel pty hands amux the stream in ~1024
// byte reads and amux paints one frame per read: an update larger than a chunk
// gets torn, and the frame painted from the torn prefix shows tmux's scratch
// state — cursor hidden, parked wherever it was drawing. The next chunk puts it
// back. That off/on cycle is the cursor flicker.
//
// This scanner runs over the same bytes fed to libvterm and tracks whether an
// update is open. TerminalView holds its frame while one is.

import Foundation

/// Tracks whether tmux currently has a synchronized-output update open.
///
/// Byte-at-a-time so a BSU/ESU split across two pty reads is still recognized —
/// the split is the whole reason this exists.
struct SyncOutputScanner {
    private enum State {
        case normal
        case sawEsc          // ESC
        case sawCSI          // ESC [
        case params          // ESC [ ? …digits and semicolons…
    }

    /// True once BSU was seen and its matching ESU has not been.
    ///
    /// Not a nesting counter: DEC 2026 leaves nesting undefined, and terminals
    /// that implement it (Ghostty, kitty) treat a second BSU as a no-op and any
    /// ESU as ending the update. Matching that is what keeps a dropped ESU from
    /// wedging the gate.
    private(set) var isInsideUpdate = false

    private var state: State = .normal
    /// Digits of the parameter currently being read. Params before it are
    /// irrelevant — only whether *some* param is 2026 matters — so a single
    /// accumulator is enough.
    private var param: Int = 0
    /// Guards against a malformed run of digits overflowing `param`.
    private var paramDigits: Int = 0
    private var sawSyncParam = false

    mutating func scan(_ bytes: [UInt8]) {
        for byte in bytes {
            step(byte)
        }
    }

    private mutating func step(_ byte: UInt8) {
        switch state {
        case .normal:
            if byte == 0x1B { state = .sawEsc }

        case .sawEsc:
            // A fresh ESC restarts the match; anything else is not a CSI.
            if byte == 0x5B { state = .sawCSI }        // '['
            else if byte == 0x1B { state = .sawEsc }
            else { state = .normal }

        case .sawCSI:
            if byte == 0x3F {                          // '?' — private mode
                state = .params
                param = 0
                paramDigits = 0
                sawSyncParam = false
            } else if byte == 0x1B {
                state = .sawEsc
            } else {
                state = .normal
            }

        case .params:
            switch byte {
            case 0x30...0x39:                          // '0'-'9'
                if paramDigits < 6 {
                    param = param * 10 + Int(byte - 0x30)
                    paramDigits += 1
                } else {
                    param = -1                          // absurd; cannot be 2026
                }
            case 0x3B:                                  // ';' — next parameter
                if param == 2026 { sawSyncParam = true }
                param = 0
                paramDigits = 0
            case 0x68, 0x6C:                            // 'h' set / 'l' reset
                if param == 2026 { sawSyncParam = true }
                if sawSyncParam { isInsideUpdate = (byte == 0x68) }
                state = .normal
            case 0x1B:
                state = .sawEsc
            default:
                // Intermediate or other final byte (e.g. the '$' of the DECRQM
                // query `ESC [ ? 2026 $ p`) — not a set/reset, so it changes
                // nothing.
                state = .normal
            }
        }
    }
}

/// Policy for how long a frame may be held waiting for an ESU.
enum SyncOutput {
    /// tmux closes an update within microseconds, so this never fires in normal
    /// operation. It exists so a client that dies mid-update — or a stream that
    /// loses the ESU — degrades to a brief stall instead of a frozen window.
    static let holdTimeout: TimeInterval = 0.15

    /// True once a held frame has waited longer than `timeout` and must be
    /// painted regardless of the missing ESU.
    static func holdExpired(openedAt: TimeInterval, now: TimeInterval,
                            timeout: TimeInterval) -> Bool {
        now - openedAt >= timeout
    }
}
