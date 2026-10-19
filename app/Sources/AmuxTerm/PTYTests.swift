#if DEBUG
import Foundation

/// PTY lifecycle against real child processes. The window closes on
/// `onExit`, so a child that dies must always produce exactly one.
enum PTYTests {
    static func runAll() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                passed += 1
            } else {
                failed += 1
                print("FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }

        /// Spin the main run loop (the PTY's read queue) until `done` or timeout.
        func waitOnMain(seconds: TimeInterval, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        // --- Child exits: onExit fires exactly once, output still delivered ---
        do {
            guard let pty = PTY(executable: "/bin/echo", args: ["echo", "hello-pty"], rows: 24, cols: 80) else {
                check("pty-spawn", false, "forkpty failed")
                print("PTY tests: \(passed) passed, \(failed) failed")
                fatalError("PTY tests failed")
            }
            var output = Data()
            var exits = 0
            pty.onOutput = { output.append($0) }
            pty.onExit = { exits += 1 }
            pty.startReading()
            waitOnMain(seconds: 5) { exits > 0 }
            // Keep pumping briefly so a duplicate callback would be observed.
            waitOnMain(seconds: 0.2) { false }
            let text = String(decoding: output, as: UTF8.self)
            check("pty-output-delivered", text.contains("hello-pty"), "got \(text.debugDescription)")
            check("pty-onexit-once", exits == 1, "fired \(exits) times")
            var status: Int32 = 0
            waitpid(pty.childPid, &status, 0)
        }

        // Small mouse/key writes queued behind a large paste must remain in
        // submission order, including when the slave applies backpressure.
        do {
            let chunks = [Data(repeating: 0x78, count: 262144)] + (0..<200).map { Data("event-\($0);".utf8) }
            let expected = chunks.reduce(into: Data()) { $0.append($1) }
            let script = """
            import os, tty
            tty.setraw(0)
            os.write(1, b'READY')
            data = b''
            while len(data) < \(expected.count):
                data += os.read(0, 65536)
            while data:
                data = data[os.write(1, data):]
            """
            guard let pty = PTY(executable: "/usr/bin/python3", args: ["python3", "-c", script], rows: 24, cols: 80) else {
                fatalError("Could not create ordered-write test PTY")
            }
            var received = Data()
            var exited = false
            pty.onOutput = { received.append($0) }
            pty.onExit = { exited = true }
            pty.startReading()
            waitOnMain(seconds: 3) { received == Data("READY".utf8) }
            received.removeAll()
            for chunk in chunks { pty.write(chunk) }
            waitOnMain(seconds: 5) { exited }
            check("pty-preserves-write-order-under-backpressure", received == expected)
            if !exited { kill(pty.childPid, SIGTERM) }
            var status: Int32 = 0
            waitpid(pty.childPid, &status, 0)
        }
        print("PTY tests: \(passed) passed, \(failed) failed")
        fflush(stdout)
        if failed > 0 { fatalError("PTY tests failed") }
    }
}
#endif
