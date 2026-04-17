import Foundation

/// Abstraction over tmux command execution.
///
/// One method. LiveTmux shells out to the real tmux binary.
/// FakeTmux pattern-matches on args and maintains in-memory state.
///
/// The existing Tmux.swift orchestration code builds arg arrays and
/// calls this instead of spawning Process directly.
public protocol TmuxExecutor {
    /// Execute a tmux command and return trimmed stdout.
    @discardableResult
    func execute(_ args: [String]) throws -> String

    /// Launch a tmux command without waiting for it to exit.
    /// Used for interactive popups where tmux manages the lifecycle.
    func launch(_ args: [String])

    /// Execute multiple tmux commands in a single subprocess using `\;` chaining.
    /// Returns stdout of the combined command (typically empty for set operations).
    /// Each inner array is one tmux command (without the "tmux" prefix).
    @discardableResult
    func executeBatch(_ commands: [[String]]) throws -> String
}

/// Production implementation — shells out to the real tmux binary.
///
/// Supports an optional custom socket name (`tmux -L SOCKET`) so integration
/// tests can run on an isolated tmux server that doesn't leak messages
/// (like "Pane 7 does not exist") to the user's live tmux session.
public class LiveTmux: TmuxExecutor {
    private let socket: String?

    public init(socket: String? = nil) {
        self.socket = socket
    }

    /// Build the full tmux argv, injecting `-L socket` if configured.
    private func tmuxArgs(_ args: [String]) -> [String] {
        if let socket = socket {
            return ["tmux", "-L", socket] + args
        }
        return ["tmux"] + args
    }

    public func execute(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = tmuxArgs(args)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw AmuxError.tmux(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func launch(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = tmuxArgs(args)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    public func executeBatch(_ commands: [[String]]) throws -> String {
        guard !commands.isEmpty else { return "" }
        // Build: tmux cmd1 arg1 arg2 \; cmd2 arg1 \; cmd3 ...
        var args: [String] = []
        for (i, cmd) in commands.enumerated() {
            if i > 0 { args.append(";") }
            args.append(contentsOf: cmd)
        }
        return try execute(args)
    }
}
