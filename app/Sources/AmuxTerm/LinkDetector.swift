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
/// 1. URLs (http:// or https://), including URLs an Ink-based TUI
///    (Claude Code) soft-wrapped across rows — see `scanScreen`.
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

    // MARK: - URL detection

    /// Characters that may appear in a plain-text URL (RFC 3986-ish).
    /// Deliberately excludes quotes, parens, and angle/square brackets
    /// (common wrappers around URLs in prose) and everything non-ASCII —
    /// tmux pane borders (│) and Claude Code's truncation ellipsis (…)
    /// must terminate a match, never join it.
    /// Keep in sync with the character class in `urlPattern`.
    private static let urlCharacters =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~:/?#@!$&*+,;=%-"

    /// `urlCharacters` as a regex character class ('-' last so it is literal).
    private static let urlPattern = "https?://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+"

    private static let urlRegex = try? NSRegularExpression(pattern: urlPattern)

    private static let urlCharacterUnits: Set<unichar> = Set(urlCharacters.utf16)

    /// Sentence punctuation that trails a URL in prose ("see https://x.com.")
    /// but is almost never the final character of the URL itself.
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// A raw URL match within a single row, before wrap joining and
    /// trailing-punctuation cleanup.
    private struct URLFragment {
        let startCol: Int
        let endCol: Int
        let text: String
    }

    private static func urlFragments(in line: String) -> [URLFragment] {
        guard let regex = urlRegex, !line.isEmpty else { return [] }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        return matches.map { match in
            URLFragment(
                startCol: match.range.location,
                endCol: match.range.location + match.range.length - 1,
                text: nsLine.substring(with: match.range)
            )
        }
    }

    private static func strippingTrailingPunctuation(_ url: String) -> (url: String, dropped: Int) {
        var trimmed = url
        var dropped = 0
        while let last = trimmed.last, trailingPunctuation.contains(last) {
            trimmed.removeLast()
            dropped += 1
        }
        return (trimmed, dropped)
    }

    // MARK: - File detection

    private static let fileRegex: NSRegularExpression? = {
        let exts = fileExtensions.joined(separator: "|")
        let pattern = "(?:^|(?<=\\s))([\\w./_-]+\\.(?:\(exts)))(?=$|\\s|[)>\\]\"',;:.!?])"
        return try? NSRegularExpression(pattern: pattern)
    }()

    // MARK: - Single-line scanning

    /// Scan a single line of text for links.
    static func scan(line: String, row: Int) -> [DetectedLink] {
        guard !line.isEmpty else { return [] }
        var links: [DetectedLink] = []
        var coveredRanges: [NSRange] = []
        let nsLine = line as NSString

        for fragment in urlFragments(in: line) {
            let (url, dropped) = strippingTrailingPunctuation(fragment.text)
            guard !url.hasSuffix("://") else { continue }
            links.append(DetectedLink(
                row: row,
                startCol: fragment.startCol,
                endCol: fragment.endCol - dropped,
                url: url
            ))
            coveredRanges.append(NSRange(
                location: fragment.startCol,
                length: fragment.endCol - fragment.startCol + 1
            ))
        }

        guard let regex = fileRegex else { return links }
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        for match in matches {
            // Use capture group 1 (the filename without leading whitespace)
            let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range

            // Skip if overlaps with an already-detected URL
            let overlaps = coveredRanges.contains { existing in
                NSIntersectionRange(existing, range).length > 0
            }
            if overlaps { continue }

            links.append(DetectedLink(
                row: row,
                startCol: range.location,
                endCol: range.location + range.length - 1,
                url: "file:\(nsLine.substring(with: range))"
            ))
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

    // MARK: - Screen scanning (wrapped-URL joining)

    /// Scan a full screen of rows, joining URLs that wrap across rows.
    ///
    /// Claude Code (and other Ink-based TUIs) pre-wrap output to the pane
    /// width, hard-breaking long URLs mid-string; tmux leaves no wrap marker
    /// on those rows. Joining is therefore heuristic: a URL fragment that
    /// runs flush into a pane border (│) or the right screen edge is treated
    /// as wrapped, and the first run of URL characters on the next row —
    /// within the same pane segment, after any wrap indent — is appended.
    /// One DetectedLink is emitted per row fragment, all carrying the full
    /// joined URL, so a click on any fragment opens the complete link.
    ///
    /// `rows` are the visible rows with trailing spaces trimmed; `cols` is
    /// the terminal width (used to decide whether a fragment reaches the
    /// right screen edge).
    static func scanScreen(rows: [String], colors: [[CellColor]], cols: Int) -> [DetectedLink] {
        let fragmentsByRow = rows.map { urlFragments(in: $0) }
        var consumed: Set<Int> = []  // row * 10_000 + startCol
        var links: [DetectedLink] = []

        for (row, fragments) in fragmentsByRow.enumerated() {
            for fragment in fragments {
                if consumed.contains(row * 10_000 + fragment.startCol) { continue }

                var url = fragment.text
                var spans = [(row: row, startCol: fragment.startCol, endCol: fragment.endCol)]
                var cur = spans[0]
                while cur.row + 1 < rows.count,
                    endsFlush(rows[cur.row], endCol: cur.endCol, cols: cols),
                    let cont = continuationRun(
                        in: rows[cur.row + 1],
                        from: segmentStart(rows[cur.row], before: cur.startCol)
                    )
                {
                    url += cont.text
                    let span = (row: cur.row + 1, startCol: cont.startCol, endCol: cont.endCol)
                    spans.append(span)
                    for f in fragmentsByRow[span.row]
                    where f.startCol >= span.startCol && f.startCol <= span.endCol {
                        consumed.insert(span.row * 10_000 + f.startCol)
                    }
                    cur = span
                }

                let (cleaned, dropped) = strippingTrailingPunctuation(url)
                guard !cleaned.hasSuffix("://") else { continue }
                if dropped > 0 {
                    var last = spans.removeLast()
                    last.endCol -= dropped
                    if last.endCol >= last.startCol { spans.append(last) }
                }
                for span in spans {
                    links.append(DetectedLink(
                        row: span.row, startCol: span.startCol, endCol: span.endCol, url: cleaned
                    ))
                }
            }
        }

        // File links (color-aware), skipping anything that overlaps a URL span.
        for (row, line) in rows.enumerated() {
            let rowColors = row < colors.count ? colors[row] : []
            let fileLinks = scan(line: line, colors: rowColors, row: row)
                .filter { $0.url.hasPrefix("file:") }
            for file in fileLinks {
                let overlapsURL = links.contains { link in
                    link.row == row && !(link.endCol < file.startCol || link.startCol > file.endCol)
                }
                if !overlapsURL { links.append(file) }
            }
        }
        return links
    }

    /// Overlay explicit OSC 8 hyperlink spans on text-detected ones.
    /// Explicit spans carry the application's actual target, so any detected
    /// span overlapping one on its row is dropped.
    static func merging(explicit: [DetectedLink], detected: [DetectedLink]) -> [DetectedLink] {
        guard !explicit.isEmpty else { return detected }
        let kept = detected.filter { d in
            !explicit.contains { e in
                e.row == d.row && !(e.endCol < d.startCol || e.startCol > d.endCol)
            }
        }
        return explicit + kept
    }

    /// tmux vertical pane-border glyphs (single, heavy, double).
    private static func isVerticalBorder(_ unit: unichar) -> Bool {
        unit == 0x2502 || unit == 0x2503 || unit == 0x2551  // │ ┃ ║
    }

    /// True when the character after `endCol` is a pane border, or `endCol`
    /// is the last character of a row that reaches the right screen edge —
    /// i.e. the fragment fills its pane segment and may be wrapped.
    private static func endsFlush(_ line: String, endCol: Int, cols: Int) -> Bool {
        let nsLine = line as NSString
        let next = endCol + 1
        if next < nsLine.length {
            return isVerticalBorder(nsLine.character(at: next))
        }
        return nsLine.length == cols
    }

    /// Column where the pane segment containing `col` starts: just after the
    /// nearest border glyph to the left, or 0.
    private static func segmentStart(_ line: String, before col: Int) -> Int {
        let nsLine = line as NSString
        var i = min(col, nsLine.length) - 1
        while i >= 0 {
            if isVerticalBorder(nsLine.character(at: i)) { return i + 1 }
            i -= 1
        }
        return 0
    }

    /// The first run of URL characters on a continuation row, starting at the
    /// wrapped fragment's pane segment (leading wrap indent skipped). Nil when
    /// the segment is empty or starts with something that can't continue a URL.
    private static func continuationRun(
        in line: String, from segLeft: Int
    ) -> (text: String, startCol: Int, endCol: Int)? {
        let nsLine = line as NSString
        var start = segLeft
        while start < nsLine.length, nsLine.character(at: start) == 0x20 { start += 1 }
        guard start < nsLine.length else { return nil }
        var end = start
        while end < nsLine.length, urlCharacterUnits.contains(nsLine.character(at: end)) { end += 1 }
        guard end > start else { return nil }
        let text = nsLine.substring(with: NSRange(location: start, length: end - start))
        return (text, start, end - 1)
    }
}
