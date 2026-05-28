// Osc52Reproducer.swift -- end-to-end check for the OSC 52 fix.
//
// Drives a VTerminal in-process with the exact byte sequences from the bug
// report (`echo … | base64` payloads wrapped in raw OSC 52 and in tmux DCS
// passthrough) and verifies each lands on the macOS general pasteboard.
// The unit tests in VTerminalTests cover the decoder/parser plumbing with an
// injected sink — this reproducer additionally exercises the real
// NSPasteboard write that the user observes via `pbpaste`.

#if DEBUG
import AppKit
import Foundation

enum Osc52Reproducer {
    /// Returns true if both reproducer cases push their payloads to the
    /// pasteboard. Restores the prior pasteboard contents before returning so
    /// the test doesn't trample the user's clipboard.
    static func run() -> Bool {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            pb.clearContents()
            if let s = saved { pb.setString(s, forType: .string) }
        }

        var allOk = true

        // Case 1: raw OSC 52 (no DCS wrapper). Equivalent to the bug's
        // "Control" reproducer.
        do {
            let payload = "osc52-direct-BBBB"
            let sentinel = "sentinel-A"
            pb.clearContents()
            pb.setString(sentinel, forType: .string)

            let term = VTerminal(rows: 24, cols: 80)
            let b64 = Data(payload.utf8).base64EncodedString()
            let seq = "\u{1B}]52;c;\(b64)\u{1B}\\"
            term.write(data: seq.data(using: .utf8)!)

            let got = pb.string(forType: .string) ?? ""
            let ok = (got == payload)
            print("OSC 52 direct: \(ok ? "PASS" : "FAIL")  expected=\(payload) got=\(got)")
            allOk = allOk && ok
        }

        // Case 2: OSC 52 wrapped in tmux DCS passthrough. Matches the bug's
        // primary reproducer byte-for-byte.
        do {
            let payload = "osc52-probe-AAAA"
            let sentinel = "sentinel-A"
            pb.clearContents()
            pb.setString(sentinel, forType: .string)

            let term = VTerminal(rows: 24, cols: 80)
            let b64 = Data(payload.utf8).base64EncodedString()
            let seq = "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;\(b64)\u{1B}\u{1B}\\\u{1B}\\"
            term.write(data: seq.data(using: .utf8)!)

            let got = pb.string(forType: .string) ?? ""
            let ok = (got == payload)
            print("OSC 52 tmux DCS passthrough: \(ok ? "PASS" : "FAIL")  expected=\(payload) got=\(got)")
            allOk = allOk && ok
        }

        return allOk
    }
}
#endif
