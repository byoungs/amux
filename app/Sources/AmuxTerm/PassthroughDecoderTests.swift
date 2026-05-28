// PassthroughDecoderTests.swift -- unit tests for the tmux DCS passthrough
// unwrapper. The VTerminalTests in this same target exercise the end-to-end
// OSC 52 path; these tests pin the byte-stream behavior of the decoder itself.

#if DEBUG
import Foundation

enum PassthroughDecoderTests {
    static func runAll() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else {
                failed += 1
                // stderr: line-buffered, survives fatalError below.
                fputs("FAIL \(name): \(msg)\n", stderr)
            }
        }
        func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

        // --- Test 1: bytes outside a passthrough are forwarded verbatim ---
        do {
            var d = PassthroughDecoder()
            let out = d.process(Data("hello\u{1B}[Hworld".utf8))
            check("forward-non-passthrough",
                  out == bytes("hello\u{1B}[Hworld"),
                  "got \(out)")
        }

        // --- Test 2: full tmux passthrough wraps OSC 52 ---
        // \ePtmux;\e\e]52;c;Zm9v\e\e\\\e\\ → \e]52;c;Zm9v\e\\
        do {
            var d = PassthroughDecoder()
            let out = d.process(Data("\u{1B}Ptmux;\u{1B}\u{1B}]52;c;Zm9v\u{1B}\u{1B}\\\u{1B}\\".utf8))
            check("unwrap-osc52",
                  out == bytes("\u{1B}]52;c;Zm9v\u{1B}\\"),
                  "got \(String(decoding: out, as: UTF8.self).debugDescription)")
        }

        // --- Test 3: BEL inside body is body data, not a passthrough terminator ---
        // A DCS string terminates only on \e\\ (ST). 0x07 in the body is data
        // and must be forwarded. Regression test for the original implementation
        // that treated BEL as a DCS terminator and silently dropped it.
        do {
            var d = PassthroughDecoder()
            let out = d.process(Data("\u{1B}Ptmux;A\u{07}B\u{1B}\\".utf8))
            check("bel-mid-body-forwarded",
                  out == bytes("A\u{07}B"),
                  "got \(out)")
        }

        // --- Test 4: BEL-terminated inner OSC 52 inside tmux passthrough ---
        // tmux only doubles ESC, never BEL. So an inner OSC that uses BEL as
        // its own terminator (\e]52;c;<b64>\a) arrives in the body as a raw
        // 0x07. The decoder must forward the BEL so libvterm sees a complete
        // OSC; otherwise the inner sequence loses its terminator (the trailing
        // wrapper ST happens to rescue this particular case, but only after a
        // BEL drop has already broken ESC-undoubling for any following bytes).
        do {
            var d = PassthroughDecoder()
            let payload = "Zm9v" // base64 of "foo"
            let inp = "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;\(payload)\u{07}\u{1B}\\"
            let out = d.process(Data(inp.utf8))
            check("bel-terminator-preserved",
                  out == bytes("\u{1B}]52;c;\(payload)\u{07}"),
                  "got \(String(decoding: out, as: UTF8.self).debugDescription)")
        }

        // --- Test 5: BEL mid-body followed by doubled-ESC content ---
        // The most damaging shape of the BEL bug: after dropping the BEL the
        // decoder leaves .body, so a subsequent \e\e is not undoubled — two
        // literal ESCs leak through and corrupt the inner sequence.
        do {
            var d = PassthroughDecoder()
            let out = d.process(Data("\u{1B}Ptmux;X\u{07}\u{1B}\u{1B}Y\u{1B}\\".utf8))
            check("bel-then-doubled-esc-undoubled",
                  out == bytes("X\u{07}\u{1B}Y"),
                  "got \(out)")
        }

        // --- Test 6: passthrough body split across process() calls ---
        // State (and any in-flight pending) must carry across calls.
        do {
            var d = PassthroughDecoder()
            let full = "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;Zm9v\u{1B}\u{1B}\\\u{1B}\\"
            let raw = Array(full.utf8)
            var out: [UInt8] = []
            let third = raw.count / 3
            out.append(contentsOf: d.process(Data(raw[..<third])))
            out.append(contentsOf: d.process(Data(raw[third..<(2 * third)])))
            out.append(contentsOf: d.process(Data(raw[(2 * third)...])))
            check("split-write",
                  out == bytes("\u{1B}]52;c;Zm9v\u{1B}\\"),
                  "got \(out)")
        }

        // --- Test 7: non-tmux DCS (DECRQSS) passes through verbatim ---
        do {
            var d = PassthroughDecoder()
            let out = d.process(Data("A\u{1B}P1$qm\u{1B}\\B".utf8))
            check("non-tmux-dcs-verbatim",
                  out == bytes("A\u{1B}P1$qm\u{1B}\\B"),
                  "got \(out)")
        }

        // --- Test 8: lone ESC at top level is forwarded once a non-P follows ---
        do {
            var d = PassthroughDecoder()
            let out = d.process(Data("\u{1B}[H".utf8))
            check("lone-esc-csi",
                  out == bytes("\u{1B}[H"),
                  "got \(out)")
        }

        print("PassthroughDecoder tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("PassthroughDecoder tests failed") }
    }
}
#endif
