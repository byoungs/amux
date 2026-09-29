/// Clipboard: Cmd-C copies tmux's paste buffer to the macOS pasteboard.
/// What reaches the pasteboard must be the buffer exactly — the executor
/// trims output, and a trimmed copy loses the first line's indentation.

import Foundation
import AmuxLib

enum ClipboardTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        let ts = TestSession(paneCount: 1)
        _ = ts

        do {
            let text = "    indented\n\tline two\n\n"
            tmux("set-buffer", text)
            let got = Tmux.pasteBuffer()
            check("pasteBuffer-exact", got == text,
                  "got \(String(reflecting: got))")
        }

        do {
            let text = "no trailing newline"
            tmux("set-buffer", text)
            check("pasteBuffer-noNewline", Tmux.pasteBuffer() == text)
        }

        do {
            // Drain every buffer: with none, there is nothing to copy.
            for _ in 0..<50 where tmux("delete-buffer").success {}
            check("pasteBuffer-noneIsNil", Tmux.pasteBuffer() == nil)
        }

        print("ClipboardTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
