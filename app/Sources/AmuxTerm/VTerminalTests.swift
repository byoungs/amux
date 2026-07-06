#if DEBUG
import Foundation
import CVterm

enum VTerminalTests {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                passed += 1
            } else {
                failed += 1
                FileHandle.standardError.write("FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")\n".data(using: .utf8)!)
            }
        }

        // --- Test 1: Dirty rows tracked on character input ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.fullRedrawNeeded = false
            term.dirtyRows.removeAll()
            term.write(data: "abc".data(using: .utf8)!)
            term.flushDamage()
            check("dirty-rows-char-input",
                  term.dirtyRows.contains(0),
                  "expected row 0 dirty, got \(term.dirtyRows)")
        }

        // --- Test 2: Dirty rows tracked on newline ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.fullRedrawNeeded = false
            term.dirtyRows.removeAll()
            term.write(data: "abc\r\ndef".data(using: .utf8)!)
            term.flushDamage()
            check("dirty-rows-newline-row0",
                  term.dirtyRows.contains(0),
                  "expected row 0 dirty")
            check("dirty-rows-newline-row1",
                  term.dirtyRows.contains(1),
                  "expected row 1 dirty")
        }

        // --- Test 3: Only dirty rows are marked, not all rows ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.fullRedrawNeeded = false
            term.dirtyRows.removeAll()
            term.write(data: "x".data(using: .utf8)!)
            term.flushDamage()
            check("dirty-rows-minimal",
                  term.dirtyRows.count <= 2,
                  "expected <= 2 dirty rows for single char, got \(term.dirtyRows.count)")
            check("dirty-rows-no-row10",
                  !term.dirtyRows.contains(10),
                  "row 10 should not be dirty")
        }

        // --- Test 4: Backspace damages the correct row ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.write(data: "abc".data(using: .utf8)!)
            term.flushDamage()
            term.dirtyRows.removeAll()
            // Backspace echo: \b \b (move back, space, move back)
            term.write(data: "\u{08} \u{08}".data(using: .utf8)!)
            term.flushDamage()
            check("dirty-rows-backspace",
                  term.dirtyRows.contains(0),
                  "expected row 0 dirty after backspace")
            check("dirty-rows-backspace-minimal",
                  term.dirtyRows.count <= 2,
                  "backspace should dirty 1-2 rows, got \(term.dirtyRows.count)")
        }

        // --- Test 5: Cursor position tracks correctly ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.write(data: "hello".data(using: .utf8)!)
            term.flushDamage()
            check("cursor-after-text",
                  term.cursorCol == 5 && term.cursorRow == 0,
                  "expected (0,5), got (\(term.cursorRow),\(term.cursorCol))")

            term.write(data: "\r\n".data(using: .utf8)!)
            term.flushDamage()
            check("cursor-after-newline",
                  term.cursorRow == 1 && term.cursorCol == 0,
                  "expected (1,0), got (\(term.cursorRow),\(term.cursorCol))")
        }

        // --- Test 6: Full redraw flag on resize ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.fullRedrawNeeded = false
            term.resize(rows: 30, cols: 100)
            check("full-redraw-on-resize",
                  term.fullRedrawNeeded,
                  "expected fullRedrawNeeded after resize")
        }

        // --- Test 7: Cell content round-trip through edits ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.write(data: "XYZ".data(using: .utf8)!)
            term.flushDamage()
            let cellX = VTerminal.cellString(term.cell(row: 0, col: 0))
            let cellY = VTerminal.cellString(term.cell(row: 0, col: 1))
            let cellZ = VTerminal.cellString(term.cell(row: 0, col: 2))
            check("cell-content-X", cellX == "X", "got '\(cellX)'")
            check("cell-content-Y", cellY == "Y", "got '\(cellY)'")
            check("cell-content-Z", cellZ == "Z", "got '\(cellZ)'")

            // Backspace erases Z
            term.write(data: "\u{08} \u{08}".data(using: .utf8)!)
            term.flushDamage()
            let cellAfter = VTerminal.cellString(term.cell(row: 0, col: 2))
            check("cell-after-backspace",
                  cellAfter == "" || cellAfter == " ",
                  "expected empty or space after backspace, got '\(cellAfter)'")
        }

        // --- Test 8: DECSET 1049 flips isAltScreen ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            check("altscreen-default-false", term.isAltScreen == false)
            term.write(data: "\u{1B}[?1049h".data(using: .utf8)!)
            term.flushDamage()
            check("altscreen-decset-true", term.isAltScreen == true)
            term.write(data: "\u{1B}[?1049l".data(using: .utf8)!)
            term.flushDamage()
            check("altscreen-decrst-false", term.isAltScreen == false)
        }

        // --- Test 9: DECSET 1000/1002/1003 updates mouseMode ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            check("mousemode-default-none", term.mouseMode == .none)
            term.write(data: "\u{1B}[?1000h".data(using: .utf8)!)
            term.flushDamage()
            check("mousemode-1000-click", term.mouseMode == .click)
            term.write(data: "\u{1B}[?1002h".data(using: .utf8)!)
            term.flushDamage()
            check("mousemode-1002-drag", term.mouseMode == .drag)
            term.write(data: "\u{1B}[?1003h".data(using: .utf8)!)
            term.flushDamage()
            check("mousemode-1003-move", term.mouseMode == .move)
            term.write(data: "\u{1B}[?1000l".data(using: .utf8)!)
            term.flushDamage()
            check("mousemode-decrst-none", term.mouseMode == .none)
        }

        // --- Test 10: OSC 52 set-clipboard routes to onSetClipboard ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            var captured: String? = nil
            term.onSetClipboard = { captured = $0 }
            let payload = "osc52-direct-BBBB"
            let b64 = Data(payload.utf8).base64EncodedString()
            // ESC ] 52 ; c ; <b64> ESC \
            let seq = "\u{1B}]52;c;\(b64)\u{1B}\\"
            term.write(data: seq.data(using: .utf8)!)
            check("osc52-direct-payload", captured == payload,
                  "expected '\(payload)', got '\(captured ?? "nil")'")
        }

        // --- Test 11: OSC 52 wrapped in tmux DCS passthrough ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            var captured: String? = nil
            term.onSetClipboard = { captured = $0 }
            let payload = "osc52-probe-AAAA"
            let b64 = Data(payload.utf8).base64EncodedString()
            // \ePtmux;\e\e]52;c;<b64>\e\e\\\e\\
            let seq = "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;\(b64)\u{1B}\u{1B}\\\u{1B}\\"
            term.write(data: seq.data(using: .utf8)!)
            check("osc52-tmux-passthrough", captured == payload,
                  "expected '\(payload)', got '\(captured ?? "nil")'")
        }

        // --- Test 12: tmux DCS passthrough split across write() calls ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            var captured: String? = nil
            term.onSetClipboard = { captured = $0 }
            let payload = "split-write-payload"
            let b64 = Data(payload.utf8).base64EncodedString()
            let seq = "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;\(b64)\u{1B}\u{1B}\\\u{1B}\\"
            // Split into three arbitrary chunks
            let bytes = Array(seq.utf8)
            let third = bytes.count / 3
            term.write(data: Data(bytes[..<third]))
            term.write(data: Data(bytes[third..<(2 * third)]))
            term.write(data: Data(bytes[(2 * third)...]))
            check("osc52-tmux-split-write", captured == payload,
                  "expected '\(payload)', got '\(captured ?? "nil")'")
        }

        // --- Test 13: ESC without DCS-P is forwarded transparently ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            // ESC [ H is CUP (home cursor). After "abc" + CUP + "X", X should
            // overwrite position 0,0.
            term.write(data: "abc\u{1B}[HX".data(using: .utf8)!)
            term.flushDamage()
            check("passthrough-non-dcs-esc",
                  VTerminal.cellString(term.cell(row: 0, col: 0)) == "X",
                  "expected X at (0,0)")
        }

        // --- Test 14: \eP non-tmux DCS does not trip the decoder ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            // ESC P 1 $ q m ESC \ — a DECRQSS request. Should pass through to
            // vterm (which will respond, harmlessly ignored here), and the
            // surrounding text should render normally.
            term.write(data: "A\u{1B}P1$qm\u{1B}\\B".data(using: .utf8)!)
            term.flushDamage()
            check("passthrough-non-tmux-dcs-A",
                  VTerminal.cellString(term.cell(row: 0, col: 0)) == "A",
                  "expected A at (0,0)")
            check("passthrough-non-tmux-dcs-B",
                  VTerminal.cellString(term.cell(row: 0, col: 1)) == "B",
                  "expected B at (0,1)")
        }

        // --- Test 15: Pure cursor move (no cell damage) marks the old row dirty ---
        // Regression: a cursor reposition with no cell changes (CUP, arrow keys,
        // TUI redraws) left dirtyRows empty, so the renderer scheduled no repaint
        // and the on-screen cursor stayed at its previous position.
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.write(data: "hello".data(using: .utf8)!)  // cursor at (0,5)
            term.flushDamage()
            term.fullRedrawNeeded = false
            term.dirtyRows.removeAll()
            // CUP to row 6, col 11 (1-based) — pure reposition, no cell damage
            term.write(data: "\u{1B}[6;11H".data(using: .utf8)!)
            term.flushDamage()
            check("cursor-move-position",
                  term.cursorRow == 5 && term.cursorCol == 10,
                  "expected (5,10), got (\(term.cursorRow),\(term.cursorCol))")
            check("cursor-move-old-row-dirty",
                  term.dirtyRows.contains(0),
                  "expected old cursor row 0 dirty, got \(term.dirtyRows)")
        }

        // --- Test 16: Same-row pure cursor move still flags the row ---
        // Moving left within a row repaints nothing without this: the cursor
        // block lingers at the old column.
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.write(data: "hello".data(using: .utf8)!)  // cursor at (0,5)
            term.flushDamage()
            term.fullRedrawNeeded = false
            term.dirtyRows.removeAll()
            term.write(data: "\u{1B}[2D".data(using: .utf8)!)  // CUB 2 → (0,3)
            term.flushDamage()
            check("cursor-move-same-row-position",
                  term.cursorRow == 0 && term.cursorCol == 3,
                  "expected (0,3), got (\(term.cursorRow),\(term.cursorCol))")
            check("cursor-move-same-row-dirty",
                  term.dirtyRows.contains(0),
                  "expected row 0 dirty after in-row cursor move, got \(term.dirtyRows)")
        }

        // --- Test 17: OSC 8 hyperlink stamps the label's cells ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.write(data: "see \u{1B}]8;;https://example.com\u{1B}\\LINK\u{1B}]8;;\u{1B}\\ done".data(using: .utf8)!)
            term.flushDamage()
            check("osc8-label-stamped",
                  term.hyperlinkURI(row: 0, col: 4) == "https://example.com"
                      && term.hyperlinkURI(row: 0, col: 7) == "https://example.com",
                  "cols 4-7 should carry the URI, got \(String(describing: term.hyperlinkURI(row: 0, col: 4)))")
            check("osc8-outside-clear",
                  term.hyperlinkURI(row: 0, col: 3) == nil && term.hyperlinkURI(row: 0, col: 8) == nil,
                  "cells outside the label must not carry the URI")
        }

        // --- Test 18: OSC 8 works with BEL terminator and id param ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.write(data: "\u{1B}]8;id=tmux1;https://a.com\u{07}X\u{1B}]8;;\u{07}".data(using: .utf8)!)
            term.flushDamage()
            check("osc8-bel-id",
                  term.hyperlinkURI(row: 0, col: 0) == "https://a.com",
                  "got \(String(describing: term.hyperlinkURI(row: 0, col: 0)))")
        }

        // --- Test 19: OSC 8 split across write() chunks still lands ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.write(data: "\u{1B}]8;;https://spl".data(using: .utf8)!)
            term.write(data: "it.example.com\u{1B}\\AB\u{1B}]8;;\u{1B}\\".data(using: .utf8)!)
            term.flushDamage()
            check("osc8-chunked",
                  term.hyperlinkURI(row: 0, col: 0) == "https://split.example.com"
                      && term.hyperlinkURI(row: 0, col: 1) == "https://split.example.com",
                  "got \(String(describing: term.hyperlinkURI(row: 0, col: 0)))")
        }

        // --- Test 20: hyperlink stamps follow a scroll ---
        do {
            let term = VTerminal(rows: 4, cols: 20)
            // Label on row 1, then three newlines: the last one scrolls the
            // screen up a row, so the label (and its stamp) land on row 0.
            term.write(data: "top\r\n\u{1B}]8;;https://s.com\u{1B}\\SCROLL\u{1B}]8;;\u{1B}\\".data(using: .utf8)!)
            term.write(data: "\r\n\r\n\r\n".data(using: .utf8)!)
            term.flushDamage()
            check("osc8-scroll-follows",
                  term.hyperlinkURI(row: 0, col: 0) == "https://s.com"
                      && term.hyperlinkURI(row: 1, col: 0) == nil,
                  "got row0 \(String(describing: term.hyperlinkURI(row: 0, col: 0))), row1 \(String(describing: term.hyperlinkURI(row: 1, col: 0)))")
        }

        // --- Test 21: plain rewrite over a link clears the stamp ---
        do {
            let term = VTerminal(rows: 24, cols: 80)
            term.write(data: "\u{1B}]8;;https://old.com\u{1B}\\OLDLABEL\u{1B}]8;;\u{1B}\\".data(using: .utf8)!)
            term.write(data: "\r".data(using: .utf8)!)
            term.write(data: "plaintext".data(using: .utf8)!)
            term.flushDamage()
            check("osc8-rewrite-clears",
                  term.hyperlinkURI(row: 0, col: 2) == nil,
                  "got \(String(describing: term.hyperlinkURI(row: 0, col: 2)))")
        }

        print("VTerminal tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("VTerminal tests failed") }
    }
}
#endif
