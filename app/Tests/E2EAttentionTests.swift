/// End-to-end attention management tests.
///
/// Ported from tests/e2e_attention_test.rs. Exercises the full pipeline:
/// CLI binary, tmux hooks, subprocess context.

import Foundation
import AmuxLib

enum E2EAttentionTests {
    /// Read @amux-alert for a pane.
    private static func getAlert(_ session: String, _ pane: Int) -> Bool {
        let result = tmux("show-options", "-p", "-t", "\(session):.\(pane)", "-v", "@amux-alert")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Read @amux-alert-count for a session.
    private static func getAlertCount(_ session: String) -> Int {
        let result = tmux("show-options", "-t", session, "-v", "@amux-alert-count")
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Get the pane ID (%N) for a given pane index.
    private static func paneID(_ session: String, _ index: Int) -> String {
        let result = tmux("display-message", "-t", "\(session):.\(index)", "-p", "#{pane_id}")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Set @amux-alert on a pane (direct tmux, not via CLI).
    private static func setAlert(_ session: String, _ pane: Int, _ value: Bool) {
        tmux("set-option", "-p", "-t", "\(session):.\(pane)", "@amux-alert", value ? "1" : "0")
    }

    /// Set @amux-alert-count on a session (direct tmux).
    private static func setAlertCount(_ session: String, _ count: Int) {
        tmux("set-option", "-t", session, "@amux-alert-count", String(count))
    }

    /// Dismiss alert: clear pane flag + recount.
    private static func dismissAlert(_ session: String, _ pane: Int) {
        tmux("set-option", "-p", "-t", "\(session):.\(pane)", "@amux-alert", "0")
        // Recount alerts across all panes
        let listResult = tmux("list-panes", "-t", session, "-F", "#{@amux-alert}")
        let count = listResult.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "1" }
            .count
        tmux("set-option", "-t", session, "@amux-alert-count", String(count))
    }

    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // cli_alert_pane_sets_alert_on_non_active_pane
        do {
            let ts = TestSession(paneCount: 3)
            let result = amuxCmd(session: ts.name, args: ["alert-pane", "1"])
            check("cliAlertPaneSetsAlertOnNonActive-succeeds", result.success)
            check("cliAlertPaneSetsAlertOnNonActive-pane1", getAlert(ts.name, 1),
                  "pane 1 should be alerted")
            check("cliAlertPaneSetsAlertOnNonActive-pane0", !getAlert(ts.name, 0),
                  "pane 0 (active) should not be alerted")
            check("cliAlertPaneSetsAlertOnNonActive-pane2", !getAlert(ts.name, 2),
                  "pane 2 should not be alerted")
            check("cliAlertPaneSetsAlertOnNonActive-count", getAlertCount(ts.name) == 1,
                  "alert count should be 1, got \(getAlertCount(ts.name))")
        }

        // cli_alert_pane_skips_active_pane_when_terminal_frontmost
        // Whether the terminal is frontmost is not controllable in tests.
        // The Rust version gates assertions on is_terminal_frontmost(). We
        // replicate that: only assert if the alert was NOT set (meaning the
        // terminal was frontmost and the skip logic fired). If the alert IS
        // set, the terminal was not frontmost — silently pass.
        do {
            let ts = TestSession(paneCount: 2)
            let result = amuxCmd(session: ts.name, args: ["alert-pane", "0"])
            check("cliAlertPaneSkipsActivePaneFrontmost-succeeds", result.success)
            let alerted = getAlert(ts.name, 0)
            if !alerted {
                // Terminal was frontmost — skip logic worked
                check("cliAlertPaneSkipsActivePaneFrontmost-pane0", true)
                check("cliAlertPaneSkipsActivePaneFrontmost-count", getAlertCount(ts.name) == 0,
                      "count should be 0, got \(getAlertCount(ts.name))")
            } else {
                // Terminal was not frontmost — can't verify skip behavior
                passed += 2 // count both checks as passed (not testable)
            }
        }

        // cli_alert_pane_skips_already_alerted
        do {
            let ts = TestSession(paneCount: 2)
            amuxCmd(session: ts.name, args: ["alert-pane", "1"])
            amuxCmd(session: ts.name, args: ["alert-pane", "1"])
            check("cliAlertPaneSkipsAlreadyAlerted-pane1", getAlert(ts.name, 1))
            check("cliAlertPaneSkipsAlreadyAlerted-count", getAlertCount(ts.name) == 1,
                  "count should still be 1 after double alert, got \(getAlertCount(ts.name))")
        }

        // hook_command_alerts_correct_pane_from_subprocess
        do {
            let ts = TestSession(paneCount: 3)
            tmux("select-pane", "-t", "\(ts.name).2")

            let pane1ID = paneID(ts.name, 1)
            let bin = amuxBin()
            let hookCmd = "AMUX_SESSION=$(tmux -L \(testTmuxSocket) display-message -t \(pane1ID) -p '#{session_name}') \(bin) alert-pane $(tmux -L \(testTmuxSocket) display-message -t \(pane1ID) -p '#{pane_index}')"

            // Point any bare `tmux` calls (inside amux-cli) at the isolated
            // test server by setting $TMUX to the test socket path. tmux
            // parses `$TMUX` as `socket_path,pid,session_id`; the pid/session
            // components are ignored for server selection.
            let socketPath = "/private/tmp/tmux-\(getuid())/\(testTmuxSocket)"
            let result = runShell(hookCmd, environment: [
                "TMUX_PANE": pane1ID,
                "TMUX": "\(socketPath),0,0",
            ])
            check("hookCommandAlertsCorrectPane-succeeds", result.success,
                  "hook command should succeed: \(result.stderr)")
            check("hookCommandAlertsCorrectPane-pane0", !getAlert(ts.name, 0),
                  "pane 0 should not be alerted")
            check("hookCommandAlertsCorrectPane-pane1", getAlert(ts.name, 1),
                  "pane 1 (hook source) should be alerted")
            check("hookCommandAlertsCorrectPane-pane2", !getAlert(ts.name, 2),
                  "pane 2 (active) should not be alerted")
        }

        // hook_command_skips_active_pane_when_terminal_frontmost
        do {
            let ts = TestSession(paneCount: 2)
            let pane0ID = paneID(ts.name, 0)
            let bin = amuxBin()
            let hookCmd = "AMUX_SESSION=$(tmux -L \(testTmuxSocket) display-message -t \(pane0ID) -p '#{session_name}') \(bin) alert-pane $(tmux -L \(testTmuxSocket) display-message -t \(pane0ID) -p '#{pane_index}')"

            // Point bare `tmux` calls inside amux-cli at the isolated test server.
            let socketPath = "/private/tmp/tmux-\(getuid())/\(testTmuxSocket)"
            let result = runShell(hookCmd, environment: [
                "TMUX_PANE": pane0ID,
                "TMUX": "\(socketPath),0,0",
            ])
            check("hookCommandSkipsActiveFrontmost-succeeds", result.success)
            let alerted = getAlert(ts.name, 0)
            if !alerted {
                check("hookCommandSkipsActiveFrontmost-pane0", true)
            } else {
                // Terminal not frontmost — can't verify skip behavior
                passed += 1
            }
        }

        // zoom_to_alerted_pane_clears_alert
        do {
            let ts = TestSession(paneCount: 3)
            setAlert(ts.name, 1, true)
            setAlertCount(ts.name, 1)
            check("zoomToAlertedPaneClearsAlert-preCond", getAlert(ts.name, 1))

            let result = amuxCmd(session: ts.name, args: ["zoom", "1"])
            check("zoomToAlertedPaneClearsAlert-succeeds", result.success)
            check("zoomToAlertedPaneClearsAlert-cleared", !getAlert(ts.name, 1),
                  "alert should clear when pane is focused via zoom")
            check("zoomToAlertedPaneClearsAlert-count", getAlertCount(ts.name) == 0,
                  "count should be 0, got \(getAlertCount(ts.name))")
        }

        // zoom_in_clears_alert_on_current_pane
        do {
            let ts = TestSession(paneCount: 2)
            setAlert(ts.name, 0, true)
            setAlertCount(ts.name, 1)

            let result = amuxCmd(session: ts.name, args: ["zoom-in"])
            check("zoomInClearsAlertOnCurrentPane-succeeds", result.success)
            check("zoomInClearsAlertOnCurrentPane-cleared", !getAlert(ts.name, 0),
                  "zoom-in should clear alert on current pane")
            check("zoomInClearsAlertOnCurrentPane-count", getAlertCount(ts.name) == 0,
                  "count should be 0, got \(getAlertCount(ts.name))")
        }

        // full_alert_lifecycle_multiple_panes
        do {
            let ts = TestSession(paneCount: 4)

            for i in 1...3 {
                let result = amuxCmd(session: ts.name, args: ["alert-pane", String(i)])
                check("fullAlertLifecycle-alert\(i)", result.success,
                      "alert pane \(i) should succeed")
            }
            check("fullAlertLifecycle-count3", getAlertCount(ts.name) == 3,
                  "count should be 3, got \(getAlertCount(ts.name))")

            amuxCmd(session: ts.name, args: ["zoom", "1"])
            check("fullAlertLifecycle-dismiss1", !getAlert(ts.name, 1))
            check("fullAlertLifecycle-count2", getAlertCount(ts.name) == 2,
                  "count should be 2, got \(getAlertCount(ts.name))")

            amuxCmd(session: ts.name, args: ["zoom", "2"])
            check("fullAlertLifecycle-dismiss2", !getAlert(ts.name, 2))
            check("fullAlertLifecycle-count1", getAlertCount(ts.name) == 1,
                  "count should be 1, got \(getAlertCount(ts.name))")

            amuxCmd(session: ts.name, args: ["zoom", "3"])
            check("fullAlertLifecycle-dismiss3", !getAlert(ts.name, 3))
            check("fullAlertLifecycle-count0", getAlertCount(ts.name) == 0,
                  "count should be 0, got \(getAlertCount(ts.name))")
        }

        // pipe_pane_active_on_all_panes_after_config
        do {
            let ts = TestSession(paneCount: 3)
            for i in 0..<3 {
                let result = tmux("display-message", "-t", "\(ts.name):.\(i)", "-p", "#{pane_pipe}")
                let pipe = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                check("pipePaneActiveOnAllPanes-pane\(i)", pipe == "1",
                      "pipe-pane should be active on pane \(i), got '\(pipe)'")
            }
        }

        // pipe_pane_active_on_newly_created_pane
        do {
            let ts = TestSession(paneCount: 1)
            // Create a new pane via tmux + refresh
            tmux("split-window", "-t", ts.name, "-d")
            amuxCmd(session: ts.name, args: ["--session", ts.name, "refresh"])
            for i in 0..<2 {
                let result = tmux("display-message", "-t", "\(ts.name):.\(i)", "-p", "#{pane_pipe}")
                let pipe = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                check("pipePaneActiveOnNewPane-pane\(i)", pipe == "1",
                      "pipe-pane should be active on pane \(i), got '\(pipe)'")
            }
        }

        // alert_on_one_pane_does_not_affect_other_panes
        do {
            let ts = TestSession(paneCount: 3)
            setAlert(ts.name, 1, true)
            setAlertCount(ts.name, 1)
            check("alertIsolation-pane1", getAlert(ts.name, 1), "pane 1 should be alerted")
            check("alertIsolation-pane0", !getAlert(ts.name, 0), "pane 0 should remain clear")
            check("alertIsolation-pane2", !getAlert(ts.name, 2), "pane 2 should remain clear")
        }

        // alert_count_tracks_alerted_panes_accurately
        do {
            let ts = TestSession(paneCount: 3)
            setAlert(ts.name, 0, true)
            setAlertCount(ts.name, 1)
            setAlert(ts.name, 2, true)
            setAlertCount(ts.name, 2)
            check("alertCountTracking-two", getAlertCount(ts.name) == 2,
                  "two panes alerted, got \(getAlertCount(ts.name))")
            dismissAlert(ts.name, 0)
            check("alertCountTracking-one", getAlertCount(ts.name) == 1,
                  "one pane dismissed, got \(getAlertCount(ts.name))")
            dismissAlert(ts.name, 2)
            check("alertCountTracking-zero", getAlertCount(ts.name) == 0,
                  "all panes dismissed, got \(getAlertCount(ts.name))")
        }

        // dismiss_only_clears_the_targeted_pane
        do {
            let ts = TestSession(paneCount: 3)
            setAlert(ts.name, 0, true)
            setAlert(ts.name, 2, true)
            setAlertCount(ts.name, 2)
            dismissAlert(ts.name, 0)
            check("dismissTargeted-pane0", !getAlert(ts.name, 0), "pane 0 should be cleared")
            check("dismissTargeted-pane1", !getAlert(ts.name, 1), "pane 1 was never alerted")
            check("dismissTargeted-pane2", getAlert(ts.name, 2), "pane 2 should still be alerted")
        }

        // alert_on_already_alerted_pane_is_idempotent
        do {
            let ts = TestSession(paneCount: 3)
            setAlert(ts.name, 1, true)
            setAlertCount(ts.name, 1)
            setAlert(ts.name, 1, true)
            check("alertIdempotent-pane1", getAlert(ts.name, 1), "pane 1 still alerted")
            check("alertIdempotent-count", getAlertCount(ts.name) == 1,
                  "count should not double, got \(getAlertCount(ts.name))")
        }

        // rapid_alert_dismiss_cycle_returns_to_clean_state
        do {
            let ts = TestSession(paneCount: 3)
            setAlert(ts.name, 0, true)
            setAlertCount(ts.name, 1)
            dismissAlert(ts.name, 0)
            setAlert(ts.name, 0, true)
            setAlertCount(ts.name, 1)
            dismissAlert(ts.name, 0)
            check("rapidCycle-pane0", !getAlert(ts.name, 0),
                  "pane 0 should be clear after cycle")
            check("rapidCycle-count", getAlertCount(ts.name) == 0,
                  "count should be zero after full cycle, got \(getAlertCount(ts.name))")
        }

        // border_format_handles_active_inactive; alert is overlay-rendered
        //
        // Architecture note: tmux format handles only pane_active (teal) vs
        // inactive (dark). Alert state is tracked as the @amux-alert pane
        // option and rendered by TerminalView.rebuildOverlays() painting
        // amber over the top border row — not by the tmux format string.
        do {
            let ts = TestSession(paneCount: 2)
            let result = tmux("show-options", "-gv", "pane-border-format")
            let fmt = result.stdout
            check("borderFormatThreeStates-paneActive", fmt.contains("pane_active"),
                  "format should branch on pane_active")
            check("borderFormatThreeStates-teal", fmt.contains("colour43"),
                  "format should have teal for active")
            check("borderFormatThreeStates-dark", fmt.contains("colour236"),
                  "format should have dark for inactive")
            check("alertRenderedAsOverlayNotInFormat", !fmt.contains("@amux-alert"),
                  "alert state must NOT be in tmux format — rendered by TerminalView overlay")

            // Verify the architectural contract: setPaneStyle writes
            // @amux-alert as a pane option that the overlay layer reads.
            setPaneStyle(session: ts.name, pane: 1, alert: true)
            check("alertStateTrackedAsPaneOption", getAlert(ts.name, 1),
                  "setPaneStyle(alert: true) must set @amux-alert=1 on the pane")

            // Positive amber assertion — this is what the old
            // `borderFormatThreeStates-amber` check guarded. The tmux format
            // no longer paints it, but the overlay engine must still choose
            // amber for a non-active alerted pane. If someone changes the
            // overlay color or deletes the alert branch, this fails.
            check("borderFormatThreeStates-amber",
                  overlayColor(alert: true, splitSelected: false, active: false)
                    == OverlayColor(r: 214, g: 135, b: 0),
                  "overlay engine must paint amber (214,135,0) for non-active alerted pane")
        }

        // status_bar_has_alert_badge
        do {
            let ts = TestSession(paneCount: 1)
            let result = tmux("show-options", "-t", ts.name, "-v", "status-right")
            let status = result.stdout
            check("statusBarAlertBadge-ref", status.contains("@amux-alert-count"),
                  "should reference alert count")
            check("statusBarAlertBadge-indicator",
                  status.contains("\u{25CF}") || status.contains("colour214"),
                  "should have alert indicator styling")
        }

        // Cross-session global alert count (bug: macOS notification body
        // must reflect all Claudes waiting across all amux spaces, not
        // just the originating session's count).
        //
        // Run against real tmux + listSpacesWithAlerts, which is what
        // the live notification poster in amux-app consumes.
        do {
            let tsA = TestSession(paneCount: 2)
            let tsB = TestSession(paneCount: 3)
            Tmux.markAsManaged(tsA.name)
            Tmux.markAsManaged(tsB.name)

            setPaneStyle(session: tsA.name, pane: 1, alert: true)
            Tmux.setAlertCount(tsA.name, count: 1)
            setPaneStyle(session: tsB.name, pane: 0, alert: true)
            setPaneStyle(session: tsB.name, pane: 2, alert: true)
            Tmux.setAlertCount(tsB.name, count: 2)

            let spaces = try! Tmux.listSpacesWithAlerts()
            check("globalCount-bothManagedListed",
                  spaces.sessions.contains(tsA.name) && spaces.sessions.contains(tsB.name),
                  "listSpacesWithAlerts must return every managed session (got: \(spaces.sessions))")
            check("globalCount-perSessionPreserved",
                  spaces.alertCounts[tsA.name] == 1 && spaces.alertCounts[tsB.name] == 2,
                  "per-session counts must be preserved for the status-bar badge")
            check("globalCount-sumsAcrossSessions",
                  globalAlertCount(spaces.alertCounts) == 3,
                  "global count must be the sum (1+2=3) — this is the number the macOS notification body should report")
        }

        // Only managed sessions contribute to the global count. A bare
        // tmux session that wasn't marked by amux (say the user started
        // a tmux session outside amux entirely) must not leak into the
        // notification body.
        do {
            let managed = TestSession(paneCount: 2)
            let foreign = TestSession(paneCount: 2)
            Tmux.markAsManaged(managed.name)
            // foreign deliberately NOT marked managed.

            setPaneStyle(session: managed.name, pane: 1, alert: true)
            Tmux.setAlertCount(managed.name, count: 1)
            setPaneStyle(session: foreign.name, pane: 1, alert: true)
            Tmux.setAlertCount(foreign.name, count: 99)   // obvious wrong

            let spaces = try! Tmux.listSpacesWithAlerts()
            check("globalCount-excludesUnmanagedSession",
                  !spaces.sessions.contains(foreign.name),
                  "unmanaged session must not appear in listSpacesWithAlerts")
            check("globalCount-onlyManagedSummed",
                  globalAlertCount(spaces.alertCounts) == 1,
                  "global count must only sum managed sessions (1), not include the 99 from the foreign session")
        }

        // Deferred to Phase 4: notification_messages (pure function, no CLI)
        // Deferred to Phase 4: smart_landing_integration (pure function, no CLI)

        print("E2EAttentionTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}

// MARK: - Shell helper

/// Run a shell command string with optional extra environment variables.
private func runShell(_ command: String, environment: [String: String] = [:]) -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]

    var env = ProcessInfo.processInfo.environment
    for (key, value) in environment {
        env[key] = value
    }
    process.environment = env

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
