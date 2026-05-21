#if DEBUG
import Foundation
import CoreGraphics

enum ScrollAccumulatorTests {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String,
                   _ actual: (cells: Int, newAccumulator: CGFloat),
                   _ expected: (cells: Int, newAccumulator: CGFloat),
                   tolerance: CGFloat = 0.0001) {
            let cellsOK = actual.cells == expected.cells
            let accumOK = abs(actual.newAccumulator - expected.newAccumulator) < tolerance
            if cellsOK && accumOK {
                passed += 1
            } else {
                failed += 1
                print("FAIL: \(name): expected (cells=\(expected.cells), accum=\(expected.newAccumulator)), got (cells=\(actual.cells), accum=\(actual.newAccumulator))")
            }
        }

        let cellHeight: CGFloat = 17

        // Precise trackpad, small dy: stays sub-cell, returns 0.
        check("precise-small-delta",
              ScrollAccumulator.step(deltaY: 2, precise: true,
                                     currentAccumulator: 0,
                                     cellHeight: cellHeight, shiftMult: 1),
              (0, 2))

        // Precise trackpad, ten events of dy=2 cross a cell on the 9th.
        var acc: CGFloat = 0
        for _ in 0..<8 {
            let r = ScrollAccumulator.step(deltaY: 2, precise: true,
                                           currentAccumulator: acc,
                                           cellHeight: cellHeight, shiftMult: 1)
            acc = r.newAccumulator
        }
        let crossing = ScrollAccumulator.step(deltaY: 2, precise: true,
                                              currentAccumulator: acc,
                                              cellHeight: cellHeight, shiftMult: 1)
        check("precise-accumulates-to-one-cell",
              crossing, (1, 1))  // 9*2=18, 18-17=1

        // Precise fast flick (dy=50): crosses 2 cells, 16 left over.
        check("precise-fast-flick",
              ScrollAccumulator.step(deltaY: 50, precise: true,
                                     currentAccumulator: 0,
                                     cellHeight: cellHeight, shiftMult: 1),
              (2, 16))

        // Imprecise wheel click dy=1: 1*17 = 17 pixels = 1 cell exactly.
        check("imprecise-wheel-one-click",
              ScrollAccumulator.step(deltaY: 1, precise: false,
                                     currentAccumulator: 0,
                                     cellHeight: cellHeight, shiftMult: 1),
              (1, 0))

        // Imprecise wheel with macOS-amplified delta (dy=4): 4 cells.
        check("imprecise-wheel-amplified",
              ScrollAccumulator.step(deltaY: 4, precise: false,
                                     currentAccumulator: 0,
                                     cellHeight: cellHeight, shiftMult: 1),
              (4, 0))

        // Imprecise tiny dy gets floored to >=1 (Ghostty Darwin special case).
        check("imprecise-floor-to-one",
              ScrollAccumulator.step(deltaY: 0.4, precise: false,
                                     currentAccumulator: 0,
                                     cellHeight: cellHeight, shiftMult: 1),
              (1, 0))

        check("imprecise-floor-negative",
              ScrollAccumulator.step(deltaY: -0.4, precise: false,
                                     currentAccumulator: 0,
                                     cellHeight: cellHeight, shiftMult: 1),
              (-1, 0))

        // Shift multiplier × 3 turns a 1-tick wheel click into 3 cells.
        check("shift-wheel",
              ScrollAccumulator.step(deltaY: 1, precise: false,
                                     currentAccumulator: 0,
                                     cellHeight: cellHeight, shiftMult: 3),
              (3, 0))

        // Shift trackpad: dy=10 × 3 = 30 pixels, 1 cell + 13 remainder.
        check("shift-trackpad",
              ScrollAccumulator.step(deltaY: 10, precise: true,
                                     currentAccumulator: 0,
                                     cellHeight: cellHeight, shiftMult: 3),
              (1, 13))

        // Direction reverse: leftover positive accumulator resets to 0
        // before adding the negative delta.
        check("direction-reverse-resets",
              ScrollAccumulator.step(deltaY: -2, precise: true,
                                     currentAccumulator: 10,
                                     cellHeight: cellHeight, shiftMult: 1),
              (0, -2))

        // Direction reverse for imprecise: accumulator resets, then floor
        // applied to deltaY, then pixel conversion. -1 * 17 = -17 = -1 cell.
        check("direction-reverse-imprecise",
              ScrollAccumulator.step(deltaY: -0.5, precise: false,
                                     currentAccumulator: 5,
                                     cellHeight: cellHeight, shiftMult: 1),
              (-1, 0))

        // Zero deltaY is a no-op (and preserves the accumulator).
        check("zero-delta-noop",
              ScrollAccumulator.step(deltaY: 0, precise: true,
                                     currentAccumulator: 7,
                                     cellHeight: cellHeight, shiftMult: 1),
              (0, 7))

        // Negative precise large flick: -50 pixels = -2 cells + -16 remainder.
        check("precise-fast-flick-down",
              ScrollAccumulator.step(deltaY: -50, precise: true,
                                     currentAccumulator: 0,
                                     cellHeight: cellHeight, shiftMult: 1),
              (-2, -16))

        // Zero cellHeight is a defensive no-op.
        check("zero-cell-height-noop",
              ScrollAccumulator.step(deltaY: 100, precise: true,
                                     currentAccumulator: 3,
                                     cellHeight: 0, shiftMult: 1),
              (0, 3))

        print("ScrollAccumulator tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("ScrollAccumulator tests failed") }
    }
}
#endif
