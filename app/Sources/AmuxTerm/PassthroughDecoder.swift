// PassthroughDecoder.swift -- byte-stream pre-processor for tmux DCS passthrough.
//
// tmux wraps inner-app escape sequences as
//     \eP tmux; <body-with-doubled-ESCs> \e\\
// so that the outer terminal sees them after tmux's parser has been bypassed.
// libvterm's stock parser breaks on the doubled ESCs in the body (the second
// ESC of a pair lands in DCS string state where libvterm aborts to NORMAL
// instead of treating it as data), so the body never reaches the OSC dispatcher
// and OSC 52 inside the passthrough is dropped.
//
// This decoder runs in front of vterm_input_write. It scans for
// `\eP tmux;…\e\\`, undoubles the body's ESCs, strips the wrapper, and emits
// the contained sequence (typically `\e]52;c;…\e\\`) for vterm to parse.
// Everything outside a tmux passthrough is forwarded byte-for-byte.

import Foundation

struct PassthroughDecoder {
    private enum State {
        case normal
        case sawEsc              // saw ESC at top level
        case checkTmux(Int)      // saw "\eP" + first n bytes of "tmux;"
        case body                // inside passthrough body
        case bodyEsc             // saw ESC inside body, awaiting next byte
    }

    private static let tmuxSig: [UInt8] = [0x74, 0x6D, 0x75, 0x78, 0x3B] // "tmux;"

    private var state: State = .normal
    // Bytes already consumed for a possible-tmux-DCS match. Flushed to output
    // if the match fails.
    private var pending: [UInt8] = []

    mutating func process(_ input: Data) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        for byte in input {
            step(byte, &out)
        }
        return out
    }

    private mutating func step(_ byte: UInt8, _ out: inout [UInt8]) {
        switch state {
        case .normal:
            if byte == 0x1B {
                pending = [0x1B]
                state = .sawEsc
            } else {
                out.append(byte)
            }

        case .sawEsc:
            if byte == 0x50 { // 'P'
                pending.append(byte)
                state = .checkTmux(0)
            } else {
                // Not a DCS — flush the saved ESC and reprocess this byte.
                out.append(0x1B)
                pending.removeAll()
                state = .normal
                step(byte, &out)
            }

        case .checkTmux(let n):
            if byte == PassthroughDecoder.tmuxSig[n] {
                pending.append(byte)
                if n == PassthroughDecoder.tmuxSig.count - 1 {
                    // Full "\ePtmux;" match. Drop the wrapper bytes.
                    pending.removeAll()
                    state = .body
                } else {
                    state = .checkTmux(n + 1)
                }
            } else {
                // Mismatch — not a tmux passthrough. Flush buffered prefix and
                // reprocess this byte from .normal so a stray ESC still starts
                // a new attempt.
                out.append(contentsOf: pending)
                pending.removeAll()
                state = .normal
                step(byte, &out)
            }

        case .body:
            // A DCS string terminates only on ST (\e\\); BEL is not a DCS
            // terminator. Forward every non-ESC byte as body data, including
            // 0x07 — which the inner sequence may legitimately use as its
            // own OSC terminator, and which tmux does not double.
            if byte == 0x1B {
                state = .bodyEsc
            } else {
                out.append(byte)
            }

        case .bodyEsc:
            if byte == 0x1B {
                // Doubled ESC → emit one literal ESC into the body.
                out.append(0x1B)
                state = .body
            } else if byte == 0x5C {
                // ESC \ → DCS terminator (ST). Passthrough complete.
                state = .normal
            } else {
                // Unusual: single ESC followed by something else. Pass both
                // through and resume body collection.
                out.append(0x1B)
                out.append(byte)
                state = .body
            }
        }
    }
}
