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
    ///
    /// Performance: every command is bundled into two batched tmux invocations
    /// (one for cleanup, one for required sets) instead of ~35 separate
    /// `Process` launches. Per-call subprocess overhead dominated session
    /// setup in the integration test suite — batching cuts session-init time
    /// roughly in half.
    public static func applyConfig(session: String) throws {
        let bin = findAmuxCLI()

        // Cleanup batch — best-effort. Removing stale -g hooks, unbinding
        // legacy keys, and clearing window-scoped overrides may "fail"
        // (option not set, key not bound) and that's fine.
        //
        // Includes pane-focus-in/out at window scope (-gw) since debug
        // experiments can leave display-message hooks there that flash
        // text on every focus change.
        Tmux.batchRaw([
            ["set-hook", "-gu", "pane-exited"],
            ["set-hook", "-gu", "client-resized"],
            ["set-hook", "-gu", "pane-focus-out"],
            ["set-hook", "-gu", "pane-focus-in"],
            ["set-hook", "-gwu", "pane-exited"],
            ["set-hook", "-gwu", "client-resized"],
            ["set-hook", "-gwu", "pane-focus-out"],
            ["set-hook", "-gwu", "pane-focus-in"],
            // Disable the tmux prefix key entirely. Amux uses root-table
            // bindings so the prefix key (Ctrl-B) is unnecessary.
            ["set", "-g", "prefix", "None"],
            ["unbind-key", "-T", "prefix", "C-b"],
            ["unbind-key", "-n", "C-b"],
            // Set terminal-features once (not append) to avoid duplication on refresh
            ["set", "-s", "terminal-features[0]",
             "xterm*:clipboard:ccolour:cstyle:focus:title:sync:extkeys"],
            // True-color support for compatible terminals
            ["set", "-sa", "terminal-overrides", ",xterm-256color:RGB"],
            // Disable interactive border drag — without this, every accidental
            // drag on a pane border resizes the pane and captures pane history
            // at a new width, causing mixed-width scrollback ("christmas tree").
            // amux owns resize via setFrameSize/SIGWINCH; users don't need
            // mouse-driven pane resizing.
            ["unbind-key", "-T", "root", "MouseDrag1Border"],
            // Scroll wheel: tmux intercepts and routes based on alt-screen state.
            //   Main screen → enter copy-mode and scroll pane history.
            //   Alt screen → pass wheel through to the pane app.
            //
            // copy-mode entry uses `-e` (auto-exit when scrolled back to the
            // live tail so typing "just works" without a forced Esc). We do
            // NOT use `-u`: that flag scrolls one full page on entry, so a
            // single wheel tick page-jumps past whatever the user wanted to
            // read.
            //
            // tmux scrolls EXACTLY 1 line per mouse event (root entry +
            // copy-mode / copy-mode-vi overrides). amux's TerminalView holds
            // a fractional pixel accumulator and emits N SGR mouse events per
            // NSEvent based on the deltaY pixel magnitude, so total scroll =
            // N lines = whatever the user's finger movement translates to.
            // This matches Ghostty's `pending_scroll_y` (Surface.zig) and
            // iTerm's `iTermScrollAccumulator`, both of which use deltaY
            // directly and let tmux own the per-event line count.
            //
            // Typing while still scrolled up (in copy-mode) is handled by
            // handleCopyModeExit in TerminalView.
            ["bind-key", "-T", "root", "WheelUpPane",
             "if-shell -Ft= '#{?pane_in_mode,1,#{alternate_on}}' " +
             "{ send-keys -M } { select-pane -t= ; copy-mode -e ; send-keys -X -N 1 scroll-up }"],
            ["bind-key", "-T", "root", "WheelDownPane", "send-keys -M"],
            ["bind-key", "-T", "copy-mode", "WheelUpPane",
             "select-pane -t= ; send-keys -X -N 1 scroll-up"],
            ["bind-key", "-T", "copy-mode", "WheelDownPane",
             "select-pane -t= ; send-keys -X -N 1 scroll-down"],
            ["bind-key", "-T", "copy-mode-vi", "WheelUpPane",
             "select-pane -t= ; send-keys -X -N 1 scroll-up"],
            ["bind-key", "-T", "copy-mode-vi", "WheelDownPane",
             "select-pane -t= ; send-keys -X -N 1 scroll-down"],
            // Clear any stale window-level format override (takes precedence
            // over global)
            ["set-option", "-w", "-u", "pane-border-format"],
        ])

        // Required-sets batch — these must apply for amux to work. tmux
        // continues processing chained commands on individual failures, so
        // we can't tell from the return which (if any) failed; treat any
        // batch error as a generic config failure.
        do {
            try Tmux.batch([
                // Border style + global session behavior
                ["set", "-g", "detach-on-destroy", "off"],
                ["set", "-g", "allow-passthrough", "on"],
                ["set", "-g", "extended-keys", "always"],
                ["set", "-sg", "escape-time", "0"],
                // Large scrollback to handle Claude Code's rapid streaming output
                ["set", "-g", "history-limit", "250000"],
                ["set", "-g", "mouse", "on"],
                // Active pane: match iTerm2 profile. Set globally so split
                // windows inherit the same styles.
                ["set", "-g", "window-active-style", "bg=colour0 fg=colour250"],
                ["set", "-g", "window-style", "bg=colour234 fg=colour245"],
                // Title bar at top of each pane
                ["set", "-g", "pane-border-status", "top"],
                ["set", "-g", "pane-border-format", paneBorderFormat],
                // Border lines (resetBorderStyles inline). Both active and
                // inactive are dark; visual distinction comes from the
                // title bar format, not the border lines.
                ["set-option", "-g", "pane-active-border-style", "fg=colour43"],
                ["set-option", "-g", "pane-border-style", "fg=colour235"],
                // Status bar
                ["set", "-t", session, "status-style", "bg=colour235 fg=colour245"],
                ["set", "-t", session, "status-left",
                 "#[fg=colour43,bold] amux #[fg=colour238]│ "],
                ["set", "-t", session, "@amux-cmd-held", "0"],
                ["set", "-t", session, "status-right", statusRightFormat],
                ["set", "-t", session, "status-left-length", "20"],
                ["set", "-t", session, "status-right-length", "120"],
                // Only set defaults if unset (preserve background tag on refresh).
                ["if-shell", "-F", "-t", session, "#{!=:#{@amux-state},background}",
                 "set -t \(session) @amux-state foreground"],
                ["if-shell", "-F", "-t", session, "#{==:#{@amux-cap},}",
                 "set -t \(session) @amux-cap 4"],
                ["if-shell", "-F", "-t", session, "#{==:#{@amux-cap-overridden},}",
                 "set -t \(session) @amux-cap-overridden 0"],
                ["if-shell", "-F", "-t", session, "#{==:#{@amux-stacked},}",
                 "set -t \(session) @amux-stacked 1"],
                // Hooks. Re-apply layout when a pane exits or window resizes;
                // update the selected pane's title from its cwd on focus
                // change (after-select-pane).
                ["set-hook", "-t", session, "pane-exited",
                 "run-shell \"\(bin) layout #{session_name}\""],
                ["set-hook", "-t", session, "client-resized",
                 "run-shell \"\(bin) layout #{session_name}\""],
                ["set-hook", "-t", session, "after-select-pane",
                 "run-shell \"AMUX_SESSION=#{session_name} \(bin) update-title #{pane_index} '#{pane_current_path}'\""],
            ])
        } catch {
            throw ConfigError.tmux("applyConfig batch failed: \(error.localizedDescription)")
        }
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
