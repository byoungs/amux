import AppKit

/// Translates NSEvents into bytes for the PTY.
/// Remaps Cmd+key -> Ctrl+key so tmux handles shortcuts natively via CSI u encoding.
enum KeyInput {

    /// Convert a keyDown NSEvent to PTY bytes.
    /// Returns nil if the event should not be sent (e.g., Cmd-Q for app quit).
    static func bytes(for event: NSEvent) -> Data? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmd = flags.contains(.command)
        let hasCtrl = flags.contains(.control)

        guard let chars = event.charactersIgnoringModifiers else { return nil }
        guard !chars.isEmpty else { return nil }

        // Cmd-Q: let the system handle app quit
        if hasCmd && chars == "q" { return nil }
        // Cmd-V: let the system handle paste via menu
        if hasCmd && chars == "v" { return nil }
        // Cmd-C: let the system handle copy via menu
        if hasCmd && chars == "c" { return nil }

        // Cmd+key -> remap to Ctrl+key
        if hasCmd {
            return ctrlBytes(for: chars)
        }

        // Ctrl+key (user pressed Ctrl directly)
        if hasCtrl {
            return ctrlBytes(for: chars)
        }

        // Special keys (with modifiers)
        let hasShift = flags.contains(.shift)
        let hasAlt = flags.contains(.option)
        switch event.keyCode {
        case 36:                                            // Return
            if hasShift {
                return "\u{1B}[13;2u".data(using: .utf8)   // Shift-Enter: CSI u for multi-line input
            }
            return Data([0x0D])
        case 48:  return Data([0x09])                       // Tab
        case 53:  return Data([0x1B])                       // Escape
        case 51:  return Data([0x7F])                       // Backspace
        case 117: return "\u{1B}[3~".data(using: .utf8)     // Forward Delete
        case 123:                                           // Left
            if hasAlt { return "\u{1B}[1;3D".data(using: .utf8) }  // Alt-Left: word back
            return "\u{1B}[D".data(using: .utf8)
        case 124:                                           // Right
            if hasAlt { return "\u{1B}[1;3C".data(using: .utf8) }  // Alt-Right: word forward
            return "\u{1B}[C".data(using: .utf8)
        case 125:                                           // Down
            if hasAlt { return "\u{1B}[1;3B".data(using: .utf8) }
            return "\u{1B}[B".data(using: .utf8)
        case 126:                                           // Up
            if hasAlt { return "\u{1B}[1;3A".data(using: .utf8) }
            return "\u{1B}[A".data(using: .utf8)
        case 115: return "\u{1B}[H".data(using: .utf8)      // Home
        case 119: return "\u{1B}[F".data(using: .utf8)      // End
        case 116: return "\u{1B}[5~".data(using: .utf8)     // Page Up
        case 121: return "\u{1B}[6~".data(using: .utf8)     // Page Down
        default: break
        }

        // Normal character input
        return event.characters?.data(using: .utf8)
    }

    /// Convert a character to Ctrl-modified bytes using CSI u encoding.
    /// For letters (a-z), send traditional control character (0x01-0x1A).
    /// For everything else, use CSI u: ESC [ <codepoint> ; 5 u
    static func ctrlBytes(for chars: String) -> Data {
        guard let scalar = chars.unicodeScalars.first else { return Data() }
        let codepoint = scalar.value

        // Ctrl + letter: traditional control character (0x01-0x1A)
        if codepoint >= 0x61 && codepoint <= 0x7A { // a-z
            return Data([UInt8(codepoint - 0x60)])
        }
        if codepoint >= 0x41 && codepoint <= 0x5A { // A-Z
            return Data([UInt8(codepoint - 0x40)])
        }

        // Everything else: CSI u encoding
        return csiU(codepoint: Int(codepoint), modifier: 5)
    }

    /// Generate a CSI u sequence: ESC [ <codepoint> ; <modifier> u
    static func csiU(codepoint: Int, modifier: Int) -> Data {
        return "\u{1B}[\(codepoint);\(modifier)u".data(using: .utf8)!
    }
}
