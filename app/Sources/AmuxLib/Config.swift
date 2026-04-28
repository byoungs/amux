// Config.swift -- tmux configuration for borders, status bar, and hooks.
//
// Applies amux visual styling and event hooks to a tmux session.
// Key bindings are NOT configured here -- the Swift app handles
// keyboard input directly via KeyInput.swift.

import Foundation

public enum Config {
    /// Pane border format — the title text rendered at the top of each pane.
    ///
    /// ## Rendering architecture (hybrid)
    ///
    /// tmux handles the base rendering: active (teal) vs inactive (gray).
    /// TerminalView handles colored states (alert, split-selected) by
    /// painting the top border row with native overlays. This avoids the
    /// tmux color-bleed problem where format fg colors leak into the
    /// border fill characters that tmux draws after the format text.
    ///
    /// ## tmux format (this string)
    ///
    /// Two branches only:
    ///   - active (pane_active) → teal `▎ N title ●`
    ///   - inactive (default)   → gray `▎ N title` (no dot)
    ///
    /// The `●` dot is omitted on inactive panes for visual hierarchy.
    /// Active pane fill after `●` stays teal because pane-active-border-style
    /// is teal. Inactive fill resets to dark (colour235) via the format.
    ///
    /// ## TerminalView overlay (top row only)
    ///
    /// TerminalView.rebuildOverlays() queries pane alert/split state and
    /// overrides the foreground color of cells on the top border row only:
    ///   - split-selected → red (255, 0, 0)
    ///   - alert          → amber (214, 135, 0)
    ///
    /// This recolors the tmux-rendered text (▎, number, title, ●, fill)
    /// without changing the text content. Only the top row is affected —
    /// side and bottom borders stay dark.
    public static let paneBorderFormat = #" #{?pane_active,#[fg=colour43]▎ #[fg=yellow]#{e|+:#{pane_index},1} #[fg=colour255 bold]#{?@amux-title,#{@amux-title},#{pane_title}}#[nobold] #[fg=colour43]●,#[fg=colour236]▎ #[fg=colour240]#{e|+:#{pane_index},1} #[fg=colour245]#{?@amux-title,#{@amux-title},#{pane_title}}#[fg=colour235]} "#

    /// Status bar right-side format string.
    public static let statusRightFormat: String = {
        // Cmd-held: bright text (colour252) when ⌘ is held, dim (colour242) normally
        let dim = "#{?#{==:#{@amux-cmd-held},1},#[fg=colour252],#[fg=colour242]}"

        // Alert indicator (amber ● count) — always amber, appended when count > 0
        let alert = "#{?#{>:#{@amux-alert-count},0}, #[fg=colour214 bold]● #{@amux-alert-count},}"

        // Mode-specific legends
        let working = "#[fg=colour245]WORKING \(dim)⌘+/- zoom · ⌘[] cycle · ⌘1-9 focus · ⌘? help · ⌘l split · ⌘s send · ⌘p spaces\(alert)"
        let fullScreen = "#[fg=yellow bold]FULL SCREEN \(dim)⌘- zoom out · ⌘[] cycle · ⌘1-9 switch · ⌘? help · ⌘s send · ⌘p spaces\(alert)"
        let splitPick = "#[fg=colour196 bold]SPLIT #[fg=colour252]← #{@amux-split-first-label} #[fg=colour238]│ ←→↑↓ · 1-9 · Enter · Esc"
        let splitView = "#[fg=cyan bold]SPLIT \(dim)⌘- exit · ⌘? help · ⌘p spaces"

        // Nested conditionals: split view > picking > zoomed > working
        return " #{?#{>:#{window_index},0},\(splitView),#{?#{==:#{@amux-picking},1},\(splitPick),#{?window_zoomed_flag,\(fullScreen),\(working)}}} "
    }()

    /// Apply all amux tmux configuration to a session (except key bindings).
    public static func applyConfig(session: String) throws {
        try applyBorderStyle(session: session)
        try applyStatusBar(session: session)
        try applyHooks(session: session)
    }

    /// Set up attention management and layout hooks.
    public static func applyHooks(session: String) throws {
        // Clean up stale global hooks from before session-scoping was added.
        // Without this, old -g hooks linger in tmux and fire for all sessions.
        // Includes pane-focus-in/out at window scope (-gw) since debug experiments
        // can leave display-message hooks there that flash text on every focus change.
        for hook in ["pane-exited", "client-resized", "pane-focus-out", "pane-focus-in"] {
            tmuxRunIgnoringErrors(["set-hook", "-gu", hook])
            tmuxRunIgnoringErrors(["set-hook", "-gwu", hook])
        }

        let bin = findAmuxCLI()

        // Re-apply layout when a pane exits (shell closes naturally)
        try tmuxRun(["set-hook", "-t", session, "pane-exited",
                     "run-shell \"\(bin) layout #{session_name}\""])

        // Re-apply layout when the terminal window is resized
        try tmuxRun(["set-hook", "-t", session, "client-resized",
                     "run-shell \"\(bin) layout #{session_name}\""])

        // Update the selected pane's title from its cwd on focus change.
        try tmuxRun(["set-hook", "-t", session, "after-select-pane",
                     "run-shell \"AMUX_SESSION=#{session_name} \(bin) update-title #{pane_index} '#{pane_current_path}'\""])
    }

    /// Configure pane borders with colored title bars.
    private static func applyBorderStyle(session: String) throws {
        // When the last pane in a session closes, switch to another session
        // instead of detaching from tmux entirely.
        try tmuxSetGlobal("detach-on-destroy", "off")

        // Fix Claude Code flickering + enable Shift-Enter passthrough
        try tmuxSetGlobal("allow-passthrough", "on")
        try tmuxSetGlobal("extended-keys", "always")
        try tmuxSetServer("escape-time", "0")

        // Disable the tmux prefix key entirely. Amux uses root-table bindings
        // so the prefix key (Ctrl-B) is unnecessary.
        tmuxRunIgnoringErrors(["set", "-g", "prefix", "None"])
        tmuxRunIgnoringErrors(["unbind-key", "-T", "prefix", "C-b"])
        tmuxRunIgnoringErrors(["unbind-key", "-n", "C-b"])

        // Set terminal-features once (not append) to avoid duplication on refresh
        tmuxRunIgnoringErrors(["set", "-s", "terminal-features[0]",
                               "xterm*:clipboard:ccolour:cstyle:focus:title:sync:extkeys"])
        // True-color support for compatible terminals
        tmuxRunIgnoringErrors(["set", "-sa", "terminal-overrides", ",xterm-256color:RGB"])
        // Large scrollback to handle Claude Code's rapid streaming output
        try tmuxSetGlobal("history-limit", "250000")

        // Scroll wheel: tmux intercepts and routes based on alt-screen state.
        //   Main screen → enter copy-mode and scroll pane history (tmux's
        //                 own reflow handles resize correctly).
        //   Alt screen → pass wheel through to the pane app (amux already
        //                 translated wheel to arrow keys when the app isn't
        //                 consuming mouse events; SGR mouse events go through).
        // Block syntax `{...}` keeps multi-statement branches as one command.
        try tmuxSetGlobal("mouse", "on")

        // Disable interactive border drag — without this, every accidental
        // drag on a pane border resizes the pane and captures pane history
        // at a new width, causing mixed-width scrollback ("christmas tree").
        // amux owns resize via setFrameSize/SIGWINCH; users don't need
        // mouse-driven pane resizing.
        tmuxRunIgnoringErrors(["unbind-key", "-T", "root", "MouseDrag1Border"])

        tmuxRunIgnoringErrors(["bind-key", "-T", "root", "WheelUpPane",
            "if-shell -Ft= '#{?pane_in_mode,1,#{alternate_on}}' " +
            "{ send-keys -M } { select-pane -t= ; copy-mode -u }"])
        // WheelDownPane: send-keys -M re-emits the wheel event. In copy-mode
        // it scrolls down. In alt-screen it forwards to the pane app. On
        // main screen at the live tail the SGR mouse event is a no-op.
        // Note: copy-mode entry uses `-u` (NOT `-eu`) so the user stays in
        // copy-mode at the bottom rather than auto-exiting and getting
        // re-entered by subsequent upward wheel events. Typing any key
        // exits copy-mode (TerminalView sends `send-keys -X cancel` on
        // first keyDown after a wheel event).
        tmuxRunIgnoringErrors(["bind-key", "-T", "root", "WheelDownPane", "send-keys -M"])

        // Active pane: match iTerm2 profile (bg #000000, fg #bbbbbb)
        // Set globally so split windows inherit the same styles.
        try tmuxSetGlobal("window-active-style", "bg=colour0 fg=colour250")
        // Inactive panes: dimmed background + muted text
        try tmuxSetGlobal("window-style", "bg=colour234 fg=colour245")

        // Title bar at top of each pane with per-pane color conditionals
        try tmuxSetGlobal("pane-border-status", "top")
        try tmuxSetGlobal("pane-border-format", paneBorderFormat)
        // Clear any stale window-level format override (takes precedence over global)
        tmuxRunIgnoringErrors(["set-option", "-w", "-u", "pane-border-format"])

        // Border lines: both active and inactive are dark. Visual distinction
        // comes from the title bar format, not the border lines.
        resetBorderStyles()
    }

    /// Configure the status bar.
    private static func applyStatusBar(session: String) throws {
        try tmuxSet(session, "status-style", "bg=colour235 fg=colour245")
        try tmuxSet(session, "status-left", "#[fg=colour43,bold] amux #[fg=colour238]│ ")
        try tmuxSet(session, "@amux-cmd-held", "0")
        try tmuxSet(session, "status-right", statusRightFormat)
        try tmuxSet(session, "status-left-length", "20")
        try tmuxSet(session, "status-right-length", "120")
    }

    // MARK: - tmux helpers

    /// Set a tmux option for a session.
    private static func tmuxSet(_ session: String, _ option: String, _ value: String) throws {
        try tmuxRun(["set", "-t", session, option, value])
    }

    /// Set a global tmux option.
    private static func tmuxSetGlobal(_ option: String, _ value: String) throws {
        try tmuxRun(["set", "-g", option, value])
    }

    /// Set a server-level tmux option.
    private static func tmuxSetServer(_ option: String, _ value: String) throws {
        try tmuxRun(["set", "-sg", option, value])
    }

    /// Run a tmux command via the shared Tmux.executor, throwing on failure.
    ///
    /// Going through the executor (instead of spawning `tmux` directly) is
    /// critical for test isolation: integration tests override the executor
    /// with LiveTmux(socket:) to redirect all tmux calls to an isolated
    /// server. Directly spawning `tmux` would bypass that and leak commands
    /// to the user's live tmux server.
    private static func tmuxRun(_ args: [String]) throws {
        do {
            _ = try Tmux.executor.execute(args)
        } catch {
            throw ConfigError.tmux("tmux \(args.joined(separator: " ")) failed")
        }
    }

    /// Run a tmux command via the shared Tmux.executor, ignoring errors.
    private static func tmuxRunIgnoringErrors(_ args: [String]) {
        _ = try? Tmux.executor.execute(args)
    }

    /// Locate the amux binary for use in tmux hook commands.
    /// Find the amux-cli binary for use in tmux hooks.
    public static func findAmuxCLI() -> String {
        let candidates: [String]
        if let execURL = Bundle.main.executableURL {
            let execDir = execURL.deletingLastPathComponent().path
            candidates = [
                "\(execDir)/amux-cli",
                "\(NSHomeDirectory())/.local/bin/amux-cli",
            ]
        } else {
            candidates = [
                "\(NSHomeDirectory())/.local/bin/amux-cli",
            ]
        }
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "amux-cli" // fall back to PATH lookup
    }

    /// Find the amux binary (legacy, used by Tmux.findAmuxBinary).
    public static func findAmuxBinary() -> String {
        return findAmuxCLI() // amux-cli replaces the old Rust binary
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case tmux(String)

    public var description: String {
        switch self {
        case .tmux(let msg): return msg
        }
    }
}
