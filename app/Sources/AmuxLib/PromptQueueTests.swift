#if DEBUG
import Foundation

public enum PromptQueueTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let pA = PermissionPrompt(question: "A?", options: [PromptOption(number: 1, label: "Yes", selected: true)])
        let pB = PermissionPrompt(question: "B?", options: [PromptOption(number: 1, label: "Yes", selected: true)])

        var q = PromptQueue(suppressWindow: 8.0)
        // Detection on two panes → FIFO by first-seen order.
        q.update(detections: [QueuedPrompt(session: "s", pane: 0, prompt: pA),
                              QueuedPrompt(session: "s", pane: 1, prompt: pB)], now: 0)
        check("count2", q.count == 2)
        check("currentA", q.current?.prompt.question == "A?")

        // Re-detecting (reordered) must not duplicate or reorder.
        q.update(detections: [QueuedPrompt(session: "s", pane: 1, prompt: pB),
                              QueuedPrompt(session: "s", pane: 0, prompt: pA)], now: 1)
        check("still2", q.count == 2)
        check("stillA", q.current?.prompt.question == "A?")

        // advance() drops the head.
        q.advance(now: 1)
        check("count1", q.count == 1)
        check("currentB", q.current?.prompt.question == "B?")

        // A prompt that vanishes from detections is dropped.
        q.update(detections: [], now: 2)
        check("count0", q.count == 0)
        check("currentNil", q.current == nil)

        // dismissAll clears everything.
        q.update(detections: [QueuedPrompt(session: "s", pane: 0, prompt: pA)], now: 3)
        q.dismissAll()
        check("dismissed", q.count == 0)

        // --- Optimistic-advance race: answering a prompt then re-detecting the
        // identical not-yet-redrawn prompt in the same pane must NOT re-queue it,
        // until the suppress window expires. A *different* prompt is not suppressed.
        var r = PromptQueue(suppressWindow: 8.0)
        let det = [QueuedPrompt(session: "s", pane: 0, prompt: pA)]
        r.update(detections: det, now: 100)
        r.advance(now: 100)                                   // answered at t=100
        check("race-advanced", r.count == 0)
        r.update(detections: det, now: 102)                   // stale capture, +2s
        check("race-suppressed", r.count == 0, "\(r.count)")
        // A different prompt in the same pane is still surfaced.
        r.update(detections: [QueuedPrompt(session: "s", pane: 0, prompt: pB)], now: 103)
        check("race-different-prompt", r.current?.prompt.question == "B?")
        // After the window, the same prompt is allowed back (e.g. answer didn't take).
        var r2 = PromptQueue(suppressWindow: 8.0)
        r2.update(detections: det, now: 0)
        r2.advance(now: 0)
        r2.update(detections: det, now: 9)                    // window expired
        check("race-window-expires", r2.current?.prompt.question == "A?")

        print("PromptQueue tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("PromptQueue tests failed") }
    }
}
#endif
