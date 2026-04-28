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

        // Scroll up sends button 64
        check("scroll-up-button",
              KeyInput.scrollBytes(deltaY: 10, col: 5, row: 3, cellHeight: 17, precise: false, visibleRows: 30)[0],
              "\u{1B}[<64;6;4M".data(using: .utf8)!)

        // Scroll down sends button 65
        check("scroll-down-button",
              KeyInput.scrollBytes(deltaY: -10, col: 5, row: 3, cellHeight: 17, precise: false, visibleRows: 30)[0],
              "\u{1B}[<65;6;4M".data(using: .utf8)!)

        // Mouse wheel sends 3 events at 30 rows (~10% = 3)
        let mouseWheel = KeyInput.scrollBytes(deltaY: 1, col: 0, row: 0, cellHeight: 17, precise: false, visibleRows: 30)
        check("scroll-mouse-count", Data([UInt8(mouseWheel.count)]), Data([3]))

        // Small pane (15 rows): scroll speed scales down to 1 line
        let smallPane = KeyInput.scrollBytes(deltaY: 1, col: 0, row: 0, cellHeight: 17, precise: false, visibleRows: 15)
        check("scroll-small-pane", Data([UInt8(smallPane.count)]), Data([1]))

        // Trackpad with small delta sends 1 event
        let trackpadSmall = KeyInput.scrollBytes(deltaY: 5, col: 0, row: 0, cellHeight: 17, precise: true, visibleRows: 30)
        check("scroll-trackpad-small", Data([UInt8(trackpadSmall.count)]), Data([1]))

        // Trackpad capped at maxLines (3 at 30 rows)
        let trackpadLarge = KeyInput.scrollBytes(deltaY: 200, col: 0, row: 0, cellHeight: 17, precise: true, visibleRows: 30)
        check("scroll-trackpad-cap", Data([UInt8(trackpadLarge.count)]), Data([3]))

        // SGR coordinates are 1-indexed
        check("scroll-1indexed",
              KeyInput.scrollBytes(deltaY: 1, col: 0, row: 0, cellHeight: 17, precise: false, visibleRows: 30)[0],
              "\u{1B}[<64;1;1M".data(using: .utf8)!)

        print("KeyInput tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("KeyInput tests failed") }
    }
}
#endif
