import Foundation

/// A detected link in terminal text.
struct DetectedLink: Equatable {
    let row: Int
    let startCol: Int
    let endCol: Int
    let url: String
}

/// Detects clickable links in terminal text.
/// Extracted from TerminalView for testability.
///
/// Detects only two things:
/// 1. URLs (http:// or https://)
/// 2. Filenames with known extensions (e.g., README.md, data.csv)
///    These may include path prefixes (src/foo.md, ./bar.csv, /abs/path.md)
enum LinkDetector {
    /// File extensions we recognize as clickable filenames.
    private static let fileExtensions = [
        "md", "csv", "txt", "pdf",
        "rs", "swift", "js", "ts", "jsx", "tsx", "py", "go",
        "json", "yaml", "yml", "toml",
        "sh", "rb", "java", "c", "h", "cpp", "hpp",
        "css", "html", "xml", "sql",
    ]

    private static let patterns: [(kind: String, regex: NSRegularExpression)] = {
        var result: [(String, NSRegularExpression)] = []

        // 1. URLs
        if let r = try? NSRegularExpression(pattern: "https?://[^\\s)>\\]\"']+") {
            result.append(("url", r))
        }

        // 2. Filenames with known extensions (with optional path prefix)
        let exts = fileExtensions.joined(separator: "|")
        let filePat = "(?:^|(?<=\\s))([\\w./_-]+\\.(?:\(exts)))(?=$|\\s|[)>\\]\"',;:.!?])"
        if let r = try? NSRegularExpression(pattern: filePat) {
            result.append(("file", r))
        }

        return result
    }()

    /// Scan a single line of text for links.
    static func scan(line: String, row: Int) -> [DetectedLink] {
        guard !line.isEmpty else { return [] }
        var links: [DetectedLink] = []
        var coveredRanges: [NSRange] = []
        let nsLine = line as NSString

        for (kind, regex) in patterns {
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            for match in matches {
                let range: NSRange
                if kind == "file" {
                    // Use capture group 1 (the filename without leading whitespace)
                    range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                } else {
                    range = match.range
                }

                // Skip if overlaps with an already-detected link
                let overlaps = coveredRanges.contains { existing in
                    NSIntersectionRange(existing, range).length > 0
                }
                if overlaps { continue }

                let text = nsLine.substring(with: range)
                let url = kind == "url" ? text : "file:\(text)"

                links.append(DetectedLink(
                    row: row,
                    startCol: range.location,
                    endCol: range.location + range.length - 1,
                    url: url
                ))
                coveredRanges.append(range)
            }
        }
        return links
    }

    /// Scan multiple lines.
    static func scanRows(_ rows: [String]) -> [DetectedLink] {
        var links: [DetectedLink] = []
        for (i, line) in rows.enumerated() {
            links.append(contentsOf: scan(line: line, row: i))
        }
        return links
    }

    // MARK: - Color-aware scanning

    /// Per-cell color info used for color-aware filename detection.
    /// Each cell has a packed RGB and a flag for whether it's the default fg.
    struct CellColor: Equatable {
        let rgb: UInt32 // 0xRRGGBB
        let isDefault: Bool
    }

    /// Scan a line with per-cell color info. When a known file extension is
    /// detected, expand the match left and right across cells that share the
    /// same non-default fg color. This captures filenames containing spaces
    /// when the terminal output (Claude, make, ls --color) draws them in a
    /// single distinct color.
    static func scan(line: String, colors: [CellColor], row: Int) -> [DetectedLink] {
        // Start with the base text-only scan for URLs.
        var links = scan(line: line, row: row).filter { $0.url.hasPrefix("http") }

        // Find file extensions in the line and expand by color.
        let exts = fileExtensions.joined(separator: "|")
        // Match the extension as a token boundary inside the line.
        guard let extRegex = try? NSRegularExpression(
            pattern: "\\.(?:\(exts))(?=$|[\\s)>\\]\"',;:.!?])",
            options: [.caseInsensitive]
        ) else {
            return links
        }
        let nsLine = line as NSString
        let matches = extRegex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))

        for match in matches {
            // The extension match ends at this position.
            let extEnd = match.range.location + match.range.length - 1
            guard extEnd < colors.count else { continue }

            // Inspect the color of the last char of the extension.
            let extColor = colors[extEnd]

            let startCol: Int
            let endCol: Int

            // Whitespace boundary: always compute as baseline.
            var wsStart = match.range.location
            while wsStart > 0 {
                let ch = nsLine.substring(with: NSRange(location: wsStart - 1, length: 1))
                if ch == " " || ch == "\t" { break }
                wsStart -= 1
            }

            if !extColor.isDefault {
                // Color-aware expansion: walk left and right while cells share
                // this color. This captures filenames with spaces.
                var s = extEnd
                while s > 0 && colors[s - 1] == extColor {
                    s -= 1
                }
                var e = extEnd
                while e + 1 < colors.count && e + 1 < nsLine.length && colors[e + 1] == extColor {
                    e += 1
                }
                let colorSpan = e - s + 1
                if colorSpan > 80 || s == 0 {
                    // Color expansion covered too much (likely all text is the
                    // same color, e.g., tmux pane fg). Fall back to whitespace.
                    startCol = wsStart
                    endCol = extEnd
                } else {
                    startCol = s
                    endCol = e
                }
            } else {
                // No color hint — use whitespace boundary.
                startCol = wsStart
                endCol = extEnd
            }

            // Sanity: must have content
            guard endCol >= startCol else { continue }
            let textRange = NSRange(location: startCol, length: endCol - startCol + 1)
            guard textRange.location + textRange.length <= nsLine.length else { continue }
            let text = nsLine.substring(with: textRange)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.contains(".") else { continue }

            // Skip overlap with already-detected URLs.
            let overlaps = links.contains { link in
                link.row == row && !(link.endCol < startCol || link.startCol > endCol)
            }
            if overlaps { continue }

            links.append(DetectedLink(
                row: row,
                startCol: startCol,
                endCol: endCol,
                url: "file:\(text)"
            ))
        }
        return links
    }

    /// Scan multiple rows with color info.
    static func scanRows(_ rows: [String], colors: [[CellColor]]) -> [DetectedLink] {
        var links: [DetectedLink] = []
        for (i, line) in rows.enumerated() {
            let rowColors = i < colors.count ? colors[i] : []
            links.append(contentsOf: scan(line: line, colors: rowColors, row: i))
        }
        return links
    }
}
