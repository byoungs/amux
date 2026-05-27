// Sticky.swift — Spatial pane matching for preserving pane positions during layout changes.
// Pure algorithm module: no tmux dependency, no I/O.

// Pane is defined in Layout.swift.

/// Events that trigger a layout recomputation.
public enum StickyLayoutEvent {
    /// A new pane was added with the given ID.
    case add(Int)
    /// A pane with the given ID was removed.
    case remove(Int)
    /// Window dimensions changed. Also used for start, attach, and space-switch.
    case resize
}

/// A pane's current and previous center coordinates.
public struct PaneCenter {
    public var id: Int
    public var cx: Int
    public var cy: Int
    public var prevCx: Int?
    public var prevCy: Int?

    public init(id: Int, cx: Int, cy: Int, prevCx: Int? = nil, prevCy: Int? = nil) {
        self.id = id
        self.cx = cx
        self.cy = cy
        self.prevCx = prevCx
        self.prevCy = prevCy
    }
}

/// A grid slot's center coordinates.
public struct SlotCenter {
    public var cx: Int
    public var cy: Int

    public init(cx: Int, cy: Int) {
        self.cx = cx
        self.cy = cy
    }
}

/// Match panes to grid slots by minimum geometric displacement.
///
/// Uses greedy nearest-first assignment (sufficient for <= 9 panes;
/// a Hungarian algorithm would be optimal but unnecessary at this scale).
///
/// - `panes`: existing panes with current (and optional previous) centers
/// - `slots`: new grid slot centers (one per slot in the new layout)
/// - `goingUp`: if true, prefer previous centers for matching (snap-back)
///
/// Returns array of length `slots.count`. Each entry is the pane ID
/// assigned to that slot, or `nil` if the slot is unoccupied (for new panes).
public func matchPanesToSlots(
    panes: [PaneCenter],
    slots: [SlotCenter],
    goingUp: Bool
) -> [Int?] {
    var result = [Int?](repeating: nil, count: slots.count)
    var usedSlots = [Bool](repeating: false, count: slots.count)
    var usedPanes = [Bool](repeating: false, count: panes.count)

    var pairs: [(pi: Int, si: Int, dist: Int64)] = []
    for (pi, pane) in panes.enumerated() {
        let px: Int
        let py: Int
        if goingUp {
            px = pane.prevCx ?? pane.cx
            py = pane.prevCy ?? pane.cy
        } else {
            px = pane.cx
            py = pane.cy
        }
        for (si, slot) in slots.enumerated() {
            let dx = Int64(px - slot.cx)
            let dy = Int64(py - slot.cy)
            let dist = dx * dx + dy * dy
            pairs.append((pi: pi, si: si, dist: dist))
        }
    }

    pairs.sort { $0.dist < $1.dist }

    for pair in pairs {
        if usedPanes[pair.pi] || usedSlots[pair.si] {
            continue
        }
        result[pair.si] = panes[pair.pi].id
        usedPanes[pair.pi] = true
        usedSlots[pair.si] = true
    }

    return result
}

/// Compute the center point of a grid slot rectangle.
private func rectCenter(x: Int, y: Int, w: Int, h: Int) -> (Int, Int) {
    (x + w / 2, y + h / 2)
}

/// Structural matching for layout transitions.
///
/// When the layout shape changes (balanced <-> balanced+column), pure geometric
/// matching can misplace panes that need to jump columns. This function uses
/// structural rules instead.
///
/// Falls back to geometric matching for cases that don't match these patterns.
public func matchPanesStructural(
    panes: [PaneCenter],
    slots: [SlotCenter],
    prevCount: Int,
    newCount: Int
) -> [Int?] {
    let prevBalanced = prevCount >= 2 && prevCount.isMultiple(of: 2)
    let newBalanced = newCount >= 2 && newCount.isMultiple(of: 2)
    let prevHasColumn = prevCount >= 3 && prevCount % 2 == 1
    let newHasColumn = newCount >= 3 && newCount % 2 == 1

    // Adding: balanced+column -> balanced (3->4, 5->6, 7->8)
    if prevHasColumn && newBalanced && newCount == prevCount + 1 {
        return matchColumnPaneSplits(panes: panes, slots: slots, goingUp: true)
    }

    // Adding: balanced -> balanced+column (4->5, 6->7)
    if prevBalanced && newHasColumn && newCount == prevCount + 1 {
        return matchPanesToSlots(panes: panes, slots: Array(slots[..<panes.count]), goingUp: false)
    }

    // Removing: balanced+column -> balanced (5->4, 7->6)
    if prevHasColumn && newBalanced && newCount == prevCount - 1 {
        return matchSubstituteFillsGap(panes: panes, slots: slots, prevCount: prevCount)
    }

    // Removing: balanced -> balanced+column (6->5, 8->7)
    if prevBalanced && newHasColumn && newCount == prevCount - 1 {
        return matchColumnMateExpands(panes: panes, slots: slots, prevCount: prevCount)
    }

    // Default: geometric matching
    return matchPanesToSlots(panes: panes, slots: slots, goingUp: false)
}

/// When adding a pane to a balanced+column layout to make it balanced,
/// the lone column pane goes to the nearest slot in its nearest column.
private func matchColumnPaneSplits(
    panes: [PaneCenter],
    slots: [SlotCenter],
    goingUp: Bool
) -> [Int?] {
    let loneIdx = findLoneColumnPane(panes: panes)

    if let idx = loneIdx {
        let lone = panes[idx]

        let loneCy: Int
        if goingUp {
            loneCy = lone.prevCy ?? 0
        } else {
            loneCy = lone.cy
        }

        // Group slots by column (cluster by cx within 10px)
        var slotColumns: [(cx: Int, slots: [(si: Int, slot: SlotCenter)])] = []
        for (si, s) in slots.enumerated() {
            if let colIdx = slotColumns.firstIndex(where: { abs(s.cx - $0.cx) < 10 }) {
                slotColumns[colIdx].slots.append((si: si, slot: s))
            } else {
                slotColumns.append((cx: s.cx, slots: [(si: si, slot: s)]))
            }
        }

        // Find the column closest to the lone pane's cx
        let nearestCol = slotColumns.min(by: { abs(lone.cx - $0.cx) < abs(lone.cx - $1.cx) })

        if let col = nearestCol {
            // In that column, find the slot closest to the pane's vertical position
            let bestSlot = col.slots.min(by: { abs(loneCy - $0.slot.cy) < abs(loneCy - $1.slot.cy) })

            if let best = bestSlot {
                let bestSi = best.si

                // Match other panes to other slots
                let others: [PaneCenter] = panes.enumerated()
                    .filter { $0.offset != idx }
                    .map { $0.element }

                let otherSlots: [SlotCenter] = slots.enumerated()
                    .filter { $0.offset != bestSi }
                    .map { $0.element }

                let otherMatched = matchPanesToSlots(panes: others, slots: otherSlots, goingUp: false)

                // Reconstruct full result
                var result = [Int?](repeating: nil, count: slots.count)
                result[bestSi] = lone.id

                var otherIdx = 0
                for si in 0..<result.count {
                    if si == bestSi {
                        continue
                    }
                    if otherIdx < otherMatched.count {
                        result[si] = otherMatched[otherIdx]
                        otherIdx += 1
                    }
                }
                return result
            }
        }
    }

    return matchPanesToSlots(panes: panes, slots: slots, goingUp: false)
}

/// The right-column pane from the previous layout fills the gap left by the
/// removed pane. All other panes stay in their relative positions.
private func matchSubstituteFillsGap(
    panes: [PaneCenter],
    slots: [SlotCenter],
    prevCount: Int
) -> [Int?] {
    // The right-column pane is the one with the largest cx (rightmost).
    let substituteIdx = panes.enumerated()
        .max(by: { $0.element.cx < $1.element.cx })
        .map { $0.offset }

    if let subIdx = substituteIdx {
        let others: [PaneCenter] = panes.enumerated()
            .filter { $0.offset != subIdx }
            .map { $0.element }

        // Group others by column (cluster by cx within 10px)
        var columns: [(cx: Int, panes: [PaneCenter])] = []
        for p in others {
            if let colIdx = columns.firstIndex(where: { abs(p.cx - $0.cx) < 10 }) {
                columns[colIdx].panes.append(p)
            } else {
                columns.append((cx: p.cx, panes: [p]))
            }
        }
        columns.sort { $0.cx < $1.cx }

        // Group target slots by column (cluster by cx within 10px)
        var slotColumns: [(cx: Int, slots: [(si: Int, slot: SlotCenter)])] = []
        for (si, s) in slots.enumerated() {
            if let colIdx = slotColumns.firstIndex(where: { abs(s.cx - $0.cx) < 10 }) {
                slotColumns[colIdx].slots.append((si: si, slot: s))
            } else {
                slotColumns.append((cx: s.cx, slots: [(si: si, slot: s)]))
            }
        }
        slotColumns.sort { $0.cx < $1.cx }

        // Sort panes within each column by cy, and slots within each column by cy
        for i in 0..<columns.count {
            columns[i].panes.sort { $0.cy < $1.cy }
        }
        for i in 0..<slotColumns.count {
            slotColumns[i].slots.sort { $0.slot.cy < $1.slot.cy }
        }

        // Map pane columns to slot columns by horizontal order.
        var result = [Int?](repeating: nil, count: slots.count)
        for (paneCol, slotCol) in zip(columns, slotColumns) {
            let colPanes = paneCol.panes
            let colSlots = slotCol.slots.map { $0.slot }
            let colMatched = matchPanesToSlots(panes: colPanes, slots: colSlots, goingUp: false)
            for (colSi, paneId) in colMatched.enumerated() {
                if let id = paneId {
                    let actualSi = slotCol.slots[colSi].si
                    result[actualSi] = id
                }
            }
        }

        // Fill the unoccupied slot with the substitute
        for i in 0..<result.count {
            if result[i] == nil {
                result[i] = panes[subIdx].id
                break
            }
        }
        return result
    } else {
        return matchPanesToSlots(panes: panes, slots: slots, goingUp: false)
    }
}

/// The column-mate of the removed pane takes the full-height column slot.
/// The remaining panes fill the split slots.
private func matchColumnMateExpands(
    panes: [PaneCenter],
    slots: [SlotCenter],
    prevCount: Int
) -> [Int?] {
    let columnMateIdx = findLoneColumnPane(panes: panes)
    let fullHeightSlot = findLoneColumnSlot(slots: slots)

    if let mateIdx = columnMateIdx, let fhSlot = fullHeightSlot {
        let others: [PaneCenter] = panes.enumerated()
            .filter { $0.offset != mateIdx }
            .map { $0.element }

        let otherSlots: [SlotCenter] = slots.enumerated()
            .filter { $0.offset != fhSlot }
            .map { $0.element }

        let otherMatched = matchPanesToSlots(panes: others, slots: otherSlots, goingUp: false)

        // Reconstruct full result with column-mate at the full-height slot
        var result = [Int?](repeating: nil, count: slots.count)
        result[fhSlot] = panes[mateIdx].id

        var otherIdx = 0
        for si in 0..<result.count {
            if si == fhSlot {
                continue
            }
            if otherIdx < otherMatched.count {
                result[si] = otherMatched[otherIdx]
                otherIdx += 1
            }
        }
        return result
    } else {
        return matchPanesToSlots(panes: panes, slots: slots, goingUp: false)
    }
}

/// Find the slot that is alone in its column (no other slot shares a similar cx).
private func findLoneColumnSlot(slots: [SlotCenter]) -> Int? {
    for (i, s) in slots.enumerated() {
        let hasPartner = slots.enumerated().contains { (j, other) in
            j != i && abs(s.cx - other.cx) < 10
        }
        if !hasPartner {
            return i
        }
    }
    return nil
}

/// Find the pane that is alone in its column (no other pane shares a similar cx).
private func findLoneColumnPane(panes: [PaneCenter]) -> Int? {
    for (i, p) in panes.enumerated() {
        let hasPartner = panes.enumerated().contains { (j, other) in
            j != i && abs(p.cx - other.cx) < 10
        }
        if !hasPartner {
            return i
        }
    }
    return nil
}

/// Pure state transition: given current pane positions, an event, and window
/// dimensions, compute the new layout. This is the single source of truth for
/// both pane ordering and geometry.
public func computeLayout(
    current: [Pane],
    event: StickyLayoutEvent,
    windowW: Int,
    windowH: Int
) -> [Pane] {
    switch event {
    case .resize:
        return computeResize(current: current, windowW: windowW, windowH: windowH)
    case .add(let newId):
        return computeAdd(current: current, newId: newId, windowW: windowW, windowH: windowH)
    case .remove(let removedId):
        return computeRemove(current: current, removedId: removedId, windowW: windowW, windowH: windowH)
    }
}

/// Resize: rescale slots to the new dimensions while preserving the
/// current layout shape. Asks `currentShape` for the variant — never picks
/// a canonical template blindly. Without this, the `pane-exited` tmux hook
/// (which fires `.resize` immediately after every kill) would collapse a
/// right-full-3 back to standard left-full-3, shuffling the column-mate.
private func computeResize(current: [Pane], windowW: Int, windowH: Int) -> [Pane] {
    if current.isEmpty {
        return []
    }
    let shape = currentShape(panes: current)
    let rects = slotsFor(shape: shape, width: windowW, height: windowH)
    let slots: [SlotCenter] = rects.map { r in
        let (cx, cy) = rectCenter(x: r.x, y: r.y, w: r.w, h: r.h)
        return SlotCenter(cx: cx, cy: cy)
    }

    let paneCenters: [PaneCenter] = current.map { p in
        let (cx, cy) = rectCenter(x: p.x, y: p.y, w: p.w, h: p.h)
        return PaneCenter(id: p.id, cx: cx, cy: cy, prevCx: nil, prevCy: nil)
    }

    let matched = matchPanesToSlots(panes: paneCenters, slots: slots, goingUp: false)

    let matchedIds: [Int] = matched.compactMap { $0 }
    var unmatched: [Int] = current
        .filter { !matchedIds.contains($0.id) }
        .map { $0.id }

    var result: [Pane] = []
    for (si, rect) in rects.enumerated() {
        let id = matched[si] ?? (unmatched.popLast() ?? 0)
        result.append(Pane(id: id, x: rect.x, y: rect.y, w: rect.w, h: rect.h))
    }
    return result
}

/// Add: compute grid for the new pane count, match existing panes, new pane gets leftover slot.
private func computeAdd(current: [Pane], newId: Int, windowW: Int, windowH: Int) -> [Pane] {
    let alreadyJoined = current.contains { $0.id == newId }

    let existing: [Pane]
    let newCount: Int
    let prevCount: Int
    if alreadyJoined {
        newCount = current.count
        prevCount = newCount - 1
        existing = current.filter { $0.id != newId }
    } else {
        existing = current
        newCount = current.count + 1
        prevCount = current.count
    }

    // Adds always produce a standard layout — the right-full-3 variant is
    // only reachable by removing from the right column.
    let rects = slotsFor(shape: .standard(count: newCount), width: windowW, height: windowH)
    let slots: [SlotCenter] = rects.map { r in
        let (cx, cy) = rectCenter(x: r.x, y: r.y, w: r.w, h: r.h)
        return SlotCenter(cx: cx, cy: cy)
    }

    let paneCenters: [PaneCenter] = existing.map { p in
        let (cx, cy) = rectCenter(x: p.x, y: p.y, w: p.w, h: p.h)
        return PaneCenter(id: p.id, cx: cx, cy: cy, prevCx: nil, prevCy: nil)
    }

    let matched = matchPanesStructural(panes: paneCenters, slots: slots, prevCount: prevCount, newCount: newCount)

    var result: [Pane] = []
    for (si, rect) in rects.enumerated() {
        let id: Int
        if si < matched.count {
            id = matched[si] ?? newId
        } else {
            id = newId
        }
        result.append(Pane(id: id, x: rect.x, y: rect.y, w: rect.w, h: rect.h))
    }
    return result
}

/// Remove: filter out the removed pane, compute grid for surviving panes,
/// match surviving panes using structural rules.
///
/// The target shape is derived from the survivors' geometry via
/// `currentShape`. For a 4→3 removal from the right column, the lone
/// column pane in the survivor set is the column-mate, sitting on the
/// right side of the centroid — `currentShape` returns `.rightFull3`,
/// so the column stays on the side where the removal happened.
private func computeRemove(current: [Pane], removedId: Int, windowW: Int, windowH: Int) -> [Pane] {
    let alreadyKilled = !current.contains { $0.id == removedId }

    let surviving: [Pane]
    let prevCount: Int
    if alreadyKilled {
        surviving = current
        prevCount = current.count + 1
    } else {
        surviving = current.filter { $0.id != removedId }
        prevCount = current.count
    }

    let newCount = surviving.count
    if newCount == 0 {
        return []
    }

    let shape = currentShape(panes: surviving)
    let rects = slotsFor(shape: shape, width: windowW, height: windowH)

    let paneCenters: [PaneCenter] = surviving.map { p in
        let (cx, cy) = rectCenter(x: p.x, y: p.y, w: p.w, h: p.h)
        return PaneCenter(id: p.id, cx: cx, cy: cy, prevCx: nil, prevCy: nil)
    }

    let slots: [SlotCenter] = rects.map { r in
        let (cx, cy) = rectCenter(x: r.x, y: r.y, w: r.w, h: r.h)
        return SlotCenter(cx: cx, cy: cy)
    }

    let matched = matchPanesStructural(panes: paneCenters, slots: slots, prevCount: prevCount, newCount: newCount)

    let matchedIds: [Int] = matched.compactMap { $0 }
    var unmatched: [Int] = surviving
        .filter { !matchedIds.contains($0.id) }
        .map { $0.id }

    var result: [Pane] = []
    for (si, rect) in rects.enumerated() {
        let id = matched[si] ?? (unmatched.popLast() ?? 0)
        result.append(Pane(id: id, x: rect.x, y: rect.y, w: rect.w, h: rect.h))
    }
    return result
}

// MARK: - Tests

#if DEBUG
public enum StickyTests {
    public static let W = 280
    public static let H = 80

    /// Build [Pane] from gridPositions -- simulates panes sitting in an N-pane layout.
    public static func panesAt(count: Int, ids: [Int], w: Int, h: Int) -> [Pane] {
        let rects = gridPositions(count: count, width: w, height: h)
        return zip(rects, ids).map { (r, id) in
            Pane(id: id, x: r.x, y: r.y, w: r.w, h: r.h)
        }
    }

    public static func runAll() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // ── Resize Tests ──

        // resize_equalizes_uneven_columns
        do {
            let current = [
                Pane(id: 1, x: 0, y: 0, w: 69, h: 32),
                Pane(id: 2, x: 70, y: 0, w: 126, h: 32),
                Pane(id: 3, x: 0, y: 33, w: 69, h: 33),
                Pane(id: 4, x: 70, y: 33, w: 126, h: 33),
                Pane(id: 5, x: 197, y: 0, w: 72, h: 66),
            ]
            let result = computeLayout(current: current, event: .resize, windowW: 269, windowH: 66)
            check("resize_equalizes_uneven_columns count", result.count == 5)
            let colWidths = [result[0].w, result[1].w, result[4].w]
            let maxW = colWidths.max()!
            let minW = colWidths.min()!
            check("resize_equalizes_uneven_columns equal", maxW - minW <= 2,
                  "columns should be roughly equal: \(colWidths)")
        }

        // resize_identity_preserves_positions
        do {
            let current = panesAt(count: 4, ids: [10, 11, 12, 13], w: W, h: H)
            let result = computeLayout(current: current, event: .resize, windowW: W, windowH: H)
            check("resize_identity count", result.count == 4)
            for (c, r) in zip(current, result) {
                check("resize_identity id=\(c.id)", c.id == r.id && c.x == r.x && c.y == r.y && c.w == r.w && c.h == r.h)
            }
        }

        // resize_preserves_pane_order
        do {
            let current = panesAt(count: 4, ids: [10, 11, 12, 13], w: W, h: H)
            let result = computeLayout(current: current, event: .resize, windowW: 200, windowH: 60)
            check("resize_preserves_pane_order count", result.count == 4)
            check("resize_preserves_pane_order tl", result[0].id == 10)
            check("resize_preserves_pane_order tr", result[1].id == 11)
            check("resize_preserves_pane_order bl", result[2].id == 12)
            check("resize_preserves_pane_order br", result[3].id == 13)
        }

        // resize_one_pane
        do {
            let current = panesAt(count: 1, ids: [10], w: 80, h: 24)
            let result = computeLayout(current: current, event: .resize, windowW: 200, windowH: 60)
            check("resize_one_pane count", result.count == 1)
            check("resize_one_pane id", result[0].id == 10)
            check("resize_one_pane w", result[0].w == 200)
            check("resize_one_pane h", result[0].h == 60)
        }

        // resize_two_panes
        do {
            let current = panesAt(count: 2, ids: [10, 11], w: 200, h: 60)
            let result = computeLayout(current: current, event: .resize, windowW: 300, windowH: 80)
            check("resize_two_panes count", result.count == 2)
            check("resize_two_panes id0", result[0].id == 10)
            check("resize_two_panes id1", result[1].id == 11)
            check("resize_two_panes h0", result[0].h == 80)
            check("resize_two_panes h1", result[1].h == 80)
            check("resize_two_panes total_w", result[0].w + 1 + result[1].w == 300)
        }

        // ── Add Tests ──

        // layout_add_3_to_4
        do {
            let current = panesAt(count: 3, ids: [10, 11, 12], w: W, h: H)
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_3_to_4 count", result.count == 4)
            check("add_3_to_4 id0", result[0].id == 10)
            check("add_3_to_4 id1", result[1].id == 11)
            check("add_3_to_4 id2", result[2].id == 99)
            check("add_3_to_4 id3", result[3].id == 12)
            let expected = gridPositions(count: 4, width: W, height: H)
            for (r, e) in zip(result, expected) {
                check("add_3_to_4 geom id=\(r.id)", r.x == e.x && r.y == e.y && r.w == e.w && r.h == e.h)
            }
        }

        // layout_add_3_to_4_already_joined_split_A
        // Simulates live flow: tmux split-window -v on the full-left pane (A).
        // tmux splits A into top/bottom halves; B and C unchanged.
        // Spec: result must still be canonical 4-pane with TL=A, TR=B, BL=NEW, BR=C.
        do {
            let r3 = gridPositions(count: 3, width: W, height: H)
            let leftW = r3[0].w  // full-left width
            let topH = r3[1].h   // half height in 3-pane right column
            // After split-window on A: A becomes top half of left col, NEW is bot half
            let A = Pane(id: 10, x: 0, y: 0, w: leftW, h: topH)
            let NEW = Pane(id: 99, x: 0, y: topH + 1, w: leftW, h: H - topH - 1)
            let B = Pane(id: 11, x: r3[1].x, y: r3[1].y, w: r3[1].w, h: r3[1].h)
            let C = Pane(id: 12, x: r3[2].x, y: r3[2].y, w: r3[2].w, h: r3[2].h)
            let current = [A, B, NEW, C]
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_3_to_4_split_A count", result.count == 4)
            check("add_3_to_4_split_A TL=A", result[0].id == 10, "result: \(result.map { $0.id })")
            check("add_3_to_4_split_A TR=B", result[1].id == 11, "result: \(result.map { $0.id })")
            check("add_3_to_4_split_A BL=NEW", result[2].id == 99, "result: \(result.map { $0.id })")
            check("add_3_to_4_split_A BR=C", result[3].id == 12, "result: \(result.map { $0.id })")
        }

        // layout_add_3_to_4_already_joined_split_B
        // tmux split-window -v on top-right pane (B). B keeps top, NEW below B, C unchanged.
        do {
            let r3 = gridPositions(count: 3, width: W, height: H)
            let bRegionH = r3[1].h
            let bH = (bRegionH - 1) / 2
            let newH = bRegionH - bH - 1
            let A = Pane(id: 10, x: r3[0].x, y: r3[0].y, w: r3[0].w, h: r3[0].h)
            let B = Pane(id: 11, x: r3[1].x, y: r3[1].y, w: r3[1].w, h: bH)
            let NEW = Pane(id: 99, x: r3[1].x, y: r3[1].y + bH + 1, w: r3[1].w, h: newH)
            let C = Pane(id: 12, x: r3[2].x, y: r3[2].y, w: r3[2].w, h: r3[2].h)
            let current = [A, B, NEW, C]
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_3_to_4_split_B count", result.count == 4)
            check("add_3_to_4_split_B TL=A", result[0].id == 10, "result: \(result.map { $0.id })")
            check("add_3_to_4_split_B TR=B", result[1].id == 11, "result: \(result.map { $0.id })")
            check("add_3_to_4_split_B BL=NEW", result[2].id == 99, "result: \(result.map { $0.id })")
            check("add_3_to_4_split_B BR=C", result[3].id == 12, "result: \(result.map { $0.id })")
        }

        // layout_add_3_to_4_already_joined_split_C
        // tmux split-window -v on bot-right pane (C). C keeps top of its region, NEW below C.
        do {
            let r3 = gridPositions(count: 3, width: W, height: H)
            let cRegionH = r3[2].h
            let cH = (cRegionH - 1) / 2
            let newH = cRegionH - cH - 1
            let A = Pane(id: 10, x: r3[0].x, y: r3[0].y, w: r3[0].w, h: r3[0].h)
            let B = Pane(id: 11, x: r3[1].x, y: r3[1].y, w: r3[1].w, h: r3[1].h)
            let C = Pane(id: 12, x: r3[2].x, y: r3[2].y, w: r3[2].w, h: cH)
            let NEW = Pane(id: 99, x: r3[2].x, y: r3[2].y + cH + 1, w: r3[2].w, h: newH)
            let current = [A, B, C, NEW]
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_3_to_4_split_C count", result.count == 4)
            check("add_3_to_4_split_C TL=A", result[0].id == 10, "result: \(result.map { $0.id })")
            check("add_3_to_4_split_C TR=B", result[1].id == 11, "result: \(result.map { $0.id })")
            check("add_3_to_4_split_C BL=NEW", result[2].id == 99, "result: \(result.map { $0.id })")
            check("add_3_to_4_split_C BR=C", result[3].id == 12, "result: \(result.map { $0.id })")
        }

        // layout_add_3right_to_4
        // Right-full 3-pane (slots: TL, BL, full-right) -> 4-pane.
        // Reproduces user's bug: close BR from 2x2, then create new pane.
        // After remove_4_br, panes are A=TL_small, C=BL_small, B=right-full.
        // Spec (sticky-panes.md "column-mate expands" symmetric add):
        // right column splits; B (right-full) stays in right column, NEW fills
        // the freshly vacated BR slot.
        do {
            let r3r = gridPositions3Right(width: W, height: H)
            let A = Pane(id: 10, x: r3r[0].x, y: r3r[0].y, w: r3r[0].w, h: r3r[0].h)
            let C = Pane(id: 12, x: r3r[1].x, y: r3r[1].y, w: r3r[1].w, h: r3r[1].h)
            let B = Pane(id: 11, x: r3r[2].x, y: r3r[2].y, w: r3r[2].w, h: r3r[2].h)
            let current = [A, C, B]
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_3right_to_4 count", result.count == 4)
            check("add_3right_to_4 TL=A", result[0].id == 10, "result: \(result.map { $0.id })")
            check("add_3right_to_4 TR=B", result[1].id == 11, "result: \(result.map { $0.id })")
            check("add_3right_to_4 BL=C", result[2].id == 12, "result: \(result.map { $0.id })")
            check("add_3right_to_4 BR=NEW", result[3].id == 99, "result: \(result.map { $0.id })")
        }

        // layout_add_3right_to_4_already_joined_split_B
        // After kill-BR, tmux focus typically stays on the column-mate (B,
        // formerly TR, now full-right). split-window -v on B yields:
        // A=TL_small, C=BL_small, B=top-right_small, NEW=bot-right_small.
        // The "natural" tmux geometry already matches 2x2 — sticky must
        // preserve it. Spec: 4-pane = [A=TL, B=TR, C=BL, NEW=BR].
        do {
            let r3r = gridPositions3Right(width: W, height: H)
            let A = Pane(id: 10, x: r3r[0].x, y: r3r[0].y, w: r3r[0].w, h: r3r[0].h)
            let C = Pane(id: 12, x: r3r[1].x, y: r3r[1].y, w: r3r[1].w, h: r3r[1].h)
            // B was full-right; after split-v, B shrinks to top, NEW fills bottom.
            let bRegionH = r3r[2].h
            let bH = (bRegionH - 1) / 2
            let newH = bRegionH - bH - 1
            let B = Pane(id: 11, x: r3r[2].x, y: r3r[2].y, w: r3r[2].w, h: bH)
            let NEW = Pane(id: 99, x: r3r[2].x, y: r3r[2].y + bH + 1, w: r3r[2].w, h: newH)
            let current = [A, C, B, NEW]
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_3right_to_4_split_B count", result.count == 4)
            check("add_3right_to_4_split_B TL=A", result[0].id == 10, "result: \(result.map { $0.id })")
            check("add_3right_to_4_split_B TR=B", result[1].id == 11, "result: \(result.map { $0.id })")
            check("add_3right_to_4_split_B BL=C", result[2].id == 12, "result: \(result.map { $0.id })")
            check("add_3right_to_4_split_B BR=NEW", result[3].id == 99, "result: \(result.map { $0.id })")
        }

        // layout_add_3right_to_4_already_joined_split_A
        // tmux split-window -v on top-left pane (A). A keeps top half of its
        // region, NEW fills bottom half. B and C unchanged.
        // Spec: 4-pane = [A=TL, B=TR, C=BL, NEW=BR].
        do {
            let r3r = gridPositions3Right(width: W, height: H)
            let aRegionH = r3r[0].h
            let aH = (aRegionH - 1) / 2
            let newH = aRegionH - aH - 1
            let A = Pane(id: 10, x: r3r[0].x, y: r3r[0].y, w: r3r[0].w, h: aH)
            let NEW = Pane(id: 99, x: r3r[0].x, y: r3r[0].y + aH + 1, w: r3r[0].w, h: newH)
            let C = Pane(id: 12, x: r3r[1].x, y: r3r[1].y, w: r3r[1].w, h: r3r[1].h)
            let B = Pane(id: 11, x: r3r[2].x, y: r3r[2].y, w: r3r[2].w, h: r3r[2].h)
            let current = [A, NEW, C, B]
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_3right_to_4_split_A count", result.count == 4)
            check("add_3right_to_4_split_A TL=A", result[0].id == 10, "result: \(result.map { $0.id })")
            check("add_3right_to_4_split_A TR=B", result[1].id == 11, "result: \(result.map { $0.id })")
            check("add_3right_to_4_split_A BL=C", result[2].id == 12, "result: \(result.map { $0.id })")
            check("add_3right_to_4_split_A BR=NEW", result[3].id == 99, "result: \(result.map { $0.id })")
        }

        // layout_add_3right_to_4_already_joined_split_C
        // tmux split-window -v on bot-left pane (C). C keeps top, NEW fills
        // bottom of C's region. A and B unchanged.
        // Spec: 4-pane = [A=TL, B=TR, C=BL, NEW=BR].
        do {
            let r3r = gridPositions3Right(width: W, height: H)
            let cRegionH = r3r[1].h
            let cH = (cRegionH - 1) / 2
            let newH = cRegionH - cH - 1
            let A = Pane(id: 10, x: r3r[0].x, y: r3r[0].y, w: r3r[0].w, h: r3r[0].h)
            let C = Pane(id: 12, x: r3r[1].x, y: r3r[1].y, w: r3r[1].w, h: cH)
            let NEW = Pane(id: 99, x: r3r[1].x, y: r3r[1].y + cH + 1, w: r3r[1].w, h: newH)
            let B = Pane(id: 11, x: r3r[2].x, y: r3r[2].y, w: r3r[2].w, h: r3r[2].h)
            let current = [A, C, NEW, B]
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_3right_to_4_split_C count", result.count == 4)
            check("add_3right_to_4_split_C TL=A", result[0].id == 10, "result: \(result.map { $0.id })")
            check("add_3right_to_4_split_C TR=B", result[1].id == 11, "result: \(result.map { $0.id })")
            check("add_3right_to_4_split_C BL=C", result[2].id == 12, "result: \(result.map { $0.id })")
            check("add_3right_to_4_split_C BR=NEW", result[3].id == 99, "result: \(result.map { $0.id })")
        }

        // resize_preserves_3right_full
        // After remove_4_br produces a 3-pane right-full layout, a subsequent
        // .resize event (e.g., fired by the pane-exited tmux hook or by a
        // window resize) must preserve that variant rather than collapsing it
        // back to standard 3-left-full. Otherwise the column-mate (B) gets
        // shuffled to BR, and the user's next "add pane" produces the wrong
        // slot (the BL-bug).
        do {
            let r3r = gridPositions3Right(width: W, height: H)
            // Panes as they sit after remove_4_br
            let A = Pane(id: 10, x: r3r[0].x, y: r3r[0].y, w: r3r[0].w, h: r3r[0].h)
            let C = Pane(id: 12, x: r3r[1].x, y: r3r[1].y, w: r3r[1].w, h: r3r[1].h)
            let B = Pane(id: 11, x: r3r[2].x, y: r3r[2].y, w: r3r[2].w, h: r3r[2].h)
            let current = [A, C, B]
            let result = computeLayout(current: current, event: .resize, windowW: W, windowH: H)
            check("resize_3right count", result.count == 3)
            // Same slot order as gridPositions3Right: TL, BL, full-right
            check("resize_3right TL=A", result[0].id == 10, "result: \(result.map { $0.id })")
            check("resize_3right BL=C", result[1].id == 12, "result: \(result.map { $0.id })")
            check("resize_3right rightfull=B", result[2].id == 11, "result: \(result.map { $0.id })")
            check("resize_3right B full height", result[2].h == H,
                  "B should remain full-height, got h=\(result[2].h)")
            check("resize_3right B right side", result[2].x > result[0].w,
                  "B should be on the right; got x=\(result[2].x), left w=\(result[0].w)")
        }

        // bug_repro_remove_br_then_add
        // Full sequence matching the user's reported bug:
        //   1. Start with 2x2 [A=TL, B=TR, C=BL, D=BR]
        //   2. Close BR (D): .removePane(13) → 3-right-full [A=TL, C=BL, B=right-full]
        //   3. pane-exited hook: .resize → MUST preserve 3-right-full
        //   4. User on B, split-window -v: B' top of right col, NEW bot of right col
        //   5. .addPane(99) → 4-pane [A=TL, B=TR, C=BL, NEW=BR]
        do {
            let start = panesAt(count: 4, ids: [10, 11, 12, 13], w: W, h: H)
            // Step 2: remove BR
            let afterRemove = computeLayout(current: start, event: .remove(13), windowW: W, windowH: H)
            check("bug_repro after remove count", afterRemove.count == 3)
            // Step 3: pane-exited hook fires .resize on the post-remove state
            let afterResize = computeLayout(current: afterRemove, event: .resize, windowW: W, windowH: H)
            check("bug_repro after resize count", afterResize.count == 3)
            check("bug_repro after resize B still right-full",
                  afterResize.first(where: { $0.id == 11 })?.h == H,
                  "B (column-mate) must stay full-height; got panes: \(afterResize.map { ($0.id, $0.x, $0.h) })")
            // Step 4: user is on B (right-full); split-v puts NEW below B
            let bIdx = afterResize.firstIndex(where: { $0.id == 11 })!
            let bPane = afterResize[bIdx]
            let bH = (bPane.h - 1) / 2
            let newH = bPane.h - bH - 1
            var withNew = afterResize
            withNew[bIdx] = Pane(id: 11, x: bPane.x, y: bPane.y, w: bPane.w, h: bH)
            withNew.append(Pane(id: 99, x: bPane.x, y: bPane.y + bH + 1, w: bPane.w, h: newH))
            // Step 5: add NEW
            let final = computeLayout(current: withNew, event: .add(99), windowW: W, windowH: H)
            check("bug_repro final count", final.count == 4)
            check("bug_repro final TL=A", final[0].id == 10, "got \(final.map { $0.id })")
            check("bug_repro final TR=B", final[1].id == 11, "got \(final.map { $0.id })")
            check("bug_repro final BL=C", final[2].id == 12, "got \(final.map { $0.id })")
            check("bug_repro final BR=NEW", final[3].id == 99,
                  "BUG: new pane should land at BR, but landed at slot \(final.firstIndex(where: { $0.id == 99 }) ?? -1). Full result: \(final.map { $0.id })")
        }

        // layout_add_4_to_5
        do {
            let current = panesAt(count: 4, ids: [10, 11, 12, 13], w: W, h: H)
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_4_to_5 count", result.count == 5)
            check("add_4_to_5 id0", result[0].id == 10)
            check("add_4_to_5 id1", result[1].id == 11)
            check("add_4_to_5 id2", result[2].id == 12)
            check("add_4_to_5 id3", result[3].id == 13)
            check("add_4_to_5 id4", result[4].id == 99)
        }

        // layout_add_5_to_6
        do {
            let r5 = gridPositions(count: 5, width: W, height: H)
            let current = r5.enumerated().map { (i, r) in
                Pane(id: 10 + i, x: r.x, y: r.y, w: r.w, h: r.h)
            }
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_5_to_6 count", result.count == 6)
            check("add_5_to_6 id2", result[2].id == 14)
            check("add_5_to_6 id5", result[5].id == 99)
        }

        // layout_add_6_to_7
        do {
            let current = panesAt(count: 6, ids: [10, 11, 12, 13, 14, 15], w: W, h: H)
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_6_to_7 count", result.count == 7)
            check("add_6_to_7 id0", result[0].id == 10)
            check("add_6_to_7 id1", result[1].id == 11)
            check("add_6_to_7 id2", result[2].id == 12)
            check("add_6_to_7 id3", result[3].id == 13)
            check("add_6_to_7 id4", result[4].id == 14)
            check("add_6_to_7 id5", result[5].id == 15)
            check("add_6_to_7 id6", result[6].id == 99)
        }

        // layout_add_6_to_7_already_joined
        do {
            let r6 = gridPositions(count: 6, width: W, height: H)
            var current = panesAt(count: 6, ids: [10, 11, 12, 13, 14, 15], w: W, h: H)
            current.append(Pane(id: 99, x: 0, y: r6[0].h / 2 + 1, w: r6[0].w, h: r6[0].h / 2))
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_6_to_7_already_joined count", result.count == 7, "should produce 7-pane layout, not 8")
            check("add_6_to_7_already_joined id6", result[6].id == 99)
            check("add_6_to_7_already_joined id0", result[0].id == 10)
            check("add_6_to_7_already_joined id1", result[1].id == 11)
            check("add_6_to_7_already_joined id2", result[2].id == 12)
            check("add_6_to_7_already_joined id3", result[3].id == 13)
            check("add_6_to_7_already_joined id4", result[4].id == 14)
            check("add_6_to_7_already_joined id5", result[5].id == 15)
            let expected = gridPositions(count: 7, width: W, height: H)
            for (r, e) in zip(result, expected) {
                check("add_6_to_7_already_joined geom", r.x == e.x && r.y == e.y && r.w == e.w && r.h == e.h,
                      "slot geometry mismatch")
            }
        }

        // layout_add_4_to_5_already_joined
        do {
            let r4 = gridPositions(count: 4, width: W, height: H)
            var current = panesAt(count: 4, ids: [10, 11, 12, 13], w: W, h: H)
            current.append(Pane(id: 99, x: 0, y: r4[0].h / 2 + 1, w: r4[0].w, h: r4[0].h / 2))
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_4_to_5_already_joined count", result.count == 5, "should produce 5-pane layout, not 6")
            check("add_4_to_5_already_joined id0", result[0].id == 10)
            check("add_4_to_5_already_joined id1", result[1].id == 11)
            check("add_4_to_5_already_joined id2", result[2].id == 12)
            check("add_4_to_5_already_joined id3", result[3].id == 13)
            check("add_4_to_5_already_joined id4", result[4].id == 99)
            let expected = gridPositions(count: 5, width: W, height: H)
            for (r, e) in zip(result, expected) {
                check("add_4_to_5_already_joined geom", r.x == e.x && r.y == e.y && r.w == e.w && r.h == e.h,
                      "slot geometry mismatch")
            }
        }

        // layout_add_7_to_8
        do {
            let r7 = gridPositions(count: 7, width: W, height: H)
            let current = r7.enumerated().map { (i, r) in
                Pane(id: 10 + i, x: r.x, y: r.y, w: r.w, h: r.h)
            }
            let result = computeLayout(current: current, event: .add(99), windowW: W, windowH: H)
            check("add_7_to_8 count", result.count == 8)
            check("add_7_to_8 id3", result[3].id == 16)
            check("add_7_to_8 id7", result[7].id == 99)
        }

        // ── 4->3 Remove Tests ──

        // layout_remove_4_tl
        do {
            let current = panesAt(count: 4, ids: [10, 11, 12, 13], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(10), windowW: W, windowH: H)
            check("remove_4_tl count", result.count == 3)
            check("remove_4_tl id0", result[0].id == 12)
            check("remove_4_tl h0", result[0].h == H)
            check("remove_4_tl id1", result[1].id == 11)
            check("remove_4_tl id2", result[2].id == 13)
        }

        // layout_remove_4_tr
        do {
            let current = panesAt(count: 4, ids: [10, 11, 12, 13], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(11), windowW: W, windowH: H)
            check("remove_4_tr count", result.count == 3)
            check("remove_4_tr id2", result[2].id == 13)
            check("remove_4_tr h2", result[2].h == H)
            check("remove_4_tr id0", result[0].id == 10)
            check("remove_4_tr id1", result[1].id == 12)
        }

        // layout_remove_4_bl
        do {
            let current = panesAt(count: 4, ids: [10, 11, 12, 13], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(12), windowW: W, windowH: H)
            check("remove_4_bl count", result.count == 3)
            check("remove_4_bl id0", result[0].id == 10)
            check("remove_4_bl h0", result[0].h == H)
            check("remove_4_bl id1", result[1].id == 11)
            check("remove_4_bl id2", result[2].id == 13)
        }

        // layout_remove_4_br
        do {
            let current = panesAt(count: 4, ids: [10, 11, 12, 13], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(13), windowW: W, windowH: H)
            check("remove_4_br count", result.count == 3)
            check("remove_4_br id2", result[2].id == 11)
            check("remove_4_br h2", result[2].h == H)
            check("remove_4_br id0", result[0].id == 10)
            check("remove_4_br id1", result[1].id == 12)
        }

        // ── 5->4 Remove Tests ──

        // layout_remove_5_tl
        do {
            let current = panesAt(count: 5, ids: [10, 11, 12, 13, 14], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(10), windowW: W, windowH: H)
            check("remove_5_tl count", result.count == 4)
            check("remove_5_tl id0", result[0].id == 14)
            check("remove_5_tl id1", result[1].id == 11)
            check("remove_5_tl id2", result[2].id == 12)
            check("remove_5_tl id3", result[3].id == 13)
        }

        // layout_remove_5_tr
        do {
            let current = panesAt(count: 5, ids: [10, 11, 12, 13, 14], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(11), windowW: W, windowH: H)
            check("remove_5_tr count", result.count == 4)
            check("remove_5_tr id0", result[0].id == 10)
            check("remove_5_tr id1", result[1].id == 14)
            check("remove_5_tr id2", result[2].id == 12)
            check("remove_5_tr id3", result[3].id == 13)
        }

        // layout_remove_5_bl
        do {
            let current = panesAt(count: 5, ids: [10, 11, 12, 13, 14], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(12), windowW: W, windowH: H)
            check("remove_5_bl count", result.count == 4)
            check("remove_5_bl id0", result[0].id == 10)
            check("remove_5_bl id1", result[1].id == 11)
            check("remove_5_bl id2", result[2].id == 14)
            check("remove_5_bl id3", result[3].id == 13)
        }

        // layout_remove_5_br
        do {
            let current = panesAt(count: 5, ids: [10, 11, 12, 13, 14], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(13), windowW: W, windowH: H)
            check("remove_5_br count", result.count == 4)
            check("remove_5_br id0", result[0].id == 10)
            check("remove_5_br id1", result[1].id == 11)
            check("remove_5_br id2", result[2].id == 12)
            check("remove_5_br id3", result[3].id == 14)
        }

        // layout_remove_5_rcol
        do {
            let current = panesAt(count: 5, ids: [10, 11, 12, 13, 14], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(14), windowW: W, windowH: H)
            check("remove_5_rcol count", result.count == 4)
            check("remove_5_rcol id0", result[0].id == 10)
            check("remove_5_rcol id1", result[1].id == 11)
            check("remove_5_rcol id2", result[2].id == 12)
            check("remove_5_rcol id3", result[3].id == 13)
        }

        // ── 6->5 Remove Tests ──

        // layout_remove_6_tl
        do {
            let current = panesAt(count: 6, ids: [10, 11, 12, 13, 14, 15], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(10), windowW: W, windowH: H)
            check("remove_6_tl count", result.count == 5)
            let ids = result.map { $0.id }
            check("remove_6_tl ids", ids == [12, 11, 15, 14, 13], "got \(ids)")
        }

        // layout_remove_6_tm
        do {
            let current = panesAt(count: 6, ids: [10, 11, 12, 13, 14, 15], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(11), windowW: W, windowH: H)
            check("remove_6_tm count", result.count == 5)
            let ids = result.map { $0.id }
            check("remove_6_tm ids", ids == [10, 12, 13, 15, 14], "got \(ids)")
        }

        // layout_remove_6_tr
        do {
            let current = panesAt(count: 6, ids: [10, 11, 12, 13, 14, 15], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(12), windowW: W, windowH: H)
            check("remove_6_tr count", result.count == 5)
            let ids = result.map { $0.id }
            check("remove_6_tr ids", ids == [10, 11, 13, 14, 15], "got \(ids)")
        }

        // layout_remove_6_bl
        do {
            let current = panesAt(count: 6, ids: [10, 11, 12, 13, 14, 15], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(13), windowW: W, windowH: H)
            check("remove_6_bl count", result.count == 5)
            let ids = result.map { $0.id }
            check("remove_6_bl ids", ids == [12, 11, 15, 14, 10], "got \(ids)")
        }

        // layout_remove_6_bm
        do {
            let current = panesAt(count: 6, ids: [10, 11, 12, 13, 14, 15], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(14), windowW: W, windowH: H)
            check("remove_6_bm count", result.count == 5)
            let ids = result.map { $0.id }
            check("remove_6_bm ids", ids == [10, 12, 13, 15, 11], "got \(ids)")
        }

        // layout_remove_6_br
        do {
            let current = panesAt(count: 6, ids: [10, 11, 12, 13, 14, 15], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(15), windowW: W, windowH: H)
            check("remove_6_br count", result.count == 5)
            let ids = result.map { $0.id }
            check("remove_6_br ids", ids == [10, 11, 13, 14, 12], "got \(ids)")
        }

        // ── 7->6 Remove Tests ──

        // layout_remove_7_tl
        do {
            let current = panesAt(count: 7, ids: [10, 11, 12, 13, 14, 15, 16], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(10), windowW: W, windowH: H)
            check("remove_7_tl count", result.count == 6)
            check("remove_7_tl id0", result[0].id == 16)
        }

        // layout_remove_7_tm
        do {
            let current = panesAt(count: 7, ids: [10, 11, 12, 13, 14, 15, 16], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(11), windowW: W, windowH: H)
            check("remove_7_tm count", result.count == 6)
            check("remove_7_tm id1", result[1].id == 16)
        }

        // layout_remove_7_tr
        do {
            let current = panesAt(count: 7, ids: [10, 11, 12, 13, 14, 15, 16], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(12), windowW: W, windowH: H)
            check("remove_7_tr count", result.count == 6)
            check("remove_7_tr id2", result[2].id == 16)
        }

        // layout_remove_7_bl
        do {
            let current = panesAt(count: 7, ids: [10, 11, 12, 13, 14, 15, 16], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(13), windowW: W, windowH: H)
            check("remove_7_bl count", result.count == 6)
            check("remove_7_bl id3", result[3].id == 16)
        }

        // layout_remove_7_bm
        do {
            let current = panesAt(count: 7, ids: [10, 11, 12, 13, 14, 15, 16], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(14), windowW: W, windowH: H)
            check("remove_7_bm count", result.count == 6)
            check("remove_7_bm id4", result[4].id == 16)
        }

        // layout_remove_7_br
        do {
            let current = panesAt(count: 7, ids: [10, 11, 12, 13, 14, 15, 16], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(15), windowW: W, windowH: H)
            check("remove_7_br count", result.count == 6)
            check("remove_7_br id5", result[5].id == 16)
        }

        // layout_remove_7_rcol
        do {
            let current = panesAt(count: 7, ids: [10, 11, 12, 13, 14, 15, 16], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(16), windowW: W, windowH: H)
            check("remove_7_rcol count", result.count == 6)
            check("remove_7_rcol id0", result[0].id == 10)
            check("remove_7_rcol id1", result[1].id == 11)
            check("remove_7_rcol id2", result[2].id == 12)
            check("remove_7_rcol id3", result[3].id == 13)
            check("remove_7_rcol id4", result[4].id == 14)
            check("remove_7_rcol id5", result[5].id == 15)
        }

        // ── 8->7 Remove Tests ──

        // layout_remove_8_tl
        do {
            let current = panesAt(count: 8, ids: [10, 11, 12, 13, 14, 15, 16, 17], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(10), windowW: W, windowH: H)
            check("remove_8_tl count", result.count == 7)
            let ids = result.map { $0.id }
            check("remove_8_tl ids", ids == [13, 11, 12, 17, 15, 16, 14], "got \(ids)")
        }

        // layout_remove_8_tml
        do {
            let current = panesAt(count: 8, ids: [10, 11, 12, 13, 14, 15, 16, 17], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(11), windowW: W, windowH: H)
            check("remove_8_tml count", result.count == 7)
            let ids = result.map { $0.id }
            check("remove_8_tml ids", ids == [10, 13, 12, 14, 17, 16, 15], "got \(ids)")
        }

        // layout_remove_8_tmr
        do {
            let current = panesAt(count: 8, ids: [10, 11, 12, 13, 14, 15, 16, 17], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(12), windowW: W, windowH: H)
            check("remove_8_tmr count", result.count == 7)
            let ids = result.map { $0.id }
            check("remove_8_tmr ids", ids == [10, 11, 13, 14, 15, 17, 16], "got \(ids)")
        }

        // layout_remove_8_tr
        do {
            let current = panesAt(count: 8, ids: [10, 11, 12, 13, 14, 15, 16, 17], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(13), windowW: W, windowH: H)
            check("remove_8_tr count", result.count == 7)
            let ids = result.map { $0.id }
            check("remove_8_tr ids", ids == [10, 11, 12, 14, 15, 16, 17], "got \(ids)")
        }

        // layout_remove_8_bl
        do {
            let current = panesAt(count: 8, ids: [10, 11, 12, 13, 14, 15, 16, 17], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(14), windowW: W, windowH: H)
            check("remove_8_bl count", result.count == 7)
            let ids = result.map { $0.id }
            check("remove_8_bl ids", ids == [13, 11, 12, 17, 15, 16, 10], "got \(ids)")
        }

        // layout_remove_8_bml
        do {
            let current = panesAt(count: 8, ids: [10, 11, 12, 13, 14, 15, 16, 17], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(15), windowW: W, windowH: H)
            check("remove_8_bml count", result.count == 7)
            let ids = result.map { $0.id }
            check("remove_8_bml ids", ids == [10, 13, 12, 14, 17, 16, 11], "got \(ids)")
        }

        // layout_remove_8_bmr
        do {
            let current = panesAt(count: 8, ids: [10, 11, 12, 13, 14, 15, 16, 17], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(16), windowW: W, windowH: H)
            check("remove_8_bmr count", result.count == 7)
            let ids = result.map { $0.id }
            check("remove_8_bmr ids", ids == [10, 11, 13, 14, 15, 17, 12], "got \(ids)")
        }

        // layout_remove_8_br
        do {
            let current = panesAt(count: 8, ids: [10, 11, 12, 13, 14, 15, 16, 17], w: W, h: H)
            let result = computeLayout(current: current, event: .remove(17), windowW: W, windowH: H)
            check("remove_8_br count", result.count == 7)
            let ids = result.map { $0.id }
            check("remove_8_br ids", ids == [10, 11, 12, 14, 15, 16, 13], "got \(ids)")
        }

        // ── Already-killed Remove Tests ──

        // layout_remove_7_to_6_already_killed
        do {
            let r7 = gridPositions(count: 7, width: W, height: H)
            let current = (0..<6).map { i in
                Pane(id: 10 + i, x: r7[i].x, y: r7[i].y, w: r7[i].w, h: r7[i].h)
            }
            let result = computeLayout(current: current, event: .remove(16), windowW: W, windowH: H)
            check("remove_7_to_6_already_killed count", result.count == 6, "should produce 6-pane layout, not 5")
            check("remove_7_to_6_already_killed id0", result[0].id == 10)
            check("remove_7_to_6_already_killed id1", result[1].id == 11)
            check("remove_7_to_6_already_killed id2", result[2].id == 12)
            check("remove_7_to_6_already_killed id3", result[3].id == 13)
            check("remove_7_to_6_already_killed id4", result[4].id == 14)
            check("remove_7_to_6_already_killed id5", result[5].id == 15)
            let expected = gridPositions(count: 6, width: W, height: H)
            for (r, e) in zip(result, expected) {
                check("remove_7_to_6_already_killed geom",
                      r.x == e.x && r.y == e.y && r.w == e.w && r.h == e.h,
                      "slot geometry mismatch")
            }
        }

        // layout_remove_5_to_4_already_killed
        do {
            let r5 = gridPositions(count: 5, width: W, height: H)
            let current = (0..<4).map { i in
                Pane(id: 10 + i, x: r5[i].x, y: r5[i].y, w: r5[i].w, h: r5[i].h)
            }
            let result = computeLayout(current: current, event: .remove(14), windowW: W, windowH: H)
            check("remove_5_to_4_already_killed count", result.count == 4, "should produce 4-pane layout, not 3")
            let expected = gridPositions(count: 4, width: W, height: H)
            for (r, e) in zip(result, expected) {
                check("remove_5_to_4_already_killed geom",
                      r.x == e.x && r.y == e.y && r.w == e.w && r.h == e.h,
                      "slot geometry mismatch")
            }
        }

        print("Sticky tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("Sticky tests failed") }
    }
}
#endif
