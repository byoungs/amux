/// amux-cli — lightweight CLI for tmux hook commands.
///
/// Called by tmux hooks (pane-exited, client-resized, after-select-pane)
/// and by pipe-pane for bell watching. Imports AmuxLib for shared logic.
///
/// Usage:
///   amux-cli layout SESSION          Re-apply grid layout
///   amux-cli update-title PANE CWD   Update pane title from directory
///   amux-cli alert-pane PANE         Mark pane as needing attention
///   amux-cli bell-watch --session SESSION PANE   Watch stdin for BEL
///   amux-cli hook-install            Install Claude Code notification hook
///   amux-cli spaces                  Interactive space picker (runs in popup)
///   amux-cli send                    Send current pane to another space

import Foundation
import Darwin
import AmuxLib

// MARK: - Raw terminal helpers

/// Key events from raw terminal input.
enum RawKey {
    case char(UInt8)
    case enter
    case escape
    case up
    case down
    case backspace
}

/// Enter raw terminal mode. Returns original termios to restore later.
func enterRawMode() -> termios {
    var orig = termios()
    tcgetattr(STDIN_FILENO, &orig)
    var raw = orig
    cfmakeraw(&raw)
    raw.c_oflag |= UInt(OPOST) // keep output processing so \n works
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    return orig
}

/// Restore terminal mode.
func restoreTerminal(_ orig: termios) {
    var t = orig
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
}

/// Read a single key event in raw mode.
func readRawKey() -> RawKey {
    var buf = [UInt8](repeating: 0, count: 1)
    guard read(STDIN_FILENO, &buf, 1) == 1 else { return .escape }

    switch buf[0] {
    case 0x1B: // Escape or arrow sequence
        var seq = [UInt8](repeating: 0, count: 2)
        // Set short timeout to distinguish bare Escape from sequences
        var t = termios()
        tcgetattr(STDIN_FILENO, &t)
        withUnsafeMutablePointer(to: &t.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { p in
                p[Int(VMIN)] = 0
                p[Int(VTIME)] = 1
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
        let n = read(STDIN_FILENO, &seq, 2)
        withUnsafeMutablePointer(to: &t.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { p in
                p[Int(VMIN)] = 1
                p[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
        if n == 2, seq[0] == 0x5B { // [
            switch seq[1] {
            case 0x41: return .up    // A
            case 0x42: return .down  // B
            default: return .escape
            }
        }
        return .escape
    case 0x0D, 0x0A: return .enter
    case 0x7F, 0x08: return .backspace
    default: return .char(buf[0])
    }
}

/// Read a line of input in raw mode. Escape cancels (returns nil).
func readInputRaw() -> String? {
    var input = ""
    while true {
        let key = readRawKey()
        switch key {
        case .escape: return nil
        case .enter:
            print("\r")
            return input
        case .backspace:
            if !input.isEmpty {
                input.removeLast()
                print("\u{08} \u{08}", terminator: "")
                fflush(stdout)
            }
        case .char(let b) where b >= 0x20:
            input.append(Character(Unicode.Scalar(b)))
            print(String(Character(Unicode.Scalar(b))), terminator: "")
            fflush(stdout)
        default: break
        }
    }
}

// MARK: - Session helpers

/// Get the current tmux session name.
func currentSession() -> String {
    let result = Tmux.runRaw(["display-message", "-p", "#{session_name}"])
    let name = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "amux" : name
}

/// Send the active pane from one session to another, switching the client
/// to the destination if this was the last pane.
///
/// When moving the last pane, the source session is destroyed by tmux.
/// If we're running inside a display-popup on the source session, that
/// kills the popup. To avoid this, we switch the client to the destination
/// BEFORE moving the pane. join-pane works with explicit pane IDs regardless
/// of which session the client is on.
func sendPaneAndFollow(from source: String, to destination: String) throws {
    let countBefore = (try? Tmux.paneCount(source)) ?? 0
    if countBefore <= 1 {
        // Switch client first so the popup survives session destruction
        try Tmux.switchSession(destination)
    }
    try Tmux.sendPaneToSession(from: source, to: destination)
    if countBefore <= 1 {
        // Re-layout and select pane on the destination
        try? Tmux.applyLayout(destination, event: .resize)
    }
}

/// Switch to a space with smart landing (alert navigation).
///
/// Optimized for absolute minimum subprocess calls:
///   1. listPanes(target) — gathers alert states + active pane in 1 call (~65ms)
///   2. One batched call: suppress hook + switch + dismiss alert + select pane + restore hook (~65ms)
///
/// Total: ~130ms before exit (down from ~500ms).
///
/// Note: applyLayout is intentionally skipped. The target session was laid out
/// correctly when we last left it, and the popup overlay doesn't change window
/// dimensions. If the window WAS resized, the client-resized hook will fire
/// applyLayout asynchronously.
func switchToSpace(_ target: String) throws {
    // 1. Single call: list panes with alert + active info
    let panes = (try? Tmux.listPanes(target)) ?? []
    let alertStates = panes.map { $0.alert }
    let prevPane = panes.first(where: { $0.active })?.index ?? 0
    let landing = smartLanding(alertStates: alertStates, prevPane: prevPane)

    // Compute landing pane and whether we need to dismiss alert
    let landingPane: Int
    let shouldDismissAlert: Bool
    switch landing {
    case .focusPane(let index):
        landingPane = index
        shouldDismissAlert = true
    case .resume(let pane):
        landingPane = pane
        shouldDismissAlert = false
    }

    // 2. Build batched command sequence
    let bin = Config.findAmuxCLI()
    let hookCmd = "run-shell \"AMUX_SESSION=#{session_name} \(bin) update-title #{pane_index} '#{pane_current_path}'\""

    var batch: [[String]] = [
        ["set-hook", "-t", target, "-u", "after-select-pane"],
        ["switch-client", "-t", target],
        ["select-pane", "-t", "\(target):.\(landingPane)"],
    ]

    if shouldDismissAlert {
        // Inline dismiss alert: clear flag, recompute count
        let alertedAfter = panes.filter { $0.alert && $0.index != landingPane }.count
        batch.append(["set-option", "-p", "-t", "\(target):.\(landingPane)", "@amux-alert", "0"])
        batch.append(["set-option", "-t", target, "@amux-alert-count", String(alertedAfter)])
    }

    batch.append(["set-hook", "-t", target, "after-select-pane", hookCmd])

    // Update the landing pane's title — the hook was suppressed during
    // select-pane, so without this the title stays stale until the user
    // manually switches panes within the session.
    batch.append(["run-shell",
        "AMUX_SESSION=\(target) \(bin) update-title \(landingPane) '#{pane_current_path}'"])

    Tmux.batchRaw(batch)
}

// MARK: - Picker TUI

/// ANSI escape helpers.
private let ansiReset    = "\u{1B}[0m"
private let ansiBold     = "\u{1B}[1m"
private let ansiCyan     = "\u{1B}[36m"
private let ansiBoldCyan = "\u{1B}[1;36m"
private let ansiYellow   = "\u{1B}[33m"
private let ansiGreen    = "\u{1B}[32m"
private let ansiAmber    = "\u{1B}[38;5;214m"
private let ansiGray     = "\u{1B}[90m"
private let ansiClear    = "\u{1B}[2J\u{1B}[H"
private let ansiDim      = "\u{1B}[2m"
private let ansiWhite    = "\u{1B}[37m"

/// Draw the spaces picker list.
func drawSpacesPicker(sessions: [String], cursor: Int, current: String, alertCounts: [String: Int]) {
    var out = ansiClear
    out += "\r\n  \(ansiBoldCyan)Spaces\(ansiReset)\r\n\r\n"

    for (i, session) in sessions.enumerated() {
        let arrow = i == cursor ? "\(ansiCyan)\u{2192}\(ansiReset)" : " "
        let num = "\(ansiYellow)\(i + 1)\(ansiReset)"
        let name = i == cursor ? "\(ansiBold)\(session)\(ansiReset)" : session
        var dots = ""
        if session == current {
            dots += " \(ansiGreen)\u{25CF}\(ansiReset)"
        }
        let alerts = alertCounts[session] ?? 0
        if alerts > 0 {
            dots += " \(ansiAmber)\(String(repeating: "\u{25CF}", count: alerts))\(ansiReset)"
        }
        out += "  \(arrow) \(num) \(name)\(dots)\r\n"
    }

    out += "\r\n  \(ansiGray)\u{2191}\u{2193} select \u{00B7} Enter switch \u{00B7} 1-9 jump \u{00B7} n new \u{00B7} Esc cancel\(ansiReset)\r\n"
    print(out, terminator: "")
    fflush(stdout)
}

/// Draw the send picker list.
func drawSendPicker(sessions: [String], cursor: Int, alertCounts: [String: Int]) {
    var out = ansiClear
    out += "\r\n  \(ansiBoldCyan)Send pane to\u{2026}\(ansiReset)\r\n\r\n"

    for (i, session) in sessions.enumerated() {
        let arrow = i == cursor ? "\(ansiCyan)\u{2192}\(ansiReset)" : " "
        let num = "\(ansiYellow)\(i + 1)\(ansiReset)"
        let name = i == cursor ? "\(ansiBold)\(session)\(ansiReset)" : session
        var dots = ""
        let alerts = alertCounts[session] ?? 0
        if alerts > 0 {
            dots += " \(ansiAmber)\(String(repeating: "\u{25CF}", count: alerts))\(ansiReset)"
        }
        out += "  \(arrow) \(num) \(name)\(dots)\r\n"
    }

    out += "\r\n  \(ansiGray)\u{2191}\u{2193} select \u{00B7} Enter send \u{00B7} 1-9 jump \u{00B7} n new \u{00B7} Esc cancel\(ansiReset)\r\n"
    print(out, terminator: "")
    fflush(stdout)
}

/// Draw the help screen — man-page-style keyboard shortcut reference.
func drawHelp() {
    var out = ansiClear
    out += "\r\n  \(ansiBoldCyan)amux Keyboard Shortcuts\(ansiReset)\r\n"

    for section in HelpContent.sections {
        out += "\r\n  \(ansiYellow)\(section.title)\(ansiReset)\r\n"
        for entry in section.entries {
            let key = entry.key.padding(toLength: 10, withPad: " ", startingAt: 0)
            out += "    \(ansiBold)\(ansiWhite)\(key)\(ansiReset)  \(ansiGray)\(entry.description)\(ansiReset)\r\n"
        }
    }

    out += "\r\n  \(ansiDim)Press any key to close\(ansiReset)\r\n"
    print(out, terminator: "")
    fflush(stdout)
}

/// Gather alert counts for a list of sessions.
func gatherAlertCounts(_ sessions: [String]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for session in sessions {
        counts[session] = (try? Tmux.getAlertCount(session)) ?? 0
    }
    return counts
}

/// Prompt for a new space name in raw mode, create the session, and return its name (or nil if cancelled).
func createNewSpace(orig: termios) throws -> String? {
    print("\r\n  \(ansiBoldCyan)New space name:\(ansiReset) ", terminator: "")
    fflush(stdout)
    guard let name = readInputRaw(), !name.isEmpty else {
        return nil
    }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    try Tmux.createSession(trimmed)
    Tmux.markAsManaged(trimmed)
    try Config.applyConfig(session: trimmed)
    try Tmux.setupAllBellWatches(trimmed)
    return trimmed
}

/// Run the spaces picker TUI. Returns when the user makes a selection or cancels.
func runSpacesPicker() throws {
    let current = currentSession()
    var sessions = (try? Tmux.listFocusSessions()) ?? []
    if sessions.isEmpty {
        sessions = [current]
    }
    var alertCounts = gatherAlertCounts(sessions)
    var cursor = sessions.firstIndex(of: current) ?? 0

    let orig = enterRawMode()
    defer { restoreTerminal(orig) }

    drawSpacesPicker(sessions: sessions, cursor: cursor, current: current, alertCounts: alertCounts)

    while true {
        let key = readRawKey()
        switch key {
        case .escape:
            return
        case .up:
            cursor = (cursor - 1 + sessions.count) % sessions.count
            drawSpacesPicker(sessions: sessions, cursor: cursor, current: current, alertCounts: alertCounts)
        case .down:
            cursor = (cursor + 1) % sessions.count
            drawSpacesPicker(sessions: sessions, cursor: cursor, current: current, alertCounts: alertCounts)
        case .enter:
            let target = sessions[cursor]
            if target != current {
                restoreTerminal(orig)
                try switchToSpace(target)
            }
            return
        case .char(let b) where b >= 0x31 && b <= 0x39: // 1-9
            let idx = Int(b - 0x31)
            if idx < sessions.count {
                let target = sessions[idx]
                if target != current {
                    restoreTerminal(orig)
                    try switchToSpace(target)
                }
                return
            }
        case .char(let b) where b == 0x6E: // 'n'
            if let newName = try createNewSpace(orig: orig) {
                restoreTerminal(orig)
                try switchToSpace(newName)
                return
            }
            // Cancelled — refresh and redraw
            sessions = (try? Tmux.listFocusSessions()) ?? sessions
            alertCounts = gatherAlertCounts(sessions)
            drawSpacesPicker(sessions: sessions, cursor: cursor, current: current, alertCounts: alertCounts)
        default:
            break
        }
    }
}

/// Run the send picker TUI. Returns when the user makes a selection or cancels.
func runSendPicker() throws {
    let current = currentSession()
    let allSessions = (try? Tmux.listFocusSessions()) ?? []
    var sessions = allSessions.filter { $0 != current }

    if sessions.isEmpty {
        // No other spaces to send to — offer to create one
        let orig = enterRawMode()
        defer { restoreTerminal(orig) }
        print(ansiClear, terminator: "")
        print("\r\n  \(ansiBoldCyan)Send pane to\u{2026}\(ansiReset)\r\n", terminator: "")
        print("\r\n  \(ansiGray)No other spaces. Press n to create one, Esc to cancel.\(ansiReset)\r\n", terminator: "")
        fflush(stdout)
        while true {
            let key = readRawKey()
            switch key {
            case .escape:
                return
            case .char(let b) where b == 0x6E:
                if let newName = try createNewSpace(orig: orig) {
                    let paneCount = (try? Tmux.paneCount(current)) ?? 1
                    restoreTerminal(orig)
                    try Tmux.sendPaneToSession(from: current, to: newName)
                    if paneCount <= 1 {
                        try switchToSpace(newName)
                    }
                }
                return
            default:
                break
            }
        }
    }

    var alertCounts = gatherAlertCounts(sessions)
    var cursor = 0

    let orig = enterRawMode()
    defer { restoreTerminal(orig) }

    drawSendPicker(sessions: sessions, cursor: cursor, alertCounts: alertCounts)

    while true {
        let key = readRawKey()
        switch key {
        case .escape:
            return
        case .up:
            cursor = (cursor - 1 + sessions.count) % sessions.count
            drawSendPicker(sessions: sessions, cursor: cursor, alertCounts: alertCounts)
        case .down:
            cursor = (cursor + 1) % sessions.count
            drawSendPicker(sessions: sessions, cursor: cursor, alertCounts: alertCounts)
        case .enter:
            let target = sessions[cursor]
            let paneCount = (try? Tmux.paneCount(current)) ?? 1
            restoreTerminal(orig)
            try Tmux.sendPaneToSession(from: current, to: target)
            if paneCount <= 1 {
                try switchToSpace(target)
            }
            return
        case .char(let b) where b >= 0x31 && b <= 0x39: // 1-9
            let idx = Int(b - 0x31)
            if idx < sessions.count {
                let target = sessions[idx]
                let paneCount = (try? Tmux.paneCount(current)) ?? 1
                restoreTerminal(orig)
                try Tmux.sendPaneToSession(from: current, to: target)
                if paneCount <= 1 {
                    try switchToSpace(target)
                }
                return
            }
        case .char(let b) where b == 0x6E: // 'n'
            if let newName = try createNewSpace(orig: orig) {
                let paneCount = (try? Tmux.paneCount(current)) ?? 1
                restoreTerminal(orig)
                try Tmux.sendPaneToSession(from: current, to: newName)
                if paneCount <= 1 {
                    try switchToSpace(newName)
                }
                return
            }
            // Cancelled — refresh and redraw
            sessions = (try? Tmux.listFocusSessions())?.filter { $0 != current } ?? sessions
            alertCounts = gatherAlertCounts(sessions)
            drawSendPicker(sessions: sessions, cursor: cursor, alertCounts: alertCounts)
        default:
            break
        }
    }
}

func main() throws {
    // Ensure UTF-8
    if ProcessInfo.processInfo.environment["LANG"] == nil {
        setenv("LANG", "en_US.UTF-8", 1)
    }

    let args = Array(CommandLine.arguments.dropFirst()) // drop binary name
    guard let command = args.first else {
        fputs("Usage: amux-cli <command> [args...]\n", stderr)
        exit(1)
    }

    switch command {
    case "layout":
        // amux-cli layout SESSION
        guard args.count >= 2 else {
            fputs("Usage: amux-cli layout SESSION\n", stderr)
            exit(1)
        }
        let session = args[1]
        try Tmux.applyLayout(session, event: .resize)

    case "update-title":
        // amux-cli update-title PANE_INDEX CWD
        // Called by after-select-pane hook with AMUX_SESSION env var
        guard args.count >= 3 else {
            fputs("Usage: amux-cli update-title PANE_INDEX CWD\n", stderr)
            exit(1)
        }
        let session = ProcessInfo.processInfo.environment["AMUX_SESSION"] ?? "amux"
        guard let paneIndex = Int(args[1]) else {
            fputs("Invalid pane index: \(args[1])\n", stderr)
            exit(1)
        }
        let cwd = args[2]
        let title = Util.autoTitle(dir: cwd)
        try Tmux.setTitle(session, paneIndex: paneIndex, title: title)

    case "alert-pane":
        // amux-cli alert-pane PANE_INDEX
        // Called by Claude Code notification hook
        guard args.count >= 2 else {
            fputs("Usage: amux-cli alert-pane PANE_INDEX\n", stderr)
            exit(1)
        }
        let session = ProcessInfo.processInfo.environment["AMUX_SESSION"] ?? "amux"
        guard let paneIndex = Int(args[1]) else {
            fputs("Invalid pane index: \(args[1])\n", stderr)
            exit(1)
        }

        // Skip the active pane if terminal is frontmost
        if Notify.isTerminalFrontmost() {
            let active = try Tmux.activePaneIndex(session)
            if paneIndex == active { exit(0) }
        }

        // Skip if already alerted
        if try Tmux.getAlert(session, paneIndex: paneIndex) { exit(0) }

        // Set alert state (TerminalView overlay handles coloring)
        try Tmux.setAlert(session, paneIndex: paneIndex, alert: true)
        let states = try Tmux.alertStates(session)
        let count = countAlerts(states)
        Tmux.setAlertCount(session, count: count)

        // System notification if terminal not frontmost
        if !Notify.isTerminalFrontmost() {
            let elapsed = (try? Tmux.getLastNotificationElapsed(session)) ?? UInt64.max
            if elapsed >= 30 {
                let msg = Notify.formatMessage(count: count)
                try? Notify.sendNotification(title: "amux", message: msg)
                Tmux.setLastNotificationTime(session)
            }
        }

    case "bell-watch":
        // amux-cli bell-watch --session SESSION PANE_INDEX
        // Long-running: reads stdin for BEL characters
        var session = "amux"
        var paneIndex = 0
        var i = 1
        while i < args.count {
            if args[i] == "--session", i + 1 < args.count {
                session = args[i + 1]
                i += 2
            } else {
                paneIndex = Int(args[i]) ?? 0
                i += 1
            }
        }

        var state = BellScanState()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let n = read(STDIN_FILENO, buf, bufSize)
            if n <= 0 { break }
            let bytes = Array(UnsafeBufferPointer(start: buf, count: n))
            let bells = scanBytes(state: state, buf: bytes)
            if bells > 0 {
                // Trigger alert (same logic as alert-pane)
                if Notify.isTerminalFrontmost() {
                    if let active = try? Tmux.activePaneIndex(session), paneIndex == active {
                        continue
                    }
                }
                if (try? Tmux.getAlert(session, paneIndex: paneIndex)) == true { continue }
                try? Tmux.setAlert(session, paneIndex: paneIndex, alert: true)
                if let states = try? Tmux.alertStates(session) {
                    let count = countAlerts(states)
                    Tmux.setAlertCount(session, count: count)
                }
            }
        }

    case "hook-install":
        // Install Claude Code notification hook
        try Hooks.ensureClaudeHook()

    case "spaces":
        // Two calls: currentSession + listSpacesWithAlerts (down from 5-7 calls)
        let current = currentSession()
        let spacesData = (try? Tmux.listSpacesWithAlerts()) ?? (sessions: [], alertCounts: [:])
        let sessions = spacesData.sessions
        let alertCounts = spacesData.alertCounts
        if sessions.isEmpty {
            print("No spaces found.")
            exit(0)
        }
        var cursor = sessions.firstIndex(of: current) ?? 0
        let orig = enterRawMode()
        defer { restoreTerminal(orig) }
        while true {
            drawSpacesPicker(sessions: sessions, cursor: cursor, current: current, alertCounts: alertCounts)
            let key = readRawKey()
            switch key {
            case .escape:
                exit(0)
            case .up:
                if cursor > 0 { cursor -= 1 }
            case .down:
                if cursor < sessions.count - 1 { cursor += 1 }
            case .enter:
                let target = sessions[cursor]
                if target != current {
                    restoreTerminal(orig)
                    try switchToSpace(target)
                }
                exit(0)
            case .char(let b) where b >= 0x31 && b <= 0x39: // 1-9
                let num = Int(b - 0x30)
                if num >= 1 && num <= sessions.count {
                    let target = sessions[num - 1]
                    if target != current {
                        restoreTerminal(orig)
                        try switchToSpace(target)
                    }
                    exit(0)
                }
            case .char(let b) where b == 0x6E || b == 0x4E: // n or N
                restoreTerminal(orig)
                if let name = try createNewSpace(orig: orig) {
                    try switchToSpace(name)
                }
                exit(0)
            default: break
            }
        }

    case "help":
        let orig = enterRawMode()
        defer { restoreTerminal(orig) }
        drawHelp()
        _ = readRawKey()
        exit(0)

    case "send":
        let current = currentSession()
        let allSessions = (try? Tmux.listFocusSessions()) ?? []
        let others = allSessions.filter { $0 != current }
        if others.isEmpty {
            print("No other spaces. Press n to create one, Esc to cancel.")
        }
        let alertCounts = gatherAlertCounts(others)
        var cursor = 0
        let orig = enterRawMode()
        defer { restoreTerminal(orig) }
        while true {
            drawSendPicker(sessions: others, cursor: cursor, alertCounts: alertCounts)
            let key = readRawKey()
            switch key {
            case .escape:
                exit(0)
            case .up:
                if cursor > 0 { cursor -= 1 }
            case .down:
                if !others.isEmpty && cursor < others.count - 1 { cursor += 1 }
            case .enter:
                if !others.isEmpty {
                    restoreTerminal(orig)
                    let target = others[cursor]
                    try sendPaneAndFollow(from: current, to: target)
                    exit(0)
                }
            case .char(let b) where b >= 0x31 && b <= 0x39:
                let num = Int(b - 0x30)
                if num >= 1 && num <= others.count {
                    restoreTerminal(orig)
                    let target = others[num - 1]
                    try sendPaneAndFollow(from: current, to: target)
                    exit(0)
                }
            case .char(let b) where b == 0x6E || b == 0x4E:
                restoreTerminal(orig)
                if let name = try createNewSpace(orig: orig) {
                    try sendPaneAndFollow(from: current, to: name)
                }
                exit(0)
            default: break
            }
        }

    default:
        fputs("Unknown command: \(command)\n", stderr)
        exit(1)
    }
}

try main()
