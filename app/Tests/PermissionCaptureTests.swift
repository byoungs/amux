/// Integration tests for permission-prompt capture + send-keys against REAL
/// tmux. Renders a committed fixture into a pane, captures it back through
/// `Tmux.capturePane`, and runs the pure detector — proving the parser works
/// on real tmux-rendered text, not just embedded literals.

import Foundation
import AmuxLib

enum PermissionCaptureTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("  FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")

        let session = TestSession(paneCount: 1)
        // Render under a clean, rc-free shell so a slow .zshrc can't swallow the
        // typed command before it runs (see TestSession.useCleanShell).
        session.useCleanShell()

        /// Render a committed fixture into pane 0 via the shell, then capture it
        /// back through real tmux. Returns the captured screen text (or "" if the
        /// fixture is missing / the prompt never rendered).
        func render(_ fixtureName: String) -> String {
            let fixture = fixturesDir.appendingPathComponent(fixtureName).path
            guard FileManager.default.fileExists(atPath: fixture) else {
                check("fixture-present-\(fixtureName)", false, "missing \(fixture)")
                return ""
            }
            try? Tmux.sendKeys(session.name, paneIndex: 0, keys: ["-l", "clear; cat '\(fixture)'"])
            try? Tmux.sendKeys(session.name, paneIndex: 0, keys: ["Enter"])
            var captured = ""
            for _ in 0..<50 {
                captured = Tmux.capturePane(session.name, paneIndex: 0, lines: 60)
                if captured.contains("Do you want to proceed?") { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return captured
        }

        // 3-option Bash prompt (single-column layout).
        let threeOpt = render("permission-bash-3opt.txt")
        check("3opt-capture-contains-prompt", threeOpt.contains("Do you want to proceed?"),
              "captured:\n\(threeOpt)")
        if let p = detectPermissionPrompt(threeOpt) {
            check("3opt-real-3-options", p.options.count == 3, "\(p.options.count)")
            check("3opt-real-reject-no", p.rejectOption?.label == "No", p.rejectOption?.label ?? "nil")
        } else {
            check("3opt-real-detects", false, "detector returned nil on real capture")
        }

        // Narrow-pane prompt: option 2's long "don't ask again for" pattern wraps
        // into a right-hand column across multiple rows (real 64-col capture). The
        // detector must still find all 3 options and identify "No" as the reject.
        let narrow = render("permission-bash-narrow.txt")
        check("narrow-capture-contains-prompt", narrow.contains("Do you want to proceed?"),
              "captured:\n\(narrow)")
        if let p = detectPermissionPrompt(narrow) {
            check("narrow-real-3-options", p.options.count == 3, "\(p.options.count)")
            check("narrow-real-opt2-yes", p.options.count > 1 && p.options[1].label.hasPrefix("Yes"),
                  p.options.count > 1 ? p.options[1].label : "nil")
            check("narrow-real-reject-no", p.rejectOption?.label == "No", p.rejectOption?.label ?? "nil")
            check("narrow-real-details-command",
                  p.details.contains(where: { $0.contains("longbinary") }),
                  p.details.joined(separator: " | "))
        } else {
            check("narrow-real-detects", false, "detector returned nil on real narrow capture")
        }

        // send-keys round-trip: a literal token reaches the pane via real tmux.
        try? Tmux.sendKeys(session.name, paneIndex: 0, keys: ["Enter"])
        try? Tmux.sendKeys(session.name, paneIndex: 0, keys: ["-l", "echo PEEK_MARKER_123"])
        try? Tmux.sendKeys(session.name, paneIndex: 0, keys: ["Enter"])
        var echoed = ""
        for _ in 0..<50 {
            echoed = Tmux.capturePane(session.name, paneIndex: 0, lines: 30)
            if echoed.contains("PEEK_MARKER_123") { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        check("send-keys-roundtrip", echoed.contains("PEEK_MARKER_123"))

        print("PermissionCapture tests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
