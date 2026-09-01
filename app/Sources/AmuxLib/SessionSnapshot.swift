// SessionSnapshot.swift -- What was open, so it can be brought back.
//
// Separate from State.swift on purpose: State is window labels + view mode
// (how the current run is arranged), this is the full pane inventory (what
// to recreate after the tmux server dies). One concern per file.
//
// Written to ~/.amux/session-snapshot.json on pane events and on clean exit.
// `cleanExit` is true only when the terminate path wrote it; anything else
// means the last run died (crash, power loss, force quit) and the snapshot
// may be a little behind what was actually on screen.

import Foundation

/// How a Claude pane's session id was resolved. Ordered by trust:
/// `.resumeArg` and `.startTime` are deterministic, `.topicMatch` is a
/// heuristic that must be shown to the user before it is acted on, and
/// `.none` means no id was found (never a guess).
public enum IDConfidence: String, Codable, Equatable {
    case resumeArg = "resume_arg"
    case startTime = "start_time"
    case topicMatch = "topic_match"
    case none = "none"
}

/// What a pane was running.
public enum PaneKind: Equatable {
    /// Claude Code. `sessionID` nil means no id resolved — restore opens a
    /// shell at the cwd rather than resuming the wrong conversation.
    case claude(sessionID: String?, confidence: IDConfidence)
    /// A plain interactive shell. Restore reopens it at its cwd.
    case shell
    /// A long-running foreground command (e.g. `wtr`). Restore re-runs it.
    case command(String)
}

public struct PaneSnapshot: Equatable {
    public var index: Int
    public var cwd: String
    public var title: String
    public var kind: PaneKind

    public init(index: Int, cwd: String, title: String, kind: PaneKind) {
        self.index = index
        self.cwd = cwd
        self.title = title
        self.kind = kind
    }
}

public struct SpaceSnapshot: Equatable {
    public var name: String
    public var panes: [PaneSnapshot]
    public var selectedPane: Int
    /// For a parked space, the space it was parked from — shown in the backlog
    /// picker. Empty for foreground spaces.
    public var parkedFrom: String

    public init(name: String, panes: [PaneSnapshot], selectedPane: Int,
                parkedFrom: String = "") {
        self.name = name
        self.panes = panes
        self.selectedPane = selectedPane
        self.parkedFrom = parkedFrom
    }
}

public struct SessionSnapshot: Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Epoch seconds. Doubles as the snapshot's identity — the restore prompt
    /// records the `capturedAt` it consumed so the same one is not offered twice.
    public var capturedAt: Double
    public var cleanExit: Bool
    public var spaces: [SpaceSnapshot]
    /// Names of the spaces in `spaces` that were parked in the backlog.
    public var backlog: [String]

    public init(capturedAt: Double, cleanExit: Bool,
                spaces: [SpaceSnapshot], backlog: [String]) {
        self.version = SessionSnapshot.currentVersion
        self.capturedAt = capturedAt
        self.cleanExit = cleanExit
        self.spaces = spaces
        self.backlog = backlog
    }

    /// Total panes across every space — what the restore prompt counts.
    public var paneCount: Int {
        spaces.reduce(0) { $0 + $1.panes.count }
    }

    /// ~/.amux/session-snapshot.json (or $AMUX_HOME).
    public static var defaultPath: URL { AmuxPaths.snapshot() }

    /// Load a snapshot. Missing, unreadable, or corrupt file → nil, no throw:
    /// a bad snapshot must never stop amux from starting.
    public static func load(from path: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    public func save(to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(self), to: path)
    }
}

/// User choices about the restore prompt. Kept in its own file because every
/// capture rewrites the snapshot and would otherwise wipe the opt-out.
public struct RestorePrefs: Codable, Equatable {
    /// Set by the prompt's "Don't ask again" option.
    public var dontAsk: Bool
    /// `capturedAt` of the snapshot already restored (or declined), so the
    /// same snapshot is not offered a second time.
    public var consumedCapturedAt: Double?

    public init(dontAsk: Bool = false, consumedCapturedAt: Double? = nil) {
        self.dontAsk = dontAsk
        self.consumedCapturedAt = consumedCapturedAt
    }

    enum CodingKeys: String, CodingKey {
        case dontAsk = "dont_ask"
        case consumedCapturedAt = "consumed_captured_at"
    }

    /// ~/.amux/restore-prefs.json (or $AMUX_HOME).
    public static var defaultPath: URL { AmuxPaths.restorePrefs() }

    /// Missing or corrupt prefs mean "no preference expressed yet".
    public static func load(from path: URL) -> RestorePrefs {
        guard let data = try? Data(contentsOf: path),
              let prefs = try? JSONDecoder().decode(RestorePrefs.self, from: data)
        else { return RestorePrefs() }
        return prefs
    }

    public func save(to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(self), to: path)
    }
}

// MARK: - Codable

// PaneKind carries associated values, so it encodes as a tagged object:
//   {"type": "claude", "session_id": "…", "confidence": "resume_arg"}
//   {"type": "shell"}
//   {"type": "command", "command": "wtr"}

extension PaneKind: Codable {
    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case confidence
        case command
    }

    private enum Tag: String, Codable {
        case claude, shell, command
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claude(let sessionID, let confidence):
            try c.encode(Tag.claude, forKey: .type)
            try c.encodeIfPresent(sessionID, forKey: .sessionID)
            try c.encode(confidence, forKey: .confidence)
        case .shell:
            try c.encode(Tag.shell, forKey: .type)
        case .command(let cmd):
            try c.encode(Tag.command, forKey: .type)
            try c.encode(cmd, forKey: .command)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .type) {
        case .claude:
            self = .claude(
                sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID),
                confidence: try c.decodeIfPresent(IDConfidence.self, forKey: .confidence) ?? .none
            )
        case .shell:
            self = .shell
        case .command:
            self = .command(try c.decode(String.self, forKey: .command))
        }
    }
}

extension PaneSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case index, cwd, title, kind
    }
}

extension SpaceSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case name, panes
        case selectedPane = "selected_pane"
        case parkedFrom = "parked_from"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.panes = try c.decode([PaneSnapshot].self, forKey: .panes)
        self.selectedPane = try c.decode(Int.self, forKey: .selectedPane)
        self.parkedFrom = try c.decodeIfPresent(String.self, forKey: .parkedFrom) ?? ""
    }
}

extension SessionSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case version, spaces, backlog
        case capturedAt = "captured_at"
        case cleanExit = "clean_exit"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.capturedAt = try c.decode(Double.self, forKey: .capturedAt)
        self.cleanExit = try c.decode(Bool.self, forKey: .cleanExit)
        self.spaces = try c.decode([SpaceSnapshot].self, forKey: .spaces)
        self.backlog = try c.decodeIfPresent([String].self, forKey: .backlog) ?? []
    }
}
