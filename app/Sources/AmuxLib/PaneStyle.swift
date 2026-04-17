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
