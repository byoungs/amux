import Foundation

#if DEBUG
public enum OrderedDispatcherTests {
    /// Stand-in for the work queue and the main queue: blocks are parked until
    /// the test runs them, so "in flight" is a state the test controls.
    final class ManualQueue {
        var blocks: [() -> Void] = []
        func enqueue(_ block: @escaping () -> Void) { blocks.append(block) }
        func runNext() { if !blocks.isEmpty { blocks.removeFirst()() } }
    }

    enum Event: Equatable {
        case type(String)   // runs inline (a PTY write)
        case action(String) // runs off main (a tmux action)
    }

    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        /// Builds a dispatcher whose plan records into `log`. Inline work logs
        /// immediately; off-main work logs when the work queue runs it.
        func make(log: Log, work: ManualQueue, main: ManualQueue,
                  planned: Log? = nil) -> OrderedDispatcher<Event> {
            OrderedDispatcher<Event>(
                plan: { event in
                    planned?.items.append("\(event)")
                    switch event {
                    case .type(let s): return .inline { log.items.append("type \(s)") }
                    case .action(let s): return .offMain { log.items.append("action \(s)") }
                    }
                },
                runOffMain: work.enqueue,
                returnToMain: main.enqueue)
        }

        // Idle: inline events run immediately, in order.
        do {
            let log = Log(), work = ManualQueue(), main = ManualQueue()
            let d = make(log: log, work: work, main: main)
            d.submit(.type("a"))
            d.submit(.type("b"))
            check("idle-inlineRunsNow", log.items == ["type a", "type b"], "\(log.items)")
            check("idle-notBusy", !d.isBusy)
        }

        // Typing after an action waits for the action, then lands after it.
        // This is the Cmd-N-then-type case: the text must reach the new pane.
        do {
            let log = Log(), work = ManualQueue(), main = ManualQueue()
            let d = make(log: log, work: work, main: main)
            d.submit(.action("newPane"))
            d.submit(.type("claude"))
            check("inFlight-typingHeld", log.items.isEmpty, "\(log.items)")
            check("inFlight-busy", d.isBusy)
            work.runNext() // action runs on the work queue
            check("inFlight-stillHeldUntilMainHop", log.items == ["action newPane"], "\(log.items)")
            main.runNext() // completion hops back to main, drains
            check("inFlight-typingAfterAction",
                  log.items == ["action newPane", "type claude"], "\(log.items)")
            check("inFlight-idleAfterDrain", !d.isBusy)
        }

        // Actions never overlap: the second starts only after the first
        // finished and returned to main.
        do {
            let log = Log(), work = ManualQueue(), main = ManualQueue()
            let d = make(log: log, work: work, main: main)
            d.submit(.action("1"))
            d.submit(.action("2"))
            check("serial-oneQueued", work.blocks.count == 1, "queued \(work.blocks.count)")
            work.runNext(); main.runNext()
            check("serial-secondQueuedAfterFirst", work.blocks.count == 1)
            work.runNext(); main.runNext()
            check("serial-order", log.items == ["action 1", "action 2"], "\(log.items)")
        }

        // A held event is planned when it runs, not when it arrived, so it
        // sees state the preceding action changed (e.g. split-pick mode).
        do {
            let log = Log(), planned = Log(), work = ManualQueue(), main = ManualQueue()
            let d = make(log: log, work: work, main: main, planned: planned)
            d.submit(.action("splitStart"))
            d.submit(.type("2"))
            check("lazyPlan-notPlannedWhileHeld", planned.items.count == 1, "\(planned.items)")
            work.runNext(); main.runNext()
            check("lazyPlan-plannedAfter", planned.items.count == 2, "\(planned.items)")
        }

        print("OrderedDispatcher tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("OrderedDispatcher tests failed") }
    }

    final class Log { var items: [String] = [] }
}
#endif
