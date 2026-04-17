// State.swift -- Persistent state for amux sessions.
//
// Saves and loads session state (selected pane, view mode, window list)
// to ~/.amux/state.json using atomic write (temp file + rename).

import Foundation

public struct WindowEntry: Codable {
    public var position: Int
    public var tmuxWindow: String
    public var label: String

    public init(position: Int, tmuxWindow: String, label: String) {
        self.position = position
        self.tmuxWindow = tmuxWindow
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case position
        case tmuxWindow = "tmux_window"
        case label
    }
}

public struct AmuxState: Codable {
    public var version: Int
    public var selected: Int
    public var viewMode: String
    public var windows: [WindowEntry]

    enum CodingKeys: String, CodingKey {
        case version
        case selected
        case viewMode = "view_mode"
        case windows
    }

    /// Create a new default state.
    public init() {
        version = 1
        selected = 0
        viewMode = "grid"
        windows = []
    }

    /// Load state from a file path. Returns nil if the file is missing or corrupt.
    public static func load(from path: URL) -> AmuxState? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(AmuxState.self, from: data)
    }

    /// Save state to a file path atomically via a temporary file + rename.
    /// Parent directories are created if they don't exist.
    public func save(to path: URL) throws {
        if let parent = path.deletingLastPathComponent() as URL? {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        // Write to a sibling temp file, then rename for atomicity.
        let tmpPath = path.deletingPathExtension().appendingPathExtension("json.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: tmpPath)
        _ = try FileManager.default.replaceItemAt(path, withItemAt: tmpPath)
    }

    /// Return the default state file path: ~/.amux/state.json
    public static var defaultPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".amux")
            .appendingPathComponent("state.json")
    }

    /// Reconcile saved state against the current live tmux windows.
    ///
    /// - Saved windows that still exist in liveWindows are kept in their saved order.
    /// - Live windows not present in the saved state are appended at the end.
    /// - selected is clamped to the valid range.
    public func reconcile(liveWindows: [String]) -> AmuxState {
        // Keep saved windows that still appear in the live set, preserving order.
        var resultWindows = windows.filter { liveWindows.contains($0.tmuxWindow) }

        // Collect the set of tmux_window names already in result.
        let alreadySaved = Set(resultWindows.map(\.tmuxWindow))

        // Collect live windows not yet represented.
        let nextPosition = resultWindows.count
        let newEntries = liveWindows
            .filter { !alreadySaved.contains($0) }
            .enumerated()
            .map { (i, live) in
                WindowEntry(position: nextPosition + i, tmuxWindow: live, label: live)
            }

        resultWindows.append(contentsOf: newEntries)

        // Reindex positions to be contiguous.
        for i in resultWindows.indices {
            resultWindows[i].position = i
        }

        // Clamp selected index.
        let maxIdx = max(resultWindows.count - 1, 0)
        let clampedSelected = min(selected, maxIdx)

        var state = AmuxState()
        state.version = version
        state.selected = clampedSelected
        state.viewMode = viewMode
        state.windows = resultWindows
        return state
    }
}
