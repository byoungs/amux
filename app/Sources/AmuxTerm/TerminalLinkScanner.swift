import Foundation

/// Translate libvterm cells to text for detection, retaining the exact clickable
/// cells. UTF-16 regex offsets must never be used directly as screen columns.
enum TerminalLinkScanner {
    static func scan(_ terminal: VTerminal) -> [DetectedLink] {
        var rows: [String] = []
        var colors: [[LinkDetector.CellColor]] = []
        var starts: [[Int]] = [], ends: [[Int]] = []
        for row in 0..<terminal.rows {
            var text = ""
            var rowColors: [LinkDetector.CellColor] = []
            var rowStarts: [Int] = [], rowEnds: [Int] = []
            for col in 0..<terminal.cols {
                let cell = terminal.cell(row: row, col: col)
                // libvterm marks the second half of a wide glyph with -1.
                if cell.chars.0 == UInt32.max { continue }
                let glyph = VTerminal.cellString(cell)
                let value = glyph.isEmpty ? " " : glyph
                text += value
                let count = value.utf16.count
                rowStarts += Array(repeating: col, count: count)
                rowEnds += Array(repeating: min(terminal.cols - 1, col + max(1, Int(cell.width)) - 1), count: count)
                let (r, g, b) = VTerminal.colorRGB(cell.fg, screen: terminal.screen)
                let color = LinkDetector.CellColor(rgb: UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b),
                                                   isDefault: cell.fg.type & 0x02 != 0)
                rowColors += Array(repeating: color, count: count)
            }
            rows.append(text); colors.append(rowColors)
            starts.append(rowStarts); ends.append(rowEnds)
        }
        return LinkDetector.scanScreen(rows: rows, colors: colors, cols: terminal.cols,
                                       cellStarts: starts, cellEnds: ends)
    }
}
