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

        print("PTY tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("PTY tests failed") }
    }
}
#endif
