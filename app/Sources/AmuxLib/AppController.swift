import Foundation

/// Application controller — all business logic for handling user actions.
///
/// Handles user actions by reading tmux state and executing effects
/// through the Tmux executor. Tests inject FakeTmux via Tmux.executor.
public class AppController {
    public private(set) var session: String
    public var mode: InputMode = .normal

    /// The TTY device path of our PTY's tmux client (e.g., /dev/ttys005).
    /// Used to resolve which session our client is currently attached to
    /// when the user switches spaces. Set by AppDelegate after PTY creation.
    public var clientTTY: String?

    /// Callback for visual border overlay. Set by AppDelegate to update TerminalView.
    /// Parameters: (top, left, width, height) of the pane to highlight, or nil to clear.
    public var onSplitSelectedChanged: (((Int, Int, Int, Int)?) -> Void)?

    public init(session: String) {
        self.session = session
    }

    /// Handle a user action (from keyboard dispatch).
    public func handleAction(_ action: AmuxCommand) {
        // Resolve the current session from tmux. The user may have
        // switched spaces via the picker, which changes the client's session.
        resolveCurrentSession()
        fputs("amux: handleAction(\(action)) mode=\(mode)\n", stderr)
        do {
            switch action {
            case .zoomIn:       try handleZoomIn()
            case .zoomOut:      try handleZoomOut()
            case .zoomTo(let p): try handleZoomTo(p)
            case .paneNext:     try handlePaneNav(.paneNext)
            case .panePrev:     try handlePaneNav(.panePrev)
            case .newPane:      try handleNewPane()
            case .spaces:       handleSpaces()
            case .send:         handleSend()
            case .help:         handleHelp()
            case .splitStart:   try handleSplitStart()
            case .splitPick(let p):     try handleSplitPick(p)
            case .splitPickCurrent:     try handleSplitPickCurrent()
            case .splitCancel:          try handleSplitCancel()
            case .splitExit:            try handleZoomOut() // Cmd-- in split = exit
            case .selectPaneLeft:       try handleSelectDirection("-L")
            case .selectPaneRight:      try handleSelectDirection("-R")
            case .selectPaneUp:         try handleSelectDirection("-U")
            case .selectPaneDown:       try handleSelectDirection("-D")
            }
        } catch {
            fputs("amux: \(error)\n", stderr)
        }
    }

    // MARK: - Zoom

    private func handleZoomIn() throws {
        if try Tmux.windowCount(session) > 1 { return } // no-op in split view
        try Tmux.applyLayout(session, event: .zoomIn)
    }

    private func handleZoomOut() throws {
        if try Tmux.windowCount(session) > 1 {
            try Tmux.exitSplit(session)
        } else if try Tmux.isZoomed(session) {
            try Tmux.applyLayout(session, event: .zoomOut)
        } else {
            handleSpaces()
        }
    }

    private func handleZoomTo(_ pane: Int) throws {
        if try Tmux.windowCount(session) > 1 {
            // Split view: Cmd-1/2 selects the pane within the split window
            let count = try Tmux.paneCount(session)
            if pane < count {
                try Tmux.selectPane(session, paneIndex: pane)
            }
            return
        }
        let count = try Tmux.paneCount(session)
        if pane >= count {
            Tmux.displayMessage(session, message: "Pane \(pane + 1) does not exist (have \(count))")
            return
        }
        try Tmux.applyLayout(session, event: .zoomTo(pane))
    }

    // MARK: - Pane navigation

    private func handlePaneNav(_ event: LayoutEvent) throws {
        try Tmux.applyLayout(session, event: event)
    }

    private func handleSelectDirection(_ direction: String) throws {
        guard mode == .picking else { return }
        Tmux.runRaw(["select-pane", "-t", session, direction])
    }

    // MARK: - New pane

    private func handleNewPane() throws {
        // Inherit the active pane's working directory
        let activeIndex = try Tmux.activePaneIndex(session)
        let activeCwd = try Tmux.paneCwd(session, paneIndex: activeIndex)
        let paneIndex = try Tmux.createPane(session, cwd: activeCwd.isEmpty ? nil : activeCwd)
        // Auto-title the new pane from its cwd
        let cwd = try Tmux.paneCwd(session, paneIndex: paneIndex)
        if !cwd.isEmpty {
            let title = Util.autoTitle(dir: cwd)
            try Tmux.setTitle(session, paneIndex: paneIndex, title: title)
        }
    }

    // MARK: - Spaces / Send (fire-and-forget popup — tmux manages lifecycle)

    private func handleSpaces() {
        let bin = Config.findAmuxCLI()
        Tmux.launch([
            "display-popup", "-t", session, "-E", "-w", "70", "-h", "20",
            "-T", " Spaces ", "\(bin) spaces"
        ])
    }

    private func handleSend() {
        let bin = Config.findAmuxCLI()
        Tmux.launch([
            "display-popup", "-t", session, "-E", "-w", "70", "-h", "20",
            "-T", " Send to Space ", "\(bin) send"
        ])
    }

    // MARK: - Help

    private func handleHelp() {
        let bin = Config.findAmuxCLI()
        Tmux.launch([
            "display-popup", "-t", session, "-E", "-w", "84", "-h", "34",
            "-T", " Help ", "\(bin) help"
        ])
    }

    // MARK: - Split mode

    private func handleSplitStart() throws {
        let panes = try Tmux.listPanes(session)
        guard panes.count >= 3 else {
            Tmux.displayMessage(session, message: "Split requires at least 3 panes")
            return
        }
        if try Tmux.windowCount(session) > 1 { return }

        let active = panes.first(where: { $0.active })?.index ?? 0

        // Save split-first pane
        Tmux.runRaw(["set-environment", "-t", session, "AMUX_SPLIT_FIRST", "\(active)"])

        // If zoomed, save state and unzoom
        if try Tmux.isZoomed(session) {
            Tmux.runRaw(["set-environment", "-t", session, "AMUX_SPLIT_WAS_ZOOMED", "1"])
            try Tmux.toggleZoom(session)
        }

        // Set pane visual state + auto-title
        let cwd = try Tmux.paneCwd(session, paneIndex: active)
        let autoTitle = cwd.isEmpty ? nil : Util.autoTitle(dir: cwd)
        setPaneStyle(session: session, pane: active,
                     title: autoTitle, splitSelected: true)

        // Notify TerminalView to draw red border overlay on this pane
        let paneInfo = panes.first(where: { $0.index == active })
        if let p = paneInfo {
            // Query pane position from tmux
            let posStr = Tmux.runRaw(["display-message", "-t", "\(session):.\(active)", "-p",
                "#{pane_top} #{pane_left} #{pane_width} #{pane_height}"])
            let parts = posStr.split(separator: " ").compactMap { Int($0) }
            if parts.count == 4 {
                onSplitSelectedChanged?((parts[0], parts[1], parts[2], parts[3]))
            }
        }

        // Move focus to the lowest-numbered pane that isn't selected
        let candidates = panes.filter { $0.index != active }.sorted { $0.index < $1.index }
        if let first = candidates.first {
            try Tmux.selectPane(session, paneIndex: first.index)
        }

        // Status bar
        let title = panes.first(where: { $0.index == active })?.title ?? ""
        setSessionStatus(session: session, picking: true,
                         label: "\(active + 1) \(title)")

        mode = .picking
    }

    private func handleSplitPick(_ secondPane: Int) throws {
        guard mode == .picking else { return }

        // Bounds check
        let count = try Tmux.paneCount(session)
        if secondPane >= count {
            Tmux.displayMessage(session, message: "Pane \(secondPane + 1) does not exist (have \(count))")
            return
        }

        let firstPane = readSplitFirst() ?? 0

        // Clear visual state
        setPaneStyle(session: session, pane: firstPane, splitSelected: false)
        onSplitSelectedChanged?(nil)
        resetBorderStyles()
        setSessionStatus(session: session, picking: false)
        Tmux.runRaw(["set-environment", "-t", session, "-u", "AMUX_SPLIT_WAS_ZOOMED"])

        // Enter split view
        try Tmux.enterSplit(session, paneA: firstPane, paneB: secondPane)

        // Clean up
        Tmux.runRaw(["set-environment", "-t", session, "-u", "AMUX_SPLIT_FIRST"])
        mode = .normal
    }

    private func handleSplitPickCurrent() throws {
        let active = try Tmux.activePaneIndex(session)
        try handleSplitPick(active)
    }

    private func handleSplitCancel() throws {
        guard mode == .picking else { return }

        // Clear visual state
        onSplitSelectedChanged?(nil)
        if let firstPane = readSplitFirst() {
            setPaneStyle(session: session, pane: firstPane, splitSelected: false)
        }
        resetBorderStyles()
        setSessionStatus(session: session, picking: false)

        // Restore zoom if was zoomed
        if readEnvironment("AMUX_SPLIT_WAS_ZOOMED") == "1" {
            try Tmux.toggleZoom(session)
        }

        // Clean up env
        Tmux.runRaw(["set-environment", "-t", session, "-u", "AMUX_SPLIT_FIRST"])
        Tmux.runRaw(["set-environment", "-t", session, "-u", "AMUX_SPLIT_WAS_ZOOMED"])
        mode = .normal
    }

    // MARK: - Startup

    /// Initialize the session: create or attach, apply config, set up hooks.
    public func startup() throws {
        if !Tmux.sessionExists(session) {
            // amux-app's CWD is `/` when launched by LaunchServices; pass
            // $HOME so the first shell lands somewhere meaningful.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            try Tmux.createSession(session, startDirectory: home)
        }
        Tmux.markAsManaged(session)
        // Re-apply Config to every amux-managed session, not just the
        // current one. Per-session options (status bar) and hooks must
        // be set on each session; global options (key bindings, format
        // strings) are idempotent so re-applying them is harmless.
        // This guarantees `make dev` (which kills + relaunches amux-app
        // and re-runs startup) also refreshes config across all spaces,
        // so a separate `refresh` step isn't needed.
        let managed = (try? Tmux.listFocusSessions()) ?? []
        let targets = managed.isEmpty ? [session] : managed
        for s in targets {
            try Config.applyConfig(session: s)
        }

        // Clear stale overrides from previous app runs.
        Tmux.clearStaleBorderOverrides(session)
        let panes = try Tmux.listPanes(session)

        // Set titles on all panes
        for pane in panes {
            let cwd = try Tmux.paneCwd(session, paneIndex: pane.index)
            if !cwd.isEmpty {
                let title = Util.autoTitle(dir: cwd)
                try Tmux.setTitle(session, paneIndex: pane.index, title: title)
            }
        }

        try Tmux.applyLayout(session, event: .resize)

        // Set up bell watchers on all panes for attention alerts
        try Tmux.setupAllBellWatches(session)

        // Ensure Claude Code notification hook is installed
        try? Hooks.ensureClaudeHook()

        // If multiple spaces exist, show spaces picker on attach
        let spaces = (try? Tmux.listFocusSessions()) ?? []
        if spaces.count > 1 {
            Tmux.setStartupSpacesHook(session)
        }
    }

    // MARK: - Session resolution

    /// Resolve which session our tmux client is currently attached to.
    ///
    /// Uses `list-clients` filtered by our PTY's tty path to find the
    /// correct session. Falls back to `display-message` if no tty is set
    /// (e.g., in tests). This is needed because `display-message -p`
    /// without a target picks an arbitrary client when multiple exist.
    private func resolveCurrentSession() {
        if let tty = clientTTY {
            let output = Tmux.runRaw([
                "list-clients", "-F", "#{client_tty}:#{client_session}",
            ])
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0] == tty {
                    let found = String(parts[1])
                    if !found.isEmpty, found != session {
                        session = found
                    }
                    return
                }
            }
        }
        // Fallback (no tty, or client not found)
        let current = Tmux.runRaw(["display-message", "-p", "#{session_name}"])
        if !current.isEmpty, current != session {
            session = current
        }
    }

    // MARK: - Helpers

    private func readSplitFirst() -> Int? {
        guard let val = readEnvironment("AMUX_SPLIT_FIRST") else { return nil }
        return Int(val)
    }

    private func readEnvironment(_ key: String) -> String? {
        let result = Tmux.runRaw(["show-environment", "-t", session, key])
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eqIdx = trimmed.firstIndex(of: "=") else { return nil }
        return String(trimmed[trimmed.index(after: eqIdx)...])
    }
}

