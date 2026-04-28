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

        // Main screen → SGR mouse so tmux binding handles
        check("scroll-mainscreen-sgr-up",
              KeyInput.scrollBytes(
                deltaY: 10, col: 5, row: 3, cellHeight: 17,
                precise: false, shiftHeld: false,
                isAltScreen: false, mouseMode: .none)[0],
              "\u{1B}[<64;6;4M".data(using: .utf8)!)

        check("scroll-mainscreen-sgr-down",
              KeyInput.scrollBytes(
                deltaY: -10, col: 5, row: 3, cellHeight: 17,
                precise: false, shiftHeld: false,
                isAltScreen: false, mouseMode: .none)[0],
              "\u{1B}[<65;6;4M".data(using: .utf8)!)

        // Imprecise wheel → 1 event (1 line per macOS pre-multiplied tick)
        let mainImprecise = KeyInput.scrollBytes(
            deltaY: 1, col: 0, row: 0, cellHeight: 17,
            precise: false, shiftHeld: false,
            isAltScreen: false, mouseMode: .none)
        check("scroll-mainscreen-count",
              Data([UInt8(mainImprecise.count)]), Data([1]))

        // Shift+wheel → 5 events
        let shiftWheel = KeyInput.scrollBytes(
            deltaY: 1, col: 0, row: 0, cellHeight: 17,
            precise: false, shiftHeld: true,
            isAltScreen: false, mouseMode: .none)
        check("scroll-shift-count",
              Data([UInt8(shiftWheel.count)]), Data([5]))

        // Hard cap: huge precise trackpad delta never exceeds 10 events
        let trackpadHuge = KeyInput.scrollBytes(
            deltaY: 9999, col: 0, row: 0, cellHeight: 17,
            precise: true, shiftHeld: false,
            isAltScreen: false, mouseMode: .none)
        check("scroll-cap-10",
              Data([UInt8(trackpadHuge.count)]), Data([10]))

        // Alt-screen + no app mouse mode → arrow keys (xterm alt-scroll)
        check("scroll-altscreen-up-arrow",
              KeyInput.scrollBytes(
                deltaY: 1, col: 0, row: 0, cellHeight: 17,
                precise: false, shiftHeld: false,
                isAltScreen: true, mouseMode: .none)[0],
              "\u{1B}[A".data(using: .utf8)!)

        check("scroll-altscreen-down-arrow",
              KeyInput.scrollBytes(
                deltaY: -1, col: 0, row: 0, cellHeight: 17,
                precise: false, shiftHeld: false,
                isAltScreen: true, mouseMode: .none)[0],
              "\u{1B}[B".data(using: .utf8)!)

        // Alt-screen + mouse mode → SGR mouse, not arrows
        check("scroll-altscreen-mouse-sgr",
              KeyInput.scrollBytes(
                deltaY: 1, col: 5, row: 3, cellHeight: 17,
                precise: false, shiftHeld: false,
                isAltScreen: true, mouseMode: .click)[0],
              "\u{1B}[<64;6;4M".data(using: .utf8)!)

        // SGR coordinates are 1-indexed
        check("scroll-1indexed",
              KeyInput.scrollBytes(
                deltaY: 1, col: 0, row: 0, cellHeight: 17,
                precise: false, shiftHeld: false,
                isAltScreen: false, mouseMode: .none)[0],
              "\u{1B}[<64;1;1M".data(using: .utf8)!)

        print("KeyInput tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("KeyInput tests failed") }
    }
}
#endif
