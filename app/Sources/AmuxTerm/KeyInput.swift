import AppKit
import AmuxLib

/// Translates NSEvents into KeyActions based on the current input mode.
///
/// In normal mode: Cmd-keys → amux commands, everything else → PTY bytes.
/// In picking mode: arrows navigate, numbers pick, Esc cancels, all else ignored.
enum KeyInput {

    // MARK: - Action-based API (new)

    /// Determine the action for a key event given the current mode.
    static func action(for event: NSEvent, mode: InputMode) -> KeyAction {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmd = flags.contains(.command)
        let chars = event.charactersIgnoringModifiers ?? ""

        switch mode {
        case .picking:
            return pickingAction(for: event)

        case .normal:
            // System keys — let macOS handle
            if hasCmd && (chars == "q" || chars == "v" || chars == "c") {
                return .system
            }

            // ⌘/ → help (macOS Help menu convention; also matches ⌘? on shifted layouts)
            if hasCmd && chars == "/" {
                return .amux(.help)
            }

            // Cmd+key → amux commands (not PTY bytes)
            if hasCmd {
                return amuxAction(for: chars)
            }

            // Everything else → PTY bytes
            if let data = ptyBytes(for: event) {
                return .sendToPTY(data)
            }
            return .ignore
        }
    }

    /// Map Cmd+key to an amux command.
    ///
    /// Delegates to the AppKit-free `KeyCommand.amuxCommand` in AmuxLib for
    /// the character→command mapping, then falls back to PTY bytes for
    /// characters that don't bind to an amux action.
    private static func amuxAction(for chars: String) -> KeyAction {
        if let cmd = KeyCommand.amuxCommand(for: chars) {
            return .amux(cmd)
        }
        // Unknown Cmd-key — send as Ctrl-key to PTY for compatibility
        return .sendToPTY(ctrlBytes(for: chars))
    }

    /// Handle keys in picking mode.
    private static func pickingAction(for event: NSEvent) -> KeyAction {
        let chars = event.charactersIgnoringModifiers ?? ""

        switch event.keyCode {
        case 123: return .amux(.selectPaneLeft)   // Left arrow
        case 124: return .amux(.selectPaneRight)  // Right arrow
        case 125: return .amux(.selectPaneDown)   // Down arrow
        case 126: return .amux(.selectPaneUp)     // Up arrow
        case 36:  return .amux(.splitPickCurrent) // Enter
        case 53:  return .amux(.splitCancel)      // Escape
        default:
            // Number keys 1-9 → pick that pane (0-indexed internally)
            if let digit = Int(chars), digit >= 1 && digit <= 9 {
                return .amux(.splitPick(digit - 1))
            }
            return .ignore
        }
    }

    // MARK: - PTY byte generation (unchanged)

    /// Convert a key event to PTY bytes (for non-command keys in normal mode).
    static func ptyBytes(for event: NSEvent) -> Data? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCtrl = flags.contains(.control)
        let hasShift = flags.contains(.shift)
        let hasAlt = flags.contains(.option)

        // Ctrl+key
        if hasCtrl {
            if let chars = event.charactersIgnoringModifiers {
                return ctrlBytes(for: chars)
            }
            return nil
        }

        // Special keys
        switch event.keyCode {
        case 36:                                            // Return
            if hasShift {
                return "\u{1B}[13;2u".data(using: .utf8)   // Shift-Enter: CSI u
            }
            return Data([0x0D])
        case 48:  return Data([0x09])                       // Tab
        case 53:  return Data([0x1B])                       // Escape
        case 51:  return Data([0x7F])                       // Backspace
        case 117: return "\u{1B}[3~".data(using: .utf8)     // Forward Delete
        case 123:                                           // Left
            if hasAlt { return "\u{1B}[1;3D".data(using: .utf8) }
            return "\u{1B}[D".data(using: .utf8)
        case 124:                                           // Right
            if hasAlt { return "\u{1B}[1;3C".data(using: .utf8) }
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

    // MARK: - Legacy API (kept for existing tests)

    /// Convert a keyDown NSEvent to PTY bytes.
    /// Returns nil if the event should not be sent (e.g., Cmd-Q for app quit).
    static func bytes(for event: NSEvent) -> Data? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmd = flags.contains(.command)
        let hasCtrl = flags.contains(.control)

        guard let chars = event.charactersIgnoringModifiers else { return nil }
        guard !chars.isEmpty else { return nil }

        if hasCmd && chars == "q" { return nil }
        if hasCmd && chars == "v" { return nil }
        if hasCmd && chars == "c" { return nil }

        if hasCmd { return ctrlBytes(for: chars) }
        if hasCtrl { return ctrlBytes(for: chars) }

        return ptyBytes(for: event)
    }

    /// Convert a character to Ctrl-modified bytes using CSI u encoding.
    static func ctrlBytes(for chars: String) -> Data {
        guard let scalar = chars.unicodeScalars.first else { return Data() }
        let codepoint = scalar.value

        if codepoint >= 0x61 && codepoint <= 0x7A { // a-z
            return Data([UInt8(codepoint - 0x60)])
        }
        if codepoint >= 0x41 && codepoint <= 0x5A { // A-Z
            return Data([UInt8(codepoint - 0x40)])
        }

        return csiU(codepoint: Int(codepoint), modifier: 5)
    }

    /// Generate a CSI u sequence: ESC [ <codepoint> ; <modifier> u
    static func csiU(codepoint: Int, modifier: Int) -> Data {
        return "\u{1B}[\(codepoint);\(modifier)u".data(using: .utf8)!
    }

    /// Encode a scroll-wheel event for tmux / the pane app.
    ///
    /// Alt-screen apps without mouse reporting receive cursor-key sequences
    /// (ESC [ A / ESC [ B) — matches xterm alternateScroll, Alacritty, WezTerm,
    /// VTE, iTerm2 (when "scroll wheel sends arrow keys" is on). Otherwise
    /// SGR mouse events; tmux's `mouse on` binding then routes (copy-mode on
    /// main screen, pass-through in alt-screen + mouse mode).
    ///
    /// Speed: 1 line per imprecise wheel tick (macOS pre-multiplies),
    /// shift = 5x, precise trackpad = deltaY / cellHeight, hard cap of 10.
    static func scrollBytes(
        deltaY: CGFloat,
        col: Int, row: Int,
        cellHeight: CGFloat,
        precise: Bool,
        shiftHeld: Bool,
        isAltScreen: Bool,
        mouseMode: VTerminal.MouseMode
    ) -> [Data] {
        let shiftMult = shiftHeld ? 5 : 1
        let baseLines: Int
        if precise {
            baseLines = max(1, Int(abs(deltaY) / cellHeight))
        } else {
            baseLines = 1
        }
        let count = min(10, baseLines * shiftMult)

        let up = deltaY > 0

        if isAltScreen && mouseMode == .none {
            let seq = up ? "\u{1B}[A" : "\u{1B}[B"
            let data = seq.data(using: .utf8)!
            return Array(repeating: data, count: count)
        }

        let button = up ? 64 : 65
        let sgrCol = col + 1
        let sgrRow = row + 1
        var result: [Data] = []
        for _ in 0..<count {
            let seq = "\u{1B}[<\(button);\(sgrCol);\(sgrRow)M"
            if let data = seq.data(using: .utf8) {
                result.append(data)
            }
        }
        return result
    }
}
