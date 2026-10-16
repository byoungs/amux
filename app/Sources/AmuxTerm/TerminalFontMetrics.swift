import CoreText
import Foundation

/// Character geometry compatible with iTerm2's conventional font metrics.
/// See iTerm2 v3.7.3 FontSizeEstimator and PTYFontInfo: round the glyph advance
/// before spacing, and place the baseline on the cell's integer grid.
struct TerminalFontMetrics {
    let width: CGFloat
    let height: CGFloat
    let baseline: CGFloat

    init(font: CTFont, horizontalSpacing: CGFloat = 1, verticalSpacing: CGFloat = 1) {
        var character: UniChar = 0x57 // W, the reference used by iTerm2
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        width = max(1, ceil(max(1, advance.width.rounded()) * horizontalSpacing))

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        height = max(1, ceil(ceil(max(1, ascent + descent) + leading) * verticalSpacing))
        let descenderAdjustment: CGFloat = (CTFontCopyPostScriptName(font) as String) == "Monaco" ? 0 : 0.5
        baseline = height - (floor(leading) - floor(-descent + descenderAdjustment))
    }
}

#if DEBUG
enum TerminalFontMetricsTests {
    static func runAll() {
        let monaco = CTFontCreateWithName("Monaco" as CFString, 12, nil)
        let metrics = TerminalFontMetrics(font: monaco)
        precondition(metrics.width == 7, "Monaco 12 must use iTerm2's 7pt columns, not 8pt")
        precondition(metrics.height == 17, "Monaco 12 must use 17pt rows")
        precondition(metrics.baseline == 13, "Monaco 12 baseline must sit 13pt below the row top")
        let menlo = TerminalFontMetrics(font: CTFontCreateWithName("Menlo" as CFString, 13, nil))
        precondition(menlo.width == 8 && menlo.height == 16 && menlo.baseline == 13,
                     "Menlo 13 must keep an integer baseline")
        let spaced = TerminalFontMetrics(font: monaco, horizontalSpacing: 1.2, verticalSpacing: 1.1)
        precondition(spaced.width == 9 && spaced.height == 19,
                     "Spacing applies to rounded base cells")
        print("TerminalFontMetrics tests: 5 passed")
    }
}
#endif
