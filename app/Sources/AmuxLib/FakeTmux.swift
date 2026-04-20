// FakeTmux.swift — In-memory tmux simulator for testing.
//
// Implements TmuxExecutor by pattern-matching on command args and maintaining
// bags of state. Intentionally dumb: stores layout strings without parsing them,
// stores pipe-pane commands without running them, etc.
//
// NOT modeled:
// - Layout string computation (accepts and stores, doesn't parse)
// - Spatial pane positioning (directional select cycles, doesn't use geometry)
// - Terminal rendering (border colors, status bar content)
// - Client attachment (attach-session is a no-op)
// - Process spawning (pipe-pane stores the command, doesn't run it)
// - display-popup (no-op)
// - Key bindings (unbind-key is a no-op)

import Foundation

// MARK: - State model

public class FakeTmux: TmuxExecutor {

    public class Session {
        public var windows: [Window] = []
        public var options: [String: String] = [:]
        public var environment: [String: String] = [:]
        public var hooks: [String: String] = [:]

        public init() {}
    }

    public class Window {
        public var index: Int
        public var panes: [FakePane] = []
        public var zoomed: Bool = false
        public var activePaneIndex: Int = 0
        public var layout: String = ""

        public init(index: Int) {
            self.index = index
        }
    }

    public class FakePane {
        public var id: Int
        public var width: Int
        public var height: Int
        public var options: [String: String] = [:]
        public var cwd: String = "/tmp"
        public var pipePaneCommand: String? = nil

        public init(id: Int, width: Int = 200, height: Int = 50) {
            self.id = id
            self.width = width
            self.height = height
        }
    }

    public var sessions: [String: Session] = [:]
    public var globalOptions: [String: String] = [:]
    public var serverOptions: [String: String] = [:]
    public var unhandledCommands: [[String]] = []
    public var launchedCommands: [[String]] = []
    /// The session the client is currently attached to.
    /// Updated by switch-client; used by display-message without -t.
    public var clientSession: String?
    private var nextPaneId: Int = 0

    public init() {}

    public func launch(_ args: [String]) {
        launchedCommands.append(args)
    }

    public func executeBatch(_ commands: [[String]]) throws -> String {
        var lastResult = ""
        for cmd in commands {
            lastResult = try execute(cmd)
        }
        return lastResult
    }

    // MARK: - TmuxExecutor

    @discardableResult
    public func execute(_ args: [String]) throws -> String {
        guard let command = args.first else {
            throw AmuxError.tmux("empty command")
        }
        switch command {
        case "has-session":
            return try handleHasSession(args)
        case "new-session":
            return try handleNewSession(args)
        case "kill-session":
            return try handleKillSession(args)
        case "list-sessions":
            return try handleListSessions(args)
        case "new-window":
            return try handleNewWindow(args)
        case "list-windows":
            return try handleListWindows(args)
        case "select-window":
            return try handleSelectWindow(args)
        case "list-panes":
            return try handleListPanes(args)
        case "select-pane":
            return try handleSelectPane(args)
        case "kill-pane":
            return try handleKillPane(args)
        case "join-pane":
            return try handleJoinPane(args)
        case "split-window":
            return try handleSplitWindow(args)
        case "set-option", "set":
            return try handleSetOption(args)
        case "show-options":
            return try handleShowOptions(args)
        case "set-environment":
            return try handleSetEnvironment(args)
        case "show-environment":
            return try handleShowEnvironment(args)
        case "resize-pane":
            return try handleResizePane(args)
        case "display-message":
            return try handleDisplayMessage(args)
        case "select-layout":
            return try handleSelectLayout(args)
        case "swap-pane":
            return try handleSwapPane(args)
        case "set-hook":
            return try handleSetHook(args)
        case "pipe-pane":
            return try handlePipePane(args)
        case "switch-client":
            if let target = flagValue(args, "-t") {
                let t = parseTarget(target)
                clientSession = t.session
            }
            return ""
        case "attach-session":
            return ""
        case "display-popup":
            return ""
        case "unbind-key":
            return ""
        case "-V":
            return "tmux 3.5"
        default:
            unhandledCommands.append(args)
            return ""
        }
    }

    // MARK: - Arg parsing helpers

    /// Extract the value following a flag in the args array.
    /// e.g. flagValue(args, "-t") returns the arg after "-t".
    private func flagValue(_ args: [String], _ flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
            return nil
        }
        return args[idx + 1]
    }

    /// Check if a flag is present in the args.
    private func hasFlag(_ args: [String], _ flag: String) -> Bool {
        args.contains(flag)
    }

    /// Collect positional args (non-flag values) after the command name.
    /// Skips the command at index 0 and any flag+value pairs.
    private func positionalArgs(_ args: [String]) -> [String] {
        var result: [String] = []
        var i = 1
        while i < args.count {
            if args[i].hasPrefix("-") {
                // Known flags that take a value
                let flagsWithValues: Set<String> = [
                    "-t", "-s", "-F", "-c", "-x", "-y", "-w", "-h", "-T", "-E",
                ]
                if flagsWithValues.contains(args[i]) {
                    i += 2
                } else {
                    i += 1
                }
            } else {
                result.append(args[i])
                i += 1
            }
        }
        return result
    }

    // MARK: - Target parsing

    /// Parse a tmux target string into components.
    /// Formats: "session", "session:.N", "session:W", "session:W.N", "%NNN"
    struct Target {
        let session: String
        let window: Int?
        let pane: Int?
    }

    private func parseTarget(_ target: String) -> Target {
        // Pane ID: %NNN — search all sessions
        if target.hasPrefix("%") {
            if let paneId = Int(target.dropFirst()) {
                for (sessName, sess) in sessions {
                    for win in sess.windows {
                        for (pIdx, p) in win.panes.enumerated() {
                            if p.id == paneId {
                                return Target(
                                    session: sessName, window: win.index, pane: pIdx
                                )
                            }
                        }
                    }
                }
            }
            return Target(session: target, window: nil, pane: nil)
        }

        // Split on ":"
        let colonParts = target.split(separator: ":", maxSplits: 1).map(String.init)
        let sessName = colonParts[0]

        guard colonParts.count > 1 else {
            return Target(session: sessName, window: nil, pane: nil)
        }

        let afterColon = colonParts[1]

        // "session:.N" — dot-prefixed pane in default window
        if afterColon.hasPrefix(".") {
            let paneIdx = Int(afterColon.dropFirst()) ?? 0
            return Target(session: sessName, window: 0, pane: paneIdx)
        }

        // "session:W.N" — window and pane
        let dotParts = afterColon.split(separator: ".", maxSplits: 1).map(String.init)
        if dotParts.count > 1 {
            return Target(
                session: sessName,
                window: Int(dotParts[0]),
                pane: Int(dotParts[1])
            )
        }

        // "session:W" — window only
        return Target(session: sessName, window: Int(afterColon), pane: nil)
    }

    /// Resolve a target to its session, window, and optionally pane objects.
    private func resolveTarget(_ target: String) -> (Session?, Window?, FakePane?) {
        let t = parseTarget(target)
        guard let sess = sessions[t.session] else {
            return (nil, nil, nil)
        }
        let win: Window?
        if let wIdx = t.window {
            win = sess.windows.first(where: { $0.index == wIdx })
        } else {
            win = sess.windows.first
        }
        let pane: FakePane?
        if let pIdx = t.pane, let w = win, pIdx < w.panes.count {
            pane = w.panes[pIdx]
        } else if let w = win, w.activePaneIndex < w.panes.count {
            pane = w.panes[w.activePaneIndex]
        } else {
            pane = nil
        }
        return (sess, win, pane)
    }

    /// Look up a pane by its %NNN id across all sessions.
    private func findPaneById(_ paneId: Int) -> (String, Window, Int)? {
        for (sessName, sess) in sessions {
            for win in sess.windows {
                for (idx, p) in win.panes.enumerated() {
                    if p.id == paneId {
                        return (sessName, win, idx)
                    }
                }
            }
        }
        return nil
    }

    /// Allocate a new pane ID.
    private func allocatePaneId() -> Int {
        let id = nextPaneId
        nextPaneId += 1
        return id
    }

    // MARK: - Session handlers

    private func handleHasSession(_ args: [String]) throws -> String {
        guard let name = flagValue(args, "-t") else {
            throw AmuxError.tmux("has-session: missing -t")
        }
        guard sessions[name] != nil else {
            throw AmuxError.tmux("session not found: \(name)")
        }
        return ""
    }

    private func handleNewSession(_ args: [String]) throws -> String {
        guard let name = flagValue(args, "-s") else {
            throw AmuxError.tmux("new-session: missing -s")
        }
        let sess = Session()
        let win = Window(index: 0)
        let pane = FakePane(id: allocatePaneId())
        win.panes.append(pane)
        sess.windows.append(win)
        sessions[name] = sess
        return ""
    }

    private func handleKillSession(_ args: [String]) throws -> String {
        guard let name = flagValue(args, "-t") else {
            throw AmuxError.tmux("kill-session: missing -t")
        }
        sessions.removeValue(forKey: name)
        return ""
    }

    private func handleListSessions(_ args: [String]) throws -> String {
        let names = sessions.keys.sorted()
        guard let format = flagValue(args, "-F") else {
            return names.joined(separator: "\n")
        }
        return names.map { evaluateFormatForSession(format, sessionName: $0) }
            .joined(separator: "\n")
    }

    /// Format evaluator for session-level format strings used with
    /// `list-sessions -F`. Handles `#{session_name}` and user options
    /// `#{@KEY}` from the session's option map.
    private func evaluateFormatForSession(
        _ format: String, sessionName: String
    ) -> String {
        var result = format
        result = result.replacingOccurrences(
            of: "#{session_name}", with: sessionName)

        let optionPattern = try! NSRegularExpression(pattern: "#\\{@([^}]+)\\}")
        let nsResult = result as NSString
        let matches = optionPattern.matches(
            in: result, range: NSRange(location: 0, length: nsResult.length))
        for match in matches.reversed() {
            let keyRange = match.range(at: 1)
            let key = nsResult.substring(with: keyRange)
            let value = sessions[sessionName]?.options["@\(key)"] ?? ""
            result = (result as NSString).replacingCharacters(
                in: match.range, with: value)
        }
        return result
    }

    // MARK: - Window handlers

    private func handleNewWindow(_ args: [String]) throws -> String {
        guard let sessTarget = flagValue(args, "-t") else {
            throw AmuxError.tmux("new-window: missing -t")
        }
        let sessName = parseTarget(sessTarget).session
        guard let sess = sessions[sessName] else {
            throw AmuxError.tmux("new-window: no session \(sessName)")
        }
        let nextIdx = (sess.windows.map(\.index).max() ?? -1) + 1
        let win = Window(index: nextIdx)
        let pane = FakePane(id: allocatePaneId())
        if let cwd = flagValue(args, "-c") {
            pane.cwd = cwd
        }
        win.panes.append(pane)
        sess.windows.append(win)

        // Return format based on -F flag
        if let format = flagValue(args, "-F") {
            return evaluateFormatForPane(
                format, sessionName: sessName, window: win, paneIndex: 0, pane: pane
            )
        }
        return ""
    }

    private func handleSplitWindow(_ args: [String]) throws -> String {
        guard let target = flagValue(args, "-t") else {
            throw AmuxError.tmux("split-window: missing -t")
        }
        let t = parseTarget(target)
        guard let sess = sessions[t.session] else {
            throw AmuxError.tmux("split-window: no session \(t.session)")
        }
        let win: Window?
        if let wIdx = t.window {
            win = sess.windows.first(where: { $0.index == wIdx })
        } else {
            win = sess.windows.first
        }
        guard let w = win else {
            throw AmuxError.tmux("split-window: no window for \(target)")
        }

        let pane = FakePane(id: allocatePaneId())
        if let cwd = flagValue(args, "-c") {
            pane.cwd = cwd
        }
        w.panes.append(pane)
        let newIndex = w.panes.count - 1

        // Real tmux: new pane becomes active unless -d is passed.
        if !hasFlag(args, "-d") {
            w.activePaneIndex = newIndex
        }

        if let format = flagValue(args, "-F") {
            return evaluateFormatForPane(
                format, sessionName: t.session, window: w,
                paneIndex: newIndex, pane: pane)
        }
        return ""
    }

    private func handleListWindows(_ args: [String]) throws -> String {
        guard let sessTarget = flagValue(args, "-t") else {
            throw AmuxError.tmux("list-windows: missing -t")
        }
        let sessName = parseTarget(sessTarget).session
        guard let sess = sessions[sessName] else {
            throw AmuxError.tmux("list-windows: no session \(sessName)")
        }
        if let format = flagValue(args, "-F") {
            return sess.windows.map { win in
                evaluateFormatForWindow(format, sessionName: sessName, window: win)
            }.joined(separator: "\n")
        }
        // Without format, return one line per window (like tmux default)
        return sess.windows.map { "  \($0.index)" }.joined(separator: "\n")
    }

    private func handleSelectWindow(_ args: [String]) throws -> String {
        guard let target = flagValue(args, "-t") else {
            throw AmuxError.tmux("select-window: missing -t")
        }
        // select-window just changes the active window; no-op for the fake
        // since we don't track which window is "current" at the session level.
        let _ = parseTarget(target)
        return ""
    }

    // MARK: - Pane handlers

    private func handleListPanes(_ args: [String]) throws -> String {
        guard let target = flagValue(args, "-t") else {
            throw AmuxError.tmux("list-panes: missing -t")
        }
        let t = parseTarget(target)
        guard let sess = sessions[t.session] else {
            throw AmuxError.tmux("list-panes: no session \(t.session)")
        }
        let win: Window?
        if let wIdx = t.window {
            win = sess.windows.first(where: { $0.index == wIdx })
        } else {
            win = sess.windows.first
        }
        guard let w = win else { return "" }

        guard let format = flagValue(args, "-F") else {
            return w.panes.enumerated().map { "\($0.offset)" }.joined(separator: "\n")
        }

        return w.panes.enumerated().map { (idx, pane) in
            evaluateFormatForPane(
                format, sessionName: t.session, window: w, paneIndex: idx, pane: pane
            )
        }.joined(separator: "\n")
    }

    private func handleSelectPane(_ args: [String]) throws -> String {
        guard let target = flagValue(args, "-t") else {
            throw AmuxError.tmux("select-pane: missing -t")
        }

        // Check for directional flags
        let directions: Set<String> = ["-L", "-R", "-U", "-D"]
        let hasDirection = args.contains(where: { directions.contains($0) })

        let t = parseTarget(target)
        guard let sess = sessions[t.session] else {
            throw AmuxError.tmux("select-pane: no session \(t.session)")
        }
        let win = t.window.flatMap { wIdx in
            sess.windows.first(where: { $0.index == wIdx })
        } ?? sess.windows.first

        guard let w = win else { return "" }

        if hasDirection {
            // Simplified: cycle through panes
            if args.contains("-R") || args.contains("-D") {
                w.activePaneIndex = (w.activePaneIndex + 1) % max(w.panes.count, 1)
            } else {
                w.activePaneIndex =
                    (w.activePaneIndex - 1 + w.panes.count) % max(w.panes.count, 1)
            }
        } else if let pIdx = t.pane {
            w.activePaneIndex = pIdx
        }
        return ""
    }

    private func handleKillPane(_ args: [String]) throws -> String {
        guard let target = flagValue(args, "-t") else {
            throw AmuxError.tmux("kill-pane: missing -t")
        }
        let t = parseTarget(target)
        guard let sess = sessions[t.session] else {
            throw AmuxError.tmux("kill-pane: no session \(t.session)")
        }
        let win = t.window.flatMap { wIdx in
            sess.windows.first(where: { $0.index == wIdx })
        } ?? sess.windows.first

        guard let w = win else { return "" }

        let pIdx = t.pane ?? w.activePaneIndex
        guard pIdx < w.panes.count else {
            throw AmuxError.tmux("kill-pane: pane index out of range")
        }
        w.panes.remove(at: pIdx)
        if w.activePaneIndex >= w.panes.count {
            w.activePaneIndex = max(w.panes.count - 1, 0)
        }
        return ""
    }

    private func handleJoinPane(_ args: [String]) throws -> String {
        guard let source = flagValue(args, "-s"),
            let targetStr = flagValue(args, "-t")
        else {
            throw AmuxError.tmux("join-pane: missing -s or -t")
        }

        // Find the source pane
        let srcTarget = parseTarget(source)
        let srcPane: FakePane?
        let srcWindow: Window?

        if source.hasPrefix("%"), let paneId = Int(source.dropFirst()) {
            // Source is a pane ID
            guard let found = findPaneById(paneId) else {
                throw AmuxError.tmux("join-pane: source pane not found")
            }
            srcWindow = found.1
            srcPane = srcWindow?.panes[found.2]
            srcWindow?.panes.remove(at: found.2)
            // Clean up empty windows; destroy session if no windows remain (matches real tmux)
            if let sw = srcWindow, sw.panes.isEmpty {
                let sessName = found.0
                let srcSess = sessions[sessName]
                srcSess?.windows.removeAll(where: { $0.index == sw.index })
                if srcSess?.windows.isEmpty == true {
                    sessions.removeValue(forKey: sessName)
                }
            }
        } else {
            let sessName = srcTarget.session
            guard let sess = sessions[sessName] else {
                throw AmuxError.tmux("join-pane: source session not found")
            }
            srcWindow =
                srcTarget.window.flatMap { wIdx in
                    sess.windows.first(where: { $0.index == wIdx })
                } ?? sess.windows.first
            let pIdx = srcTarget.pane ?? srcWindow?.activePaneIndex ?? 0
            guard let sw = srcWindow, pIdx < sw.panes.count else {
                throw AmuxError.tmux("join-pane: source pane not found")
            }
            srcPane = sw.panes[pIdx]
            sw.panes.remove(at: pIdx)
            if sw.activePaneIndex >= sw.panes.count {
                sw.activePaneIndex = max(sw.panes.count - 1, 0)
            }
            // Destroy empty window; destroy session if no windows remain (matches real tmux)
            if sw.panes.isEmpty {
                sess.windows.removeAll(where: { $0.index == sw.index })
                if sess.windows.isEmpty {
                    sessions.removeValue(forKey: sessName)
                }
            }
        }

        guard let pane = srcPane else {
            throw AmuxError.tmux("join-pane: could not resolve source pane")
        }

        // Add to target window
        let dstTarget = parseTarget(targetStr)
        guard let dstSess = sessions[dstTarget.session] else {
            throw AmuxError.tmux("join-pane: target session not found")
        }
        let dstWin =
            dstTarget.window.flatMap { wIdx in
                dstSess.windows.first(where: { $0.index == wIdx })
            } ?? dstSess.windows.first
        guard let dw = dstWin else {
            throw AmuxError.tmux("join-pane: target window not found")
        }
        dw.panes.append(pane)
        return ""
    }

    // MARK: - Option handlers

    private func handleSetOption(_ args: [String]) throws -> String {
        let isPaneOption = hasFlag(args, "-p")
        let isGlobal = hasFlag(args, "-g")
        let isServer = hasFlag(args, "-s") || hasFlag(args, "-sg")
        let isAppend = hasFlag(args, "-sa")
        let isUnset = hasFlag(args, "-u")

        let target = flagValue(args, "-t")
        let positionals = positionalArgs(args)

        if isGlobal || isServer || isAppend {
            let key = positionals.count > 0 ? positionals[0] : ""
            let value = positionals.count > 1 ? positionals[1] : ""
            if isAppend {
                let existing = serverOptions[key] ?? globalOptions[key] ?? ""
                serverOptions[key] = existing + value
            } else if isServer {
                serverOptions[key] = value
            } else {
                globalOptions[key] = value
            }
            return ""
        }

        if isPaneOption {
            // Pane option: set-option -p [-u] -t TARGET KEY [VALUE]
            guard let tgt = target else {
                throw AmuxError.tmux("set-option -p: missing -t")
            }
            let key = positionals.count > 0 ? positionals[0] : ""
            let (_, _, pane) = resolveTarget(tgt)
            if isUnset {
                pane?.options.removeValue(forKey: key)
            } else {
                let value = positionals.count > 1 ? positionals[1] : ""
                pane?.options[key] = value
            }
            return ""
        }

        // Session option
        if let tgt = target {
            let sessName = parseTarget(tgt).session
            guard let sess = sessions[sessName] else {
                return ""  // runIgnoring pattern — don't throw
            }
            if isUnset {
                let key = positionals.count > 0 ? positionals[0] : ""
                sess.options.removeValue(forKey: key)
            } else {
                let key = positionals.count > 0 ? positionals[0] : ""
                let value = positionals.count > 1 ? positionals[1] : ""
                sess.options[key] = value
            }
        }
        return ""
    }

    private func handleShowOptions(_ args: [String]) throws -> String {
        let isPaneOption = hasFlag(args, "-p")
        let isGlobal = hasFlag(args, "-gv") || hasFlag(args, "-g")

        if isGlobal {
            // show-options -gv KEY
            let positionals = positionalArgs(args)
            let key = positionals.first ?? ""
            return globalOptions[key] ?? ""
        }

        let target = flagValue(args, "-t")

        if isPaneOption {
            guard let tgt = target else { return "" }
            let positionals = positionalArgs(args)
            let key = positionals.first ?? ""
            let (_, _, pane) = resolveTarget(tgt)
            // Real tmux throws for unset user options (non-zero exit).
            // Match that behavior so tests catch missing-option bugs.
            guard let value = pane?.options[key] else {
                throw AmuxError.tmux("invalid option: \(key)")
            }
            return value
        }

        // Session option
        guard let tgt = target else { return "" }
        let sessName = parseTarget(tgt).session
        let positionals = positionalArgs(args)
        let key = positionals.first ?? ""
        guard let value = sessions[sessName]?.options[key] else {
            throw AmuxError.tmux("invalid option: \(key)")
        }
        return value
    }

    // MARK: - Environment handlers

    private func handleSetEnvironment(_ args: [String]) throws -> String {
        guard let tgt = flagValue(args, "-t") else {
            throw AmuxError.tmux("set-environment: missing -t")
        }
        let sessName = parseTarget(tgt).session

        if hasFlag(args, "-u") {
            // Unset
            let positionals = positionalArgs(args)
            let key = positionals.first ?? ""
            sessions[sessName]?.environment.removeValue(forKey: key)
        } else {
            let positionals = positionalArgs(args)
            let key = positionals.count > 0 ? positionals[0] : ""
            let value = positionals.count > 1 ? positionals[1] : ""
            sessions[sessName]?.environment[key] = value
        }
        return ""
    }

    private func handleShowEnvironment(_ args: [String]) throws -> String {
        guard let tgt = flagValue(args, "-t") else {
            throw AmuxError.tmux("show-environment: missing -t")
        }
        let sessName = parseTarget(tgt).session
        let positionals = positionalArgs(args)
        let key = positionals.first ?? ""
        if let val = sessions[sessName]?.environment[key] {
            return "\(key)=\(val)"
        }
        return ""
    }

    // MARK: - Resize handler

    private func handleResizePane(_ args: [String]) throws -> String {
        guard let target = flagValue(args, "-t") else {
            throw AmuxError.tmux("resize-pane: missing -t")
        }

        // Toggle zoom: resize-pane -t SESSION -Z
        if hasFlag(args, "-Z") {
            let sessName = parseTarget(target).session
            guard let sess = sessions[sessName] else { return "" }
            let win = sess.windows.first
            win?.zoomed.toggle()
            return ""
        }

        // Resize specific pane: resize-pane -t TARGET -x COLS -y ROWS
        if let colsStr = flagValue(args, "-x"), let rowsStr = flagValue(args, "-y") {
            let (_, _, pane) = resolveTarget(target)
            if let cols = Int(colsStr) { pane?.width = cols }
            if let rows = Int(rowsStr) { pane?.height = rows }
        }
        return ""
    }

    // MARK: - Display message handler

    private func handleDisplayMessage(_ args: [String]) throws -> String {
        let target: String
        if let explicit = flagValue(args, "-t") {
            target = explicit
        } else if let client = clientSession {
            target = client
        } else {
            throw AmuxError.tmux("display-message: missing -t and no client session")
        }

        // display-message -t TARGET -p FORMAT → evaluate format
        if hasFlag(args, "-p") {
            let positionals = positionalArgs(args)
            let format = positionals.first ?? ""
            return evaluateFormat(target: target, format: format)
        }

        // display-message -t SESSION MESSAGE → no-op (status bar)
        return ""
    }

    // MARK: - Layout handler

    private func handleSwapPane(_ args: [String]) throws -> String {
        // swap-pane -s SOURCE -t TARGET
        guard let srcStr = flagValue(args, "-s"),
              let dstStr = flagValue(args, "-t") else {
            throw AmuxError.tmux("swap-pane: missing -s or -t")
        }
        let src = parseTarget(srcStr)
        let dst = parseTarget(dstStr)
        guard let sess = sessions[src.session],
              let srcWinIdx = src.window, let dstWinIdx = dst.window,
              let srcPaneIdx = src.pane, let dstPaneIdx = dst.pane else { return "" }
        guard let srcWin = sess.windows.first(where: { $0.index == srcWinIdx }),
              let dstWin = sess.windows.first(where: { $0.index == dstWinIdx }) else { return "" }
        guard srcPaneIdx < srcWin.panes.count, dstPaneIdx < dstWin.panes.count else { return "" }

        // Swap the panes
        if srcWin === dstWin {
            srcWin.panes.swapAt(srcPaneIdx, dstPaneIdx)
        }
        return ""
    }

    private func handleSelectLayout(_ args: [String]) throws -> String {
        guard let target = flagValue(args, "-t") else {
            throw AmuxError.tmux("select-layout: missing -t")
        }
        let positionals = positionalArgs(args)
        let layout = positionals.first ?? ""
        let t = parseTarget(target)
        guard let sess = sessions[t.session] else { return "" }
        let win =
            t.window.flatMap { wIdx in
                sess.windows.first(where: { $0.index == wIdx })
            } ?? sess.windows.first
        win?.layout = layout
        return ""
    }

    // MARK: - Hook handler

    private func handleSetHook(_ args: [String]) throws -> String {
        // Global unset: set-hook -gu HOOK
        if hasFlag(args, "-gu") {
            return ""
        }

        // Session unset: set-hook -u -t SESSION HOOK
        if hasFlag(args, "-u") {
            if let tgt = flagValue(args, "-t") {
                let sessName = parseTarget(tgt).session
                let positionals = positionalArgs(args)
                let hook = positionals.first ?? ""
                sessions[sessName]?.hooks.removeValue(forKey: hook)
            }
            return ""
        }

        // Session hook: set-hook -t SESSION HOOK COMMAND
        if let tgt = flagValue(args, "-t") {
            let sessName = parseTarget(tgt).session
            let positionals = positionalArgs(args)
            let hook = positionals.count > 0 ? positionals[0] : ""
            let command = positionals.count > 1 ? positionals[1] : ""
            sessions[sessName]?.hooks[hook] = command
        }
        return ""
    }

    // MARK: - Pipe-pane handler

    private func handlePipePane(_ args: [String]) throws -> String {
        guard let target = flagValue(args, "-t") else {
            throw AmuxError.tmux("pipe-pane: missing -t")
        }
        let positionals = positionalArgs(args)
        let command = positionals.first ?? ""
        let (_, _, pane) = resolveTarget(target)
        pane?.pipePaneCommand = command.isEmpty ? nil : command
        return ""
    }

    // MARK: - Format evaluation

    /// Evaluate a tmux format string for a specific target.
    private func evaluateFormat(target: String, format: String) -> String {
        let t = parseTarget(target)
        let sess = sessions[t.session]
        let win: Window?
        if let wIdx = t.window {
            win = sess?.windows.first(where: { $0.index == wIdx })
        } else {
            win = sess?.windows.first
        }

        let pane: FakePane?
        if let pIdx = t.pane, let w = win, pIdx < w.panes.count {
            pane = w.panes[pIdx]
        } else if let w = win, w.activePaneIndex < w.panes.count {
            pane = w.panes[w.activePaneIndex]
        } else {
            pane = nil
        }

        let paneIndex: Int
        if let pIdx = t.pane {
            paneIndex = pIdx
        } else {
            paneIndex = win?.activePaneIndex ?? 0
        }

        return evaluateFormatForPane(
            format,
            sessionName: t.session,
            window: win,
            paneIndex: paneIndex,
            pane: pane
        )
    }

    /// Core format evaluator given resolved objects.
    private func evaluateFormatForPane(
        _ format: String,
        sessionName: String,
        window: Window?,
        paneIndex: Int,
        pane: FakePane?
    ) -> String {
        var result = format
        result = result.replacingOccurrences(
            of: "#{pane_index}", with: "\(paneIndex)")
        result = result.replacingOccurrences(
            of: "#{pane_id}", with: "%\(pane?.id ?? 0)")
        result = result.replacingOccurrences(
            of: "#{pane_width}", with: "\(pane?.width ?? 200)")
        result = result.replacingOccurrences(
            of: "#{pane_height}", with: "\(pane?.height ?? 50)")
        result = result.replacingOccurrences(
            of: "#{pane_active}",
            with: (paneIndex == (window?.activePaneIndex ?? 0)) ? "1" : "0")
        result = result.replacingOccurrences(
            of: "#{pane_left}", with: "0")
        result = result.replacingOccurrences(
            of: "#{pane_top}", with: "0")
        result = result.replacingOccurrences(
            of: "#{pane_current_path}", with: pane?.cwd ?? "/tmp")
        result = result.replacingOccurrences(
            of: "#{window_zoomed_flag}",
            with: (window?.zoomed ?? false) ? "1" : "0")
        result = result.replacingOccurrences(
            of: "#{window_width}", with: "\(pane?.width ?? 200)")
        result = result.replacingOccurrences(
            of: "#{window_height}", with: "\(pane?.height ?? 50)")
        result = result.replacingOccurrences(
            of: "#{window_index}", with: "\(window?.index ?? 0)")
        result = result.replacingOccurrences(
            of: "#{session_name}", with: sessionName)

        // User options: #{@KEY} — look up in pane options first, then session
        let optionPattern = try! NSRegularExpression(pattern: "#\\{@([^}]+)\\}")
        let nsResult = result as NSString
        let matches = optionPattern.matches(
            in: result, range: NSRange(location: 0, length: nsResult.length)
        )
        // Process matches in reverse to preserve indices
        for match in matches.reversed() {
            let fullRange = match.range
            let keyRange = match.range(at: 1)
            let key = nsResult.substring(with: keyRange)
            let optionKey = "@\(key)"
            let value =
                pane?.options[optionKey]
                ?? sessions[sessionName]?.options[optionKey]
                ?? ""
            result = (result as NSString).replacingCharacters(in: fullRange, with: value)
        }

        return result
    }

    /// Format evaluator for window-level format strings.
    private func evaluateFormatForWindow(
        _ format: String, sessionName: String, window: Window
    ) -> String {
        var result = format
        result = result.replacingOccurrences(
            of: "#{window_index}", with: "\(window.index)")
        result = result.replacingOccurrences(
            of: "#{session_name}", with: sessionName)
        result = result.replacingOccurrences(
            of: "#{window_zoomed_flag}",
            with: window.zoomed ? "1" : "0")
        return result
    }
}

// MARK: - Builder helpers

extension FakeTmux {

    /// Create a session with N panes in window 0.
    @discardableResult
    public func addSession(
        _ name: String, panes paneCount: Int = 1,
        width: Int = 200, height: Int = 50
    ) -> Session {
        let session = Session()
        let window = Window(index: 0)
        for _ in 0..<paneCount {
            let pane = FakePane(id: allocatePaneId(), width: width, height: height)
            window.panes.append(pane)
        }
        session.windows.append(window)
        sessions[name] = session
        if clientSession == nil { clientSession = name }
        return session
    }

    /// Set zoom state on a session's first window.
    public func setZoomed(_ session: String, _ zoomed: Bool) {
        sessions[session]?.windows.first?.zoomed = zoomed
    }

    /// Set a pane option directly (convenience for test setup).
    public func setPaneOption(
        _ session: String, paneIndex: Int, key: String, value: String
    ) {
        let (_, win, _) = resolveTarget("\(session):.0")
        if let w = win, paneIndex < w.panes.count {
            w.panes[paneIndex].options[key] = value
        }
    }

    /// Set a session environment variable directly.
    public func setEnvironment(_ session: String, key: String, value: String) {
        sessions[session]?.environment[key] = value
    }

    /// Set a session option directly.
    public func setSessionOption(_ session: String, key: String, value: String) {
        sessions[session]?.options[key] = value
    }

    /// Get a pane by session name and index (for assertions in tests).
    public func pane(_ session: String, index: Int) -> FakePane? {
        guard let sess = sessions[session],
            let win = sess.windows.first,
            index < win.panes.count
        else { return nil }
        return win.panes[index]
    }
}
