/// Bell routing: a BEL must alert the pane that rang, even after panes move.
///
/// Each pane's bell watcher is a long-lived `pipe-pane` process. It used to be
/// told its session and pane index once, at setup. Closing a pane shifts every
/// later pane's index down, so the watcher kept alerting an index that now
/// belonged to a different pane — or to no pane at all.

import Foundation
import AmuxLib

enum BellRoutingTests {
    private static func alertFlag(_ session: String, _ index: Int) -> String {
        tmux("show-options", "-p", "-t", "\(session):0.\(index)", "-v", "@amux-alert")
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return cond()
    }

    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // Close pane 1 of 3; the old pane 2 (now index 1) rings.
        do {
            let ts = TestSession(paneCount: 3)
            for i in 0..<3 { ts.useCleanShell(paneIndex: i) }
            // respawn-pane replaced the processes; re-attach watchers the way
            // startup does.
            try? Tmux.setupAllBellWatches(ts.name)
            Thread.sleep(forTimeInterval: 0.3)

            tmux("kill-pane", "-t", "\(ts.name):0.1")
            tmux("send-keys", "-t", "\(ts.name):0.1", "printf '\\a'", "Enter")

            let alerted = waitFor(3) { alertFlag(ts.name, 1) == "1" }
            check("bellAfterClose-alertsRingingPane", alerted,
                  "pane 1 @amux-alert=\(alertFlag(ts.name, 1))")
            check("bellAfterClose-otherPaneQuiet", alertFlag(ts.name, 0) != "1",
                  "pane 0 @amux-alert=\(alertFlag(ts.name, 0))")
        }

        print("BellRoutingTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
