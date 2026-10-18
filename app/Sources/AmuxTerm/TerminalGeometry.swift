import AppKit
import CoreText

/// Cell and grid sizing, shared by the view (on every resize) and the app
/// delegate (at launch, before the view exists).
///
/// Launch matters: the PTY attaches to tmux before the window has a size.
/// Attaching at a placeholder grid made tmux shrink every window and grow it
/// back a moment later — which, for a zoomed window, left the hidden grid
/// lopsided. Computing the real grid up front means tmux sees one size.
enum TerminalGeometry {
    /// The terminal font.
    static func baseFont() -> CTFont {
        CTFontCreateWithName("Menlo" as CFString, 14, nil)
    }

    /// One character cell for a monospaced font, in points (rounded up).
    static func cellSize(for font: CTFont) -> CGSize {
        let height = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        var chars: [UniChar] = [0x4D] // 'M'
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
        return CGSize(width: ceil(advance.width), height: height)
    }

    /// Whole cells that fit in a view. Pure.
    static func grid(viewSize: CGSize, cell: CGSize) -> (cols: Int, rows: Int) {
        guard cell.width > 0, cell.height > 0 else { return (1, 1) }
        return (max(1, Int(viewSize.width / cell.width)), max(1, Int(viewSize.height / cell.height)))
    }
}
