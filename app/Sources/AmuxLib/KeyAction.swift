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
}

/// Input mode — determines how keys are interpreted.
public enum InputMode: Equatable {
    /// Normal terminal mode: Cmd-keys → amux commands, everything else → PTY
    case normal

    /// Split-pick mode: arrows navigate, numbers pick, Esc cancels
    case picking
}
