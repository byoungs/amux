import AppKit
import CoreText

/// Cell and grid sizing, shared by the view (on every resize) and the window
/// owner (at launch, before the view exists).
///
/// Launch matters: the PTY attaches to tmux before the window has a size.
/// Attaching at a placeholder grid made tmux shrink every window and grow it
/// back a moment later — which, for a zoomed window, left the hidden grid
/// lopsided. Computing the real grid up front means tmux sees one size.
enum TerminalGeometry {
    /// The terminal font from appearance.json, or Menlo 14.
    static func font(settings: TerminalAppearance?) -> CTFont {
        CTFontCreateWithName((settings?.fontName ?? "Menlo") as CFString,
                             CGFloat(settings?.fontSize ?? 14), nil)
    }

    /// Cell metrics for the terminal font and its spacing settings.
    static func metrics(settings: TerminalAppearance?) -> TerminalFontMetrics {
        TerminalFontMetrics(
            font: font(settings: settings),
            horizontalSpacing: CGFloat(settings?.horizontalSpacing ?? 1),
            verticalSpacing: CGFloat(settings?.verticalSpacing ?? 1))
    }

    /// Whole cells that fit in a view. Pure.
    static func grid(viewSize: CGSize, cell: CGSize) -> (cols: Int, rows: Int) {
        guard cell.width > 0, cell.height > 0 else { return (1, 1) }
        return (max(1, Int(viewSize.width / cell.width)), max(1, Int(viewSize.height / cell.height)))
    }
}
