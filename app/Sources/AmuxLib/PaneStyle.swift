import Foundation

/// Reset border line styles.
///
/// Active pane borders are teal (colour43) — this colors both the top
/// border fill (after the format text) and the vertical/bottom borders.
/// Inactive borders are dark (colour235).
/// TerminalView overlay handles alert/split-selected on the top row only.
public func resetBorderStyles() {
    Tmux.runRaw(["set-option", "-g", "pane-active-border-style", "fg=colour43"])
    Tmux.runRaw(["set-option", "-g", "pane-border-style", "fg=colour235"])
}

/// Set visual properties for a pane.
///
/// Sets per-pane tmux user options (@amux-title, @amux-alert,
/// @amux-split-selected). No per-pane pane-border-format overrides —
/// the global format handles active/inactive, and TerminalView
/// overlay handles alert/split coloring on the top border row.
///
/// - Parameters:
///   - session: tmux session name
///   - pane: pane index
///   - title: pane title (set @amux-title). Pass nil to leave unchanged.
///   - alert: alert state (set @amux-alert). Pass nil to leave unchanged.
///   - splitSelected: split-selected state (set @amux-split-selected). Pass nil to leave unchanged.
public func setPaneStyle(
    session: String,
    pane: Int,
    title: String? = nil,
    alert: Bool? = nil,
    splitSelected: Bool? = nil
) {
    let target = "\(session):.\(pane)"

    if let title = title {
        Tmux.runRaw(["set-option", "-p", "-t", target, "@amux-title", title])
    }

    if let alert = alert {
        Tmux.runRaw(["set-option", "-p", "-t", target, "@amux-alert", alert ? "1" : "0"])
    }

    if let splitSelected = splitSelected {
        Tmux.runRaw(["set-option", "-p", "-t", target, "@amux-split-selected", splitSelected ? "1" : "0"])
    }
}

/// Update the session-level status bar state for split-pick mode.
///
/// - Parameters:
///   - session: tmux session name
///   - picking: whether we're in pick mode
///   - label: the "← N title" label for the status bar. Pass nil to clear.
///   - alertCount: total alert count across all panes. Pass nil to leave unchanged.
public func setSessionStatus(
    session: String,
    picking: Bool? = nil,
    label: String? = nil,
    alertCount: Int? = nil
) {
    if let picking = picking {
        Tmux.runRaw(["set-option", "-t", session, "@amux-picking", picking ? "1" : "0"])
    }

    if let label = label {
        Tmux.runRaw(["set-option", "-t", session, "@amux-split-first-label", label])
    } else if picking == false {
        // Clear label when exiting pick mode
        Tmux.runRaw(["set-option", "-t", session, "-u", "@amux-split-first-label"])
    }

    if let count = alertCount {
        Tmux.runRaw(["set-option", "-t", session, "@amux-alert-count", "\(count)"])
    }
}

/// Update the Cmd-held state for status bar highlighting.
///
/// When Cmd is held, the status bar legend brightens from dim gray
/// to white so shortcuts are easier to read.
public func setCmdHeld(session: String, held: Bool) {
    Tmux.runRaw(["set-option", "-t", session, "@amux-cmd-held", held ? "1" : "0"])
}

/// setCmdHeld, off the caller's thread. Fires on every Cmd press/release
/// from the key-event path on main; the subprocess must not park the main
/// thread (it can wait out a whole PermissionWatcher capture-pane burst on
/// LiveTmux's process-wide lock). The shared serial queue preserves
/// press/release ordering.
public func setCmdHeldAsync(session: String, held: Bool) {
    Tmux.backgroundQueue.async {
        setCmdHeld(session: session, held: held)
    }
}

/// 24-bit RGB color for a top-border overlay.
public struct OverlayColor: Equatable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Pure decision: given a pane's state, what color (if any) should its top
/// border row be painted? Returns nil for "let tmux draw it" (active teal or
/// inactive dark via pane-border-format).
///
/// Rules:
///   - split-selected wins over alert (red always takes precedence on picking)
///   - alert only paints on non-active panes (alert clears on focus, so an
///     active+alerted pane is a transient state that shouldn't render amber)
///   - otherwise nil — tmux renders the active/inactive base color itself
///
/// Factored out of `TerminalView.rebuildOverlays` so integration tests can
/// pin the color values without constructing a TerminalView (which pulls in
/// AppKit). TerminalView remains responsible for querying tmux for pane
/// positions and dispatching the paint — only the color decision lives here.
public func overlayColor(
    alert: Bool,
    splitSelected: Bool,
    active: Bool
) -> OverlayColor? {
    if splitSelected {
        return OverlayColor(r: 255, g: 0, b: 0)    // red
    }
    if alert && !active {
        return OverlayColor(r: 214, g: 135, b: 0)  // amber
    }
    return nil
}
