/// Ported from tests/amux_test.rs — the main integration test suite.
///
/// Covers: session creation, pane operations, config application, layout
/// management, zoom, spatial stickiness, split view, border formatting,
/// and spaces/send.

import Foundation
import AmuxLib

// MARK: - Helpers

/// List panes as "index:title" strings (matches Rust tmux_list_panes).
private func tmuxListPanes(_ session: String) -> [String] {
    let result = tmux("list-panes", "-t", session, "-F", "#{pane_index}:#{@amux-title}")
    return result.stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty }
}

/// Return (pane_left, pane_top) for each pane.
private func panePositions(_ session: String) -> [(Int, Int)] {
    let result = tmux("list-panes", "-t", session, "-F", "#{pane_left} #{pane_top}")
    return result.stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty }
        .map { line in
            let parts = line.components(separatedBy: " ")
            return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
        }
}

/// Return (pane_width, pane_height) for each pane.
private func paneSizes(_ session: String) -> [(Int, Int)] {
    let result = tmux("list-panes", "-t", session, "-F", "#{pane_width} #{pane_height}")
    return result.stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty }
        .map { line in
            let parts = line.components(separatedBy: " ")
            return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
        }
}

/// Read a tmux session-level option.
private func tmuxOption(_ session: String, _ option: String) -> String {
    let result = tmux("show-options", "-t", session, "-v", option)
    let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty { return value }
    // Fall back to global (options set with -g won't appear at session level)
    return tmux("show-options", "-gv", option).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Count windows in a session.
private func windowCount(_ session: String) -> Int {
    let result = tmux("list-windows", "-t", session, "-F", "#{window_index}")
    let lines = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if lines.isEmpty { return 0 }
    return lines.components(separatedBy: "\n").count
}

/// Get pane IDs (%N) for all panes in a session.
private func getPaneIds(_ session: String) -> [String] {
    let result = tmux("list-panes", "-t", session, "-F", "#{pane_id}")
    return result.stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty }
}

/// Create a pane via split-window (basic tmux split).
/// For proper amux grid layout, call applyLayout() after creating panes.
@discardableResult
private func createPane(_ session: String) -> ProcessResult {
    tmux("split-window", "-t", session, "-d")
}

/// Apply layout via amux CLI.
@discardableResult
private func applyLayout(_ session: String) -> ProcessResult {
    amuxCmd(session: session, args: ["--session", session, "layout", session])
}

/// Apply config via amux refresh.
@discardableResult
private func applyConfig(_ session: String) -> ProcessResult {
    amuxCmd(session: session, args: ["--session", session, "refresh"])
}

/// Set a pane title.
@discardableResult
private func setTitle(_ session: String, _ pane: Int, _ title: String) -> ProcessResult {
    tmux("set-option", "-p", "-t", "\(session).\(pane)", "@amux-title", title)
}

/// Select a pane.
@discardableResult
private func selectPane(_ session: String, _ pane: Int) -> ProcessResult {
    tmux("select-pane", "-t", "\(session).\(pane)")
}

/// Toggle zoom.
@discardableResult
private func toggleZoom(_ session: String) -> ProcessResult {
    tmux("resize-pane", "-t", session, "-Z")
}

/// Kill a specific pane by index.
@discardableResult
private func killPane(_ session: String, _ pane: Int) -> ProcessResult {
    tmux("kill-pane", "-t", "\(session).\(pane)")
}

/// Resize a pane to specific dimensions.
@discardableResult
private func resizePane(_ session: String, _ pane: Int, cols: Int, rows: Int) -> ProcessResult {
    tmux("resize-pane", "-t", "\(session).\(pane)", "-x", String(cols), "-y", String(rows))
}

/// Enter split view: set AMUX_SPLIT_FIRST then call split-pick.
private func enterSplit(_ session: String, _ paneA: Int, _ paneB: Int) {
    tmux("set-environment", "-t", session, "AMUX_SPLIT_FIRST", String(paneA))
    amuxCmd(session: session, args: ["--session", session, "split-pick", String(paneB)])
}

/// Exit split view.
private func exitSplit(_ session: String) {
    amuxCmd(session: session, args: ["--session", session, "split-exit"])
}

/// Send the active pane from one session to another (mirrors Rust send_pane_to_session).
private func sendPaneToSession(_ fromSession: String, _ toSession: String) {
    let result = tmux("display-message", "-t", fromSession, "-p", "#{pane_id}")
    let paneId = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    tmux("join-pane", "-s", paneId, "-t", "\(toSession):0")
    applyLayout(fromSession)
    applyLayout(toSession)
}

/// Restore tiled layout (unzoom first if needed).
private func restoreTiled(_ session: String) {
    if isZoomed(session) {
        toggleZoom(session)
    }
    applyLayout(session)
}

/// Smart resize: only enlarge dimensions below the minimum.
private func smartResize(_ session: String, pane: Int, minCols: Int, minRows: Int) {
    let sizes = paneSizes(session)
    guard pane < sizes.count else { return }
    let (w, h) = sizes[pane]
    if w >= minCols, h >= minRows { return }
    let targetCols = max(w, minCols)
    let targetRows = max(h, minRows)
    resizePane(session, pane, cols: targetCols, rows: targetRows)
}

// MARK: - Tests

enum AmuxTests {
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

        // --- start_creates_session_with_one_pane ---
        do {
            let ts = TestSession(paneCount: 1)
            let panes = tmuxListPanes(ts.name)
            check("startCreatesSessionWithOnePane",
                  panes.count == 1,
                  "expected 1 pane, got \(panes.count)")
        }

        // --- config_sets_border_style ---
        do {
            let ts = TestSession(paneCount: 1)
            let borderStatus = tmuxOption(ts.name, "pane-border-status")
            check("configSetsBorderStatus",
                  borderStatus == "top",
                  "expected 'top', got '\(borderStatus)'")
            let borderStyle = tmuxOption(ts.name, "pane-active-border-style")
            check("configSetsBorderStyle",
                  borderStyle.contains("colour43"),
                  "active border should be bright teal: \(borderStyle)")
        }

        // --- config_border_format_preserves_unicode ---
        do {
            let ts = TestSession(paneCount: 1)
            let fmt = tmuxOption(ts.name, "pane-border-format")
            check("configBorderFormatPreservesLeftQuarterBlock",
                  fmt.contains("\u{258E}"),
                  "pane-border-format lost \u{258E} through tmux round-trip: \(fmt)")
            check("configBorderFormatPreservesBlackCircle",
                  fmt.contains("\u{25CF}"),
                  "pane-border-format lost \u{25CF} through tmux round-trip: \(fmt)")
        }

        // --- create_pane_increases_count ---
        do {
            let ts = TestSession(paneCount: 0)
            createPane(ts.name)
            let panes = tmuxListPanes(ts.name)
            check("createPaneIncreasesCount",
                  panes.count == 2,
                  "expected 2 panes, got \(panes.count)")
        }

        // --- pane_title_is_set ---
        do {
            let ts = TestSession(paneCount: 0)
            setTitle(ts.name, 0, "my-project")
            let panes = tmuxListPanes(ts.name)
            check("paneTitleIsSet",
                  panes[0].contains("my-project"),
                  "title should be set: \(panes)")
        }

        // --- four_panes_in_tiled_layout ---
        do {
            let ts = TestSession(paneCount: 4)
            for i in 1..<4 {
                setTitle(ts.name, i, "pane-\(i)")
            }
            let panes = tmuxListPanes(ts.name)
            check("fourPanesInTiledLayout",
                  panes.count == 4,
                  "expected 4 panes, got \(panes.count)")
        }

        // --- zoom_and_unzoom ---
        do {
            let ts = TestSession(paneCount: 0)
            createPane(ts.name)
            check("zoomAndUnzoom-notZoomedInitially",
                  !isZoomed(ts.name))
            toggleZoom(ts.name)
            check("zoomAndUnzoom-zoomedAfterToggle",
                  isZoomed(ts.name))
            toggleZoom(ts.name)
            check("zoomAndUnzoom-unzoomedAfterSecondToggle",
                  !isZoomed(ts.name))
        }

        // --- kill_pane_reduces_count ---
        do {
            let ts = TestSession(paneCount: 0)
            createPane(ts.name)
            createPane(ts.name)
            check("killPaneReducesCount-before",
                  paneCount(ts.name) == 3,
                  "expected 3 panes, got \(paneCount(ts.name))")
            killPane(ts.name, 1)
            check("killPaneReducesCount-after",
                  paneCount(ts.name) == 2,
                  "expected 2 panes, got \(paneCount(ts.name))")
        }

        // --- key_bindings_are_installed ---
        //
        // In the Swift port, Cmd-keys are dispatched by the native app via
        // KeyInput/KeyCommand (app/Sources/AmuxTerm/KeyInput.swift and
        // app/Sources/AmuxLib/KeyAction.swift). They are NOT bound in tmux
        // anymore, so inspecting `tmux list-keys` is meaningless.
        //
        // These checks verify the pure character→command mapping that
        // KeyInput delegates to. No tmux session required.
        do {
            check("keyBindingCmdEqualsMapsToZoomIn",
                  KeyCommand.amuxCommand(for: "=") == .zoomIn,
                  "Cmd-= should map to .zoomIn, got \(String(describing: KeyCommand.amuxCommand(for: "=")))")
            check("keyBindingCmdMinusMapsToZoomOut",
                  KeyCommand.amuxCommand(for: "-") == .zoomOut,
                  "Cmd-- should map to .zoomOut, got \(String(describing: KeyCommand.amuxCommand(for: "-")))")
            check("keyBindingCmdNMapsToNewPane",
                  KeyCommand.amuxCommand(for: "n") == .newPane,
                  "Cmd-N should map to .newPane, got \(String(describing: KeyCommand.amuxCommand(for: "n")))")
            // Historically a separate check verified the "amux zoom-in"
            // command string appeared in the tmux binding. In the Swift
            // port the command is dispatched end-to-end: KeyCommand maps
            // the character → AmuxCommand, then AppController turns it
            // into a layout event via Tmux.applyLayout. Preserve the
            // audit trail by testing the downstream half — an explicit
            // zoomIn layout event against a real session actually zooms
            // the window. This complements the pure-mapping check above
            // and would catch a regression like "AppController drops
            // zoomIn" or "Tmux.applyLayout misroutes the event".
            do {
                let ts = TestSession(paneCount: 2)
                try? Tmux.applyLayout(ts.name, event: .zoomIn)
                check("keyBindingZoomInCommandIsDispatched",
                      isZoomed(ts.name),
                      "zoomIn layout event should zoom the session")
            }
        }

        // === STICKY PANE INTEGRATION TESTS ===
        // End-to-end repro of sticky-pane bugs: real tmux, real Tmux.createPane,
        // real applyLayout pipeline. Independent of any user session.

        // --- sticky_3_to_4_active_full_left ---
        // 3-pane left-full + Cmd-N from full-left. Spec: TL=A, TR=B, BL=NEW, BR=C.
        do {
            let ts = TestSession(paneCount: 3)
            // 3-pane state: index 0=full-left, 1=top-right, 2=bot-right.
            let idsBefore = getPaneIds(ts.name)
            let aId = idsBefore[0]
            let bId = idsBefore[1]
            let cId = idsBefore[2]
            try? Tmux.selectPane(ts.name, paneIndex: 0)  // active = full-left
            _ = try? Tmux.createPane(ts.name)
            let idsAfter = getPaneIds(ts.name)
            check("sticky_3_to_4_full_left count", idsAfter.count == 4,
                  "expected 4 panes, got \(idsAfter.count): \(idsAfter)")
            if idsAfter.count == 4 {
                let newId = idsAfter.first { ![aId, bId, cId].contains($0) } ?? "?"
                check("sticky_3_to_4_full_left TL=A", idsAfter[0] == aId,
                      "TL should be A (\(aId)), got \(idsAfter[0]). full=\(idsAfter)")
                check("sticky_3_to_4_full_left TR=B", idsAfter[1] == bId,
                      "TR should be B (\(bId)), got \(idsAfter[1]). full=\(idsAfter)")
                check("sticky_3_to_4_full_left BL=NEW", idsAfter[2] == newId,
                      "BL should be NEW (\(newId)), got \(idsAfter[2]). full=\(idsAfter)")
                check("sticky_3_to_4_full_left BR=C", idsAfter[3] == cId,
                      "BR should be C (\(cId)), got \(idsAfter[3]). full=\(idsAfter)")
            }
        }

        // --- sticky_3_to_4_active_top_right ---
        do {
            let ts = TestSession(paneCount: 3)
            let idsBefore = getPaneIds(ts.name)
            let aId = idsBefore[0]
            let bId = idsBefore[1]
            let cId = idsBefore[2]
            try? Tmux.selectPane(ts.name, paneIndex: 1)  // active = top-right
            _ = try? Tmux.createPane(ts.name)
            let idsAfter = getPaneIds(ts.name)
            check("sticky_3_to_4_top_right count", idsAfter.count == 4)
            if idsAfter.count == 4 {
                let newId = idsAfter.first { ![aId, bId, cId].contains($0) } ?? "?"
                check("sticky_3_to_4_top_right TL=A", idsAfter[0] == aId,
                      "got \(idsAfter), expected TL=A=\(aId)")
                check("sticky_3_to_4_top_right TR=B", idsAfter[1] == bId,
                      "got \(idsAfter), expected TR=B=\(bId)")
                check("sticky_3_to_4_top_right BL=NEW", idsAfter[2] == newId,
                      "got \(idsAfter), expected BL=NEW=\(newId)")
                check("sticky_3_to_4_top_right BR=C", idsAfter[3] == cId,
                      "got \(idsAfter), expected BR=C=\(cId)")
            }
        }

        // --- sticky_3_to_4_active_bot_right ---
        do {
            let ts = TestSession(paneCount: 3)
            let idsBefore = getPaneIds(ts.name)
            let aId = idsBefore[0]
            let bId = idsBefore[1]
            let cId = idsBefore[2]
            try? Tmux.selectPane(ts.name, paneIndex: 2)  // active = bot-right
            _ = try? Tmux.createPane(ts.name)
            let idsAfter = getPaneIds(ts.name)
            check("sticky_3_to_4_bot_right count", idsAfter.count == 4)
            if idsAfter.count == 4 {
                let newId = idsAfter.first { ![aId, bId, cId].contains($0) } ?? "?"
                check("sticky_3_to_4_bot_right TL=A", idsAfter[0] == aId,
                      "got \(idsAfter), expected TL=A=\(aId)")
                check("sticky_3_to_4_bot_right TR=B", idsAfter[1] == bId,
                      "got \(idsAfter), expected TR=B=\(bId)")
                check("sticky_3_to_4_bot_right BL=NEW", idsAfter[2] == newId,
                      "got \(idsAfter), expected BL=NEW=\(newId)")
                check("sticky_3_to_4_bot_right BR=C", idsAfter[3] == cId,
                      "got \(idsAfter), expected BR=C=\(cId)")
            }
        }

        // --- sticky_4_to_5_active_each ---
        // 2x2 + Cmd-N from each pane. Spec: existing 2x2 unchanged, NEW=right col.
        for activeIdx in 0..<4 {
            let ts = TestSession(paneCount: 4)
            let idsBefore = getPaneIds(ts.name)
            let originalIds = Set(idsBefore)
            try? Tmux.selectPane(ts.name, paneIndex: activeIdx)
            _ = try? Tmux.createPane(ts.name)
            let idsAfter = getPaneIds(ts.name)
            check("sticky_4_to_5_active_\(activeIdx) count", idsAfter.count == 5,
                  "got \(idsAfter)")
            if idsAfter.count == 5 {
                // 2x2 preserved
                for i in 0..<4 {
                    check("sticky_4_to_5_active_\(activeIdx) slot\(i) preserved",
                          idsAfter[i] == idsBefore[i],
                          "slot \(i): want \(idsBefore[i]), got \(idsAfter[i]). full=\(idsAfter)")
                }
                // NEW at slot 4 (right col)
                let newId = idsAfter.first { !originalIds.contains($0) } ?? "?"
                check("sticky_4_to_5_active_\(activeIdx) right=NEW",
                      idsAfter[4] == newId,
                      "right col should be NEW=\(newId), got \(idsAfter[4]). full=\(idsAfter)")
            }
        }

        // === STRESS TESTS ===

        // --- create_and_kill_many_panes ---
        // Use paneCount: 0 (no config) and redistribute layout between
        // splits so no single pane gets too small for further splitting.
        do {
            let ts = TestSession(paneCount: 0)
            for _ in 0..<8 {
                createPane(ts.name)
                // Redistribute so the next split has enough space
                tmux("select-layout", "-t", ts.name, "tiled")
            }
            check("createAndKillManyPanes-created",
                  paneCount(ts.name) == 9,
                  "expected 9 panes, got \(paneCount(ts.name))")
            for i in stride(from: 8, through: 1, by: -1) {
                killPane(ts.name, i)
            }
            check("createAndKillManyPanes-killed",
                  paneCount(ts.name) == 1,
                  "expected 1 pane, got \(paneCount(ts.name))")
        }

        // --- rapid_zoom_unzoom_cycles ---
        do {
            let ts = TestSession(paneCount: 4)
            for _ in 0..<10 {
                toggleZoom(ts.name)
            }
            check("rapidZoomUnzoomCycles-notZoomed",
                  !isZoomed(ts.name),
                  "should not be zoomed after even number of toggles")
            check("rapidZoomUnzoomCycles-paneCount",
                  paneCount(ts.name) == 4,
                  "expected 4 panes, got \(paneCount(ts.name))")
        }

        // --- zoom_each_pane_individually ---
        do {
            let ts = TestSession(paneCount: 4)
            for i in 0..<4 {
                selectPane(ts.name, i)
                toggleZoom(ts.name)
                check("zoomEachPaneIndividually-zoomed-\(i)",
                      isZoomed(ts.name))
                toggleZoom(ts.name)
                check("zoomEachPaneIndividually-unzoomed-\(i)",
                      !isZoomed(ts.name))
            }
            check("zoomEachPaneIndividually-paneCount",
                  paneCount(ts.name) == 4,
                  "expected 4 panes, got \(paneCount(ts.name))")
        }

        // --- pane_titles_survive_layout_changes ---
        do {
            let ts = TestSession(paneCount: 3)
            setTitle(ts.name, 0, "alpha")
            setTitle(ts.name, 1, "beta")
            setTitle(ts.name, 2, "gamma")
            applyLayout(ts.name)
            let panes1 = tmuxListPanes(ts.name)
            check("paneTitlesSurviveLayout-alpha1",
                  panes1.contains { $0.contains("alpha") },
                  "alpha missing after layout: \(panes1)")
            check("paneTitlesSurviveLayout-beta1",
                  panes1.contains { $0.contains("beta") },
                  "beta missing after layout: \(panes1)")
            check("paneTitlesSurviveLayout-gamma1",
                  panes1.contains { $0.contains("gamma") },
                  "gamma missing after layout: \(panes1)")
            toggleZoom(ts.name)
            toggleZoom(ts.name)
            let panes2 = tmuxListPanes(ts.name)
            check("paneTitlesSurviveLayout-alpha2",
                  panes2.contains { $0.contains("alpha") },
                  "alpha missing after zoom cycle: \(panes2)")
            check("paneTitlesSurviveLayout-beta2",
                  panes2.contains { $0.contains("beta") },
                  "beta missing after zoom cycle: \(panes2)")
            check("paneTitlesSurviveLayout-gamma2",
                  panes2.contains { $0.contains("gamma") },
                  "gamma missing after zoom cycle: \(panes2)")
        }

        // --- split_then_zoom_then_exit ---
        do {
            let ts = TestSession(paneCount: 3)
            enterSplit(ts.name, 0, 1)
            check("splitThenZoomThenExit-windows",
                  windowCount(ts.name) == 2,
                  "expected 2 windows, got \(windowCount(ts.name))")
            exitSplit(ts.name)
            check("splitThenZoomThenExit-windowsAfterExit",
                  windowCount(ts.name) == 1,
                  "expected 1 window, got \(windowCount(ts.name))")
            check("splitThenZoomThenExit-paneCount",
                  paneCount(ts.name) == 3,
                  "expected 3 panes, got \(paneCount(ts.name))")
            toggleZoom(ts.name)
            check("splitThenZoomThenExit-zoomed",
                  isZoomed(ts.name))
            toggleZoom(ts.name)
        }

        // --- split_with_four_panes_various_pairs ---
        do {
            let ts = TestSession(paneCount: 4)
            check("splitFourPanesVariousPairs-initial",
                  paneCount(ts.name) == 4,
                  "expected 4 panes, got \(paneCount(ts.name))")
            enterSplit(ts.name, 0, 2)
            check("splitFourPanesVariousPairs-split02-windows",
                  windowCount(ts.name) == 2,
                  "expected 2 windows, got \(windowCount(ts.name))")
            exitSplit(ts.name)
            check("splitFourPanesVariousPairs-exit02-panes",
                  paneCount(ts.name) == 4,
                  "expected 4 panes, got \(paneCount(ts.name))")
            enterSplit(ts.name, 1, 3)
            check("splitFourPanesVariousPairs-split13-windows",
                  windowCount(ts.name) == 2,
                  "expected 2 windows, got \(windowCount(ts.name))")
            exitSplit(ts.name)
            check("splitFourPanesVariousPairs-exit13-panes",
                  paneCount(ts.name) == 4,
                  "expected 4 panes, got \(paneCount(ts.name))")
        }

        // --- kill_pane_then_create_maintains_layout ---
        do {
            let ts = TestSession(paneCount: 4)
            check("killPaneThenCreate-initial",
                  paneCount(ts.name) == 4,
                  "expected 4 panes, got \(paneCount(ts.name))")
            killPane(ts.name, 1)
            check("killPaneThenCreate-afterKill",
                  paneCount(ts.name) == 3,
                  "expected 3 panes, got \(paneCount(ts.name))")
            createPane(ts.name)
            check("killPaneThenCreate-afterRecreate",
                  paneCount(ts.name) == 4,
                  "expected 4 panes, got \(paneCount(ts.name))")
        }

        // --- config_applied_multiple_times_is_idempotent ---
        do {
            let ts = TestSession(paneCount: 0)
            applyConfig(ts.name)
            applyConfig(ts.name)
            applyConfig(ts.name)
            let panes = tmuxListPanes(ts.name)
            check("configAppliedMultipleTimesIdempotent",
                  panes.count == 1,
                  "expected 1 pane, got \(panes.count)")
        }

        // --- version_check_passes ---
        do {
            let result = tmux("-V")
            check("versionCheckPasses",
                  result.success,
                  "tmux -V failed: \(result.stderr)")
        }

        // --- split_requires_at_least_three_panes ---
        do {
            let ts = TestSession(paneCount: 2)
            // With only 2 panes, split should fail (need at least 3)
            tmux("set-environment", "-t", ts.name, "AMUX_SPLIT_FIRST", "0")
            let result = amuxCmd(session: ts.name, args: ["--session", ts.name, "split-pick", "1"])
            check("splitRequiresAtLeastThreePanes",
                  !result.success,
                  "split should require at least 3 panes")
        }

        // --- smart_resize_with_many_panes ---
        do {
            let ts = TestSession(paneCount: 4)
            selectPane(ts.name, 0)
            // MIN_PANE_COLS = 120, MIN_PANE_ROWS = 24
            smartResize(ts.name, pane: 0, minCols: 120, minRows: 24)

            let sizesAfter = paneSizes(ts.name)
            check("smartResizeWithManyPanes-enlarged",
                  sizesAfter[0].0 > 60,
                  "pane 0 should be enlarged, got \(sizesAfter[0].0)x\(sizesAfter[0].1)")

            // Restore tiled
            restoreTiled(ts.name)
            let sizesRestored = paneSizes(ts.name)
            let widths = sizesRestored.map { $0.0 }
            let maxW = widths.max() ?? 0
            let minW = widths.min() ?? 0
            check("smartResizeWithManyPanes-equalAfterRestore",
                  maxW - minW <= 2,
                  "should be roughly equal after restore: \(widths)")
        }

        // --- smart_resize_preserves_sufficient_dimensions ---
        do {
            let ts = TestSession(paneCount: 4)
            // 4 panes in 2x2 grid with amux layout applied.
            // In a 200x50 terminal, each pane is ~99x24. Use minCols above
            // the actual width so width needs enlarging but height doesn't.
            let sizes = paneSizes(ts.name)
            let heightBefore = sizes[0].1
            let minCols = sizes[0].0 + 20
            let minRows = 5
            check("smartResizePreserves-widthBelowMin",
                  sizes[0].0 < minCols,
                  "width \(sizes[0].0) should be below min \(minCols)")
            check("smartResizePreserves-heightAboveMin",
                  heightBefore > minRows,
                  "height \(heightBefore) should be above min \(minRows)")

            smartResize(ts.name, pane: 0, minCols: minCols, minRows: minRows)

            let sizesAfter = paneSizes(ts.name)
            check("smartResizePreserves-heightNotShrunk",
                  sizesAfter[0].1 >= heightBefore - 1,
                  "smart_resize shrunk height from \(heightBefore) to \(sizesAfter[0].1) (min was \(minRows))")
        }

        // --- restore_tiled_unzooms_first ---
        do {
            let ts = TestSession(paneCount: 2)
            toggleZoom(ts.name)
            check("restoreTiledUnzoomsFirst-zoomed",
                  isZoomed(ts.name))
            restoreTiled(ts.name)
            check("restoreTiledUnzoomsFirst-unzoomed",
                  !isZoomed(ts.name))
        }

        // === SPACES TESTS ===

        // --- list_sessions_includes_created ---
        do {
            let ts = TestSession(paneCount: 0)
            let result = tmux("list-sessions", "-F", "#{session_name}")
            let sessions = result.stdout.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            check("listSessionsIncludesCreated",
                  sessions.contains(ts.name),
                  "session \(ts.name) should be listed")
        }

        // --- send_pane_to_session ---
        do {
            let ts1 = TestSession(paneCount: 0)
            let ts2 = TestSession(paneCount: 0)
            createPane(ts1.name)
            check("sendPaneToSession-ts1Before",
                  paneCount(ts1.name) == 2,
                  "expected 2 panes in ts1, got \(paneCount(ts1.name))")
            check("sendPaneToSession-ts2Before",
                  paneCount(ts2.name) == 1,
                  "expected 1 pane in ts2, got \(paneCount(ts2.name))")
            sendPaneToSession(ts1.name, ts2.name)
            check("sendPaneToSession-ts1After",
                  paneCount(ts1.name) == 1,
                  "expected 1 pane in ts1, got \(paneCount(ts1.name))")
            check("sendPaneToSession-ts2After",
                  paneCount(ts2.name) == 2,
                  "expected 2 panes in ts2, got \(paneCount(ts2.name))")
        }

        // --- switch_session_sessions_exist ---
        do {
            let ts1 = TestSession(paneCount: 0)
            let ts2 = TestSession(paneCount: 0)
            check("switchSessionSessionsExist-ts1",
                  tmux("has-session", "-t", ts1.name).success,
                  "ts1 should exist")
            check("switchSessionSessionsExist-ts2",
                  tmux("has-session", "-t", ts2.name).success,
                  "ts2 should exist")
        }

        // === LAYOUT STABILITY TESTS ===

        // --- layout_two_panes_always_left_right ---
        do {
            let ts = TestSession(paneCount: 2)
            let panes = tmuxListPanes(ts.name)
            check("layoutTwoPanesLeftRight-count",
                  panes.count == 2,
                  "expected 2 panes, got \(panes.count)")
            let result = tmux("list-panes", "-t", ts.name, "-F", "#{pane_top}")
            let tops = result.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            check("layoutTwoPanesLeftRight-sameTop",
                  tops.count >= 2 && tops[0] == tops[1],
                  "2 panes should be side-by-side (same top): \(tops)")
        }

        // --- layout_close_preserves_positions ---
        do {
            let ts = TestSession(paneCount: 4)
            let sizesBefore = paneSizes(ts.name)
            check("layoutClosePreservesPositions-initial",
                  sizesBefore.count == 4,
                  "expected 4 panes, got \(sizesBefore.count)")
            let p0HeightBefore = sizesBefore[0].1
            // Kill pane 2 (bottom-left in 2x2)
            killPane(ts.name, 2)
            // Apply layout after kill to get proper 3-pane arrangement
            applyLayout(ts.name)
            let sizesAfter = paneSizes(ts.name)
            check("layoutClosePreservesPositions-afterKill",
                  sizesAfter.count == 3,
                  "expected 3 panes, got \(sizesAfter.count)")
            check("layoutClosePreservesPositions-expanded",
                  sizesAfter[0].1 > p0HeightBefore,
                  "pane 0 should expand: before_h=\(p0HeightBefore), after_h=\(sizesAfter[0].1)")
        }

        // --- layout_four_panes_is_2x2 ---
        do {
            let ts = TestSession(paneCount: 4)
            let positions = panePositions(ts.name)
            check("layoutFourPanesIs2x2-count",
                  positions.count == 4,
                  "expected 4 panes, got \(positions.count)")
            let xs = Set(positions.map { $0.0 })
            let ys = Set(positions.map { $0.1 })
            check("layoutFourPanesIs2x2-columns",
                  xs.count == 2,
                  "should have 2 columns: \(positions)")
            check("layoutFourPanesIs2x2-rows",
                  ys.count == 2,
                  "should have 2 rows: \(positions)")
        }

        // --- spatial_stickiness_kill_and_recreate ---
        do {
            let ts = TestSession(paneCount: 4)
            let idsBefore = getPaneIds(ts.name)
            let positionsBefore = panePositions(ts.name)

            killPane(ts.name, 1)
            applyLayout(ts.name)
            let positionsAfterKill = panePositions(ts.name)
            check("spatialStickinessKillRecreate-pane0StaysLeft",
                  positionsAfterKill[0].0 < 10,
                  "pane 0 should stay on left: \(positionsAfterKill)")

            createPane(ts.name)
            applyLayout(ts.name)
            let positionsAfterCreate = panePositions(ts.name)
            let idsAfter = getPaneIds(ts.name)

            // Find surviving pane IDs
            let survivors = idsBefore.filter { idsAfter.contains($0) }

            // Check pane widths to see if terminal is large enough
            let sizes = paneSizes(ts.name)
            let maxW = sizes.map { $0.0 }.max() ?? 0
            if maxW >= 100 {
                for survId in survivors {
                    guard let beforeIdx = idsBefore.firstIndex(of: survId),
                          let afterIdx = idsAfter.firstIndex(of: survId) else { continue }
                    let (bx, by) = positionsBefore[beforeIdx]
                    let (ax, ay) = positionsAfterCreate[afterIdx]
                    let dist = abs(bx - ax) + abs(by - ay)
                    check("spatialStickinessKillRecreate-\(survId)-stable",
                          dist < 20,
                          "pane \(survId) moved too far: (\(bx),\(by)) -> (\(ax),\(ay)), dist=\(dist)")
                }
            }
        }

        // --- apply_layout_twice_preserves_centers ---
        do {
            let ts = TestSession(paneCount: 4)
            applyLayout(ts.name)
            let positions1 = panePositions(ts.name)
            applyLayout(ts.name)
            let positions2 = panePositions(ts.name)
            let positionsMatch = positions1.count == positions2.count &&
                zip(positions1, positions2).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            check("applyLayoutTwicePreservesCenters",
                  positionsMatch,
                  "layout should be stable on reapply: \(positions1) vs \(positions2)")
        }

        // --- stickiness_survives_rapid_changes ---
        do {
            let ts = TestSession(paneCount: 4)
            for _ in 0..<3 {
                killPane(ts.name, 1)
                createPane(ts.name)
                applyLayout(ts.name)
            }
            check("stickinessSurvivesRapidChanges-paneCount",
                  paneCount(ts.name) == 4,
                  "expected 4 panes, got \(paneCount(ts.name))")
            let positions = panePositions(ts.name)
            let xs = Set(positions.map { $0.0 })
            let ys = Set(positions.map { $0.1 })
            check("stickinessSurvivesRapidChanges-columns",
                  xs.count == 2,
                  "should have 2 columns: \(positions)")
            check("stickinessSurvivesRapidChanges-rows",
                  ys.count == 2,
                  "should have 2 rows: \(positions)")
        }

        // === PANE SIZE EQUALITY TESTS (border-status compensation) ===

        // --- four_panes_equal_height_with_border_status ---
        do {
            let ts = TestSession(paneCount: 4)
            let sizes = paneSizes(ts.name)
            check("fourPanesEqualHeight-count",
                  sizes.count == 4,
                  "expected 4 panes, got \(sizes.count)")
            let heights = sizes.map { $0.1 }
            let maxH = heights.max() ?? 0
            let minH = heights.min() ?? 0
            check("fourPanesEqualHeight-equal",
                  maxH - minH <= 1,
                  "all panes should have roughly equal height, got \(sizes) (diff \(maxH - minH))")
        }

        // --- three_panes_right_column_equal_with_border_status ---
        do {
            let ts = TestSession(paneCount: 3)
            let sizes = paneSizes(ts.name)
            check("threePanesRightColumnEqual-count",
                  sizes.count == 3,
                  "expected 3 panes, got \(sizes.count)")
            let rightDiff = abs(sizes[1].1 - sizes[2].1)
            check("threePanesRightColumnEqual-equal",
                  rightDiff <= 1,
                  "right column panes should have roughly equal height: \(sizes) (diff \(rightDiff))")
        }

        // --- six_panes_equal_height_with_border_status ---
        // TestSession(paneCount: 6) may fail because split-window runs out
        // of space with border-status enabled. Create 4 first (reliable),
        // then add 2 more and re-layout.
        do {
            let ts = TestSession(paneCount: 4)
            createPane(ts.name)
            createPane(ts.name)
            applyLayout(ts.name)
            let sizes = paneSizes(ts.name)
            check("sixPanesEqualHeight-count",
                  sizes.count == 6,
                  "expected 6 panes, got \(sizes.count)")
            if sizes.count == 6 {
                let heights = sizes.map { $0.1 }
                let maxH = heights.max() ?? 0
                let minH = heights.min() ?? 0
                check("sixPanesEqualHeight-equal",
                      maxH - minH <= 1,
                      "all panes should have roughly equal height, got \(sizes) (diff \(maxH - minH))")
            }
        }

        print("AmuxTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
