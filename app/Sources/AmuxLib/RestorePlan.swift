// RestorePlan.swift -- Turning a snapshot back into panes.
//
// Pure: a snapshot plus what tmux currently has becomes an ordered list of
// tmux commands. Nothing here talks to tmux, so the ordering rules that are
// easy to get wrong — re-tile before every split, select the pane last, skip
// spaces that already exist — are unit-testable against FakeTmux.

import Foundation

public struct RestorePlan: Equatable {
    /// tmux commands to run in order, each without the leading "tmux".
    public let commands: [[String]]
    /// Spaces left alone because they already exist with panes.
    public let skippedSpaces: [String]
    /// How many panes this plan actually recreates.
    public let restoredPaneCount: Int

    public init(commands: [[String]], skippedSpaces: [String], restoredPaneCount: Int) {
        self.commands = commands
        self.skippedSpaces = skippedSpaces
        self.restoredPaneCount = restoredPaneCount
    }

    public var isEmpty: Bool { commands.isEmpty }
}

public enum SessionRestore {

    // MARK: - Gating

    /// Whether to offer the restore prompt at startup.
    ///
    /// Restore is for the case where nothing survived: if amux-managed tmux
    /// sessions are still running (the app was relaunched, e.g. `make dev`,
    /// while the tmux server kept going) those panes are the truth and there
    /// is nothing to bring back.
    public static func shouldOfferRestore(hadExistingSessions: Bool,
                                          snapshot: SessionSnapshot?,
                                          prefs: RestorePrefs) -> Bool {
        guard !hadExistingSessions else { return false }
        guard let snapshot = snapshot, snapshot.paneCount > 0 else { return false }
        guard !prefs.dontAsk else { return false }
        return prefs.consumedCapturedAt != snapshot.capturedAt
    }

    // MARK: - Planning

    /// Build the tmux command list that recreates a snapshot.
    ///
    /// - Parameters:
    ///   - existing: session name → pane count for sessions tmux already has.
    ///     Any space present there is skipped rather than clobbered, which is
    ///     what makes restore safe to run twice.
    ///   - now: epoch seconds stamped on re-parked backlog sessions.
    ///   - adoptSession: the session the app just created and is attached to.
    ///     If the snapshot contains a space of that name and the live session
    ///     is still a single untouched pane, its panes are restored into it
    ///     (the first pane `cd`s to its saved cwd) instead of being skipped —
    ///     it cannot be recreated, because killing it would drop our client.
    public static func planRestore(snapshot: SessionSnapshot,
                                   existing: [String: Int],
                                   now: UInt64,
                                   adoptSession: String? = nil) -> RestorePlan {
        var commands: [[String]] = []
        var skipped: [String] = []
        var restoredPanes = 0
        let backlog = Set(snapshot.backlog)

        for space in snapshot.spaces {
            guard !space.panes.isEmpty else { continue }
            let livePanes = existing[space.name] ?? 0
            let adopting = space.name == adoptSession && livePanes == 1
            if livePanes > 0 && !adopting {
                skipped.append(space.name)
                continue
            }

            let target = "\(space.name):0"
            let panes = space.panes.sorted { $0.index < $1.index }

            let first = panes[0]
            if adopting {
                // The pane already exists (it is where this prompt is running),
                // so move it to the saved cwd rather than recreating it.
                commands.append(["send-keys", "-t", "\(target).0",
                                 "cd \(singleQuoted(first.cwd)) && clear", "Enter"])
            } else {
                commands.append(["new-session", "-d", "-s", space.name, "-c", first.cwd])
            }
            commands.append(["set-option", "-t", space.name, "@amux-managed", "1"])
            commands.append(contentsOf: paneSetup(target: target, position: 0, pane: first))
            restoredPanes += 1

            for (position, pane) in panes.enumerated().dropFirst() {
                // Re-tile before every split. Without this tmux refuses with
                // "no space for a new pane" once the default halving leaves the
                // target pane too short — seen live at the 6th pane.
                commands.append(["select-layout", "-t", target, "tiled"])
                // Split the pane we just made, never the window: tmux inserts
                // the new pane immediately after the target, so splitting the
                // window (i.e. its active pane, still pane 0 because every
                // split is detached) inserts at index 1 every time and reverses
                // the saved order. Verified against real tmux 2026-09-01.
                commands.append(["split-window", "-t", "\(target).\(position - 1)",
                                 "-d", "-c", pane.cwd])
                commands.append(contentsOf: paneSetup(target: target, position: position, pane: pane))
                restoredPanes += 1
            }
            commands.append(["select-layout", "-t", target, "tiled"])

            if backlog.contains(space.name) {
                // parkedFrom must never be empty: it is the last field tmux
                // prints for the backlog listing, and an empty trailing field
                // is trimmed off the response, dropping the whole row.
                let from = space.parkedFrom.isEmpty ? space.name : space.parkedFrom
                commands.append(["set-option", "-t", space.name,
                                 AmuxSessionOption.parkedFrom, from])
                commands.append(["set-option", "-t", space.name,
                                 AmuxSessionOption.parkedAt, String(now)])
                commands.append(["set-option", "-t", space.name,
                                 AmuxSessionOption.state, SessionState.background.rawValue])
            } else {
                commands.append(["set-option", "-t", space.name,
                                 AmuxSessionOption.state, SessionState.foreground.rawValue])
            }

            // Focus last: the splits above are detached (`-d`) so the layout
            // pipeline runs cleanly, and computeAdd never sets selectPane.
            let selected = panes.contains(where: { $0.index == space.selectedPane })
                ? space.selectedPane : panes[0].index
            let selectedPosition = panes.firstIndex(where: { $0.index == selected }) ?? 0
            commands.append(["select-pane", "-t", "\(target).\(selectedPosition)"])
        }

        return RestorePlan(commands: commands, skippedSpaces: skipped,
                           restoredPaneCount: restoredPanes)
    }

    /// Title + launch command for one pane. `position` is the pane's ordinal
    /// in the recreated window, which is what tmux will index it by — the
    /// saved `index` describes the old window and may have gaps.
    private static func paneSetup(target: String, position: Int,
                                  pane: PaneSnapshot) -> [[String]] {
        var out: [[String]] = []
        let paneTarget = "\(target).\(position)"
        if !pane.title.isEmpty {
            out.append(["set-option", "-p", "-t", paneTarget, "@amux-title", pane.title])
        }
        if let launch = launchCommand(for: pane) {
            out.append(["send-keys", "-t", paneTarget, launch, "Enter"])
        }
        return out
    }

    /// What to type into a restored pane, or nil for a plain shell.
    public static func launchCommand(for pane: PaneSnapshot) -> String? {
        switch pane.kind {
        case .claude(let sessionID, _):
            guard let id = sessionID else {
                // No id resolved: never guess. Leave a shell at the right cwd
                // with the topic and the command needed to pick it up by hand.
                let topic = pane.title.isEmpty ? "(untitled)" : pane.title
                return "echo " + singleQuoted(
                    "amux: no Claude session id resolved for \"\(topic)\" — "
                    + "resume it with: claude --resume <id>  (claude --resume lists them)")
            }
            return "claude --resume \(id)"
        case .shell:
            return nil
        case .command(let cmd):
            return cmd
        }
    }

    /// Wrap in single quotes for a shell, escaping embedded single quotes.
    public static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Execution

    /// Run a plan through the tmux executor. Individual failures are logged
    /// and skipped: a space that will not come back must not stop the rest.
    public static func execute(_ plan: RestorePlan) {
        for command in plan.commands {
            do {
                _ = try Tmux.executor.execute(command)
            } catch {
                fputs("amux: restore step failed (\(command.joined(separator: " "))): \(error)\n", stderr)
            }
        }
    }

    /// Current sessions and their pane counts, for `planRestore(existing:)`.
    public static func existingSessionPaneCounts() -> [String: Int] {
        let stdout = Tmux.runRaw(["list-sessions", "-F", "#{session_name}\t#{session_windows}"])
        var out: [String: Int] = [:]
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard let name = parts.first else { continue }
            out[name] = (try? Tmux.paneCount(name)) ?? 1
        }
        return out
    }
}
