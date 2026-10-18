/// Window resize: when the amux window changes size, every pane must be
/// re-tiled to fill the new window — whether the grid is showing or a pane
/// is zoomed full-screen at the time.
///
/// Drives the real path: a real tmux client attached to the session (inside
/// a pane of a "viewer" session on the test server) is resized, tmux fires
/// the client-resized hook amux installed, and the real amux-cli re-tiles.

import Foundation
import AmuxLib

enum ResizeTests {
    struct Geometry {
        let windowW: Int, windowH: Int
        let maxRight: Int, maxBottom: Int, zoomed: Bool
        var fillsWindow: Bool { maxRight == windowW - 1 && maxBottom == windowH - 1 }
    }

    private static func geometry(_ session: String) -> Geometry {
        let out = tmux("list-panes", "-t", session, "-F",
                       "#{pane_left} #{pane_top} #{pane_width} #{pane_height} #{window_width} #{window_height} #{window_zoomed_flag}").stdout
        var maxRight = 0, maxBottom = 0, winW = 0, winH = 0, zoomed = false
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ").compactMap { Int($0) }
            guard f.count == 7 else { continue }
            maxRight = max(maxRight, f[0] + f[2] - 1)
            maxBottom = max(maxBottom, f[1] + f[3] - 1)
            winW = f[4]; winH = f[5]; zoomed = f[6] == 1
        }
        return Geometry(windowW: winW, windowH: winH, maxRight: maxRight, maxBottom: maxBottom, zoomed: zoomed)
    }

    private static func paneRects(_ session: String) -> [String] {
        tmux("list-panes", "-t", session, "-F",
             "#{pane_id}@#{pane_left},#{pane_top}:#{pane_width}x#{pane_height}")
            .stdout.split(separator: "\n").map(String.init)
    }

    private static func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return cond()
    }

    /// Attach a real client to `session`, sized by the viewer window.
    private static func attachViewer(to session: String, cols: Int, rows: Int) -> String {
        let viewer = "\(session)-viewer"
        tmux("new-session", "-d", "-s", viewer, "-x", String(cols), "-y", String(rows),
             "env -u TMUX tmux -L \(testTmuxSocket) attach -t \(session)")
        return viewer
    }

    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // Grid showing: resize wider, then narrower.
        do {
            let ts = TestSession(paneCount: 4)
            let viewer = attachViewer(to: ts.name, cols: 120, rows: 40)
            defer { tmux("kill-session", "-t", viewer) }
            _ = waitFor(3) { geometry(ts.name).windowW == 120 }
            for width in [160, 100] {
                tmux("resize-window", "-t", viewer, "-x", String(width), "-y", "40")
                let ok = waitFor(3) {
                    let g = geometry(ts.name)
                    return g.windowW == width && g.fillsWindow
                }
                let g = geometry(ts.name)
                check("resize-grid-\(width)-fills", ok,
                      "window \(g.windowW)x\(g.windowH), panes reach col \(g.maxRight) row \(g.maxBottom)")
            }
        }

        // Zoomed while resized: the zoomed pane fills, and unzooming shows a
        // grid that fills the new size. Five panes: an uneven grid is where
        // tmux's proportional squeeze drifts from amux's layout (a 2x2 grid
        // scales evenly and would hide the bug).
        do {
            let ts = TestSession(paneCount: 5)
            let viewer = attachViewer(to: ts.name, cols: 120, rows: 40)
            defer { tmux("kill-session", "-t", viewer) }
            _ = waitFor(3) { geometry(ts.name).windowW == 120 }
            try? Tmux.applyLayout(ts.name, event: .zoomIn)
            tmux("resize-window", "-t", viewer, "-x", "170", "-y", "44")
            let zoomedOK = waitFor(3) {
                let g = geometry(ts.name)
                return g.windowW == 170 && g.zoomed && g.fillsWindow
            }
            var g = geometry(ts.name)
            check("resize-zoomed-fills", zoomedOK,
                  "window \(g.windowW)x\(g.windowH) zoomed=\(g.zoomed), reach col \(g.maxRight) row \(g.maxBottom)")
            try? Tmux.applyLayout(ts.name, event: .zoomOut)
            let gridOK = waitFor(3) {
                let g = geometry(ts.name)
                return !g.zoomed && g.fillsWindow
            }
            g = geometry(ts.name)
            check("resize-zoomed-then-unzoom-fills", gridOK,
                  "window \(g.windowW)x\(g.windowH) zoomed=\(g.zoomed), reach col \(g.maxRight) row \(g.maxBottom)")
            // Filling isn't enough: while zoomed, tmux squeezes the hidden
            // grid proportionally, and that stale shape (e.g. 47/94/48 where
            // amux's grid is 63/63/63) must not survive zooming out. The
            // unzoomed layout must be exactly what a fresh re-tile produces.
            let afterUnzoom = paneRects(ts.name)
            try? Tmux.applyLayout(ts.name, event: .resize)
            let retiled = paneRects(ts.name)
            check("resize-zoomed-then-unzoom-is-amux-grid", afterUnzoom == retiled,
                  "after unzoom \(afterUnzoom), fresh grid \(retiled)")
        }

        // The launch squeeze: amux attaches at a placeholder size before the
        // window reports its real one, so tmux shrinks the window and grows
        // it back. While zoomed nothing re-tiles; tmux's proportional
        // rounding leaves the hidden grid lopsided (seen live: 47/94/48 where
        // amux's grid is 63/63/63). Zooming out must restore amux's grid.
        do {
            let ts = TestSession(paneCount: 5)
            let viewer = attachViewer(to: ts.name, cols: 191, rows: 81)
            defer { tmux("kill-session", "-t", viewer) }
            _ = waitFor(3) { geometry(ts.name).windowW == 191 }
            try? Tmux.applyLayout(ts.name, event: .resize)
            try? Tmux.applyLayout(ts.name, event: .zoomIn)
            for (w, h) in [(120, 40), (37, 12), (191, 81)] {
                tmux("resize-window", "-t", viewer, "-x", String(w), "-y", String(h))
                _ = waitFor(3) { geometry(ts.name).windowW == w }
            }
            try? Tmux.applyLayout(ts.name, event: .zoomOut)
            let afterUnzoom = paneRects(ts.name)
            try? Tmux.applyLayout(ts.name, event: .resize)
            let retiled = paneRects(ts.name)
            check("launch-squeeze-then-unzoom-is-amux-grid", afterUnzoom == retiled,
                  "after unzoom \(afterUnzoom), fresh grid \(retiled)")
        }

        print("ResizeTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
