/// Hook latency: amux's tmux hooks must not stall the command that fired them.
///
/// tmux runs a hook's `run-shell` in the caller's command queue and does not
/// finish it until every process holding the job's stdin has closed it. When
/// the after-select-pane hook left a forked `amux-cli snapshot` holding that
/// stdin, every `select-pane` (Cmd-1..9, Cmd-[/], new pane, notification
/// click) waited out the snapshot's 0.5s coalescing sleep plus the capture
/// itself — 650ms+ per keypress. These tests time the real hooks installed by
/// Config.applyConfig against the real amux-cli.

import Foundation
import AmuxLib

enum HookLatencyTests {
    /// Generous for a loaded machine; the regression was 650ms+.
    static let budgetMs = 250.0

    private static func timeMs(_ block: () -> Void) -> Double {
        let start = Date()
        block()
        return Date().timeIntervalSince(start) * 1000
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s[s.count / 2]
    }

    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // select-pane returns promptly with the after-select-pane hook installed
        do {
            let ts = TestSession(paneCount: 3)
            var samples: [Double] = []
            for i in 1...6 {
                samples.append(timeMs {
                    tmux("select-pane", "-t", "\(ts.name):0.\(i % 3)")
                })
            }
            let m = median(samples)
            check("selectPane-hookDoesNotBlock", m < budgetMs,
                  "median select-pane \(Int(m))ms (samples \(samples.map { Int($0) }))")
        }

        // pane exit re-tiles without waiting on the snapshot either
        do {
            let ts = TestSession(paneCount: 3)
            let ms = timeMs {
                tmux("kill-pane", "-t", "\(ts.name):0.2")
            }
            check("killPane-hookDoesNotBlock", ms < budgetMs, "kill-pane took \(Int(ms))ms")
        }

        print("HookLatencyTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
