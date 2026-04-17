/// Session resolution priority: --session flag > AMUX_SESSION env var.
///
/// Ported from tests/session_resolution_test.rs.

import Foundation

enum SessionResolutionTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // cli_session_flag_is_passed_to_subcommand
        do {
            let ts = TestSession(paneCount: 3)

            // Run amux with --session flag pointing to the real session,
            // but AMUX_SESSION env set to a wrong name. The flag should win.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: amuxBin())
            process.arguments = ["--session", ts.name, "zoom-in"]

            var env = ProcessInfo.processInfo.environment
            env["AMUX_SESSION"] = "wrong-session-name"
            process.environment = env

            let stderrPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                failed += 1
                print("FAIL: sessionFlagPriority — failed to launch: \(error)")
                print("SessionResolutionTests: \(passed) passed, \(failed) failed")
                return (passed, failed)
            }

            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            check("sessionFlagPriority-succeeds", process.terminationStatus == 0,
                  "zoom-in with --session flag should succeed: \(stderr)")
            check("sessionFlagPriority-zoomed", isZoomed(ts.name),
                  "--session flag should target the correct session")
        }

        print("SessionResolutionTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
