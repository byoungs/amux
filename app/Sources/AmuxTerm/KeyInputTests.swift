#if DEBUG
import Foundation
import AmuxLib

enum KeyInputTests {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ actual: Data, _ expected: Data) {
            if actual == expected {
                passed += 1
            } else {
                failed += 1
                print("FAIL: \(name)")
                print("  expected: \(expected.map { String(format: "%02x", $0) }.joined(separator: " "))")
                print("  actual:   \(actual.map { String(format: "%02x", $0) }.joined(separator: " "))")
            }
        }

        // CSI u encoding
        check("csiU(49,5)", KeyInput.csiU(codepoint: 49, modifier: 5),
              "\u{1B}[49;5u".data(using: .utf8)!)

        // Shift-Enter: CSI u encoding ESC [ 13 ; 2 u
        check("Shift-Enter CSI u", KeyInput.csiU(codepoint: 13, modifier: 2),
              "\u{1B}[13;2u".data(using: .utf8)!)

        // Cmd-= -> ESC[61;5u
        check("Cmd-=", KeyInput.ctrlBytes(for: "="),
              "\u{1B}[61;5u".data(using: .utf8)!)

        // Cmd-- -> ESC[45;5u
        check("Cmd--", KeyInput.ctrlBytes(for: "-"),
              "\u{1B}[45;5u".data(using: .utf8)!)

        // Cmd-n -> 0x0E (Ctrl-N)
        check("Cmd-n", KeyInput.ctrlBytes(for: "n"), Data([0x0E]))

        // Cmd-p -> 0x10 (Ctrl-P)
        check("Cmd-p", KeyInput.ctrlBytes(for: "p"), Data([0x10]))

        // Cmd-l -> 0x0C (Ctrl-L)
        check("Cmd-l", KeyInput.ctrlBytes(for: "l"), Data([0x0C]))

        // Cmd-s -> 0x13 (Ctrl-S)
        check("Cmd-s", KeyInput.ctrlBytes(for: "s"), Data([0x13]))

        // Numbers 1-9 use CSI u
        for i in 1...9 {
            let expected = "\u{1B}[\(48 + i);5u".data(using: .utf8)!
            check("Cmd-\(i)", KeyInput.ctrlBytes(for: String(i)), expected)
        }

        // Main screen → SGR mouse buttons 64 (up) / 65 (down) with 1-indexed
        // coords. count is supplied by the caller's accumulator.
        check("scroll-mainscreen-sgr-up",
              KeyInput.scrollBytes(
                count: 1, up: true, col: 5, row: 3,
                isAltScreen: false, mouseMode: .none)[0],
              "\u{1B}[<64;6;4M".data(using: .utf8)!)

        check("scroll-mainscreen-sgr-down",
              KeyInput.scrollBytes(
                count: 1, up: false, col: 5, row: 3,
                isAltScreen: false, mouseMode: .none)[0],
              "\u{1B}[<65;6;4M".data(using: .utf8)!)

        // count of N emits N identical SGR events.
        let many = KeyInput.scrollBytes(
            count: 7, up: true, col: 0, row: 0,
            isAltScreen: false, mouseMode: .none)
        check("scroll-count-7",
              Data([UInt8(many.count)]), Data([7]))

        // count of 0 emits nothing — the accumulator hasn't crossed a cell.
        let zero = KeyInput.scrollBytes(
            count: 0, up: true, col: 0, row: 0,
            isAltScreen: false, mouseMode: .none)
        check("scroll-count-0-empty",
              Data([UInt8(zero.count)]), Data([0]))

        // Alt-screen + no app mouse mode → arrow keys (xterm alt-scroll)
        check("scroll-altscreen-up-arrow",
              KeyInput.scrollBytes(
                count: 1, up: true, col: 0, row: 0,
                isAltScreen: true, mouseMode: .none)[0],
              "\u{1B}[A".data(using: .utf8)!)

        check("scroll-altscreen-down-arrow",
              KeyInput.scrollBytes(
                count: 1, up: false, col: 0, row: 0,
                isAltScreen: true, mouseMode: .none)[0],
              "\u{1B}[B".data(using: .utf8)!)

        // Alt-screen + mouse mode → SGR mouse, not arrows
        check("scroll-altscreen-mouse-sgr",
              KeyInput.scrollBytes(
                count: 1, up: true, col: 5, row: 3,
                isAltScreen: true, mouseMode: .click)[0],
              "\u{1B}[<64;6;4M".data(using: .utf8)!)

        // SGR coordinates are 1-indexed
        check("scroll-1indexed",
              KeyInput.scrollBytes(
                count: 1, up: true, col: 0, row: 0,
                isAltScreen: false, mouseMode: .none)[0],
              "\u{1B}[<64;1;1M".data(using: .utf8)!)

        print("KeyInput tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("KeyInput tests failed") }
    }
}
#endif
