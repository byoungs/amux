// ClaudeSession.swift -- Resolving which Claude conversation a pane is running.
//
// Pure core. Everything here takes process samples and transcript metadata as
// parameters and returns a mapping; the `ps`/`pgrep`/filesystem reads that
// produce those inputs live in ClaudeScan.swift.
//
// This is the part that has to be right: resuming a wrong id drops Brian into
// someone else's conversation. Three signals, most trustworthy first:
//
//   .resumeArg   the process argv literally says `claude --resume <uuid>`
//   .startTime   a fresh session's transcript begins when the process started
//   .topicMatch  word overlap between pane title and transcript topic (heuristic)
//
// and `.none` when nothing is convincing — never a guess.
//
// Facts this encodes, verified 2026-09-01 against the running system:
//   - The project dir slug is the cwd with every non-alphanumeric char -> '-'.
//   - Claude does not hold its transcript open (no lsof signal); it appends
//     and closes, so there is no "which file is live" shortcut.
//   - No session id in the process environment, and none in argv unless resumed.
//   - A pane sitting at Claude's "resume from summary?" prompt still reports
//     its *shell* as pane_current_command, so the process scan — not the pane
//     command — is what decides whether a pane is a Claude pane.
//   - Transcript mtimes are not a reliable recency signal (a bulk touch can
//     stamp old files); the timestamps inside the file are.

import Foundation

/// One process observed under a pane (the pane's own pid or a descendant).
public struct ProcSample: Equatable {
    public let startTime: Double   // epoch seconds
    public let command: String     // full command line

    public init(startTime: Double, command: String) {
        self.startTime = startTime
        self.command = command
    }
}

/// A pane plus the processes running under it.
public struct PaneProcesses {
    public let session: String
    public let index: Int
    public let cwd: String
    public let title: String
    /// `#{pane_current_command}` — a hint only; see the note above.
    public let paneCommand: String
    public let processes: [ProcSample]

    public init(session: String, index: Int, cwd: String, title: String,
                paneCommand: String, processes: [ProcSample]) {
        self.session = session
        self.index = index
        self.cwd = cwd
        self.title = title
        self.paneCommand = paneCommand
        self.processes = processes
    }
}

/// Metadata read from one `~/.claude/projects/<slug>/<id>.jsonl`.
public struct TranscriptMeta {
    public let sessionID: String
    public let slug: String
    /// Epoch of the first timestamped entry — when the conversation began.
    public let firstTimestamp: Double?
    /// Epoch of the last timestamped entry — recency, used to rank candidates.
    public let lastTimestamp: Double?
    /// Summaries + first and last user message, for topic matching.
    public let topicBlob: String

    public init(sessionID: String, slug: String, firstTimestamp: Double?,
                lastTimestamp: Double?, topicBlob: String) {
        self.sessionID = sessionID
        self.slug = slug
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.topicBlob = topicBlob
    }
}

/// Identifies a pane across spaces.
public struct PaneRef: Hashable {
    public let session: String
    public let index: Int

    public init(session: String, index: Int) {
        self.session = session
        self.index = index
    }
}

public struct ClaudePaneID: Equatable {
    public let sessionID: String?
    public let confidence: IDConfidence

    public init(sessionID: String?, confidence: IDConfidence) {
        self.sessionID = sessionID
        self.confidence = confidence
    }
}

public enum ClaudeSession {
    /// Seconds a transcript's first timestamp may differ from the process
    /// start time and still be considered the same session.
    public static let startTimeTolerance: Double = 300

    // MARK: - Recognizers

    /// Claude Code renames its process to its version string (e.g. "2.1.156"),
    /// so both spellings count.
    public static func isClaudeCommand(_ command: String) -> Bool {
        let first = command.split(separator: " ").first.map(String.init) ?? ""
        let base = (first as NSString).lastPathComponent
        if base == "claude" { return true }
        if isVersionLike(base) { return true }
        return command.contains("claude")
    }

    private static func isVersionLike(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 2 else { return false }
        return parts.prefix(2).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// True when this pane is running Claude Code — decided by the process
    /// scan, with the pane command as a secondary hint.
    public static func isClaudePane(paneCommand: String, processes: [ProcSample]) -> Bool {
        if paneCommand == "claude" || isVersionLike(paneCommand) { return true }
        return processes.contains { isClaudeCommand($0.command) }
    }

    /// The uuid from a `claude --resume <uuid>` command line, if present.
    public static func resumeArgID(_ command: String) -> String? {
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "=" }).map(String.init)
        guard let i = tokens.firstIndex(of: "--resume"), i + 1 < tokens.count else { return nil }
        let candidate = tokens[i + 1]
        return isSessionID(candidate) ? candidate : nil
    }

    /// Claude session ids are lowercase hex uuids.
    public static func isSessionID(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        for (i, ch) in s.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                if ch != "-" { return false }
            } else if !ch.isHexDigit {
                return false
            }
        }
        return true
    }

    /// Claude Code's project-dir slug: every non-alphanumeric char → '-'.
    public static func slugFor(_ cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Whether `slug` is the pane's own project dir or one nested inside it.
    ///
    /// A pane often sits in a repo root while Claude runs in a worktree below
    /// it, and Claude files the transcript under the worktree's slug. Matching
    /// the pane's slug exactly finds nothing in that case. The trailing
    /// separator check keeps a sibling that merely shares a name prefix
    /// (`…-amux2` against `…-amux`) out of the candidate set.
    public static func slugMatches(_ slug: String, paneSlug: String) -> Bool {
        if slug == paneSlug { return true }
        guard slug.hasPrefix(paneSlug) else { return false }
        return slug.dropFirst(paneSlug.count).first == "-"
    }

    // MARK: - Resolution

    /// Resolve a session id for every Claude pane. Non-Claude panes are absent
    /// from the result; Claude panes with nothing convincing map to
    /// `(nil, .none)`.
    public static func resolveSessionIDs(
        panes: [PaneProcesses],
        transcripts: [TranscriptMeta],
        tolerance: Double = startTimeTolerance
    ) -> [PaneRef: ClaudePaneID] {
        let claudePanes = panes.filter {
            isClaudePane(paneCommand: $0.paneCommand, processes: $0.processes)
        }
        var result: [PaneRef: ClaudePaneID] = [:]
        var claimed = Set<String>()
        for p in claudePanes { result[ref(p)] = ClaudePaneID(sessionID: nil, confidence: .none) }

        // 1. --resume argv. Deterministic, so it settles those panes outright.
        for p in claudePanes {
            for proc in p.processes where isClaudeCommand(proc.command) {
                if let id = resumeArgID(proc.command) {
                    result[ref(p)] = ClaudePaneID(sessionID: id, confidence: .resumeArg)
                    claimed.insert(id)
                    break
                }
            }
        }

        // Candidates for a pane: its own project dir plus any nested one, so a
        // pane in a repo root still finds the session Claude is running in a
        // worktree beneath it.
        func candidateTranscripts(forCwd cwd: String) -> [TranscriptMeta] {
            let paneSlug = slugFor(cwd)
            return transcripts.filter { slugMatches($0.slug, paneSlug: paneSlug) }
        }

        // 2. Process start time vs the transcript's first entry. Scored across
        //    all unresolved panes at once, then assigned smallest-delta-first
        //    so two panes can't land on the same transcript.
        var candidates: [(delta: Double, pane: PaneRef, id: String)] = []
        for p in claudePanes where result[ref(p)]?.sessionID == nil {
            let starts = p.processes.filter { isClaudeCommand($0.command) }.map(\.startTime)
            guard !starts.isEmpty else { continue }
            for t in candidateTranscripts(forCwd: p.cwd) {
                guard let first = t.firstTimestamp, !claimed.contains(t.sessionID) else { continue }
                for start in starts {
                    let delta = abs(first - start)
                    if delta <= tolerance {
                        candidates.append((delta, ref(p), t.sessionID))
                    }
                }
            }
        }
        candidates.sort { $0.delta < $1.delta }
        var settled = Set<PaneRef>()
        for c in candidates {
            guard !settled.contains(c.pane), !claimed.contains(c.id) else { continue }
            result[c.pane] = ClaudePaneID(sessionID: c.id, confidence: .startTime)
            settled.insert(c.pane)
            claimed.insert(c.id)
        }

        // 3. Topic overlap, per project dir, assigned uniquely by elimination.
        //    Heuristic — labelled `.topicMatch` so the restore prompt can flag
        //    it before a wrong resume happens rather than after.
        let unresolved = claudePanes.filter { result[ref($0)]?.sessionID == nil }
        for (_, group) in Dictionary(grouping: unresolved, by: { slugFor($0.cwd) }) {
            // Liveness: the running sessions are the most recently written
            // transcripts, so only the N freshest unclaimed ones are eligible.
            // That stops an old same-topic conversation from being latched on to.
            let pool = candidateTranscripts(forCwd: group[0].cwd)
                .filter { !claimed.contains($0.sessionID) }
                .sorted { ($0.lastTimestamp ?? 0) > ($1.lastTimestamp ?? 0) }
                .prefix(group.count)
            guard !pool.isEmpty else { continue }

            var scored: [(score: Int, pane: PaneRef, id: String)] = []
            for p in group {
                let titleTokens = tokens(p.title)
                for t in pool {
                    let overlap = titleTokens.intersection(tokens(t.topicBlob)).count
                    if overlap > 0 { scored.append((overlap, ref(p), t.sessionID)) }
                }
            }
            scored.sort { $0.score > $1.score }
            var usedPanes = Set<PaneRef>()
            for s in scored {
                guard !usedPanes.contains(s.pane), !claimed.contains(s.id) else { continue }
                result[s.pane] = ClaudePaneID(sessionID: s.id, confidence: .topicMatch)
                usedPanes.insert(s.pane)
                claimed.insert(s.id)
            }
            // Panes with no overlap keep `.none`. The python original filled
            // them with "newest transcript in the dir"; that is exactly the
            // guess that resumed the wrong conversation, so it is not repeated.
        }

        return result
    }

    private static func ref(_ p: PaneProcesses) -> PaneRef {
        PaneRef(session: p.session, index: p.index)
    }

    /// Project slugs that still hold an unresolved Claude pane after the
    /// deterministic signals have run — the only ones worth reading topic
    /// text for. Everything else keeps its cheap head-only read.
    public static func slugsNeedingTopics(panes: [PaneProcesses],
                                          resolutions: [PaneRef: ClaudePaneID]) -> Set<String> {
        var out = Set<String>()
        for pane in panes {
            let resolved = resolutions[ref(pane)]
            if resolved != nil && resolved?.sessionID == nil {
                out.insert(slugFor(pane.cwd))
            }
        }
        return out
    }

    // MARK: - Topic tokens

    private static let stopWords: Set<String> = Set(
        ("the a an of to and or is in on for with you i we our my your this that have "
         + "get got back app keep keeps trying try go let lets need want can do please "
         + "look review work across over from into about it its")
            .split(separator: " ").map(String.init))

    /// Lowercase alphanumeric words of 3+ chars, minus common filler.
    public static func tokens(_ text: String) -> Set<String> {
        var out = Set<String>()
        var current = ""
        func flush() {
            if current.count >= 3 && !stopWords.contains(current) { out.insert(current) }
            current = ""
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
        }
        flush()
        return out
    }
}
