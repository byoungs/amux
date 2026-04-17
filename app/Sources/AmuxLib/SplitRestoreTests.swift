#if DEBUG
import Foundation

/// Tests that pane positions are preserved through split view enter/exit.
///
/// The scenario: 4 panes in working grid → enter split with 2 of them →
/// exit split → all 4 panes should be back in their original positions.
public enum SplitRestoreTests {
    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // Use FakeTmux so we don't need a real tmux server
        let fake = FakeTmux()
        Tmux.executor = fake

        // --- Test 1: Split panes 0,1 and restore ---
        do {
            fake.addSession("test", panes: 4)

            // Record original pane IDs in order
            let originalPanes = fake.sessions["test"]!.windows[0].panes.map { $0.id }
            check("setup-4panes", originalPanes.count == 4,
                  "should have 4 panes, got \(originalPanes.count)")

            // Enter split with panes 0 and 1
            try? Tmux.enterSplit("test", paneA: 0, paneB: 1)

            // Should now have 2 windows
            let wc = fake.sessions["test"]!.windows.count
            check("split-2windows", wc == 2,
                  "should have 2 windows during split, got \(wc)")

            // Grid window should have 2 panes
            let gridPanes = fake.sessions["test"]!.windows[0].panes.count
            check("split-gridHas2", gridPanes == 2,
                  "grid should have 2 panes during split, got \(gridPanes)")

            // Exit split
            try? Tmux.exitSplit("test")

            // Should be back to 1 window
            let wcAfter = fake.sessions["test"]!.windows.count
            check("restore-1window", wcAfter == 1,
                  "should have 1 window after exit, got \(wcAfter)")

            // Should have all 4 panes back
            let restoredPanes = fake.sessions["test"]!.windows[0].panes.map { $0.id }
            check("restore-4panes", restoredPanes.count == 4,
                  "should have 4 panes after exit, got \(restoredPanes.count)")

            // KEY ASSERTION: pane IDs should be in the same order as before
            check("restore-sameOrder",
                  restoredPanes == originalPanes,
                  "panes should be in original order: \(originalPanes), got \(restoredPanes)")
        }

        // --- Test 2: Split panes 0,2 (non-adjacent) and restore ---
        do {
            let fake2 = FakeTmux()
            Tmux.executor = fake2
            fake2.addSession("test2", panes: 4)

            let originalPanes = fake2.sessions["test2"]!.windows[0].panes.map { $0.id }

            try? Tmux.enterSplit("test2", paneA: 0, paneB: 2)
            try? Tmux.exitSplit("test2")

            let restoredPanes = fake2.sessions["test2"]!.windows[0].panes.map { $0.id }
            check("restore-nonAdjacent-count", restoredPanes.count == 4,
                  "should have 4 panes, got \(restoredPanes.count)")
            check("restore-nonAdjacent-order",
                  restoredPanes == originalPanes,
                  "panes should be in original order: \(originalPanes), got \(restoredPanes)")
        }

        // --- Test 3: Split panes 1,3 and restore ---
        do {
            let fake3 = FakeTmux()
            Tmux.executor = fake3
            fake3.addSession("test3", panes: 4)

            let originalPanes = fake3.sessions["test3"]!.windows[0].panes.map { $0.id }

            try? Tmux.enterSplit("test3", paneA: 1, paneB: 3)
            try? Tmux.exitSplit("test3")

            let restoredPanes = fake3.sessions["test3"]!.windows[0].panes.map { $0.id }
            check("restore-1and3-count", restoredPanes.count == 4,
                  "should have 4 panes, got \(restoredPanes.count)")
            check("restore-1and3-order",
                  restoredPanes == originalPanes,
                  "panes should be in original order: \(originalPanes), got \(restoredPanes)")
        }

        // Reset executor
        Tmux.executor = LiveTmux()

        print("SplitRestore tests: \(passed) passed, \(failed) failed")
        fflush(stdout)
        if failed > 0 { fatalError("SplitRestore tests failed") }
    }
}
#endif
