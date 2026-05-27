#if DEBUG
import Foundation
import AmuxLib

// Tests the imperative shell (PermissionWatcher) against FakeTmux: the
// answer/reject/poll paths that drive real tmux. Covers the optimistic-advance
// re-append race and the engage-on-already-zoomed-session case.
enum PermissionWatcherTests {
    // A minimal but real-shaped prompt: selection glyph + footer so the detector
    // fires; "No" reject option last.
    private static let promptText = """
     Bash command

       echo hello

     Do you want to proceed?
     ❯ 1. Yes
       2. No

     Esc to cancel · Tab to amend
    """

    static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let saved = Tmux.executor
        defer { Tmux.executor = saved }

        // --- Answer in place, then re-poll: the just-answered prompt must NOT
        // re-queue (optimistic-advance race), and the digit reaches the pane. ---
        do {
            let fake = FakeTmux()
            fake.addSession("watch", panes: 1)
            fake.setPaneContent("watch", index: 0, content: promptText)
            Tmux.executor = fake
            Tmux.markAsManaged("watch")

            var clock: TimeInterval = 100
            let w = PermissionWatcher(now: { clock }, attachedSession: { nil })
            w.pollSync()
            check("answer-detected", w.queue.count == 1, "\(w.queue.count)")

            w.answerCurrent(optionNumber: 1)
            check("answer-sent-digit", fake.pane("watch", index: 0)?.sentKeys == ["1"],
                  "\(fake.pane("watch", index: 0)?.sentKeys ?? [])")
            check("answer-advanced", w.queue.count == 0)

            // Stale capture before Claude redrew (same content, +2s): no re-queue.
            clock = 102
            w.pollSync()
            check("answer-no-requeue", w.queue.count == 0, "\(w.queue.count)")
        }

        // --- Engage reject: switch to the session, focus the target pane, send
        // the reject digit there, advance. (FakeTmux models zoom as a bare
        // window flag, so it can't reproduce real tmux's select-pane
        // auto-unzoom; the zoom-pane visual correctness is a real-tmux concern
        // verified separately. This asserts the path issues the right calls.) ---
        do {
            let fake = FakeTmux()
            fake.addSession("eng", panes: 2)
            fake.setPaneContent("eng", index: 1, content: promptText)
            fake.setZoomed("eng", true)                 // zoomed on pane 0
            Tmux.executor = fake
            Tmux.markAsManaged("eng")

            let w = PermissionWatcher(now: { 0 }, attachedSession: { nil })
            w.pollSync()
            check("engage-detected", w.queue.current?.pane == 1, "\(w.queue.current?.pane ?? -1)")

            w.engageReject(optionNumber: 2)             // "No" is option 2
            let win = fake.sessions["eng"]?.windows.first
            check("engage-switched-client", fake.clientSession == "eng", fake.clientSession ?? "nil")
            check("engage-target-active", win?.activePaneIndex == 1, "\(win?.activePaneIndex ?? -1)")
            check("engage-zoomed", win?.zoomed == true)
            check("engage-sent-digit", fake.pane("eng", index: 1)?.sentKeys == ["2"],
                  "\(fake.pane("eng", index: 1)?.sentKeys ?? [])")
            check("engage-advanced", w.queue.count == 0)
        }

        // --- Focused pane is excluded from the queue. ---
        do {
            let fake = FakeTmux()
            fake.addSession("foc", panes: 1)
            fake.setPaneContent("foc", index: 0, content: promptText)
            Tmux.executor = fake
            Tmux.markAsManaged("foc")

            let w = PermissionWatcher(now: { 0 }, attachedSession: { ("foc", 0) })
            w.pollSync()
            check("focused-pane-excluded", w.queue.count == 0, "\(w.queue.count)")
        }

        print("PermissionWatcher tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("PermissionWatcher tests failed") }
    }
}
#endif
