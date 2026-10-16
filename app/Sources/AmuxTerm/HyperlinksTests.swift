#if DEBUG
import Foundation

enum HyperlinksTests {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // === OSC8Payload parsing ===

        do {
            let p = OSC8Payload.parse(";https://example.com")
            check("payload-no-params", p == OSC8Payload(id: nil, uri: "https://example.com"), "got \(String(describing: p))")
        }

        do {
            let p = OSC8Payload.parse("id=tmux1;https://example.com")
            check("payload-id", p == OSC8Payload(id: "tmux1", uri: "https://example.com"), "got \(String(describing: p))")
        }

        do {
            let p = OSC8Payload.parse("foo=bar:id=x;mailto:a@b.c")
            check("payload-multi-params", p == OSC8Payload(id: "x", uri: "mailto:a@b.c"), "got \(String(describing: p))")
        }

        do {
            let p = OSC8Payload.parse(";")
            check("payload-terminator", p == OSC8Payload(id: nil, uri: ""), "got \(String(describing: p))")
        }

        do {
            let p = OSC8Payload.parse("no-separator")
            check("payload-malformed", p == nil, "got \(String(describing: p))")
        }

        // === HyperlinkGrid: open / stamp / close / clear ===

        do {
            let grid = HyperlinkGrid(rows: 4, cols: 20)
            grid.feed(";https://a.com")
            grid.writeCells(row: 0, startCol: 2, endCol: 7)  // write 5 cells
            grid.feed(";")
            check("grid-stamp",
                  grid.uri(row: 0, col: 2) == "https://a.com"
                      && grid.uri(row: 0, col: 6) == "https://a.com"
                      && grid.uri(row: 0, col: 1) == nil
                      && grid.uri(row: 0, col: 7) == nil,
                  "cols 2-6 should carry the link")
            check("grid-closed", grid.activeID == 0)

            // Plain text written over the label clears the stamps.
            grid.writeCells(row: 0, startCol: 0, endCol: 10)
            check("grid-overwrite-clears", grid.uri(row: 0, col: 4) == nil)
        }

        do {
            // Same id + URI across separate emissions interns to one id
            // (split links stay one logical link).
            let grid = HyperlinkGrid(rows: 2, cols: 20)
            grid.feed("id=x;https://a.com")
            grid.writeCells(row: 0, startCol: 0, endCol: 3)
            grid.feed(";")
            grid.feed("id=x;https://a.com")
            grid.writeCells(row: 1, startCol: 0, endCol: 3)
            grid.feed(";")
            check("grid-id-continuity",
                  grid.id(row: 0, col: 0) != 0 && grid.id(row: 0, col: 0) == grid.id(row: 1, col: 0),
                  "same id= and URI must intern to the same internal id")
        }

        do {
            // Different URIs get different ids even without id= params.
            let grid = HyperlinkGrid(rows: 1, cols: 20)
            grid.feed(";https://a.com")
            grid.writeCells(row: 0, startCol: 0, endCol: 2)
            grid.feed(";https://b.com")
            grid.writeCells(row: 0, startCol: 2, endCol: 4)
            grid.feed(";")
            check("grid-distinct-ids",
                  grid.uri(row: 0, col: 0) == "https://a.com" && grid.uri(row: 0, col: 2) == "https://b.com",
                  "got \(String(describing: grid.uri(row: 0, col: 0))) / \(String(describing: grid.uri(row: 0, col: 2)))")
        }

        // === HyperlinkGrid: streamed fragments ===

        do {
            let grid = HyperlinkGrid(rows: 1, cols: 20)
            let part1 = Array(";https://frag".utf8).map { CChar(bitPattern: $0) }
            let part2 = Array("ment.com".utf8).map { CChar(bitPattern: $0) }
            part1.withUnsafeBufferPointer { p in
                grid.feed(bytes: p.baseAddress, length: p.count, initial: true, final: false)
            }
            part2.withUnsafeBufferPointer { p in
                grid.feed(bytes: p.baseAddress, length: p.count, initial: false, final: true)
            }
            grid.writeCells(row: 0, startCol: 0, endCol: 1)
            check("grid-fragmented-body", grid.uri(row: 0, col: 0) == "https://fragment.com",
                  "got \(String(describing: grid.uri(row: 0, col: 0)))")
        }

        do {
            // Oversized body closes the link instead of stamping a
            // truncated URI.
            let grid = HyperlinkGrid(rows: 1, cols: 20)
            grid.feed(";https://a.com")
            let huge = Array(";https://\(String(repeating: "x", count: 5000)).com".utf8)
                .map { CChar(bitPattern: $0) }
            huge.withUnsafeBufferPointer { p in
                grid.feed(bytes: p.baseAddress, length: p.count, initial: true, final: true)
            }
            grid.writeCells(row: 0, startCol: 0, endCol: 1)
            check("grid-overflow-closes", grid.id(row: 0, col: 0) == 0)
        }

        // === HyperlinkGrid: scroll mirroring, clear, resize ===

        do {
            let grid = HyperlinkGrid(rows: 3, cols: 10)
            grid.feed(";https://a.com")
            grid.writeCells(row: 1, startCol: 0, endCol: 4)
            grid.feed(";")
            // Scroll up one row: rows 1..3 move to rows 0..2.
            grid.moveRect(destStartRow: 0, destStartCol: 0,
                          srcStartRow: 1, srcStartCol: 0,
                          rowCount: 2, colCount: 10)
            check("grid-scroll-follows",
                  grid.uri(row: 0, col: 0) == "https://a.com" && grid.uri(row: 1, col: 0) == nil,
                  "link should move from row 1 to row 0")
        }

        // Scrolling down (reverse scroll, e.g. a TUI inserting a line) must
        // walk rows bottom-up so a moved stamp isn't copied twice.
        do {
            let grid = HyperlinkGrid(rows: 4, cols: 10)
            grid.feed(";https://a.com")
            grid.writeCells(row: 0, startCol: 0, endCol: 3)
            grid.feed(";")
            // Rows 0..2 move to rows 1..3.
            grid.moveRect(destStartRow: 1, destStartCol: 0,
                          srcStartRow: 0, srcStartCol: 0,
                          rowCount: 3, colCount: 10)
            check("grid-scroll-down-follows",
                  grid.uri(row: 1, col: 0) == "https://a.com"
                      && grid.uri(row: 2, col: 0) == nil && grid.uri(row: 3, col: 0) == nil,
                  "row1 \(String(describing: grid.uri(row: 1, col: 0))) row2 \(String(describing: grid.uri(row: 2, col: 0)))")
            check("grid-stamp-count-tracks-moves", grid.stampedCells == 6,
                  "stampedCells \(grid.stampedCells)")
        }

        // Once the last link scrolls away the counter is back to zero, which
        // is what lets per-line scrolls of plain output skip the grid.
        do {
            let grid = HyperlinkGrid(rows: 2, cols: 10)
            grid.feed(";https://a.com")
            grid.writeCells(row: 0, startCol: 0, endCol: 4)
            grid.feed(";")
            grid.moveRect(destStartRow: 0, destStartCol: 0,
                          srcStartRow: 1, srcStartCol: 0,
                          rowCount: 1, colCount: 10)
            check("grid-stamp-count-zero-after-scroll-off", grid.stampedCells == 0,
                  "stampedCells \(grid.stampedCells)")
        }

        do {
            let grid = HyperlinkGrid(rows: 2, cols: 10)
            grid.feed(";https://a.com")
            grid.writeCells(row: 0, startCol: 0, endCol: 4)
            grid.clearAll()
            check("grid-clear", grid.id(row: 0, col: 0) == 0)
            grid.writeCells(row: 1, startCol: 0, endCol: 2)
            check("grid-active-survives-clear", grid.uri(row: 1, col: 0) == "https://a.com")
        }

        do {
            let grid = HyperlinkGrid(rows: 2, cols: 10)
            grid.feed(";https://a.com")
            grid.writeCells(row: 0, startCol: 0, endCol: 4)
            grid.resize(rows: 4, cols: 20)
            check("grid-resize-clears",
                  grid.rows == 4 && grid.cols == 20 && grid.id(row: 0, col: 0) == 0)
        }

        // Exercise the actual parser: cursor positioning is not text output.
        do {
            let terminal = VTerminal(rows: 4, cols: 20)
            func write(_ text: String) { terminal.write(data: Data(text.utf8)) }
            write("\u{1B}]8;;https://example.com\u{1B}\\Read the docs\u{1B}]8;;\u{1B}\\")
            check("parser-stamps-label", terminal.hyperlinkURI(row: 0, col: 5) == "https://example.com")
            write("\r\u{1B}[15C")
            check("cursor-forward-preserves-link", terminal.hyperlinkURI(row: 0, col: 5) == "https://example.com")
            write("\rplain")
            check("overwrite-clears-only-written-cells", terminal.hyperlinkURI(row: 0, col: 0) == nil && terminal.hyperlinkURI(row: 0, col: 6) == "https://example.com")
            write("\u{1B}[2;20H\u{1B}]8;;https://edge.example\u{1B}\\X\u{1B}]8;;\u{1B}\\")
            check("rightmost-cell-has-link", terminal.hyperlinkURI(row: 1, col: 19) == "https://edge.example")
            write("\u{1B}[2;20HY")
            check("rightmost-overwrite-clears-link", terminal.hyperlinkURI(row: 1, col: 19) == nil)
        }

        // === tmux client must advertise the hyperlinks feature ===

        do {
            // Without -T hyperlinks, tmux draws OSC 8 labels but never
            // re-emits the URIs to this client (xterm-256color's terminfo
            // doesn't declare the feature), so nothing below the tmux layer
            // ever sees a hyperlink.
            let args = AppDelegate.tmuxAttachArgs(session: "amux")
            let tIndex = args.firstIndex(of: "-T")
            check("attach-advertises-hyperlinks",
                  tIndex != nil && tIndex! + 1 < args.count && args[tIndex! + 1] == "hyperlinks"
                      && args.contains("attach-session"),
                  "got \(args)")
        }

        print("Hyperlinks tests: \(passed) passed, \(failed) failed")
        Darwin.fflush(Darwin.stdout)
        if failed > 0 { fatalError("Hyperlinks tests failed") }
    }
}
#endif
