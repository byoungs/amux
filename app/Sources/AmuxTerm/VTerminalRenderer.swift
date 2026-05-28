// VTerminalRenderer.swift — simple cell-grid renderer for scan-mode tiles.
//
// Production TerminalView.draw uses a CGContext-based per-cell path that
// renders attributes, cursor, etc. This renderer is intentionally simpler:
// monospaced font, foreground color only, no cursor. It's used by scan-mode
// tile views which only need a readable static snapshot.

import AppKit

enum VTerminalRenderer {
    /// Render every cell of `terminal` into `rect` using a monospaced font
    /// at `fontSize`. Caller is responsible for clipping if needed.
    static func render(terminal: VTerminal, in rect: NSRect, fontSize: CGFloat) {
        let font = NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let cellW = "M".size(withAttributes: [.font: font]).width
        let cellH = font.boundingRectForFont.height
        guard cellW > 0, cellH > 0 else { return }
        let maxCols = min(terminal.cols, Int((rect.width / cellW).rounded(.down)))
        let maxRows = min(terminal.rows, Int((rect.height / cellH).rounded(.down)))
        for row in 0..<maxRows {
            for col in 0..<maxCols {
                let cell = terminal.cell(row: row, col: col)
                let s = VTerminal.cellString(cell)
                guard !s.isEmpty else { continue }
                let (r, g, b) = VTerminal.colorRGB(cell.fg, screen: terminal.screen)
                let color = VTerminal.cachedColor(r: r, g: g, b: b)
                let origin = NSPoint(
                    x: rect.minX + CGFloat(col) * cellW,
                    y: rect.minY + CGFloat(row) * cellH)
                (s as NSString).draw(at: origin, withAttributes: [
                    .font: font,
                    .foregroundColor: color,
                ])
            }
        }
    }
}
