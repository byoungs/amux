// Util.swift -- Auto-title generation from directory paths.
//
// Generates session titles like "myproject/feature-auth" from the
// current working directory, using git branch info when available.

import Foundation

public enum Util {
    /// Auto-generate a session title from the current directory.
    /// Format: "<project>/<worktree-or-branch>" e.g. "myproject/feature-auth"
    /// Falls back to directory name if not in a git repo under ~/src/.
    public static func autoTitle(dir: String) -> String {
        let absPath = URL(fileURLWithPath: dir).standardized.path

        let project = extractSrcProject(path: absPath)
            ?? URL(fileURLWithPath: absPath).lastPathComponent

        let branch = gitWorktreeOrBranch(dir: dir)

        if let b = branch, b != "main", b != "master" {
            return "\(project)/\(b)"
        }
        return project
    }

    /// Extract the project name from a path containing /src/.
    /// e.g. "/Users/me/src/myproject/some/sub" -> "myproject"
    public static func extractSrcProject(path: String) -> String? {
        let parts = path.split(separator: "/")
        for (i, part) in parts.enumerated() {
            if part == "src", i + 1 < parts.count {
                return String(parts[i + 1])
            }
        }
        return nil
    }

    /// Get the current git branch name for a directory.
    public static func gitWorktreeOrBranch(dir: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "branch", "--show-current"]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let b = branch, !b.isEmpty {
            return b
        }
        return nil
    }
}
