import Foundation
import CoreGraphics

/// Pure function for the scroll-wheel pixel accumulator.
///
/// macOS NSEvent gives a scroll delta in two flavors:
///   - Precise (trackpad): `scrollingDeltaY` is in raw pixel units.
///   - Imprecise (wheel): `scrollingDeltaY` is in tick units, pre-multiplied
///     by the user's macOS "Scrolling speed" preference.
///
/// We want both to drive a per-cell scroll count proportional to finger
/// movement (and to honor `scrollingDeltaY`'s sub-cell precision). This
/// matches Ghostty's `pending_scroll_y` (Surface.zig:3400-3469) and iTerm2's
/// `iTermScrollAccumulator`: accumulate pixel-equivalents, emit only the
/// whole-cell portion, carry the sub-cell remainder to the next event.
///
/// For imprecise events on Darwin, Ghostty floors |deltaY| to >= 1 to
/// compensate for AppKit emitting micro-deltas; we do the same.
enum ScrollAccumulator {
    /// Step the accumulator one NSEvent.
    ///
    /// - Parameters:
    ///   - deltaY: NSEvent.scrollingDeltaY. Sign indicates direction.
    ///   - precise: NSEvent.hasPreciseScrollingDeltas.
    ///   - currentAccumulator: pixels left over from the previous call.
    ///   - cellHeight: pixel height of one terminal cell.
    ///   - shiftMult: multiplier applied to pixel delta (1 normal, 3 with shift).
    /// - Returns: `cells` is the whole-cell count to scroll (positive = up,
    ///   negative = down). `newAccumulator` is the sub-cell remainder the
    ///   caller should pass into the next step.
    static func step(
        deltaY: CGFloat,
        precise: Bool,
        currentAccumulator: CGFloat,
        cellHeight: CGFloat,
        shiftMult: CGFloat
    ) -> (cells: Int, newAccumulator: CGFloat) {
        guard cellHeight > 0, deltaY != 0 else {
            return (0, currentAccumulator)
        }

        // Direction-change reset: leftover sub-cell from a reversed scroll
        // would replay backward on a tiny first event in the new direction.
        var accum = currentAccumulator
        if (deltaY > 0 && accum < 0) || (deltaY < 0 && accum > 0) {
            accum = 0
        }

        let pixels: CGFloat
        if precise {
            pixels = deltaY * shiftMult
        } else {
            // Floor magnitude to >=1 (Ghostty Darwin special case).
            let d: CGFloat = deltaY > 0 ? max(deltaY, 1) : min(deltaY, -1)
            pixels = d * cellHeight * shiftMult
        }
        accum += pixels

        // Int() truncates toward zero, symmetric for positive and negative.
        let cells = Int(accum / cellHeight)
        accum -= CGFloat(cells) * cellHeight
        return (cells, accum)
    }
}
