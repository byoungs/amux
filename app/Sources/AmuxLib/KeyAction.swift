import Foundation

/// Actions that can result from a key press.
///
/// The app processes key events in two phases:
/// 1. KeyInput.action(for:mode:) determines what to do
/// 2. The caller (TerminalView/AppDelegate) executes the action
///
/// This separation makes key handling testable without tmux or a PTY.
public enum KeyAction: Equatable {
    /// Forward raw bytes to the PTY (normal terminal input)
    case sendToPTY(Data)

    /// Execute an amux command against the current session.
    /// The session name is resolved at dispatch time.
    case amux(AmuxCommand)

    /// Let the system handle (Cmd-Q quit, Cmd-C copy, Cmd-V paste)
    case system

    /// Ignore — don't forward, don't act
    case ignore
}

/// Amux commands that can be triggered by keyboard shortcuts.
public enum AmuxCommand: Equatable {
    case zoomIn
    case zoomOut
    case zoomTo(Int)        // 0-indexed pane
    case paneNext
    case panePrev
    case newPane
    case spaces
    case send
    case help
    case splitStart
    case splitPick(Int)     // 0-indexed pane
    case splitCancel
    case splitExit
    case selectPaneLeft
    case selectPaneRight
    case selectPaneUp
    case selectPaneDown
    case splitPickCurrent   // pick whatever pane is currently active
    case peek               // Cmd-Y: toggle the permission-peek popup
}

/// Input mode — determines how keys are interpreted.
public enum InputMode: Equatable {
    /// Normal terminal mode: Cmd-keys → amux commands, everything else → PTY
    case normal

    /// Split-pick mode: arrows navigate, numbers pick, Esc cancels
    case picking
}

/// Pure mapping from a Cmd+key character to the corresponding KeyAction.
///
/// Lives in AmuxLib (not AmuxTerm) so it can be tested without AppKit.
/// KeyInput in AmuxTerm translates NSEvents into characters and delegates
/// here; AppKit-free test targets can call it directly with literal strings.
///
/// Unknown Cmd-key → `.sendToPTY(ctrlBytes)` fallback is handled by the
/// caller since it requires the byte encoder in AmuxTerm.
public enum KeyCommand {
    /// Returns the amux action for a Cmd-key character, or nil if the
    /// character doesn't bind to an amux command.
    public static func amuxCommand(for chars: String) -> AmuxCommand? {
        switch chars {
        case "=":  return .zoomIn          // Cmd-+ (zoom in)
        case "-":  return .zoomOut         // Cmd-- (zoom out / spaces)
        case "n":  return .newPane         // Cmd-N (new pane)
        case "p":  return .spaces          // Cmd-P (spaces picker)
        case "s":  return .send            // Cmd-S (send to space)
        case "l":  return .splitStart      // Cmd-L (split start)
        case "[":  return .panePrev        // Cmd-[ (previous pane)
        case "]":  return .paneNext        // Cmd-] (next pane)
        case "/":  return .help            // Cmd-/ (help)
        case "y":  return .peek            // Cmd-Y (permission peek)
        default:
            // Cmd-1..9 → zoom to pane (0-indexed internally)
            if let digit = Int(chars), digit >= 1 && digit <= 9 {
                return .zoomTo(digit - 1)
            }
            return nil
        }
    }
}
