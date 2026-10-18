import Foundation

#if DEBUG
public enum DebugLogTests {
    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        func state(_ panes: [Pane], w: Int = 191, h: Int = 80, zoomed: Bool = false) -> LayoutState {
            LayoutState(panes: panes, windowW: w, windowH: h, borderTop: 1,
                        zoomed: zoomed, activePane: 0, paneCount: panes.count)
        }

        // The live session's healthy 5-pane grid (border row on top).
        let grid = [Pane(id: 9, x: 0, y: 1, w: 63, h: 39), Pane(id: 11, x: 64, y: 1, w: 63, h: 39),
                    Pane(id: 12, x: 0, y: 41, w: 63, h: 39), Pane(id: 14, x: 64, y: 41, w: 63, h: 39),
                    Pane(id: 17, x: 128, y: 1, w: 63, h: 79)]
        check("grid fills window", state(grid).panesFillWindow)
        // Same panes after the window grew but nothing re-tiled.
        check("stale grid after grow is a mismatch", !state(grid, w: 285, h: 53).panesFillWindow)
        check("zoomed pane fills",
              state([Pane(id: 9, x: 0, y: 1, w: 191, h: 79)], zoomed: true).panesFillWindow)

        check("summary names geometry",
              state(grid).debugSummary.hasPrefix("win=191x80 zoomed=0 active=0 panes=[%9@0,1:63x39"),
              state(grid).debugSummary)

        let line = DebugLog.line("hello", at: Date(timeIntervalSince1970: 0), process: "amux-cli", pid: 42)
        check("line has process, pid, message, newline",
              line.hasSuffix(" amux-cli[42] hello\n") && line.hasPrefix("19"), line)

        print("DebugLog tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("DebugLog tests failed") }
    }
}
#endif
