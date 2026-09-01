#if DEBUG
import Foundation

/// Restore planning + prompt gating. The ordering rules here are the ones
/// that failed live: splitting without re-tiling ("no space for a new pane")
/// and detached splits leaving focus in the wrong pane.
public enum RestorePlanTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let uuid = "11111111-2222-3333-4444-555555555555"
        func snapshot(spaces: [SpaceSnapshot], backlog: [String] = [],
                      capturedAt: Double = 1_000, cleanExit: Bool = true) -> SessionSnapshot {
            SessionSnapshot(capturedAt: capturedAt, cleanExit: cleanExit,
                            spaces: spaces, backlog: backlog)
        }
        let work = SpaceSnapshot(name: "amux", panes: [
            PaneSnapshot(index: 0, cwd: "/src/amux", title: "amux",
                         kind: .claude(sessionID: uuid, confidence: .resumeArg)),
            PaneSnapshot(index: 1, cwd: "/src/amux", title: "shell", kind: .shell),
            PaneSnapshot(index: 2, cwd: "/src/other", title: "wtr", kind: .command("wtr")),
        ], selectedPane: 2)

        // 1. Gating: only when nothing survived, something was saved, and the
        //    user has neither opted out nor already consumed this snapshot.
        let prefs = RestorePrefs()
        let snap = snapshot(spaces: [work])
        check("gate-offer", SessionRestore.shouldOfferRestore(
            hadExistingSessions: false, snapshot: snap, prefs: prefs))
        check("gate-live-sessions", !SessionRestore.shouldOfferRestore(
            hadExistingSessions: true, snapshot: snap, prefs: prefs))
        check("gate-no-snapshot", !SessionRestore.shouldOfferRestore(
            hadExistingSessions: false, snapshot: nil, prefs: prefs))
        check("gate-empty-snapshot", !SessionRestore.shouldOfferRestore(
            hadExistingSessions: false, snapshot: snapshot(spaces: []), prefs: prefs))
        check("gate-dont-ask", !SessionRestore.shouldOfferRestore(
            hadExistingSessions: false, snapshot: snap,
            prefs: RestorePrefs(dontAsk: true)))
        check("gate-already-consumed", !SessionRestore.shouldOfferRestore(
            hadExistingSessions: false, snapshot: snap,
            prefs: RestorePrefs(consumedCapturedAt: 1_000)))

        // 2. Every split is preceded by a re-tile, or tmux refuses the split
        //    once halving leaves the target pane too short.
        let plan = SessionRestore.planRestore(snapshot: snap, existing: [:], now: 42)
        var splitsSeen = 0
        for (i, cmd) in plan.commands.enumerated() where cmd.first == "split-window" {
            splitsSeen += 1
            let previous = i > 0 ? plan.commands[i - 1] : []
            check("retile-before-split-\(splitsSeen)",
                  previous.first == "select-layout" && previous.last == "tiled",
                  previous.joined(separator: " "))
        }
        check("split-count", splitsSeen == 2, "\(splitsSeen)")
        // Each split targets the pane created just before it, so panes land in
        // saved order (tmux inserts the new pane right after the target).
        check("split-targets-previous-pane",
              plan.commands.filter { $0.first == "split-window" }.map { $0[2] }
                == ["amux:0.0", "amux:0.1"],
              plan.commands.filter { $0.first == "split-window" }.map { $0[2] }.joined(separator: ","))
        check("pane-count", plan.restoredPaneCount == 3, "\(plan.restoredPaneCount)")

        // 3. Focus is restored last, on the pane that was active.
        check("select-pane-last",
              plan.commands.last == ["select-pane", "-t", "amux:0.2"],
              plan.commands.last?.joined(separator: " ") ?? "nil")

        // 4. Launch commands: resume by id, run saved commands, leave shells alone.
        check("launch-claude",
              SessionRestore.launchCommand(for: work.panes[0]) == "claude --resume \(uuid)")
        check("launch-shell", SessionRestore.launchCommand(for: work.panes[1]) == nil)
        check("launch-command", SessionRestore.launchCommand(for: work.panes[2]) == "wtr")

        // 5. A Claude pane whose id never resolved must not resume anything —
        //    it gets a shell and a hint instead.
        let unresolved = PaneSnapshot(index: 0, cwd: "/src/amux", title: "mystery",
                                      kind: .claude(sessionID: nil, confidence: .none))
        let hint = SessionRestore.launchCommand(for: unresolved) ?? ""
        check("no-id-no-resume", hint.hasPrefix("echo ") && !hint.hasPrefix("claude --resume"), hint)
        check("no-id-names-topic", hint.contains("mystery"), hint)

        // 6. Spaces that already exist are skipped, not clobbered.
        let skipPlan = SessionRestore.planRestore(snapshot: snap, existing: ["amux": 4], now: 42)
        check("skip-existing", skipPlan.skippedSpaces == ["amux"] && skipPlan.isEmpty,
              "\(skipPlan.skippedSpaces) \(skipPlan.commands.count)")

        // 6b. The space the app just created and is attached to is adopted, not
        //     skipped — it cannot be recreated without dropping our client.
        let adopt = SessionRestore.planRestore(snapshot: snap, existing: ["amux": 1],
                                               now: 42, adoptSession: "amux")
        check("adopt-not-skipped", adopt.skippedSpaces.isEmpty && adopt.restoredPaneCount == 3,
              "\(adopt.skippedSpaces) \(adopt.restoredPaneCount)")
        check("adopt-cds-first-pane",
              adopt.commands.first == ["send-keys", "-t", "amux:0.0",
                                       "cd '/src/amux' && clear", "Enter"],
              adopt.commands.first?.joined(separator: " ") ?? "nil")
        check("adopt-only-when-untouched",
              SessionRestore.planRestore(snapshot: snap, existing: ["amux": 3],
                                         now: 42, adoptSession: "amux").skippedSpaces == ["amux"])

        // 7. Backlog spaces come back parked, not as visible spaces.
        let parked = SpaceSnapshot(name: "parked-fix", panes: [
            PaneSnapshot(index: 0, cwd: "/src/fix", title: "fix", kind: .shell),
        ], selectedPane: 0)
        let backlogPlan = SessionRestore.planRestore(
            snapshot: snapshot(spaces: [parked], backlog: ["parked-fix"]),
            existing: [:], now: 42)
        check("backlog-state",
              backlogPlan.commands.contains(["set-option", "-t", "parked-fix",
                                             "@amux-state", "background"]),
              backlogPlan.commands.map { $0.joined(separator: " ") }.joined(separator: " | "))
        check("backlog-parked-at",
              backlogPlan.commands.contains(["set-option", "-t", "parked-fix",
                                             "@amux-parked-at", "42"]))
        // parkedFrom is never left empty: tmux trims a trailing empty field
        // out of the backlog listing, which would hide the session entirely.
        check("backlog-parked-from-defaulted",
              backlogPlan.commands.contains(["set-option", "-t", "parked-fix",
                                             "@amux-parked-from", "parked-fix"]))
        let fromKnown = SessionRestore.planRestore(
            snapshot: snapshot(spaces: [SpaceSnapshot(name: "parked-fix", panes: parked.panes,
                                                      selectedPane: 0, parkedFrom: "amux")],
                               backlog: ["parked-fix"]),
            existing: [:], now: 42)
        check("backlog-parked-from-saved",
              fromKnown.commands.contains(["set-option", "-t", "parked-fix",
                                           "@amux-parked-from", "amux"]))

        // 8. The plan actually produces the panes when run through tmux.
        let saved = Tmux.executor
        let fake = FakeTmux()
        Tmux.executor = fake
        SessionRestore.execute(plan)
        let panes = (try? Tmux.listPanes("amux")) ?? []
        check("fake-pane-count", panes.count == 3, "\(panes.count)")
        check("fake-titles", panes.map(\.title) == ["amux", "shell", "wtr"],
              panes.map(\.title).joined(separator: ","))
        check("fake-active", panes.first(where: \.active)?.index == 2,
              String(describing: panes.first(where: \.active)?.index))
        Tmux.executor = saved

        print("RestorePlan tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("RestorePlan tests failed") }
    }
}
#endif
