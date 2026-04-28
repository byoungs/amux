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
                print("FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
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

        print("VTerminal tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("VTerminal tests failed") }
    }
}
#endif
