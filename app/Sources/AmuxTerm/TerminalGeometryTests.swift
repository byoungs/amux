import Foundation

#if DEBUG
enum TerminalGeometryTests {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        let cell = CGSize(width: 9, height: 17)
        // The live window: 1720x1378pt of content is 191x81 cells.
        let g = TerminalGeometry.grid(viewSize: CGSize(width: 1720, height: 1378), cell: cell)
        check("grid from content size", g.cols == 191 && g.rows == 81, "\(g)")
        // Partial cells don't count.
        let p = TerminalGeometry.grid(viewSize: CGSize(width: 17.9, height: 33.9), cell: cell)
        check("partial cells dropped", p.cols == 1 && p.rows == 1, "\(p)")
        // A zero-size view (before layout) still yields a usable 1x1 grid.
        let z = TerminalGeometry.grid(viewSize: .zero, cell: cell)
        check("zero size clamps to 1x1", z.cols == 1 && z.rows == 1, "\(z)")

        let real = TerminalGeometry.metrics(settings: nil)
        check("menlo cell is a sane size",
              real.width >= 6 && real.width <= 12 && real.height >= 12 && real.height <= 24,
              "\(real.width)x\(real.height)")

        print("TerminalGeometry tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("TerminalGeometry tests failed") }
    }
}
#endif
