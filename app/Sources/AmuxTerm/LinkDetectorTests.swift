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

        print("LinkDetector tests: \(passed) passed, \(failed) failed")
        Darwin.fflush(Darwin.stdout)
        if failed > 0 { fatalError("LinkDetector tests failed") }
    }
}
#endif
