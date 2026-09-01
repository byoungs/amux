// SnapshotCapture.swift -- Recording what is open, so restore has something to read.
//
// Capture is event-driven, never timed (explicit design decision): it runs on
// pane add/close, on pane focus change, and on clean exit. Focus changes are
// hooked as well as add/close because typing `claude` into an existing shell
// is not a pane event — focusing another pane afterwards is what closes most
// of that gap.
//
// Every capture shells out to ps/pgrep and reads transcript heads, so it never
// runs on the app's main thread and never holds LiveTmux.processLock. Bursts
// are coalesced to a single trailing write via a request marker file.

import Foundation

public enum SnapshotCapture {
    /// Command names that mean "a plain interactive shell", i.e. restore just
    /// needs to reopen the pane at its cwd.
    static let shellCommands: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "-fish", "login",
    ]

    /// One pane as tmux reports it.
    public struct PaneObservation: Equatable {
        public let session: String
        public let index: Int
        public let cwd: String
        public let title: String
        public let paneCommand: String
        public let panePID: Int
        public let active: Bool

        public init(session: String, index: Int, cwd: String, title: String,
                    paneCommand: String, panePID: Int, active: Bool) {
            self.session = session
            self.index = index
            self.cwd = cwd
            self.title = title
            self.paneCommand = paneCommand
            self.panePID = panePID
            self.active = active
        }
    }

    // MARK: - Pure core

    /// Assemble a snapshot from what was observed. Pure: no tmux, no process
    /// tree, no clock — every input is a parameter.
    /// - Parameter parkedFrom: for each parked space, the space it came from.
    public static func buildSnapshot(observations: [PaneObservation],
                                     resolutions: [PaneRef: ClaudePaneID],
                                     backlog: [String],
                                     parkedFrom: [String: String] = [:],
                                     cleanExit: Bool,
                                     capturedAt: Double) -> SessionSnapshot {
        let bySession = Dictionary(grouping: observations, by: \.session)
        let spaces = bySession.keys.sorted().map { name -> SpaceSnapshot in
            let panes = (bySession[name] ?? []).sorted { $0.index < $1.index }
            return SpaceSnapshot(
                name: name,
                panes: panes.map { obs in
                    PaneSnapshot(index: obs.index, cwd: obs.cwd, title: obs.title,
                                 kind: kind(for: obs, resolutions: resolutions))
                },
                selectedPane: panes.first(where: \.active)?.index ?? 0,
                parkedFrom: parkedFrom[name] ?? "")
        }
        return SessionSnapshot(capturedAt: capturedAt, cleanExit: cleanExit,
                               spaces: spaces,
                               backlog: backlog.filter { bySession[$0] != nil }.sorted())
    }

    private static func kind(for obs: PaneObservation,
                             resolutions: [PaneRef: ClaudePaneID]) -> PaneKind {
        let ref = PaneRef(session: obs.session, index: obs.index)
        if let resolved = resolutions[ref] {
            return .claude(sessionID: resolved.sessionID, confidence: resolved.confidence)
        }
        if shellCommands.contains(obs.paneCommand) || obs.paneCommand.isEmpty {
            return .shell
        }
        return .command(obs.paneCommand)
    }

    // MARK: - Shell

    /// Read every pane of every amux-managed session.
    public static func observePanes(managed: Set<String>) -> [PaneObservation] {
        let format = ["#{session_name}", "#{pane_index}", "#{pane_current_path}",
                      "#{@amux-title}", "#{pane_title}", "#{pane_current_command}",
                      "#{pane_pid}", "#{pane_active}"].joined(separator: "\t")
        let stdout = Tmux.runRaw(["list-panes", "-a", "-F", format])
        return stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, managed.contains(f[0]), let index = Int(f[1]) else { return nil }
            return PaneObservation(
                session: f[0], index: index, cwd: f[2],
                title: f[3].isEmpty ? f[4] : f[3],
                paneCommand: f[5],
                panePID: Int(f[6]) ?? 0,
                active: f[7] == "1")
        }
    }

    /// Capture the current state and write it to disk.
    ///
    /// A snapshot with no panes is never written: the only way to observe zero
    /// panes is a tmux server that is already gone, and overwriting a good
    /// snapshot with an empty one would destroy the very thing restore needs.
    @discardableResult
    public static func captureNow(cleanExit: Bool,
                                  to path: URL = SessionSnapshot.defaultPath,
                                  now: Double = Date().timeIntervalSince1970) -> SessionSnapshot? {
        let foreground = (try? Tmux.listFocusSessions()) ?? []
        let parked = (try? Tmux.listBackgroundSessions()) ?? []
        let background = parked.map(\.name)
        let managed = Set(foreground + background)
        guard !managed.isEmpty else { return nil }

        let observations = observePanes(managed: managed)
        guard !observations.isEmpty else { return nil }

        let panes = observations.map { obs in
            PaneProcesses(session: obs.session, index: obs.index, cwd: obs.cwd,
                          title: obs.title, paneCommand: obs.paneCommand,
                          processes: ClaudeScan.processes(paneProcessID: obs.panePID))
        }
        // Two passes. The first reads a few KB per transcript, which settles
        // every pane launched with --resume or started recently enough to match
        // its transcript's first timestamp. Only if a Claude pane is still
        // unresolved do we read topic text, and only for its project directory
        // — those files run to hundreds of megabytes, and this whole capture
        // fires on every pane focus change.
        let slugs = Set(panes.map { ClaudeSession.slugFor($0.cwd) })
        let heads = ClaudeScan.transcriptHeads(slugs: slugs)
        var resolutions = ClaudeSession.resolveSessionIDs(panes: panes, transcripts: heads)
        let needTopics = ClaudeSession.slugsNeedingTopics(panes: panes, resolutions: resolutions)
        if !needTopics.isEmpty {
            let enriched = ClaudeScan.withTopics(heads, slugs: needTopics)
            resolutions = ClaudeSession.resolveSessionIDs(panes: panes, transcripts: enriched)
        }

        let snapshot = buildSnapshot(
            observations: observations, resolutions: resolutions,
            backlog: background,
            parkedFrom: Dictionary(uniqueKeysWithValues: parked.map { ($0.name, $0.parkedFrom) }),
            cleanExit: cleanExit, capturedAt: now)
        do {
            try snapshot.save(to: path)
        } catch {
            fputs("amux: snapshot write failed: \(error)\n", stderr)
            return nil
        }
        return snapshot
    }

    // MARK: - Coalescing

    /// ~/.amux/snapshot-request (or $AMUX_HOME) — holds the token of the most
    /// recent request.
    public static var requestMarkerPath: URL { AmuxPaths.snapshotRequest() }

    /// Claim the trailing edge of a burst of events.
    ///
    /// Stamps the marker with our own token, waits, then proceeds only if no
    /// later event overwrote it. Ten focus changes in a row therefore produce
    /// one capture — the last one, with the state the user actually left.
    public static func claimTrailingEdge(delay: TimeInterval = 0.5,
                                         marker: URL = requestMarkerPath) -> Bool {
        let token = UUID().uuidString
        // Written directly, not through AtomicFile: several of these racing is
        // the normal case, and they would collide on one shared temp path. A
        // 36-byte write lands in a single syscall, so the last writer wins and
        // readers see one whole token or another — never a mixture.
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? Data(token.utf8).write(to: marker)) != nil else { return true }
        Thread.sleep(forTimeInterval: delay)
        let current = (try? String(contentsOf: marker, encoding: .utf8)) ?? token
        return current == token
    }

    /// Ask for a capture without waiting for it: spawns `amux-cli snapshot`,
    /// which does the coalescing and the work in its own process. Safe to call
    /// from a tmux hook or from the app.
    public static func requestAsync() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Config.findAmuxCLI())
        process.arguments = ["snapshot"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
