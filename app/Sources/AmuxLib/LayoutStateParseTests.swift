import Foundation

#if DEBUG
/// Tests for `Tmux.parseLayoutRows`: the list-panes reply must become a
/// complete LayoutState or an error, never a silent empty layout.
public enum LayoutStateParseTests {
    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        func row(_ fields: [String]) -> String { fields.joined(separator: "\t") }

        func parses(_ stdout: String) -> Bool {
            (try? Tmux.parseLayoutRows(stdout, borderTop: 1)) != nil
        }

        // A zoomed 3-pane window, pane %1 active (rows as tmux prints them).
        let zoomed = [
            row(["%0", "0", "0", "192", "15", "192", "60", "1", "0", "0"]),
            row(["%2", "0", "16", "192", "14", "192", "60", "1", "0", "1"]),
            row(["%1", "0", "31", "192", "29", "192", "60", "1", "1", "2"]),
        ].joined(separator: "\n")

        if let state = try? Tmux.parseLayoutRows(zoomed, borderTop: 1) {
            check("parse-pane-count", state.panes.count == 3, "got \(state.panes.count)")
            check("parse-zoomed-flag", state.zoomed)
            check("parse-active-pane", state.activePane == 2, "got \(state.activePane)")
            check("parse-window-size", state.windowW == 192 && state.windowH == 60,
                  state.debugSummary)
        } else {
            check("parse-zoomed-output-accepted", false, "healthy zoomed output threw")
        }

        // Empty reply must throw, not become an 80x24 layout with no panes.
        check("parse-empty-throws", !parses(""))

        // A row that drops a field must throw, not be skipped.
        check("parse-short-row-throws",
              !parses(row(["%0", "0", "0", "192", "15", "192", "60", "1", "1"])))

        // An empty field (tmux printed nothing for it) must throw.
        check("parse-empty-field-throws",
              !parses(row(["%0", "0", "0", "192", "15", "192", "60", "", "1", "0"])))

        // One bad row among good rows poisons the whole reply.
        check("parse-bad-row-among-good-throws",
              !parses(zoomed + "\n" + row(["%9", "x", "0", "1", "1", "192", "60", "1", "0", "3"])))

        print("LayoutStateParse tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("LayoutStateParse tests failed") }
    }
}
#endif
