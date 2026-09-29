// OrderedDispatcher.swift -- Keep tmux round-trips off the main thread
// without reordering what the user typed.
//
// An amux action (Cmd-1..9, Cmd-N, ...) is a handful of tmux subprocesses.
// Run on the main thread, every one of them freezes drawing and input; on a
// loaded machine that is hundreds of milliseconds per keypress. Run on a
// background queue naively, keystrokes typed right after the action reach the
// PTY first — Cmd-N then `claude` would land in the old pane.
//
// So actions run off main one at a time, and every event that arrives while
// one is in flight is held and replayed in arrival order once it finishes.
// Events are planned when they run, not when they arrive, so a held key sees
// the state the action before it left behind (e.g. split-pick mode).

import Foundation

/// How to carry out one event.
public enum DispatchStep {
    /// Run now, on the submitting (main) thread. For cheap work: PTY writes,
    /// UI toggles.
    case inline(() -> Void)
    /// Run on the work queue. Later events wait until it completes.
    case offMain(() -> Void)
}

/// Serializes events so off-main work and inline work interleave in exactly
/// the order they were submitted. Not thread-safe by design: `submit` and the
/// `returnToMain` hop must both run on the main thread.
public final class OrderedDispatcher<Event> {
    private let plan: (Event) -> DispatchStep
    private let runOffMain: (@escaping () -> Void) -> Void
    private let returnToMain: (@escaping () -> Void) -> Void
    private var pending: [Event] = []
    private var busy = false

    /// - Parameters:
    ///   - plan: decides how to run an event; called on main, at run time.
    ///   - runOffMain: schedules a block on the (serial) work queue.
    ///   - returnToMain: schedules a block back on the main thread.
    public init(plan: @escaping (Event) -> DispatchStep,
                runOffMain: @escaping (@escaping () -> Void) -> Void,
                returnToMain: @escaping (@escaping () -> Void) -> Void) {
        self.plan = plan
        self.runOffMain = runOffMain
        self.returnToMain = returnToMain
    }

    /// True while an off-main step is running; events submitted now are held.
    public var isBusy: Bool { busy }

    public func submit(_ event: Event) {
        pending.append(event)
        drain()
    }

    private func drain() {
        while !busy, !pending.isEmpty {
            let event = pending.removeFirst()
            switch plan(event) {
            case .inline(let work):
                work()
            case .offMain(let work):
                busy = true
                runOffMain { [self] in
                    work()
                    returnToMain {
                        self.busy = false
                        self.drain()
                    }
                }
            }
        }
    }
}
