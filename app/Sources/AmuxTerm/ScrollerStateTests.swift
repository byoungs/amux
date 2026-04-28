#if DEBUG
import Foundation

enum ScrollerStateTests {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                passed += 1
            } else {
                failed += 1
                FileHandle.standardError.write("FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")\n".data(using: .utf8)!)
            }
        }

        // Alt-screen → scrollbar hidden
        do {
            let r = ScrollerState.compute(
                isAltScreen: true,
                visibleRows: 30,
                tmuxState: (historySize: 1000, scrollPosition: 0))
            check("alt-screen-hidden", r.hidden)
        }

        // Tmux query failed → neutral pinned-bottom indicator
        do {
            let r = ScrollerState.compute(
                isAltScreen: false,
                visibleRows: 30,
                tmuxState: nil)
            check("tmux-fail-not-hidden", !r.hidden)
            check("tmux-fail-knob-full", r.knobProportion == 1.0)
            check("tmux-fail-value-bottom", r.doubleValue == 1.0)
        }

        // No history yet → thumb at bottom, full knob
        do {
            let r = ScrollerState.compute(
                isAltScreen: false,
                visibleRows: 30,
                tmuxState: (historySize: 0, scrollPosition: nil))
            check("zero-history-knob-full", r.knobProportion == 1.0)
            check("zero-history-value-bottom", r.doubleValue == 1.0)
        }

        // Live tail: history present, not in copy-mode → thumb at bottom
        do {
            let r = ScrollerState.compute(
                isAltScreen: false,
                visibleRows: 30,
                tmuxState: (historySize: 970, scrollPosition: nil))
            check("live-tail-value-bottom", r.doubleValue == 1.0)
            // visible / (visible + history) = 30 / 1000 = 0.03
            check("live-tail-knob-proportional",
                  abs(r.knobProportion - 0.03) < 0.001,
                  "got \(r.knobProportion)")
        }

        // Copy-mode at top: scrollPosition == historySize → value 0
        do {
            let r = ScrollerState.compute(
                isAltScreen: false,
                visibleRows: 30,
                tmuxState: (historySize: 1000, scrollPosition: 1000))
            check("copy-top-value-zero", r.doubleValue == 0.0)
        }

        // Copy-mode middle: half-way back
        do {
            let r = ScrollerState.compute(
                isAltScreen: false,
                visibleRows: 30,
                tmuxState: (historySize: 1000, scrollPosition: 500))
            check("copy-middle-value-half",
                  abs(r.doubleValue - 0.5) < 0.001,
                  "got \(r.doubleValue)")
        }

        // Knob has 2% floor for huge histories so it stays clickable
        do {
            let r = ScrollerState.compute(
                isAltScreen: false,
                visibleRows: 30,
                tmuxState: (historySize: 100_000, scrollPosition: nil))
            check("knob-floor-2pct", r.knobProportion >= 0.02,
                  "got \(r.knobProportion)")
        }

        // Knob never exceeds 1.0
        do {
            let r = ScrollerState.compute(
                isAltScreen: false,
                visibleRows: 100,
                tmuxState: (historySize: 0, scrollPosition: nil))
            check("knob-cap-1", r.knobProportion <= 1.0)
        }

        print("ScrollerState tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("ScrollerState tests failed") }
    }
}
#endif
