// Notify.swift -- macOS notification and frontmost-app detection.
//
// System notifications are macOS-only. Uses lsappinfo for frontmost
// detection (no Automation permissions needed) and osascript for
// sending notifications.

import Foundation

public enum Notify {
    /// Check if a given app name is a known terminal emulator.
    public static func isKnownTerminal(_ app: String) -> Bool {
        let lower = app.lowercased()
        return lower.contains("terminal")
            || lower.contains("iterm")
            || lower.contains("alacritty")
            || lower.contains("kitty")
            || lower.contains("wezterm")
            || lower.contains("ghostty")
    }

    /// Check if the terminal emulator hosting this tmux session is the
    /// frontmost macOS application.
    ///
    /// Uses lsappinfo which requires no Automation permissions (unlike
    /// osascript + System Events). Returns true (safe default: don't notify)
    /// if detection fails.
    public static func isTerminalFrontmost() -> Bool {
        guard let app = frontmostApp() else {
            return true // safe default: assume frontmost, don't notify
        }
        return isKnownTerminal(app)
    }

    /// Get the name of the frontmost macOS application via lsappinfo.
    /// Returns nil if the command fails.
    private static func frontmostApp() -> String? {
        // Get the ASN (Application Serial Number) of the frontmost app
        let frontProcess = Process()
        frontProcess.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        frontProcess.arguments = ["front"]
        let frontPipe = Pipe()
        frontProcess.standardOutput = frontPipe
        frontProcess.standardError = FileHandle.nullDevice
        do {
            try frontProcess.run()
            frontProcess.waitUntilExit()
        } catch {
            return nil
        }
        let asnData = frontPipe.fileHandleForReading.readDataToEndOfFile()
        let asn = String(data: asnData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !asn.isEmpty else { return nil }

        // Get the display name for that ASN
        let infoProcess = Process()
        infoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        infoProcess.arguments = ["info", "-only", "name", asn]
        let infoPipe = Pipe()
        infoProcess.standardOutput = infoPipe
        infoProcess.standardError = FileHandle.nullDevice
        do {
            try infoProcess.run()
            infoProcess.waitUntilExit()
        } catch {
            return nil
        }
        let infoData = infoPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: infoData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Parse: "LSDisplayName"="AppName"
        guard let rest = output.stripPrefix("\"LSDisplayName\"=\""),
              rest.hasSuffix("\"") else {
            return nil
        }
        return String(rest.dropLast())
    }

    /// Format a human-readable notification message from alert count.
    public static func formatMessage(count: Int) -> String {
        switch count {
        case 0: return "All agents are working"
        case 1: return "1 agent is ready for you"
        default: return "\(count) agents are ready for you"
        }
    }
}

private extension String {
    /// Strip a prefix and return the remainder, or nil if the prefix doesn't match.
    func stripPrefix(_ prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count)
    }
}
