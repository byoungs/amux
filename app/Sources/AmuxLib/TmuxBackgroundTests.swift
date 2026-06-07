#if DEBUG
import Foundation

/// Tests for keeping blocking tmux subprocess work off the caller's thread.
///
/// Regression context: publishPeekCount issued 1 + N + 1 sequential
/// subprocesses on the main thread whenever the permission-prompt count
/// changed, and setCmdHeld issued one on every Cmd press/release. Each
/// LiveTmux.execute parks the calling thread (semaphore wait, no run-loop
/// service) and contends a process-wide lock with the PermissionWatcher's
/// 4s capture-pane bursts — so the main thread stalled and the UI froze.
public enum TmuxBackgroundTests {

    /// TmuxExecutor decorator: records calls, optionally sleeps per call to
    /// model real subprocess latency, forwards to an inner executor.
    /// Thread-safe — tests read from the test thread while Tmux.backgroundQueue
    /// writes.
    private final class InstrumentedExecutor: TmuxExecutor {
        private let inner: TmuxExecutor
        private let delay: TimeInterval
        private let lock = NSLock()
        private var executeLog: [[String]] = []
        private var batchLog: [[[String]]] = []

        init(inner: TmuxExecutor, delay: TimeInterval = 0) {
            self.inner = inner
            self.delay = delay
        }

        var executeCalls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return executeLog
        }

        var batchCalls: [[[String]]] {
            lock.lock()
            defer { lock.unlock() }
            return batchLog
        }

        /// Each execute() and each executeBatch() is one tmux subprocess
        /// in production.
        var subprocessCount: Int { executeCalls.count + batchCalls.count }

        @discardableResult
        func execute(_ args: [String]) throws -> String {
            lock.lock()
            executeLog.append(args)
            lock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return try inner.execute(args)
        }

        func launch(_ args: [String]) {
            inner.launch(args)
        }

        @discardableResult
        func executeBatch(_ commands: [[String]]) throws -> String {
            lock.lock()
            batchLog.append(commands)
            lock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return try inner.executeBatch(commands)
        }
    }

    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else {
                failed += 1
                FileHandle.standardError.write(
                    "FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")\n".data(using: .utf8)!)
            }
        }

        func peekCount(_ fake: FakeTmux, _ session: String) -> String? {
            fake.sessions[session]?.options["@amux-peek-count"]
        }

        // === publishPeekCount uses one batch, not N+2 subprocesses ===
        do {
            let fake = FakeTmux()
            let counting = InstrumentedExecutor(inner: fake)
            Tmux.executor = counting
            try? Tmux.createSession("a")
            Tmux.markAsManaged("a")
            Tmux.setSessionState("a", state: .foreground)
            try? Tmux.createSession("b")
            Tmux.markAsManaged("b")
            Tmux.setSessionState("b", state: .foreground)
            let before = counting.subprocessCount

            Tmux.publishPeekCount(3)

            check("publish-peek-sets-all-sessions",
                  peekCount(fake, "a") == "3" && peekCount(fake, "b") == "3",
                  "got a=\(peekCount(fake, "a") ?? "nil") b=\(peekCount(fake, "b") ?? "nil")")
            let used = counting.subprocessCount - before
            check("publish-peek-two-subprocesses",
                  used <= 2,
                  "expected <=2 subprocesses (list + batch), got \(used)")
        }

        // === publishPeekCountAsync returns without waiting for tmux ===
        do {
            let fake = FakeTmux()
            Tmux.executor = fake  // fast setup, no delay
            try? Tmux.createSession("a")
            Tmux.markAsManaged("a")
            Tmux.setSessionState("a", state: .foreground)
            let slow = InstrumentedExecutor(inner: fake, delay: 0.2)
            Tmux.executor = slow

            let start = CFAbsoluteTimeGetCurrent()
            Tmux.publishPeekCountAsync(2)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            check("publish-peek-async-returns-fast",
                  elapsed < 0.1,
                  String(format: "caller blocked %.0fms", elapsed * 1000))

            Tmux.backgroundQueue.sync {}  // drain the queue
            check("publish-peek-async-applies",
                  peekCount(fake, "a") == "2",
                  "got \(peekCount(fake, "a") ?? "nil")")
        }

        // === setCmdHeldAsync: fast return, ordering preserved ===
        do {
            let fake = FakeTmux()
            Tmux.executor = fake  // fast setup, no delay
            try? Tmux.createSession("s")
            let slow = InstrumentedExecutor(inner: fake, delay: 0.05)
            Tmux.executor = slow

            let start = CFAbsoluteTimeGetCurrent()
            setCmdHeldAsync(session: "s", held: true)
            setCmdHeldAsync(session: "s", held: false)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            check("cmd-held-async-returns-fast",
                  elapsed < 0.05,
                  String(format: "caller blocked %.0fms", elapsed * 1000))

            Tmux.backgroundQueue.sync {}  // drain the queue
            check("cmd-held-async-final-state",
                  fake.sessions["s"]?.options["@amux-cmd-held"] == "0",
                  "got \(fake.sessions["s"]?.options["@amux-cmd-held"] ?? "nil")")
            let cmdHeldValues = slow.executeCalls
                .filter { $0.contains("@amux-cmd-held") }
                .compactMap { $0.last }
            check("cmd-held-async-order",
                  cmdHeldValues == ["1", "0"],
                  "got \(cmdHeldValues)")
        }

        print("TmuxBackground tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("TmuxBackground tests failed") }
    }
}
#endif
