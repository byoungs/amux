// Tmux.swift — tmux CLI command wrappers.
// Every function shells out to tmux via Process. No persistent connection.

import Foundation

// MARK: - Error type

public enum AmuxError: Error, LocalizedError {
    case tmux(String)
    public var errorDescription: String? {
        switch self { case .tmux(let msg): return msg }
    }
}

// MARK: - PaneInfo

public struct PaneInfo {
    public let index: Int
    public let title: String
    public let width: Int
    public let height: Int
    public let active: Bool
    public let alert: Bool

    public init(index: Int, title: String, width: Int, height: Int, active: Bool, alert: Bool) {
        self.index = index
        self.title = title
        self.width = width
        self.height = height
        self.active = active
        self.alert = alert
    }
}

// MARK: - Tmux namespace

public enum Tmux {

    // MARK: - Executor

    /// The executor used for all tmux commands. Defaults to LiveTmux.
    /// Tests set this to FakeTmux before running.
    nonisolated(unsafe) public static var executor: TmuxExecutor = LiveTmux()

    // MARK: - Internal helpers (delegate to executor)

    /// Run a tmux command and return trimmed stdout.
    /// Returns empty string on failure (non-throwing).
    private static func run(_ args: [String]) throws -> String {
        try executor.execute(args)
    }

    /// Run a tmux command, returning trimmed stdout. Throws on non-zero exit.
    @discardableResult
    private static func runChecked(_ args: [String], context: String) throws -> String {
        do {
            return try executor.execute(args)
        } catch {
            throw AmuxError.tmux("\(context): \(error.localizedDescription)")
        }
    }

    /// Run a tmux command and return stdout.
    @discardableResult
    public static func runRaw(_ args: [String]) -> String {
        (try? executor.execute(args)) ?? ""
    }

    /// Run a tmux command, ignoring exit status. Used for fire-and-forget operations.
    private static func runIgnoring(_ args: [String]) {
        _ = try? executor.execute(args)
    }

    /// Launch a tmux command without waiting for exit. Fire-and-forget.
    /// Used for interactive popups (display-popup) where tmux manages the lifecycle.
    public static func launch(_ args: [String]) {
        executor.launch(args)
    }

    /// Execute multiple tmux commands in a single subprocess call.
    /// Uses `\;` chaining to avoid per-command Process overhead (~65ms each).
    @discardableResult
    public static func batch(_ commands: [[String]]) throws -> String {
        try executor.executeBatch(commands)
    }

    /// Execute multiple tmux commands in a single subprocess, ignoring errors.
    public static func batchRaw(_ commands: [[String]]) {
        _ = try? executor.executeBatch(commands)
    }

    /// Clear stale per-pane and window-level border overrides on a session.
    ///
    /// The hybrid rendering architecture uses only the global pane-border-format
    /// (active/inactive) + TerminalView overlay (alert/split). Old code set
    /// per-pane formats and window-level border styles that persist across app
    /// restarts. Call this when entering a session (startup or space switch).
    public static func clearStaleBorderOverrides(_ session: String) {
        runIgnoring(["set-option", "-w", "-u", "-t", session, "pane-active-border-style"])
        runIgnoring(["set-option", "-w", "-u", "-t", session, "pane-border-style"])
        if let panes = try? listPanes(session) {
            for pane in panes {
                runIgnoring(["set-option", "-p", "-u", "-t", "\(session):.\(pane.index)", "pane-border-format"])
            }
        }
    }

    /// Parse PaneInfo lines from tmux list-panes format output.
    private static func parsePaneLines(_ stdout: String) -> [PaneInfo] {
        stdout.split(separator: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                    .map(String.init)
                guard parts.count >= 5,
                      let index = Int(parts[0]),
                      let width = Int(parts[2]),
                      let height = Int(parts[3]) else {
                    return nil
                }
                return PaneInfo(
                    index: index,
                    title: parts[1],
                    width: width,
                    height: height,
                    active: parts[4] == "1",
                    alert: parts.count > 5 && parts[5] == "1"
                )
            }
    }

    // MARK: - Session management

    /// Check if a tmux session exists.
    public static func sessionExists(_ session: String) -> Bool {
        do {
            _ = try executor.execute(["has-session", "-t", session])
            return true
        } catch {
            return false
        }
    }

    /// Create a new tmux session. No-op if it already exists.
    public static func createSession(_ name: String) throws {
        if sessionExists(name) { return }
        try runChecked(
            ["new-session", "-d", "-s", name],
            context: "tmux new-session failed"
        )
    }

    /// List all tmux sessions.
    public static func listSessions() throws -> [String] {
        let stdout: String
        do {
            stdout = try executor.execute(["list-sessions", "-F", "#{session_name}"])
        } catch {
            return []
        }
        return stdout.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// List only amux-managed tmux sessions (marked with AMUX_MANAGED env var).
    public static func listFocusSessions() throws -> [String] {
        let all = try listSessions()
        var managed: [String] = []
        for session in all {
            let stdout = (try? run(["show-environment", "-t", session, "AMUX_MANAGED"])) ?? ""
            if stdout.contains("AMUX_MANAGED=1") {
                managed.append(session)
            }
        }
        return managed
    }

    /// List amux-managed sessions with their alert counts in a single tmux call.
    /// Returns (sessions, alertCounts).
    ///
    /// Uses `list-sessions -F` with format string to get session name, managed flag,
    /// and alert count all at once. One subprocess call regardless of session count.
    public static func listSpacesWithAlerts() throws -> (sessions: [String], alertCounts: [String: Int]) {
        let stdout = try runChecked(
            ["list-sessions", "-F", "#{session_name} #{@amux-managed} #{@amux-alert-count}"],
            context: "list-sessions failed"
        )
        var managed: [String] = []
        var counts: [String: Int] = [:]
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            let isManaged = parts[1] == "1"
            guard isManaged else { continue }
            managed.append(name)
            let count = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
            counts[name] = count
        }
        return (managed, counts)
    }

    /// Mark a session as amux-managed.
    /// Sets both an environment variable (legacy) and a session option
    /// (@amux-managed) which is queryable via list-sessions -F.
    public static func markAsManaged(_ session: String) {
        runIgnoring(["set-environment", "-t", session, "AMUX_MANAGED", "1"])
        runIgnoring(["set-option", "-t", session, "@amux-managed", "1"])
    }

    /// Switch the current client to a different session.
    public static func switchSession(_ session: String) throws {
        try runChecked(
            ["switch-client", "-t", session],
            context: "tmux switch-client failed"
        )
    }

    /// Attach to a tmux session (blocking, takes over terminal).
    /// NOTE: This bypasses the executor because it needs stdin/stdout passthrough.
    /// The fake handles "attach-session" as a no-op.
    public static func attach(_ session: String) throws {
        // In test/fake mode, delegate to executor (which no-ops)
        if !(executor is LiveTmux) {
            _ = try? executor.execute(["attach-session", "-t", session])
            return
        }
        // In production, need real stdin/stdout passthrough
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "attach-session", "-t", session]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AmuxError.tmux("No amux session found. Run `amux start` to create one.")
        }
    }

    /// Kill a tmux session.
    public static func killSession(_ session: String) throws {
        try runChecked(
            ["kill-session", "-t", session],
            context: "tmux kill-session failed"
        )
    }

    // MARK: - Pane management

    /// Create a pane via split-window directly in window 0.
    ///
    /// Previous approach used new-window + join-pane, which created a
    /// visible temporary window then immediately destroyed it — causing
    /// status bar flicker and a double layout redraw. split-window adds
    /// the pane directly to the existing window with no intermediate state.
    public static func createPane(_ session: String, cwd: String? = nil) throws -> Int {
        var args = ["split-window", "-t", "\(session):0", "-d", "-P", "-F", "#{pane_id}"]
        if let dir = cwd {
            args.append(contentsOf: ["-c", dir])
        }
        let newPaneId = try runChecked(args, context: "tmux split-window failed")

        // Apply clean grid layout with the new pane's ID
        let paneIdNumeric = Int(newPaneId.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? 0
        try applyLayout(session, event: .addPane(paneIdNumeric))
        let panes = try listPanes(session)
        let active = panes.first(where: { $0.active })?.index ?? 0
        try setupBellWatch(session, paneIndex: active)
        return active
    }

    /// List all panes in a session.
    public static func listPanes(_ session: String) throws -> [PaneInfo] {
        let stdout = try runChecked(
            ["list-panes", "-t", session, "-F",
             "#{pane_index}\t#{@amux-title}\t#{pane_width}\t#{pane_height}\t#{pane_active}\t#{@amux-alert}"],
            context: "tmux list-panes failed"
        )
        return parsePaneLines(stdout)
    }

    /// List panes in a specific window.
    public static func listPanesInWindow(_ session: String, window: Int) throws -> [PaneInfo] {
        let target = "\(session):\(window)"
        let stdout: String
        do {
            stdout = try executor.execute(["list-panes", "-t", target, "-F",
                "#{pane_index}\t#{@amux-title}\t#{pane_width}\t#{pane_height}\t#{pane_active}\t#{@amux-alert}"])
        } catch {
            return []
        }
        return parsePaneLines(stdout)
    }

    /// Kill a pane by index.
    public static func killPane(_ session: String, paneIndex: Int) throws {
        // Capture pane ID before killing (needed for Remove event)
        let target = "\(session):.\(paneIndex)"
        let idOutput = (try? run(["display-message", "-t", target, "-p", "#{pane_id}"])) ?? ""
        let paneId = Int(idOutput.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? 0

        try runChecked(
            ["kill-pane", "-t", target],
            context: "tmux kill-pane failed"
        )
        try applyLayout(session, event: .removePane(paneId))
    }

    /// Get the number of panes in a session.
    public static func paneCount(_ session: String) throws -> Int {
        try listPanes(session).count
    }

    /// Get the number of windows in a session.
    public static func windowCount(_ session: String) throws -> Int {
        let stdout = try runChecked(
            ["list-windows", "-t", session],
            context: "failed to list windows"
        )
        return stdout.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    /// Select (focus) a pane by index, with retries.
    public static func selectPane(_ session: String, paneIndex: Int) throws {
        let target = "\(session):.\(paneIndex)"
        for attempt in 0..<3 {
            do {
                try executor.execute(["select-pane", "-t", target])
                return
            } catch {
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        throw AmuxError.tmux("tmux select-pane failed after retries")
    }

    /// Get the active pane index.
    public static func activePaneIndex(_ session: String) throws -> Int {
        let stdout = try runChecked(
            ["display-message", "-t", session, "-p", "#{pane_index}"],
            context: "failed to get active pane index"
        )
        return Int(stdout) ?? 0
    }

    /// Get the active pane's tmux ID (e.g., "%1234").
    public static func activePaneId(_ session: String) throws -> String {
        try runChecked(
            ["display-message", "-t", session, "-p", "#{pane_id}"],
            context: "failed to get active pane id"
        )
    }

    /// Get the current working directory of a pane.
    public static func paneCwd(_ session: String, paneIndex: Int) throws -> String {
        try runChecked(
            ["display-message", "-t", "\(session):.\(paneIndex)", "-p", "#{pane_current_path}"],
            context: "failed to get pane cwd"
        )
    }

    /// Get the pane ID at a specific index.
    public static func paneIdAt(_ session: String, index: Int) throws -> String {
        try runChecked(
            ["display-message", "-t", "\(session):.\(index)", "-p", "#{pane_id}"],
            context: "failed to get pane id"
        )
    }

    /// Get the pane ID at a specific window and pane index.
    private static func paneIdAtWindow(_ session: String, window: String, pane: Int) throws -> String {
        try runChecked(
            ["display-message", "-t", "\(session):\(window).\(pane)", "-p", "#{pane_id}"],
            context: "failed to get pane id"
        )
    }

    // MARK: - Title management

    /// Set the @amux-title on a pane.
    public static func setTitle(_ session: String, paneIndex: Int, title: String) throws {
        let target = "\(session):.\(paneIndex)"
        try runChecked(
            ["set-option", "-p", "-t", target, "@amux-title", title],
            context: "tmux set-option @amux-title failed"
        )
    }

    /// Get the @amux-title for a pane. Returns empty string if unset.
    public static func getTitle(_ session: String, paneIndex: Int) throws -> String {
        let target = "\(session):.\(paneIndex)"
        return try run(["display-message", "-t", target, "-p", "#{@amux-title}"])
    }

    // MARK: - Alert management

    /// Set or clear the alert flag on a pane.
    public static func setAlert(_ session: String, paneIndex: Int, alert: Bool) throws {
        let target = "\(session):.\(paneIndex)"
        let value = alert ? "1" : "0"
        try runChecked(
            ["set-option", "-p", "-t", target, "@amux-alert", value],
            context: "tmux set @amux-alert failed"
        )
    }

    /// Get the alert flag for a pane.
    public static func getAlert(_ session: String, paneIndex: Int) throws -> Bool {
        let target = "\(session):.\(paneIndex)"
        // Use runRaw — option may not exist yet (returns empty, not error)
        let stdout = runRaw(["show-options", "-p", "-t", target, "-v", "@amux-alert"])
        return stdout == "1"
    }

    /// Get alert states for all panes in a session, ordered by pane index.
    public static func alertStates(_ session: String) throws -> [Bool] {
        let panes = try listPanes(session)
        return panes.map { $0.alert }
    }

    /// Update the @amux-alert-count session option.
    public static func setAlertCount(_ session: String, count: Int) {
        runIgnoring(["set-option", "-t", session, "@amux-alert-count", String(count)])
    }

    /// Get the alert count for a session.
    public static func getAlertCount(_ session: String) throws -> Int {
        let stdout = runRaw(["show-options", "-t", session, "-v", "@amux-alert-count"])
        return Int(stdout) ?? 0
    }

    /// Clear alert on a pane and update the session alert count.
    public static func dismissAlert(_ session: String, paneIndex: Int) throws {
        let wasAlert = try getAlert(session, paneIndex: paneIndex)
        guard wasAlert else { return }
        try setAlert(session, paneIndex: paneIndex, alert: false)
        let states = try alertStates(session)
        let count = countAlerts(states)
        setAlertCount(session, count: count)
    }

    // MARK: - Split visual state

    /// Set the split-selected flag on a pane.
    public static func setSplitSelected(_ session: String, paneIndex: Int, selected: Bool) throws {
        let target = "\(session):.\(paneIndex)"
        let value = selected ? "1" : "0"
        try runChecked(
            ["set-option", "-p", "-t", target, "@amux-split-selected", value],
            context: "tmux set @amux-split-selected failed"
        )
    }

    /// Get the split-selected flag for a pane.
    public static func getSplitSelected(_ session: String, paneIndex: Int) throws -> Bool {
        let target = "\(session):.\(paneIndex)"
        let stdout = runRaw(["show-options", "-p", "-t", target, "-v", "@amux-split-selected"])
        return stdout == "1"
    }

    /// Set the picking mode flag on a session.
    public static func setPicking(_ session: String, picking: Bool) {
        let value = picking ? "1" : "0"
        runIgnoring(["set-option", "-t", session, "@amux-picking", value])
    }

    /// Get the picking mode flag for a session.
    public static func getPicking(_ session: String) throws -> Bool {
        let stdout = runRaw(["show-options", "-t", session, "-v", "@amux-picking"])
        return stdout == "1"
    }

    /// Set the split-first-label on a session.
    public static func setSplitFirstLabel(_ session: String, label: String) {
        runIgnoring(["set-option", "-t", session, "@amux-split-first-label", label])
    }

    /// Get the split-first-label for a session.
    public static func getSplitFirstLabel(_ session: String) throws -> String {
        runRaw(["show-options", "-t", session, "-v", "@amux-split-first-label"])
    }

    /// Clear the split-first-label on a session.
    public static func clearSplitFirstLabel(_ session: String) {
        runIgnoring(["set-option", "-t", session, "-u", "@amux-split-first-label"])
    }

    // MARK: - Zoom

    /// Toggle zoom on a session.
    public static func toggleZoom(_ session: String) throws {
        try runChecked(
            ["resize-pane", "-t", session, "-Z"],
            context: "tmux resize-pane -Z failed"
        )
    }

    /// Check if the session is zoomed.
    public static func isZoomed(_ session: String) throws -> Bool {
        let stdout = try run(["display-message", "-t", session, "-p", "#{window_zoomed_flag}"])
        return stdout == "1"
    }

    // MARK: - Layout

    /// Read current pane positions from tmux as Pane structs.
    public static func readPanePositions(_ session: String) throws -> [Pane] {
        let stdout = try runChecked(
            ["list-panes", "-t", session, "-F",
             "#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}"],
            context: "failed to read pane positions"
        )
        return stdout.split(separator: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.split(separator: "\t").map(String.init)
                guard parts.count >= 5 else { return nil }
                let id = Int(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? 0
                let x = Int(parts[1]) ?? 0
                let y = Int(parts[2]) ?? 0
                let w = Int(parts[3]) ?? 0
                let h = Int(parts[4]) ?? 0
                return Pane(id: id, x: x, y: y, w: w, h: h)
            }
    }

    /// Get ordered list of tmux pane IDs (numeric, like 5, 268).
    public static func getPaneIds(_ session: String) throws -> [Int] {
        let stdout = try runChecked(
            ["list-panes", "-t", session, "-F", "#{pane_id}"],
            context: "failed to list pane ids"
        )
        return stdout.split(separator: "\n")
            .compactMap { line in
                Int(line.trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            }
    }

    /// Get the window dimensions.
    public static func windowSize(_ session: String) throws -> (width: Int, height: Int) {
        let stdout = try runChecked(
            ["display-message", "-t", session, "-p", "#{window_width} #{window_height}"],
            context: "failed to get window size"
        )
        let parts = stdout.split(separator: " ").map(String.init)
        let w = Int(parts.first ?? "") ?? 80
        let h = Int(parts.count > 1 ? parts[1] : "") ?? 24
        return (w, h)
    }

    /// Check if pane-border-status is "top" (steals a row from the top).
    private static func hasPaneBorderStatus(_ session: String) -> Bool {
        let stdout = (try? run(["show-options", "-t", session, "-v", "pane-border-status"])) ?? ""
        return stdout == "top"
    }

    /// Gather all tmux state needed by the layout engine into a single snapshot.
    ///
    /// Batches tmux queries to minimize subprocess calls:
    /// - 1 call: list-panes (pane positions)
    /// - 1 call: display-message (window size, zoom flag, active pane, border status)
    /// Total: 2 subprocess calls instead of 5.
    public static func gatherLayoutState(_ session: String) throws -> LayoutState {
        let panes = try readPanePositions(session)

        // Batch window metadata into a single display-message call
        let meta = try runChecked(
            ["display-message", "-t", session, "-p",
             "#{window_width} #{window_height} #{window_zoomed_flag} #{pane_index}"],
            context: "failed to get window metadata"
        )
        let parts = meta.split(separator: " ").map(String.init)
        let windowW = Int(parts.count > 0 ? parts[0] : "") ?? 80
        let windowH = Int(parts.count > 1 ? parts[1] : "") ?? 24
        let zoomed = parts.count > 2 && parts[2] == "1"
        let activePane = Int(parts.count > 3 ? parts[3] : "") ?? 0

        // Border status is a session option, always "top" for amux-managed sessions
        let borderTop = hasPaneBorderStatus(session) ? 1 : 0

        return LayoutState(
            panes: panes,
            windowW: windowW,
            windowH: windowH,
            borderTop: borderTop,
            zoomed: zoomed,
            activePane: activePane,
            paneCount: panes.count
        )
    }

    /// Execute a LayoutAction by issuing tmux commands.
    ///
    /// Execution order matters:
    /// 1. Unzoom first (if needed) so select-layout and select-pane work
    /// 2. Apply layout string
    /// 3. Select pane (while unzoomed, so it works)
    /// 4. Zoom in (if needed) — handles pane cycling while zoomed
    /// 5. Dismiss alert
    /// 6. Error message
    /// 7. Open spaces popup (last, since it blocks)
    public static func executeLayout(_ session: String, action: LayoutAction) throws {
        // Step 1: Unzoom if needed
        if action.zoom == false, (try? isZoomed(session)) == true {
            try toggleZoom(session)
        }

        // Step 2: Apply layout
        if let ls = action.layoutString {
            try runChecked(
                ["select-layout", "-t", session, ls],
                context: "select-layout failed"
            )
        }

        // Step 3: Dismiss alert BEFORE select-pane so the border re-renders
        // with the cleared state. The after-select-pane hook fires during
        // select-pane and re-renders the border — if the alert flag is still
        // set at that point, the border stays amber.
        if let pane = action.dismissAlert {
            try dismissAlert(session, paneIndex: pane)
        }

        // Step 4: Select pane
        if let pane = action.selectPane {
            try selectPane(session, paneIndex: pane)
        }

        // Step 5: Zoom in if needed
        if action.zoom == true {
            if (try? isZoomed(session)) == true {
                // Pane cycling while zoomed: unzoom→select→re-zoom
                try toggleZoom(session) // unzoom
                try toggleZoom(session) // re-zoom on newly selected pane
            } else {
                try toggleZoom(session)
            }
        }

        // Step 6: Error message
        if let msg = action.errorMessage {
            displayMessage(session, message: msg)
        }

        // Step 7: Open spaces popup (last, since it blocks)
        if action.openSpaces {
            try openSpacesPopup()
        }
    }

    /// The unified layout pipeline: gather → compute → execute.
    public static func applyLayout(_ session: String, event: LayoutEvent) throws {
        let state = try gatherLayoutState(session)
        let action = LayoutEngine.computeLayout(state: state, event: event)
        try executeLayout(session, action: action)
    }

    // MARK: - Split view

    /// Enter split view: move two panes to a new side-by-side window.
    public static func enterSplit(_ session: String, paneA: Int, paneB: Int) throws {
        let count = try paneCount(session)
        guard count >= 3 else {
            throw AmuxError.tmux("split view requires at least 3 panes (need at least 1 remaining in grid)")
        }

        // Save original pane ID order so exitSplit can restore it
        let idsOutput = try runChecked(
            ["list-panes", "-t", session, "-F", "#{pane_id}"],
            context: "list-panes for ID order"
        )
        let originalIds = idsOutput.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        runIgnoring(["set-environment", "-t", session, "AMUX_SPLIT_PANE_ORDER",
                     originalIds.joined(separator: ",")])

        let idA = try paneIdAt(session, index: paneA)
        let idB = try paneIdAt(session, index: paneB)

        // Create a new window for the split view
        let splitWindowIdx = try runChecked(
            ["new-window", "-t", session, "-d", "-P", "-F", "#{window_index}"],
            context: "tmux new-window failed"
        )

        let targetSplit = "\(session):\(splitWindowIdx)"

        // Move pane A to the split window
        runIgnoring(["join-pane", "-s", idA, "-t", targetSplit, "-h"])

        // Move pane B next to pane A
        runIgnoring(["join-pane", "-s", idB, "-t", targetSplit, "-h"])

        // Kill the default pane that was created with new-window
        let splitPanes = try listPanesInWindow(session, window: Int(splitWindowIdx) ?? 1)
        for p in splitPanes {
            let thisId = try paneIdAtWindow(session, window: splitWindowIdx, pane: p.index)
            if thisId != idA, thisId != idB {
                let target = "\(session):\(splitWindowIdx).\(p.index)"
                runIgnoring(["kill-pane", "-t", target])
            }
        }

        // Apply side-by-side layout
        runIgnoring(["select-layout", "-t", targetSplit, "even-horizontal"])

        // Switch to the split window
        runIgnoring(["select-window", "-t", targetSplit])

        // Retile the grid window
        let gridWindow = "\(session):0"
        try applyLayout(gridWindow, event: .resize)
    }

    /// Exit split view: move panes back to grid window.
    public static func exitSplit(_ session: String) throws {
        let gridTarget = "\(session):0"

        let winCount = try windowCount(session)
        if winCount <= 1 {
            try applyLayout(session, event: .resize)
            return
        }

        // List all windows, find the non-zero one
        let stdout = try runChecked(
            ["list-windows", "-t", session, "-F", "#{window_index}"],
            context: "failed to list windows"
        )
        let splitIdx = stdout.split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.isEmpty && $0.trimmingCharacters(in: .whitespaces) != "0" })
            ?? "1"

        // Move all panes from split window back to grid
        var safety = 0
        while safety < 20 {
            safety += 1
            let splitPanes = try listPanesInWindow(session, window: Int(splitIdx) ?? 1)
            guard !splitPanes.isEmpty else { break }
            let source = "\(session):\(splitIdx).0"
            do {
                try executor.execute(["join-pane", "-s", source, "-t", gridTarget])
            } catch {
                break
            }
        }

        runIgnoring(["select-window", "-t", gridTarget])

        // Restore original pane order.
        // After join-pane, panes are appended at the end of the window.
        // We saved the original ID order in enterSplit. Now swap panes
        // into their original positions.
        let savedOrder = runRaw(["show-environment", "-t", session, "AMUX_SPLIT_PANE_ORDER"])
        if savedOrder.contains("=") {
            let orderStr = String(savedOrder.split(separator: "=").last ?? "")
            let originalIds = orderStr.split(separator: ",").map(String.init)

            // Swap panes into original order using swap-pane
            for targetIndex in 0..<originalIds.count {
                let wantedId = originalIds[targetIndex]
                // Re-read current IDs after each swap (indices shift)
                let currentOutput = runRaw(["list-panes", "-t", "\(session):0", "-F", "#{pane_id}"])
                let currentIds = currentOutput.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                guard let currentIndex = currentIds.firstIndex(of: wantedId) else { continue }
                if currentIndex != targetIndex {
                    let src = "\(session):0.\(currentIndex)"
                    let dst = "\(session):0.\(targetIndex)"
                    runIgnoring(["swap-pane", "-s", src, "-t", dst])
                }
            }

            runIgnoring(["set-environment", "-t", session, "-u", "AMUX_SPLIT_PANE_ORDER"])
        }

        try applyLayout(session, event: .resize)
    }

    // MARK: - Bell watch

    /// Set up pipe-pane on a pane to watch for BEL characters.
    public static func setupBellWatch(_ session: String, paneIndex: Int) throws {
        let bin = Config.findAmuxCLI()
        let target = "\(session):.\(paneIndex)"
        runIgnoring([
            "pipe-pane", "-t", target,
            "exec \(bin) bell-watch --session \(session) \(paneIndex)"
        ])
    }

    /// Set up bell watchers on all panes in a session.
    public static func setupAllBellWatches(_ session: String) throws {
        let panes = try listPanes(session)
        for pane in panes {
            try setupBellWatch(session, paneIndex: pane.index)
        }
    }

    // MARK: - Notifications

    /// Record the current time as the last system notification timestamp.
    public static func setLastNotificationTime(_ session: String) {
        let now = Int(Date().timeIntervalSince1970)
        runIgnoring(["set-environment", "-t", session, "AMUX_LAST_NOTIFY", String(now)])
    }

    /// Get seconds elapsed since the last system notification.
    /// Returns UInt64.max if no notification has been sent.
    public static func getLastNotificationElapsed(_ session: String) throws -> UInt64 {
        let stdout = try run(["show-environment", "-t", session, "AMUX_LAST_NOTIFY"])
        let timestampStr = stdout.hasPrefix("AMUX_LAST_NOTIFY=")
            ? String(stdout.dropFirst("AMUX_LAST_NOTIFY=".count))
            : nil
        guard let ts = timestampStr, let timestamp = UInt64(ts), timestamp > 0 else {
            return UInt64.max
        }
        let now = UInt64(Date().timeIntervalSince1970)
        return now >= timestamp ? now - timestamp : 0
    }

    // MARK: - Pane operations

    /// Move the active pane from one session to another.
    public static func sendPaneToSession(from fromSession: String, to toSession: String) throws {
        let paneId = try runChecked(
            ["display-message", "-t", fromSession, "-p", "#{pane_id}"],
            context: "failed to get pane id"
        )
        let target = "\(toSession):0"
        try runChecked(
            ["join-pane", "-s", paneId, "-t", target],
            context: "tmux join-pane failed"
        )
        // Source session may have been destroyed if we moved its last pane.
        if sessionExists(fromSession), (try? paneCount(fromSession)) ?? 0 > 0 {
            try applyLayout(fromSession, event: .resize)
        }
        try applyLayout(toSession, event: .resize)
    }

    /// Kill the default phantom pane left by createSession in a freshly-created session.
    public static func killPhantomPane(_ session: String, sentPaneId: String) throws {
        let panes = try listPanesInWindow(session, window: 0)
        for p in panes {
            let thisId = try paneIdAtWindow(session, window: "0", pane: p.index)
            if thisId != sentPaneId {
                let target = "\(session):0.\(p.index)"
                runIgnoring(["kill-pane", "-t", target])
            }
        }
    }

    // MARK: - Resize

    /// Resize a specific pane to the given dimensions.
    public static func resizePane(_ session: String, paneIndex: Int, cols: Int, rows: Int) throws {
        let target = "\(session):.\(paneIndex)"
        try runChecked(
            ["resize-pane", "-t", target, "-x", String(cols), "-y", String(rows)],
            context: "resize-pane failed"
        )
    }

    /// Smart resize: enlarge the active pane to at least minCols x minRows.
    /// If already big enough, do nothing.
    public static func smartResize(_ session: String, paneIndex: Int, minCols: Int, minRows: Int) throws {
        let panes = try listPanes(session)
        guard let pane = panes.first(where: { $0.index == paneIndex }) else { return }
        if pane.width >= minCols, pane.height >= minRows { return }
        let targetCols = max(pane.width, minCols)
        let targetRows = max(pane.height, minRows)
        try resizePane(session, paneIndex: paneIndex, cols: targetCols, rows: targetRows)
    }

    /// Restore tiled layout (equal sizes for all panes).
    public static func restoreTiled(_ session: String) throws {
        if try isZoomed(session) {
            try toggleZoom(session)
        }
        try applyLayout(session, event: .resize)
    }

    // MARK: - Display

    /// Display a message in the tmux status bar.
    public static func displayMessage(_ session: String, message: String) {
        runIgnoring(["display-message", "-t", session, message])
    }

    // MARK: - Version

    /// Check that tmux >= 3.2 is installed.
    public static func checkVersion() throws {
        let stdout = try runChecked(["-V"], context: "tmux not found — is it installed?")
        let afterTmux = stdout.hasPrefix("tmux ")
            ? String(stdout.dropFirst("tmux ".count))
            : ""
        let versionPart = afterTmux.hasPrefix("next-")
            ? String(afterTmux.dropFirst("next-".count))
            : afterTmux
        let numeric = String(versionPart.prefix(while: { $0.isNumber || $0 == "." }))
        let parts = numeric.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        if major < 3 || (major == 3 && minor < 2) {
            throw AmuxError.tmux("amux requires tmux >= 3.2 (found \(stdout))")
        }
    }

    // MARK: - Spaces popup

    /// Open the spaces picker as a tmux popup.
    public static func openSpacesPopup() throws {
        let bin = Config.findAmuxCLI()
        runIgnoring([
            "display-popup", "-E", "-w", "70", "-h", "20", "-T", " Spaces ", "\(bin) spaces"
        ])
    }

    /// Set a one-shot client-attached hook that opens the spaces picker.
    public static func setStartupSpacesHook(_ session: String) {
        let bin = Config.findAmuxCLI()
        runIgnoring([
            "set-hook", "-t", session, "client-attached",
            "run-shell \"\(bin) spaces; tmux set-hook -u -t #{session_name} client-attached\""
        ])
    }

    // MARK: - Utility

    /// Find the amux-cli binary. Delegates to Config.findAmuxCLI().
    public static func findAmuxBinary() -> String {
        return Config.findAmuxCLI()
    }

    // Legacy path search (kept for reference, unused)
    private static func _legacyFindAmux() -> String {
        let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let siblingCandidate = execURL.deletingLastPathComponent().appendingPathComponent("amux-cli")
        if FileManager.default.fileExists(atPath: siblingCandidate.path) {
            return siblingCandidate.path
        }

        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates = [
            "\(home)/.local/bin/amux-cli",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "amux"
    }
}
