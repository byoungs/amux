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

    /// Serializes Process.run()/readback/waitUntilExit across all LiveTmux
    /// calls in this process.
    ///
    /// Foundation's `Process` uses an internal GCD signal source for SIGCHLD
    /// plus shared per-process state for pipe fd inheritance during
    /// `posix_spawn`. When many `Process` + `Pipe` pairs are launched and
    /// torn down in rapid succession (as the integration-test runner does —
    /// ~30 tmux subprocesses per TestSession, hundreds of sessions per run),
    /// those internals race and the parent ends up calling
    /// `readDataToEndOfFile` on a pipe FD that Foundation has already closed
    /// underneath us. That surfaces as `NSPOSIXErrorDomain Code=9`
    /// ("Bad file descriptor"), which breaks `try!` expressions in tests and
    /// aborts the runner. A single process-wide lock around the Process
    /// lifecycle sidesteps the race entirely at negligible cost — tmux
    /// commands here are small and fast, so serializing them through one
    /// lock is effectively free.
    private static let processLock = NSLock()

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
        LiveTmux.processLock.lock()
        defer { LiveTmux.processLock.unlock() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = tmuxArgs(args)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Wait for termination via a semaphore signalled from the termination
        // handler — NOT `Process.waitUntilExit()`. `waitUntilExit()` pumps the
        // calling thread's run loop, so on the main thread it can fire a
        // scheduled Timer or drain a queued main-queue block re-entrantly
        // *while we still hold `processLock`*. If that re-entrant work issues
        // its own tmux command, it blocks on the non-recursive lock the same
        // thread already owns — a self-deadlock that freezes the app. A plain
        // semaphore wait blocks the thread without servicing the run loop, so
        // nothing can re-enter while the lock is held.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()

        // Read BEFORE waiting so a large child output can't fill the pipe
        // buffer and deadlock, and so we read via the FileHandle we still own
        // rather than racing tmux/Foundation teardown.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()

        // Release the parent's read-end FDs immediately rather than
        // waiting for ARC. (Foundation itself closes the parent's
        // write-end after spawn; the read-end is ours.) Leaving read
        // FDs to ARC dealloc delays their release and lets the next
        // Process.run() race with this one's teardown.
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw AmuxError.tmux(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func launch(_ args: [String]) {
        LiveTmux.processLock.lock()
        defer { LiveTmux.processLock.unlock() }

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
