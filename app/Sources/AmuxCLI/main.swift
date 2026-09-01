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
///   amux-cli backlog list
///   amux-cli backlog park SESSION PANE_INDEX
///   amux-cli backlog unpark SESSION [merge-into TARGET_SESSION]

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

/// A row in the spaces picker: either a real session or the virtual Backlog entry.
enum SpaceRow {
    case session(String)
    case backlog(count: Int)
}

/// Draw the spaces picker with support for a trailing virtual Backlog row.
func drawSpacesPickerWithBacklog(rows: [SpaceRow], cursor: Int, current: String, alertCounts: [String: Int]) {
    var out = ansiClear
    out += "\r\n  \(ansiBoldCyan)Spaces\(ansiReset)\r\n\r\n"

    for (i, row) in rows.enumerated() {
        let arrow = i == cursor ? "\(ansiCyan)\u{2192}\(ansiReset)" : " "
        let num = "\(ansiYellow)\(i + 1)\(ansiReset)"
        switch row {
        case .session(let session):
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
        case .backlog(let count):
            let label = "Backlog (\(count))"
            let styled = i == cursor
                ? "\(ansiBold)\(ansiGray)\(label)\(ansiReset)"
                : "\(ansiDim)\(ansiGray)\(label)\(ansiReset)"
            out += "  \(arrow) \(num) \(styled)\r\n"
        }
    }

    out += "\r\n  \(ansiGray)\u{2191}\u{2193} select \u{00B7} Enter switch \u{00B7} 1-9 jump \u{00B7} n new \u{00B7} Esc cancel\(ansiReset)\r\n"
    print(out, terminator: "")
    fflush(stdout)
}

/// Current time in seconds since the Unix epoch.
func nowSeconds() -> UInt64 { UInt64(Date().timeIntervalSince1970) }

/// Human-friendly relative time like "5s ago", "3m ago", "2h ago", "4d ago".
func formatAgo(seconds: UInt64) -> String {
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86400)d ago"
}

/// Draw the backlog sub-picker (background sessions).
func drawBacklogPicker(sessions: [BackgroundSession], selected: Int) {
    var out = ansiClear
    out += "\r\n  \(ansiBoldCyan)Backlog\(ansiReset)\r\n\r\n"
    for (i, s) in sessions.enumerated() {
        let arrow = i == selected ? "\(ansiCyan)\u{2192}\(ansiReset)" : " "
        let title = s.title.isEmpty ? s.name : s.title
        let name = i == selected ? "\(ansiBold)\(title)\(ansiReset)" : title
        let ago = formatAgo(seconds: nowSeconds() - s.parkedAt)
        let meta = "\(ansiDim)(from \(s.parkedFrom), \(ago))\(ansiReset)"
        out += "  \(arrow) \(name)  \(meta)\r\n"
    }
    out += "\r\n  \(ansiGray)Enter: promote \u{00B7} m: merge into current \u{00B7} Esc: cancel\(ansiReset)\r\n"
    print(out, terminator: "")
    fflush(stdout)
}

/// Picker for background sessions. Enter = promote in place;
/// 'm' = merge into current foreground space; Esc = cancel.
func runBacklogPicker(currentForegroundSession: String?) {
    let sessions = (try? Tmux.listBackgroundSessions()) ?? []
    if sessions.isEmpty {
        print("\r\n  Backlog is empty.\r\n", terminator: "")
        Thread.sleep(forTimeInterval: 0.6)
        return
    }
    var selected = 0
    let orig = enterRawMode()
    defer { restoreTerminal(orig) }
    while true {
        drawBacklogPicker(sessions: sessions, selected: selected)
        let key = readRawKey()
        switch key {
        case .escape: return
        case .up:   if selected > 0 { selected -= 1 }
        case .down: if selected + 1 < sessions.count { selected += 1 }
        case .enter:
            let pick = sessions[selected]
            restoreTerminal(orig)
            try? Tmux.unparkSession(pick.name, mode: .promote)
            try? Tmux.switchSession(pick.name)
            return
        case .char(let b) where b == 0x6D || b == 0x4D: // 'm' or 'M'
            if let target = currentForegroundSession {
                let pick = sessions[selected]
                restoreTerminal(orig)
                try? Tmux.unparkSession(pick.name, mode: .merge(into: target))
            }
            return
        default: break
        }
    }
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

/// A destination in the send picker: either the virtual Backlog (always first)
/// or a real foreground session.
enum SendDestination {
    case backlog
    case session(String)
}

/// Draw the send picker with `→ Backlog` as the first destination, followed
/// by real foreground sessions. Backlog uses the same dim/highlighted style
/// as the spaces picker's Backlog row.
func drawSendPickerWithBacklog(dests: [SendDestination], cursor: Int, alertCounts: [String: Int]) {
    var out = ansiClear
    out += "\r\n  \(ansiBoldCyan)Send pane to\u{2026}\(ansiReset)\r\n\r\n"

    for (i, dest) in dests.enumerated() {
        let arrow = i == cursor ? "\(ansiCyan)\u{2192}\(ansiReset)" : " "
        let num = "\(ansiYellow)\(i + 1)\(ansiReset)"
        switch dest {
        case .backlog:
            let label = "\u{2192} Backlog"
            let styled = i == cursor
                ? "\(ansiBold)\(ansiGray)\(label)\(ansiReset)"
                : "\(ansiDim)\(ansiGray)\(label)\(ansiReset)"
            out += "  \(arrow) \(num) \(styled)\r\n"
        case .session(let session):
            let name = i == cursor ? "\(ansiBold)\(session)\(ansiReset)" : session
            var dots = ""
            let alerts = alertCounts[session] ?? 0
            if alerts > 0 {
                dots += " \(ansiAmber)\(String(repeating: "\u{25CF}", count: alerts))\(ansiReset)"
            }
            out += "  \(arrow) \(num) \(name)\(dots)\r\n"
        }
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

/// Re-tile a session after its geometry or pane set changed.
///
/// Last-pane-close detection lives here: if the session emptied out and the
/// backlog isn't empty, fire the close-prompt popup instead of the usual
/// layout reapply. The popup runs `amux-cli prompt close`.
func reapplyLayout(session: String) throws {
    let count = (try? Tmux.paneCount(session)) ?? 0
    if count == 0 {
        let backlogCount = (try? Tmux.listBackgroundSessions().count) ?? 0
        if backlogCount > 0 {
            let bin = Config.findAmuxCLI()
            Tmux.launch([
                "display-popup", "-t", session, "-E", "-w", "70", "-h", "16",
                "-T", " Last pane closed — pull from backlog? ",
                "\(bin) prompt close \(session)",
            ])
            exit(0)
        }
    }
    try Tmux.applyLayout(session, event: .resize)
    // Cap-override re-arm: if pane count drops back at or under the cap,
    // clear the override flag so the next newPane re-prompts.
    let cap = (try? Tmux.getSessionCap(session)) ?? 4
    if count <= cap {
        Tmux.setCapOverridden(session, overridden: false)
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
        // amux-cli layout SESSION — client-resized hook.
        guard args.count >= 2 else {
            fputs("Usage: amux-cli layout SESSION\n", stderr)
            exit(1)
        }
        try reapplyLayout(session: args[1])

    case "layout-changed":
        // amux-cli layout-changed SESSION — pane-exited hook.
        // Same relayout as `layout`, plus a snapshot: the set of panes just
        // changed. Kept separate from `layout` so a window resize (which fires
        // continuously while dragging) does not trigger snapshots.
        guard args.count >= 2 else {
            fputs("Usage: amux-cli layout-changed SESSION\n", stderr)
            exit(1)
        }
        try reapplyLayout(session: args[1])
        SnapshotCapture.requestAsync()

    case "update-title":
        // amux-cli update-title PANE_INDEX CWD
        // Called by after-select-pane hook with AMUX_SESSION env var.
        //
        // This is the catch-all "pane became active" handler: it both
        // refreshes the title from cwd AND clears the alert flag, per
        // spec (docs/attention-management.md, Dismissal step 1: "When a
        // pane becomes the active pane: clear its ready-for-you state").
        // Routing dismissal through the tmux hook covers every focus
        // path — mouse clicks, direct tmux subprocess select-pane, and
        // any future binding — instead of relying solely on
        // `LayoutEngine.action.dismissAlert`, which only fires for amux's
        // own keybinding-driven navigation.
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
        try? Tmux.dismissAlert(session, paneIndex: paneIndex)

        // Stamp per-pane focus time so we can find least-recently-focused
        // when prompting at the cap.
        if !session.isEmpty {
            let now = String(UInt64(Date().timeIntervalSince1970))
            let target = "\(session):.\(paneIndex)"
            _ = try? Tmux.executor.execute(
                ["set-option", "-p", "-t", target, "@amux-focused-at", now])
        }

        // Focus changed — record it for session restore. Focus is hooked as
        // well as add/close because typing `claude` into an existing shell is
        // not a pane event; moving to another pane is what happens next.
        SnapshotCapture.requestAsync()

    case "alert-pane":
        guard args.count >= 2 else {
            fputs("Usage: amux-cli alert-pane PANE_INDEX\n", stderr)
            exit(1)
        }
        let session = ProcessInfo.processInfo.environment["AMUX_SESSION"] ?? "amux"
        guard let paneIndex = Int(args[1]) else {
            fputs("Invalid pane index: \(args[1])\n", stderr)
            exit(1)
        }

        // Update tmux state (pane option + session alert count).
        // applyAlertState is idempotent — re-asserting on an already-alerted
        // pane is a no-op.
        try applyAlertState(session: session, pane: paneIndex)

        // Fire-and-forget: notify amux-app (if running) to post the macOS
        // notification. amux-app owns UNUserNotificationCenter so clicks
        // route back here. If amux-app isn't listening, we just miss the
        // system notification — the amber pane overlay still works.
        let event = AlertEvent(
            session: session,
            pane: paneIndex,
            terminalFrontmost: Notify.isTerminalFrontmost()
        )
        let client = UnixSocketAlertEventClient(socketPath: defaultAlertSocketPath())
        try? client.send(event)

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

        let state = BellScanState()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let n = read(STDIN_FILENO, buf, bufSize)
            if n <= 0 { break }
            let bytes = Array(UnsafeBufferPointer(start: buf, count: n))
            let bells = scanBytes(state: state, buf: bytes)
            if bells > 0 {
                // Same pipeline as `alert-pane`: mutate tmux state locally,
                // then fire a one-shot event to amux-app so it posts the
                // macOS notification via UNUserNotificationCenter (amux-cli
                // is short-lived and can't own UN notifications itself).
                // If amux-app isn't listening, the event send is a silent
                // no-op — the amber overlay still works.
                try? applyAlertState(session: session, pane: paneIndex)
                let event = AlertEvent(
                    session: session,
                    pane: paneIndex,
                    terminalFrontmost: Notify.isTerminalFrontmost()
                )
                let client = UnixSocketAlertEventClient(
                    socketPath: defaultAlertSocketPath())
                try? client.send(event)
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
        let backlogCount = (try? Tmux.listBackgroundSessions().count) ?? 0
        var displayRows: [SpaceRow] = sessions.map { SpaceRow.session($0) }
        if backlogCount > 0 {
            displayRows.append(.backlog(count: backlogCount))
        }
        var cursor = sessions.firstIndex(of: current) ?? 0
        let orig = enterRawMode()
        defer { restoreTerminal(orig) }

        while true {
            drawSpacesPickerWithBacklog(rows: displayRows, cursor: cursor, current: current, alertCounts: alertCounts)
            let key = readRawKey()
            switch key {
            case .escape:
                exit(0)
            case .up:
                if cursor > 0 { cursor -= 1 }
            case .down:
                if cursor < displayRows.count - 1 { cursor += 1 }
            case .enter:
                switch displayRows[cursor] {
                case .session(let target):
                    if target != current {
                        restoreTerminal(orig)
                        try switchToSpace(target)
                    }
                    exit(0)
                case .backlog:
                    restoreTerminal(orig)
                    runBacklogPicker(currentForegroundSession: current)
                    exit(0)
                }
            case .char(let b) where b >= 0x31 && b <= 0x39: // 1-9
                let num = Int(b - 0x30)
                if num >= 1 && num <= displayRows.count {
                    switch displayRows[num - 1] {
                    case .session(let target):
                        if target != current {
                            restoreTerminal(orig)
                            try switchToSpace(target)
                        }
                        exit(0)
                    case .backlog:
                        restoreTerminal(orig)
                        runBacklogPicker(currentForegroundSession: current)
                        exit(0)
                    }
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
        // Backlog is always available as the first destination, so the picker
        // is never empty. No "No other spaces" message needed.
        let dests: [SendDestination] = [.backlog]
            + others.map { SendDestination.session($0) }
        let alertCounts = gatherAlertCounts(others)
        var cursor = 0
        let orig = enterRawMode()
        defer { restoreTerminal(orig) }

        func dispatch(_ dest: SendDestination) throws {
            switch dest {
            case .backlog:
                // Park the active pane of the current session. Splits to a
                // new background session, or flips the source if it's the
                // last pane.
                let activeIdx = (try? Tmux.activePaneIndex(current)) ?? 0
                _ = try Tmux.parkPane(current, paneIndex: activeIdx)
            case .session(let target):
                try sendPaneAndFollow(from: current, to: target)
            }
        }

        while true {
            drawSendPickerWithBacklog(dests: dests, cursor: cursor, alertCounts: alertCounts)
            let key = readRawKey()
            switch key {
            case .escape:
                exit(0)
            case .up:
                if cursor > 0 { cursor -= 1 }
            case .down:
                if cursor < dests.count - 1 { cursor += 1 }
            case .enter:
                restoreTerminal(orig)
                try dispatch(dests[cursor])
                exit(0)
            case .char(let b) where b >= 0x31 && b <= 0x39:
                let num = Int(b - 0x30)
                if num >= 1 && num <= dests.count {
                    restoreTerminal(orig)
                    try dispatch(dests[num - 1])
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

    case "backlog":
        // amux-cli backlog list
        // amux-cli backlog park SESSION PANE_INDEX
        // amux-cli backlog unpark SESSION [merge-into TARGET_SESSION]
        let action = args.count >= 2 ? args[1] : "list"
        switch action {
        case "list":
            let bg = (try? Tmux.listBackgroundSessions()) ?? []
            if bg.isEmpty {
                print("Backlog is empty.")
                exit(0)
            }
            for s in bg {
                print("\(s.name)\t\(s.title)\t\(s.parkedFrom)\t\(s.parkedAt)\t\(s.paneCount)")
            }
            exit(0)
        case "park":
            guard args.count >= 4, let idx = Int(args[3]) else {
                fputs("Usage: amux-cli backlog park SESSION PANE_INDEX\n", stderr)
                exit(2)
            }
            let session = args[2]
            do {
                let parkedName = try Tmux.parkPane(session, paneIndex: idx)
                print(parkedName)
                exit(0)
            } catch {
                fputs("Park failed: \(error)\n", stderr)
                exit(1)
            }
        case "unpark":
            guard args.count >= 3 else {
                fputs("Usage: amux-cli backlog unpark SESSION [merge-into TARGET_SESSION]\n", stderr)
                exit(2)
            }
            let session = args[2]
            let mode: Tmux.UnparkMode
            if args.count >= 5, args[3] == "merge-into" {
                mode = .merge(into: args[4])
            } else {
                mode = .promote
            }
            do {
                try Tmux.unparkSession(session, mode: mode)
                exit(0)
            } catch {
                fputs("Unpark failed: \(error)\n", stderr)
                exit(1)
            }
        default:
            fputs("Unknown backlog action: \(action)\n", stderr)
            exit(2)
        }

    case "snapshot":
        // amux-cli snapshot [--clean-exit]
        // Records every managed pane to ~/.amux/session-snapshot.json.
        // Invoked from the pane-exited and after-select-pane hooks (via
        // SnapshotCapture.requestAsync), so bursts are coalesced to one
        // trailing write; --clean-exit skips the wait and marks the snapshot
        // as a tidy shutdown.
        let cleanExit = args.contains("--clean-exit")
        if !cleanExit && !SnapshotCapture.claimTrailingEdge() {
            exit(0) // a newer event superseded this one
        }
        SnapshotCapture.captureNow(cleanExit: cleanExit)
        exit(0)

    case "restore-popup":
        // amux-cli restore-popup SESSION
        // Runs from the one-shot client-attached hook set by startup(). Clears
        // the hook first so a later attach never re-prompts, then opens the
        // prompt as a popup — the prompt is a raw-mode TUI and needs a tty.
        guard args.count >= 2 else {
            fputs("Usage: amux-cli restore-popup SESSION\n", stderr)
            exit(2)
        }
        let session = args[1]
        _ = Tmux.runRaw(["set-hook", "-u", "-t", session, "client-attached"])
        let bin = Config.findAmuxCLI()
        Tmux.launch([
            "display-popup", "-t", session, "-E", "-w", "80", "-h", "24",
            "-T", " Restore last session ",
            "\(bin) prompt restore \(session)",
        ])
        exit(0)

    case "prompt":
        // amux-cli prompt park SESSION    — popup to pick pane to park when at cap
        // amux-cli prompt close SESSION   — popup to pull from backlog after last close
        // amux-cli prompt restore SESSION — popup to restore the last snapshot
        let sub = args.count >= 2 ? args[1] : ""
        switch sub {
        case "restore":
            guard args.count >= 3 else {
                fputs("Usage: amux-cli prompt restore SESSION\n", stderr)
                exit(2)
            }
            runRestorePrompt(session: args[2])
            exit(0)
        case "park":
            guard args.count >= 3 else {
                fputs("Usage: amux-cli prompt park SESSION\n", stderr)
                exit(2)
            }
            runParkPrompt(session: args[2])
            exit(0)
        case "close":
            guard args.count >= 3 else {
                fputs("Usage: amux-cli prompt close SESSION\n", stderr)
                exit(2)
            }
            runCloseLastPrompt(session: args[2])
            exit(0)
        default:
            fputs("Usage: amux-cli prompt park|close|restore SESSION\n", stderr)
            exit(2)
        }

    default:
        fputs("Unknown command: \(command)\n", stderr)
        exit(1)
    }
}

// MARK: - Park prompt (fires on 5th-pane open at cap)

func drawParkPrompt(panes: [PaneInfo], selected: Int) {
    var out = ansiClear
    out += "\r\n  \(ansiBoldCyan)4 panes already open\(ansiReset)  \(ansiGray)pick one to send to backlog\(ansiReset)\r\n\r\n"
    for (i, p) in panes.enumerated() {
        let arrow = i == selected ? "\(ansiCyan)\u{2192}\(ansiReset)" : " "
        let title = p.title.isEmpty ? "(pane \(p.index + 1))" : p.title
        let styled = i == selected ? "\(ansiBold)\(title)\(ansiReset)" : title
        out += "  \(arrow) \(ansiYellow)\(p.index + 1)\(ansiReset) \(styled)\r\n"
    }
    out += "\r\n  \(ansiGray)Enter: park selected · Esc: open anyway (override cap)\(ansiReset)\r\n"
    print(out, terminator: "")
    fflush(stdout)
}

func runParkPrompt(session: String) {
    let panes = (try? Tmux.listPanes(session)) ?? []
    if panes.isEmpty { return }
    let lrf = (try? Tmux.leastRecentlyFocusedPane(session)) ?? panes[0].index
    var selected = panes.firstIndex(where: { $0.index == lrf }) ?? 0
    let orig = enterRawMode()
    defer { restoreTerminal(orig) }
    while true {
        drawParkPrompt(panes: panes, selected: selected)
        let key = readRawKey()
        switch key {
        case .up:
            if selected > 0 { selected -= 1 }
        case .down:
            if selected + 1 < panes.count { selected += 1 }
        case .enter:
            let pick = panes[selected]
            restoreTerminal(orig)
            _ = try? Tmux.parkPane(session, paneIndex: pick.index)
            _ = try? Tmux.createPane(session, cwd: nil)
            return
        case .escape:
            restoreTerminal(orig)
            Tmux.setCapOverridden(session, overridden: true)
            _ = try? Tmux.createPane(session, cwd: nil)
            return
        default:
            break
        }
    }
}

// MARK: - Close-last prompt (fires on last-pane-close when backlog non-empty)

func drawCloseLastPrompt(sessions: [BackgroundSession], selected: Int) {
    var out = ansiClear
    out += "\r\n  \(ansiBoldCyan)Last pane closed\(ansiReset)  \(ansiGray)pull one from backlog?\(ansiReset)\r\n\r\n"
    for (i, s) in sessions.enumerated() {
        let arrow = i == selected ? "\(ansiCyan)\u{2192}\(ansiReset)" : " "
        let title = s.title.isEmpty ? s.name : s.title
        let styled = i == selected ? "\(ansiBold)\(title)\(ansiReset)" : title
        let ago = formatAgo(seconds: nowSeconds() - s.parkedAt)
        out += "  \(arrow) \(styled)  \(ansiDim)(from \(s.parkedFrom), \(ago))\(ansiReset)\r\n"
    }
    out += "\r\n  \(ansiGray)Enter: pull here · Esc: leave empty\(ansiReset)\r\n"
    print(out, terminator: "")
    fflush(stdout)
}

func runCloseLastPrompt(session: String) {
    let backlog = (try? Tmux.listBackgroundSessions()) ?? []
    if backlog.isEmpty { return }
    var sorted = backlog
    sorted.sort { (a, b) in
        let aFromSelf = a.parkedFrom == session
        let bFromSelf = b.parkedFrom == session
        if aFromSelf != bFromSelf { return aFromSelf }
        return a.parkedAt > b.parkedAt
    }
    var selected = 0
    let orig = enterRawMode()
    defer { restoreTerminal(orig) }
    while true {
        drawCloseLastPrompt(sessions: sorted, selected: selected)
        let key = readRawKey()
        switch key {
        case .up:
            if selected > 0 { selected -= 1 }
        case .down:
            if selected + 1 < sorted.count { selected += 1 }
        case .enter:
            let pick = sorted[selected]
            restoreTerminal(orig)
            try? Tmux.unparkSession(pick.name, mode: .merge(into: session))
            return
        case .escape:
            return
        default:
            break
        }
    }
}

// MARK: - Restore prompt (fires at startup when nothing survived)

enum RestoreChoice: Int, CaseIterable {
    case restore = 0
    case fresh = 1
    case dontAsk = 2
}

func drawRestorePrompt(snapshot: SessionSnapshot, selected: Int) {
    var out = ansiClear
    let crash = snapshot.cleanExit
        ? ""
        : "  \(ansiAmber)(last run ended in a crash — may be slightly behind)\(ansiReset)"
    out += "\r\n  \(ansiBoldCyan)Restore your last session?\(ansiReset)\(crash)\r\n\r\n"

    // Show what comes back, so the choice is informed. Topic-matched ids are
    // marked: that is the one signal that can resume the wrong conversation,
    // and it should be visible before it happens rather than after.
    for space in snapshot.spaces {
        let parked = snapshot.backlog.contains(space.name) ? " \(ansiDim)(backlog)\(ansiReset)" : ""
        out += "  \(ansiWhite)\(space.name)\(ansiReset)\(parked)\r\n"
        for pane in space.panes {
            let label: String
            switch pane.kind {
            case .claude(let id, let confidence):
                if id == nil {
                    label = "\(ansiAmber)claude — no id, opens a shell\(ansiReset)"
                } else if confidence == .topicMatch {
                    label = "\(ansiGreen)claude\(ansiReset) \(ansiAmber)[topic match — verify]\(ansiReset)"
                } else {
                    label = "\(ansiGreen)claude\(ansiReset)"
                }
            case .shell:
                label = "\(ansiGray)shell\(ansiReset)"
            case .command(let cmd):
                label = "\(ansiGray)\(cmd)\(ansiReset)"
            }
            let title = pane.title.isEmpty ? "(pane \(pane.index + 1))" : pane.title
            out += "    \(ansiDim)·\(ansiReset) \(title)  \(label)\r\n"
        }
    }

    let ago = formatAgo(seconds: nowSeconds() &- UInt64(max(0, snapshot.capturedAt)))
    let spaceWord = snapshot.spaces.count == 1 ? "space" : "spaces"
    let options = [
        "Restore \(snapshot.paneCount) panes across \(snapshot.spaces.count) \(spaceWord)"
            + "  \(ansiDim)saved \(ago)\(ansiReset)",
        "Start fresh",
        "Don't ask again",
    ]
    out += "\r\n"
    for (i, option) in options.enumerated() {
        let arrow = i == selected ? "\(ansiCyan)❯\(ansiReset)" : " "
        let number = "\(ansiYellow)\(i + 1).\(ansiReset)"
        let text = i == selected ? "\(ansiBold)\(option)\(ansiReset)" : option
        out += "  \(arrow) \(number) \(text)\r\n"
    }
    out += "\r\n  \(ansiGray)Enter to confirm · Esc to start fresh\(ansiReset)\r\n"
    print(out, terminator: "")
    fflush(stdout)
}

func runRestorePrompt(session: String) {
    guard let snapshot = SessionSnapshot.load(from: SessionSnapshot.defaultPath),
          snapshot.paneCount > 0 else { return }

    var selected = 0
    let orig = enterRawMode()
    defer { restoreTerminal(orig) }
    while true {
        drawRestorePrompt(snapshot: snapshot, selected: selected)
        switch readRawKey() {
        case .up:
            if selected > 0 { selected -= 1 }
        case .down:
            if selected + 1 < RestoreChoice.allCases.count { selected += 1 }
        case .char(let c) where c >= 0x31 && c <= 0x33:
            selected = Int(c - 0x31)
        case .enter:
            restoreTerminal(orig)
            applyRestoreChoice(RestoreChoice(rawValue: selected) ?? .fresh,
                               snapshot: snapshot, session: session)
            return
        case .escape:
            restoreTerminal(orig)
            applyRestoreChoice(.fresh, snapshot: snapshot, session: session)
            return
        default:
            break
        }
    }
}

func applyRestoreChoice(_ choice: RestoreChoice, snapshot: SessionSnapshot, session: String) {
    var prefs = RestorePrefs.load(from: RestorePrefs.defaultPath)
    // Every outcome consumes this snapshot, so relaunching the app (or a
    // `make dev` cycle) does not ask about the same one twice.
    prefs.consumedCapturedAt = snapshot.capturedAt

    switch choice {
    case .restore:
        let plan = SessionRestore.planRestore(
            snapshot: snapshot,
            existing: SessionRestore.existingSessionPaneCounts(),
            now: nowSeconds(),
            adoptSession: session)
        SessionRestore.execute(plan)
        // Hand the restored panes to amux's own layout engine — the plan
        // tiles only to keep tmux willing to split.
        try? Tmux.applyLayout(session, event: .resize)
        try? Tmux.setupAllBellWatches(session)
        if !plan.skippedSpaces.isEmpty {
            Tmux.displayMessage(session,
                message: "Restore skipped \(plan.skippedSpaces.joined(separator: ", ")) — already open")
        }
    case .fresh:
        break
    case .dontAsk:
        prefs.dontAsk = true
    }

    try? prefs.save(to: RestorePrefs.defaultPath)
}

try main()
