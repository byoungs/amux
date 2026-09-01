// AmuxPaths.swift -- Where amux keeps its state on disk.
//
// One place resolves every path, and one environment variable (AMUX_HOME)
// moves all of them together. That is what makes the real code paths — the
// capture, the restore prompt, the CLI as it actually runs inside a pane —
// drivable by tests without writing into the developer's live ~/.amux.
// Redirecting one file but not another would be worse than no override at
// all: a test would appear isolated while quietly clobbering real state.

import Foundation

public enum AmuxPaths {
    public static let homeOverrideKey = "AMUX_HOME"

    /// The amux state directory: $AMUX_HOME if set and non-empty, else ~/.amux.
    public static func home(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = env[homeOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".amux")
    }

    /// Window labels, selected space, view mode.
    public static func state(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        home(env: env).appendingPathComponent("state.json")
    }

    /// The pane inventory restore reads after a cold start.
    public static func snapshot(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        home(env: env).appendingPathComponent("session-snapshot.json")
    }

    /// The user's answers to the restore prompt.
    public static func restorePrefs(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        home(env: env).appendingPathComponent("restore-prefs.json")
    }

    /// Token of the most recent capture request, for burst coalescing.
    public static func snapshotRequest(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        home(env: env).appendingPathComponent("snapshot-request")
    }
}
