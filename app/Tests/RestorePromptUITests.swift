/// The restore prompt, driven as a user drives it.
///
/// These run the real `amux-cli prompt restore` inside a real tmux pane on the
/// isolated test server, read what it painted with capture-pane, press keys,
/// and assert the state tmux and the prefs file are left in. Nothing here is
/// a stand-in for the UI: it is the UI, minus the popup frame tmux draws
/// around it.
///
/// Two seams make it possible: $AMUX_HOME moves every amux state file into a
/// scratch dir, and amux-cli talks to the tmux server named in $TMUX (the
/// pane's own), so a test can never touch the developer's live amux.

import Foundation
import AmuxLib

enum RestorePromptUITests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition {
                passed += 1
            } else {
                failed += 1
                print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")")
            }
        }

        // 1. What the prompt paints: counts, the panes coming back, and the
        //    topic-match warning that stops a wrong resume before it happens.
        do {
            let h = PromptHarness(snapshot: PromptHarness.snapshot(
                spaceName: "restore-a-\(ProcessInfo.processInfo.processIdentifier)",
                cleanExit: true,
                panes: [
                    (cwd: "/usr", title: "scroll reflow",
                     kind: .claude(sessionID: "11111111-2222-3333-4444-555555555555",
                                   confidence: .resumeArg)),
                    (cwd: "/usr/lib", title: "mystery",
                     kind: .claude(sessionID: "99999999-8888-7777-6666-555555555555",
                                   confidence: .topicMatch)),
                ]))
            defer { h.cleanUp() }

            let screen = h.start()
            check("prompt-appears", screen.contains("Restore your last session?"), screen)
            check("prompt-counts", screen.contains("Restore 2 panes across 1 space"), screen)
            check("prompt-lists-panes",
                  screen.contains("scroll reflow") && screen.contains("mystery"), screen)
            check("prompt-flags-topic-match", screen.contains("topic match"), screen)
            check("prompt-no-crash-note-when-clean", !screen.lowercased().contains("crash"), screen)
            check("prompt-options",
                  screen.contains("Start fresh") && screen.contains("Don't ask again"), screen)
        }

        // 2. A snapshot from a run that died says so — that is the signal the
        //    contents may be slightly behind what was on screen.
        do {
            let h = PromptHarness(snapshot: PromptHarness.snapshot(
                spaceName: "restore-b-\(ProcessInfo.processInfo.processIdentifier)",
                cleanExit: false,
                panes: [(cwd: "/usr", title: "one", kind: .shell)]))
            defer { h.cleanUp() }

            let screen = h.start()
            check("prompt-crash-note", screen.lowercased().contains("crash"), screen)
        }

        // 3. Choosing Restore actually rebuilds the space, at the saved cwds,
        //    and consumes the snapshot so a relaunch does not re-offer it.
        do {
            let space = "restore-c-\(ProcessInfo.processInfo.processIdentifier)"
            let h = PromptHarness(snapshot: PromptHarness.snapshot(
                spaceName: space, cleanExit: true,
                panes: [(cwd: "/usr", title: "one", kind: .shell),
                        (cwd: "/usr/lib", title: "two", kind: .shell),
                        (cwd: "/usr/share", title: "three", kind: .shell)]))
            defer { h.cleanUp(alsoKill: [space]) }

            _ = h.start()
            h.press("Enter")
            let restored = h.waitFor { (try? Tmux.paneCount(space)) ?? 0 == 3 }
            check("restore-creates-panes", restored,
                  "panes=\((try? Tmux.paneCount(space)) ?? -1)")
            var cwds: [String] = []
            // pane_current_path is empty until the pane's shell is exec'd.
            _ = h.waitFor {
                cwds = (0..<3).map { (try? Tmux.paneCwd(space, paneIndex: $0)) ?? "" }
                return !cwds.contains("")
            }
            check("restore-cwds-in-order", cwds == ["/usr", "/usr/lib", "/usr/share"],
                  cwds.joined(separator: ","))
            check("restore-consumes-snapshot",
                  h.waitFor { h.prefs().consumedCapturedAt == PromptHarness.capturedAt },
                  String(describing: h.prefs()))
        }

        // 4. Start fresh restores nothing but still consumes the snapshot, so
        //    the next launch does not ask about the same one again.
        do {
            let space = "restore-d-\(ProcessInfo.processInfo.processIdentifier)"
            let h = PromptHarness(snapshot: PromptHarness.snapshot(
                spaceName: space, cleanExit: true,
                panes: [(cwd: "/usr", title: "one", kind: .shell)]))
            defer { h.cleanUp(alsoKill: [space]) }

            _ = h.start()
            h.press("2")
            h.press("Enter")
            check("fresh-consumes-snapshot",
                  h.waitFor { h.prefs().consumedCapturedAt == PromptHarness.capturedAt },
                  String(describing: h.prefs()))
            check("fresh-restores-nothing", !Tmux.sessionExists(space))
            check("fresh-leaves-dont-ask-unset", h.prefs().dontAsk == false)
        }

        // 5. Don't ask again is sticky: the gate must refuse the same snapshot
        //    for good, not just this once.
        do {
            let space = "restore-e-\(ProcessInfo.processInfo.processIdentifier)"
            let snapshot = PromptHarness.snapshot(
                spaceName: space, cleanExit: true,
                panes: [(cwd: "/usr", title: "one", kind: .shell)])
            let h = PromptHarness(snapshot: snapshot)
            defer { h.cleanUp(alsoKill: [space]) }

            _ = h.start()
            h.press("3")
            h.press("Enter")
            check("dont-ask-persisted", h.waitFor { h.prefs().dontAsk }, String(describing: h.prefs()))
            check("dont-ask-closes-gate",
                  !SessionRestore.shouldOfferRestore(hadExistingSessions: false,
                                                     snapshot: snapshot, prefs: h.prefs()))
            check("dont-ask-restores-nothing", !Tmux.sessionExists(space))
        }

        // 6. Esc is the same as choosing Start fresh — nothing restored, and
        //    the snapshot consumed so it stops nagging.
        do {
            let space = "restore-f-\(ProcessInfo.processInfo.processIdentifier)"
            let h = PromptHarness(snapshot: PromptHarness.snapshot(
                spaceName: space, cleanExit: true,
                panes: [(cwd: "/usr", title: "one", kind: .shell)]))
            defer { h.cleanUp(alsoKill: [space]) }

            _ = h.start()
            h.press("Escape")
            check("esc-consumes-snapshot",
                  h.waitFor { h.prefs().consumedCapturedAt == PromptHarness.capturedAt },
                  String(describing: h.prefs()))
            check("esc-restores-nothing", !Tmux.sessionExists(space))
        }

        print("RestorePromptUI tests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
