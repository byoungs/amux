#if DEBUG
import Foundation

enum LinkDetectorTests {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        func urls(_ line: String) -> [String] {
            LinkDetector.scan(line: line, row: 0).map { $0.url }
        }

        // === URLs ===

        do {
            let result = urls("Visit https://example.com/path?q=1 for info")
            check("url-https", result == ["https://example.com/path?q=1"], "got \(result)")
        }

        do {
            let result = urls("http://localhost:3000/api")
            check("url-http", result == ["http://localhost:3000/api"], "got \(result)")
        }

        do {
            let result = urls("no urls here")
            check("url-none", result.isEmpty, "got \(result)")
        }

        // === Bare filenames (.md) ===

        do {
            let result = urls("complete-property-inventory.md")
            check("file-md", result == ["file:complete-property-inventory.md"], "got \(result)")
        }

        do {
            let result = urls("competitive-analysis-ssg-vs-avantstay.md")
            check("file-md-complex", result == ["file:competitive-analysis-ssg-vs-avantstay.md"], "got \(result)")
        }

        do {
            let result = urls("  README.md")
            check("file-md-indented", result == ["file:README.md"], "got \(result)")
        }

        // === Bare filenames (other extensions) ===

        do {
            let result = urls("data.csv")
            check("file-csv", result == ["file:data.csv"], "got \(result)")
        }

        do {
            let result = urls("config.json")
            check("file-json", result == ["file:config.json"], "got \(result)")
        }

        // === Filenames with paths ===

        do {
            let result = urls("src/main.swift")
            check("file-path", result == ["file:src/main.swift"], "got \(result)")
        }

        do {
            let result = urls("/Users/brianyoungs/src/scratch-claude/MASTER-analysis.md")
            check("file-absolute-path",
                  result == ["file:/Users/brianyoungs/src/scratch-claude/MASTER-analysis.md"],
                  "got \(result)")
        }

        do {
            let result = urls("app/Sources/AmuxTerm/TerminalView.swift")
            check("file-deep-path", result == ["file:app/Sources/AmuxTerm/TerminalView.swift"], "got \(result)")
        }

        // === Mixed ===

        do {
            let result = urls("See https://docs.rs and README.md")
            check("mixed-count", result.count == 2, "should find 2, got \(result)")
        }

        // === Trailing punctuation ===

        do {
            let result = urls("/Users/brianyoungs/src/scratch-claude/MASTER-analysis.md.")
            check("file-trailing-period",
                  result == ["file:/Users/brianyoungs/src/scratch-claude/MASTER-analysis.md"],
                  "should strip trailing period, got \(result)")
        }

        do {
            let result = urls("See README.md.")
            check("file-trailing-period-short",
                  result == ["file:README.md"],
                  "got \(result)")
        }

        do {
            let result = urls("Check file.json, then continue")
            check("file-trailing-comma",
                  result == ["file:file.json"],
                  "got \(result)")
        }

        // === No false positives ===

        do {
            let result = urls("hello world")
            check("no-match-plain", result.isEmpty, "got \(result)")
        }

        do {
            let result = urls("the number 42 is important")
            check("no-match-numbers", result.isEmpty, "got \(result)")
        }

        do {
            let result = urls("just a sentence with no files")
            check("no-match-sentence", result.isEmpty, "got \(result)")
        }

        // === Color-aware: filenames with spaces ===

        // Helper: build a colors array where a substring [start..<end] has a
        // distinct (non-default) color and the rest is default.
        func colorize(_ line: String, coloredRange: Range<Int>) -> [LinkDetector.CellColor] {
            let blue = LinkDetector.CellColor(rgb: 0x0066ff, isDefault: false)
            let def = LinkDetector.CellColor(rgb: 0xbbbbbb, isDefault: true)
            return (0..<line.count).map { coloredRange.contains($0) ? blue : def }
        }

        func urlsColored(_ line: String, coloredRange: Range<Int>) -> [String] {
            let colors = colorize(line, coloredRange: coloredRange)
            return LinkDetector.scan(line: line, colors: colors, row: 0).map { $0.url }
        }

        do {
            // Filename "my file.md" colored blue, surrounded by default text
            let line = "Open my file.md please"
            let result = urlsColored(line, coloredRange: 5..<15) // "my file.md"
            check("color-file-with-space",
                  result == ["file:my file.md"],
                  "got \(result)")
        }

        do {
            // Filename "complete inventory list.txt" colored
            let line = "  complete inventory list.txt  "
            let result = urlsColored(line, coloredRange: 2..<29) // the filename
            check("color-txt-with-spaces",
                  result == ["file:complete inventory list.txt"],
                  "got \(result)")
        }

        do {
            // Without color, falls back to whitespace boundary (no spaces in name)
            let line = "see README.md here"
            let colors = (0..<line.count).map { _ in
                LinkDetector.CellColor(rgb: 0xbbbbbb, isDefault: true)
            }
            let result = LinkDetector.scan(line: line, colors: colors, row: 0).map { $0.url }
            check("color-fallback-whitespace",
                  result == ["file:README.md"],
                  "got \(result)")
        }

        do {
            // .txt file is recognized
            let line = "open notes.txt for details"
            let colors = (0..<line.count).map { _ in
                LinkDetector.CellColor(rgb: 0xbbbbbb, isDefault: true)
            }
            let result = LinkDetector.scan(line: line, colors: colors, row: 0).map { $0.url }
            check("color-txt-extension",
                  result == ["file:notes.txt"],
                  "got \(result)")
        }

        // === Screen scanning: borders, truncation, trailing punctuation ===

        func defaultColors(_ rows: [String]) -> [[LinkDetector.CellColor]] {
            rows.map { line in
                (0..<line.count).map { _ in
                    LinkDetector.CellColor(rgb: 0xbbbbbb, isDefault: true)
                }
            }
        }

        func screenLinks(_ rows: [String], cols: Int) -> [DetectedLink] {
            LinkDetector.scanScreen(rows: rows, colors: defaultColors(rows), cols: cols)
        }

        do {
            // URL flush against a tmux pane border must stop at the border,
            // not bleed into the neighbor pane's text.
            let rows = ["  open https://example.com│ neighbor pane text"]
            let result = screenLinks(rows, cols: 80).map { $0.url }
            check("screen-border-stop", result == ["https://example.com"], "got \(result)")
        }

        do {
            // Claude Code truncates long URLs with an ellipsis in tool-call
            // headers. The ellipsis is not part of the URL.
            let result = urls("⏺ Fetch(https://example.com/long/pa… )")
            check("url-ellipsis-stop", result == ["https://example.com/long/pa"], "got \(result)")
        }

        do {
            // Sentence-final punctuation after a URL is not part of it.
            let rows = ["  See https://example.com/docs. Then continue"]
            let result = screenLinks(rows, cols: 80)
            check("screen-trailing-period",
                  result.map { $0.url } == ["https://example.com/docs"] && result[0].endCol == 29,
                  "got \(result)")
        }

        // === Screen scanning: wrapped-URL joining ===

        do {
            // Ink-style soft wrap in a zoomed pane: the fragment fills the row
            // to the right screen edge, the tail is indented on the next row.
            // Every fragment carries the full joined URL.
            let rows = [
                "  ⎿  Visit your newly deployed app",
                "      at https://youngs-boat-2026.",
                "     fly.dev/",
            ]
            let result = screenLinks(rows, cols: 34)
            let joined = "https://youngs-boat-2026.fly.dev/"
            check("screen-wrap-join",
                  result.count == 2
                      && result.allSatisfy { $0.url == joined }
                      && result[0].row == 1 && result[0].startCol == 9 && result[0].endCol == 33
                      && result[1].row == 2 && result[1].startCol == 5 && result[1].endCol == 12,
                  "got \(result)")
        }

        do {
            // Same join inside a grid: the fragment runs flush into the pane
            // border, with another pane's text beyond it.
            let rows = [
                "⏺ Fetch(https://a.com/xy│ noise here",
                "       z-1.php?q=2│ more noise",
            ]
            let result = screenLinks(rows, cols: 80).map { $0.url }
            check("screen-wrap-join-bordered",
                  result == ["https://a.com/xyz-1.php?q=2", "https://a.com/xyz-1.php?q=2"],
                  "got \(result)")
        }

        do {
            // Three-row wrap: middle fragment is itself flush at the border.
            let rows = [
                "x https://a.bc/de│p",
                "fgh│q",
                "ij k",
            ]
            let result = screenLinks(rows, cols: 80).map { $0.url }
            check("screen-wrap-join-multihop",
                  result == ["https://a.bc/defghij", "https://a.bc/defghij", "https://a.bc/defghij"],
                  "got \(result)")
        }

        do {
            // A URL that ends mid-row is complete — never joined with the
            // next row's text.
            let rows = [
                "  see https://example.com",
                "  and more prose",
            ]
            let result = screenLinks(rows, cols: 40).map { $0.url }
            check("screen-no-join-when-not-flush", result == ["https://example.com"], "got \(result)")
        }

        do {
            // A continuation row consumed by a join must not also surface as
            // its own standalone link.
            let rows = [
                "xx https://a.com/?u=",
                "https://b.com/p",
            ]
            let result = screenLinks(rows, cols: 20)
            let joined = "https://a.com/?u=https://b.com/p"
            check("screen-join-consumes-continuation",
                  result.count == 2 && result.allSatisfy { $0.url == joined },
                  "got \(result)")
        }

        do {
            // File links still come through the screen scan.
            let rows = ["  see README.md"]
            let result = screenLinks(rows, cols: 40).map { $0.url }
            check("screen-file-link", result == ["file:README.md"], "got \(result)")
        }

        // === Merging explicit OSC 8 spans with text-detected spans ===

        do {
            // An explicit hyperlink span suppresses any text-detected span
            // it overlaps on the same row; non-overlapping spans survive.
            let explicit = [DetectedLink(row: 0, startCol: 4, endCol: 11, url: "https://real.example.com")]
            let detected = [
                DetectedLink(row: 0, startCol: 8, endCol: 20, url: "https://scraped.example.com"),
                DetectedLink(row: 1, startCol: 0, endCol: 5, url: "file:a.md"),
            ]
            let result = LinkDetector.merging(explicit: explicit, detected: detected)
            check("merge-explicit-wins",
                  result.map { $0.url } == ["https://real.example.com", "file:a.md"],
                  "got \(result.map { $0.url })")
        }

        print("LinkDetector tests: \(passed) passed, \(failed) failed")
        Darwin.fflush(Darwin.stdout)
        if failed > 0 { fatalError("LinkDetector tests failed") }
    }
}
#endif
