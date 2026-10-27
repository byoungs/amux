// Sticky.swift — Pane order across layout changes.
// Pure algorithm module: no tmux dependency, no I/O.
//
// A pane's number (its tmux index, what Cmd-1..9 selects) is its slot in
// reading order: top row left to right, bottom row, then the right column.
// Every event keeps the panes in their current order and re-tiles them into
// the standard grid for the new count. A new pane goes last; closing a pane
// moves each later pane down one number. Geometry never decides placement.
// See docs/sticky-panes.md.

/// Events that trigger a layout recomputation.
public enum StickyLayoutEvent {
    /// A new pane was added with the given ID.
    case add(Int)
    /// A pane with the given ID was removed.
    case remove(Int)
    /// Window dimensions or the pane set changed. Also used for start,
    /// attach, space-switch, and pane exit (tmux has already dropped it).
    case resize
}

/// Desired pane IDs by slot, given the current IDs in tmux index order.
///
/// tmux inserts a split pane right after its source, so on `.add` the new
/// pane may already sit mid-list; it moves to the end either way.
public func paneOrder(current: [Int], event: StickyLayoutEvent) -> [Int] {
    switch event {
    case .resize:
        return current
    case .add(let newId):
        return current.filter { $0 != newId } + [newId]
    case .remove(let removedId):
        return current.filter { $0 != removedId }
    }
}

// MARK: - Tests

#if DEBUG
public enum StickyTests {
    public static func runAll() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // resize keeps the order
        do {
            let order = paneOrder(current: [10, 11, 12, 13], event: .resize)
            check("resize keeps order", order == [10, 11, 12, 13], "got \(order)")
        }

        // add puts the new pane last
        do {
            let order = paneOrder(current: [10, 11, 12], event: .add(99))
            check("add appends", order == [10, 11, 12, 99], "got \(order)")
        }

        // add when tmux already inserted the split after its source
        do {
            let order = paneOrder(current: [10, 99, 11, 12], event: .add(99))
            check("add moves joined pane last", order == [10, 11, 12, 99], "got \(order)")
        }

        // remove closes the gap; later panes move down one
        do {
            let order = paneOrder(current: [10, 11, 12, 13, 14], event: .remove(10))
            check("remove first", order == [11, 12, 13, 14], "got \(order)")
            let mid = paneOrder(current: [10, 11, 12, 13, 14], event: .remove(12))
            check("remove middle", mid == [10, 11, 13, 14], "got \(mid)")
        }

        // remove after tmux already dropped the pane
        do {
            let order = paneOrder(current: [10, 11, 13], event: .remove(12))
            check("remove already killed", order == [10, 11, 13], "got \(order)")
        }

        // Two closes in a row from a 9-pane grid (the 2026-10-26 report):
        // the last pane goes 9 → 8 → 7.
        do {
            let nine = [4, 10, 7, 6, 2, 3, 8, 1, 11]
            let eight = paneOrder(current: nine, event: .remove(4))
            let seven = paneOrder(current: eight, event: .remove(10))
            check("two closes eight", eight == [10, 7, 6, 2, 3, 8, 1, 11], "got \(eight)")
            check("two closes seven", seven == [7, 6, 2, 3, 8, 1, 11], "got \(seven)")
        }

        print("Sticky tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("Sticky tests failed") }
    }
}
#endif
