// Hooks.swift -- Claude Code hook installation for attention management.
//
// Ensures the Notification hook is configured in ~/.claude/settings.json
// so that Claude Code calls `amux alert-pane` when it needs user attention.

import Foundation

public enum Hooks {
    /// The hook command that Claude Code should run on notifications.
    /// Uses $TMUX_PANE to target the specific pane (not the active pane).
    /// Passes AMUX_SESSION because the hook runs as a child process of Claude Code,
    /// which may not have tmux client context to resolve the session name.
    private static let hookCommand = "AMUX_SESSION=$(tmux display-message -t $TMUX_PANE -p '#{session_name}') amux-cli alert-pane $(tmux display-message -t $TMUX_PANE -p '#{pane_index}')"

    /// Path to Claude Code's global settings.
    private static var claudeSettingsPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }

    /// Ensure the Claude Code Notification hook is installed.
    /// Reads existing settings, adds the hook if missing, writes back.
    /// Does nothing if the hook is already present.
    public static func ensureClaudeHook() throws {
        let path = claudeSettingsPath

        // Read existing settings or start with empty object
        var settings: [String: Any]
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HooksError.parse("~/.claude/settings.json is not a JSON object")
            }
            settings = parsed
        } else {
            settings = [:]
        }

        // Check if our hook is already installed
        if hasAmuxHook(settings) {
            return
        }

        // Build the hook entry
        let hookEntry: [String: Any] = [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": hookCommand]
            ]
        ]

        // Add to existing Notification hooks (or create the array)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var notification = hooks["Notification"] as? [[String: Any]] ?? []
        notification.append(hookEntry)
        hooks["Notification"] = notification
        settings["hooks"] = hooks

        // Write back with pretty formatting
        let jsonData = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        // Ensure parent directory exists
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try jsonData.write(to: path)

        FileHandle.standardError.write(
            "Installed amux notification hook in ~/.claude/settings.json\n".data(using: .utf8)!
        )
    }

    /// Check if the amux alert-pane hook is already installed.
    private static func hasAmuxHook(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
              let notification = hooks["Notification"] as? [[String: Any]] else {
            return false
        }
        return notification.contains { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { hook in
                guard let command = hook["command"] as? String else { return false }
                return command.contains("amux alert-pane")
            }
        }
    }
}

public enum HooksError: Error, CustomStringConvertible {
    case parse(String)

    public var description: String {
        switch self {
        case .parse(let msg): return msg
        }
    }
}
