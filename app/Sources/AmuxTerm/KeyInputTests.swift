#if DEBUG
import Foundation

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

        print("KeyInput tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("KeyInput tests failed") }
    }
}
#endif
