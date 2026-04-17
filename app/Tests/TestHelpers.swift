/// Shared test utilities for tmux integration tests.
///
/// Provides `TestSession` — a class that creates a uniquely-named tmux
/// session and kills it on deinit (even on test failure).
///
/// Concurrency is limited via file-lock slots in /tmp (max 4 concurrent)
/// to avoid overwhelming the single-threaded tmux server.

import Foundation
import AmuxLib

// MARK: - ProcessResult

struct ProcessResult {
    let stdout: String
    let stderr: String
    let status: Int32
    var success: Bool { status == 0 }
}

// MARK: - Helpers

/// Locate the amux binary for use in integration tests.
func amuxBin() -> String {
    Tmux.findAmuxBinary()
}

private let maxConcurrent = 4
nonisolated(unsafe) private var cleanupDone = false
private let cleanupLock = NSLock()
nonisolated(unsafe) private var sessionCounter: Int64 = 0
private let counterLock = NSLock()

private func nextSessionID() -> Int64 {
    counterLock.lock()
    defer { counterLock.unlock() }
    let value = sessionCounter
    sessionCounter += 1
    return value
}

/// The isolated tmux socket name for integration tests.
///
/// Tied to the test process PID so concurrent test runs don't collide
/// and parallel runs from different developers on the same machine
/// stay isolated. The Tmux library uses this socket via
/// `LiveTmux(socket:)` configured in main.swift.
let testTmuxSocket = "amux-test-\(ProcessInfo.processInfo.processIdentifier)"

/// Run a tmux command against the isolated test server.
///
/// All direct `tmux` shell calls from tests go through this helper so
/// they target the isolated socket, not the user's default tmux server.
@discardableResult
func tmux(_ args: String...) -> ProcessResult {
    runProcess("/usr/bin/env", arguments: ["tmux", "-L", testTmuxSocket] + args)
}

/// Run an amux command against a test session via the Swift library.
/// This replaces the old amuxCmd that called the Rust binary.
@discardableResult
func amuxCmd(session: String, args: [String]) -> ProcessResult {
    // Parse the args to determine which command to run
    // Args pattern: ["zoom-in"], ["zoom", "0"], ["split-start"], ["layout", session], etc.
    // Also handles legacy format: ["--session", session, "command", ...args]
    var effectiveArgs = args
    if effectiveArgs.first == "--session" {
        effectiveArgs.removeFirst() // remove "--session"
        if !effectiveArgs.isEmpty {
            effectiveArgs.removeFirst() // remove the session name
        }
    }
    do {
        let command = effectiveArgs.first ?? ""
        switch command {
        case "zoom-in":
            try Tmux.applyLayout(session, event: .zoomIn)
        case "zoom-out":
            try Tmux.applyLayout(session, event: .zoomOut)
        case "zoom":
            if let paneStr = effectiveArgs.dropFirst().first, let pane = Int(paneStr) {
                try Tmux.applyLayout(session, event: .zoomTo(pane))
            }
        case "pane-next":
            try Tmux.applyLayout(session, event: .paneNext)
        case "pane-prev":
            try Tmux.applyLayout(session, event: .panePrev)
        case "layout":
            // layout command takes session as arg — ignore, use the session param
            try Tmux.applyLayout(session, event: .resize)
        case "refresh":
            try Config.applyConfig(session: session)
            try Tmux.setupAllBellWatches(session)
            let panes = try Tmux.listPanes(session)
            for pane in panes {
                let cwd = try Tmux.paneCwd(session, paneIndex: pane.index)
                if !cwd.isEmpty {
                    let title = Util.autoTitle(dir: cwd)
                    try Tmux.setTitle(session, paneIndex: pane.index, title: title)
                }
            }
            try Tmux.applyLayout(session, event: .resize)
        case "split-start":
            let panes = try Tmux.listPanes(session)
            let active = panes.first(where: { $0.active })?.index ?? 0
            Tmux.runRaw(["set-environment", "-t", session, "AMUX_SPLIT_FIRST", String(active)])
            if try Tmux.isZoomed(session) {
                Tmux.runRaw(["set-environment", "-t", session, "AMUX_SPLIT_WAS_ZOOMED", "1"])
                try Tmux.toggleZoom(session)
            }
            setPaneStyle(session: session, pane: active, splitSelected: true)
            try Tmux.setPicking(session, picking: true)
            let title = panes.first(where: { $0.index == active })?.title ?? ""
            try Tmux.setSplitFirstLabel(session, label: "\(active + 1) \(title)")
        case "split-pick":
            if let paneStr = effectiveArgs.dropFirst().first, let secondPane = Int(paneStr) {
                let envResult = Tmux.runRaw(["show-environment", "-t", session, "AMUX_SPLIT_FIRST"])
                let firstPane = envResult.components(separatedBy: "=").last
                    .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                setPaneStyle(session: session, pane: firstPane, splitSelected: false)
                try Tmux.setPicking(session, picking: false)
                try Tmux.clearSplitFirstLabel(session)
                Tmux.runRaw(["set-environment", "-t", session, "-u", "AMUX_SPLIT_WAS_ZOOMED"])
                try Tmux.enterSplit(session, paneA: firstPane, paneB: secondPane)
                Tmux.runRaw(["set-environment", "-t", session, "-u", "AMUX_SPLIT_FIRST"])
            }
        case "split-cancel":
            let envResult = Tmux.runRaw(["show-environment", "-t", session, "AMUX_SPLIT_FIRST"])
            if let firstPaneStr = envResult.components(separatedBy: "=").last,
               let firstPane = Int(firstPaneStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                setPaneStyle(session: session, pane: firstPane, splitSelected: false)
            }
            try Tmux.setPicking(session, picking: false)
            try Tmux.clearSplitFirstLabel(session)
            let zoomResult = Tmux.runRaw(["show-environment", "-t", session, "AMUX_SPLIT_WAS_ZOOMED"])
            if zoomResult.trimmingCharacters(in: .whitespacesAndNewlines) == "AMUX_SPLIT_WAS_ZOOMED=1" {
                try Tmux.toggleZoom(session)
            }
            Tmux.runRaw(["set-environment", "-t", session, "-u", "AMUX_SPLIT_FIRST"])
            Tmux.runRaw(["set-environment", "-t", session, "-u", "AMUX_SPLIT_WAS_ZOOMED"])
        case "split-exit":
            try Tmux.exitSplit(session)
        case "alert-pane":
            if let paneStr = effectiveArgs.dropFirst().first, let pane = Int(paneStr) {
                let active = try Tmux.activePaneIndex(session)
                if pane != active {
                    if !(try Tmux.getAlert(session, paneIndex: pane)) {
                        try Tmux.setAlert(session, paneIndex: pane, alert: true)
                        let states = try Tmux.alertStates(session)
                        let count = countAlerts(states)
                        Tmux.setAlertCount(session, count: count)
                    }
                }
            }
        case "list":
            let panes = try Tmux.listPanes(session)
            var output = ""
            for pane in panes {
                let indicator = pane.active ? ">" : " "
                output += "\(indicator) \(pane.index + 1) \(pane.title) (\(pane.width)x\(pane.height))\n"
            }
            return ProcessResult(stdout: output, stderr: "", status: 0)
        default:
            return ProcessResult(stdout: "", stderr: "Unknown command: \(command)", status: 1)
        }
        return ProcessResult(stdout: "", stderr: "", status: 0)
    } catch {
        return ProcessResult(stdout: "", stderr: "\(error)", status: 1)
    }
}

/// Check whether the active window in the session is zoomed.
func isZoomed(_ session: String) -> Bool {
    (try? Tmux.isZoomed(session)) ?? false
}

/// Return the active pane index in the session.
func activePane(_ session: String) -> Int {
    (try? Tmux.activePaneIndex(session)) ?? 0
}

/// Count panes in the session.
func paneCount(_ session: String) -> Int {
    (try? Tmux.paneCount(session)) ?? 0
}

// MARK: - Process runner

private func runProcess(
    _ path: String,
    arguments: [String],
    environment: [String: String]? = nil
) -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments

    if let environment {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return ProcessResult(stdout: "", stderr: "Failed to launch: \(error)", status: -1)
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return ProcessResult(
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        status: process.terminationStatus
    )
}

// MARK: - Slot-based concurrency limiting

private func acquireSessionSlot() -> Int {
    while true {
        for i in 0..<maxConcurrent {
            let path = "/tmp/amux-test-slot-\(i)"
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                close(fd)
                return i
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

private func releaseSessionSlot(_ slot: Int) {
    unlink("/tmp/amux-test-slot-\(slot)")
}

// MARK: - Stale session cleanup

private func cleanupStaleSessions() {
    cleanupLock.lock()
    defer { cleanupLock.unlock() }
    guard !cleanupDone else { return }
    cleanupDone = true

    for i in 0..<maxConcurrent {
        unlink("/tmp/amux-test-slot-\(i)")
    }

    let myPid = String(ProcessInfo.processInfo.processIdentifier)
    let result = tmux("list-sessions", "-F", "#{session_name}")
    guard result.success else { return }

    for session in result.stdout.components(separatedBy: "\n") {
        let name = session.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("amux-test-"), !name.contains(myPid) {
            tmux("kill-session", "-t", name)
        }
    }
}

// MARK: - TestSession

/// A tmux session that cleans up after itself.
class TestSession {
    let name: String
    private let slot: Int

    init(paneCount count: Int) {
        cleanupStaleSessions()
        slot = acquireSessionSlot()

        let pid = ProcessInfo.processInfo.processIdentifier
        let id = nextSessionID()
        name = "amux-test-\(pid)-\(id)"

        try! Tmux.createSession(name)

        if count > 0 {
            for _ in 1..<count {
                _ = try! Tmux.createPane(name)
            }
            try! Config.applyConfig(session: name)
            try! Tmux.setupAllBellWatches(name)
            try! Tmux.applyLayout(name, event: .resize)
            try! Tmux.selectPane(name, paneIndex: 0)
        }
    }

    deinit {
        tmux("kill-session", "-t", name)
        releaseSessionSlot(slot)
    }
}
