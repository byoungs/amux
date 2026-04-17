// Layout.swift — Grid layout calculation and tmux layout string generation.
// Pure algorithm module — no I/O, no tmux dependency.

/// A rectangular region in the terminal.
public struct Rect: Equatable {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// A pane with its ID and position in the terminal.
public struct Pane: Equatable {
    public var id: Int
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(id: Int, x: Int, y: Int, w: Int, h: Int) {
        self.id = id
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Calculate grid positions for N panes in a WxH terminal.
/// Returns an array of Rect, one per pane, in slot order.
///
/// Grid rules (alternating balanced / balanced+column):
/// - 1 pane: full screen
/// - 2 panes: left/right split (never top/bottom)
/// - 3 panes: left full-height + right split vertically
/// - 4 panes: 2x2 (balanced)
/// - 5 panes: 2x2 + full-height right column
/// - 6 panes: 3x2 (balanced)
/// - 7 panes: 3x2 + full-height right column
/// - 8 panes: 4x2 (balanced)
/// - 9 panes: 4x2 + full-height right column
public func gridPositions(count: Int, width: Int, height: Int) -> [Rect] {
    switch count {
    case 0:
        return []
    case 1:
        return [Rect(x: 0, y: 0, w: width, h: height)]
    case 2:
        return layoutColumns(n: 2, width: width, height: height)
    case 3:
        // Left full-height + right column split into 2
        let leftW = (width - 1) / 2
        let rightW = width - 1 - leftW
        let rightX = leftW + 1
        let topH = (height - 1) / 2
        let botH = height - 1 - topH
        return [
            Rect(x: 0, y: 0, w: leftW, h: height),
            Rect(x: rightX, y: 0, w: rightW, h: topH),
            Rect(x: rightX, y: topH + 1, w: rightW, h: botH),
        ]
    case 4:
        return layoutGrid(rows: 2, cols: 2, width: width, height: height)
    default:
        if count % 2 == 0 {
            // Even counts >= 6: balanced grid (2 rows, count/2 columns)
            return layoutGrid(rows: 2, cols: count / 2, width: width, height: height)
        } else {
            // Odd counts >= 5: balanced grid + full-height right column
            let balancedCols = (count - 1) / 2
            return layoutBalancedPlusColumn(balancedCols: balancedCols, width: width, height: height)
        }
    }
}

/// 3-pane layout with full-height RIGHT column (mirrored variant).
/// Slot order: left-top, left-bottom, full-right.
/// Used when removing from the right column of a 2x2.
public func gridPositions3Right(width: Int, height: Int) -> [Rect] {
    return layoutBalancedPlusColumn(balancedCols: 1, width: width, height: height)
}

/// Layout a balanced grid (cols x 2) plus a full-height right column.
/// Slot order: top row L->R, bottom row L->R, then right column.
private func layoutBalancedPlusColumn(balancedCols: Int, width: Int, height: Int) -> [Rect] {
    let totalCols = balancedCols + 1
    let colDividers = max(totalCols - 1, 0)
    let availableW = max(width - colDividers, 0)
    let colW = availableW / totalCols

    let rowAvailable = max(height - 1, 0)
    let topH = rowAvailable / 2
    let botH = rowAvailable - topH
    let botY = topH + 1

    var rects: [Rect] = []

    // Top row of balanced grid
    var cx = 0
    for _ in 0..<balancedCols {
        rects.append(Rect(x: cx, y: 0, w: colW, h: topH))
        cx += colW + 1
    }

    // Bottom row of balanced grid
    cx = 0
    for _ in 0..<balancedCols {
        rects.append(Rect(x: cx, y: botY, w: colW, h: botH))
        cx += colW + 1
    }

    // Full-height right column
    let rightX = (colW + 1) * balancedCols
    let rightW = width - rightX
    rects.append(Rect(x: rightX, y: 0, w: rightW, h: height))

    return rects
}

/// Layout N equal columns, each full height.
private func layoutColumns(n: Int, width: Int, height: Int) -> [Rect] {
    let dividers = max(n - 1, 0)
    let available = max(width - dividers, 0)
    let colW = available / n
    var rects: [Rect] = []
    var x = 0
    for i in 0..<n {
        let w = (i == n - 1) ? (width - x) : colW
        rects.append(Rect(x: x, y: 0, w: w, h: height))
        x += w + 1 // +1 for divider
    }
    return rects
}

/// Layout N equal rows in a given region.
private func layoutRows(n: Int, x: Int, y: Int, width: Int, height: Int) -> [Rect] {
    let dividers = max(n - 1, 0)
    let available = max(height - dividers, 0)
    let rowH = available / n
    var rects: [Rect] = []
    var cy = y
    for i in 0..<n {
        let h = (i == n - 1) ? (y + height - cy) : rowH
        rects.append(Rect(x: x, y: cy, w: width, h: h))
        cy += h + 1 // +1 for divider
    }
    return rects
}

/// Layout a rows x cols grid.
private func layoutGrid(rows: Int, cols: Int, width: Int, height: Int) -> [Rect] {
    let colDividers = max(cols - 1, 0)
    let rowDividers = max(rows - 1, 0)
    let colAvailable = max(width - colDividers, 0)
    let rowAvailable = max(height - rowDividers, 0)
    let colW = colAvailable / cols
    let rowH = rowAvailable / rows

    var rects: [Rect] = []
    var cy = 0
    for r in 0..<rows {
        let h = (r == rows - 1) ? (height - cy) : rowH
        var cx = 0
        for c in 0..<cols {
            let w = (c == cols - 1) ? (width - cx) : colW
            rects.append(Rect(x: cx, y: cy, w: w, h: h))
            cx += w + 1
        }
        cy += h + 1
    }
    return rects
}

/// Build a tmux layout string for N panes in the standard grid.
/// This generates the split tree directly rather than trying to
/// decompose grid positions back into a tree.
///
/// `borderTop` compensates for `pane-border-status top`: the top row of
/// panes loses `borderTop` rows to the border title bar, so we make the
/// first row that many rows taller in the layout string.
public func buildLayoutStringDirect(
    width: Int,
    height: Int,
    paneIds: [Int],
    borderTop: Int
) -> String? {
    let n = paneIds.count
    if n == 0 {
        return nil
    }

    let body: String
    switch n {
    case 1:
        body = "\(width)x\(height),0,0,\(paneIds[0])"
    case 2:
        // Left/right split
        let lw = (width - 1) / 2
        let rw = width - 1 - lw
        let rx = lw + 1
        body = "\(width)x\(height),0,0{\(lw)x\(height),0,0,\(paneIds[0]),\(rw)x\(height),\(rx),0,\(paneIds[1])}"
    case 3:
        // Left full-height + right split vertically
        let lw = (width - 1) / 2
        let rw = width - 1 - lw
        let rx = lw + 1
        let (th, bh) = splitTwoRows(height: height, borderTop: borderTop)
        let by = th + 1
        body = "\(width)x\(height),0,0{\(lw)x\(height),0,0,\(paneIds[0]),\(rw)x\(height),\(rx),0[\(rw)x\(th),\(rx),0,\(paneIds[1]),\(rw)x\(bh),\(rx),\(by),\(paneIds[2])]}"
    case 4:
        // 2x2
        let lw = (width - 1) / 2
        let rw = width - 1 - lw
        let rx = lw + 1
        let (th, bh) = splitTwoRows(height: height, borderTop: borderTop)
        let by = th + 1
        body = "\(width)x\(height),0,0[\(width)x\(th),0,0{\(lw)x\(th),0,0,\(paneIds[0]),\(rw)x\(th),\(rx),0,\(paneIds[1])},\(width)x\(bh),0,\(by){\(lw)x\(bh),0,\(by),\(paneIds[2]),\(rw)x\(bh),\(rx),\(by),\(paneIds[3])}]"
    default:
        if n % 2 == 0 {
            // Even counts >= 6: balanced grid (2 rows, n/2 columns per row)
            let cols = n / 2
            let (th, bh) = splitTwoRows(height: height, borderTop: borderTop)
            let by = th + 1

            let topRow = layoutRowString(ids: Array(paneIds[..<cols]), x: 0, y: 0, width: width, height: th)
            let botRow = layoutRowString(ids: Array(paneIds[cols...]), x: 0, y: by, width: width, height: bh)

            body = "\(width)x\(height),0,0[\(topRow),\(botRow)]"
        } else {
            // Odd counts >= 5: balanced grid + full-height right column
            let balancedCols = (n - 1) / 2
            let totalCols = balancedCols + 1
            let colDividers = totalCols - 1
            let available = width - colDividers
            let colW = available / totalCols

            let leftW = colW * balancedCols + max(balancedCols - 1, 0)
            let rightX = leftW + 1
            let rightW = width - rightX

            let (th, bh) = splitTwoRows(height: height, borderTop: borderTop)
            let by = th + 1

            let topIds = Array(paneIds[..<balancedCols])
            let botIds = Array(paneIds[balancedCols..<(2 * balancedCols)])
            let rightId = paneIds[2 * balancedCols]

            let topRow = layoutRowString(ids: topIds, x: 0, y: 0, width: leftW, height: th)
            let botRow = layoutRowString(ids: botIds, x: 0, y: by, width: leftW, height: bh)

            body = "\(width)x\(height),0,0{\(leftW)x\(height),0,0[\(topRow),\(botRow)],\(rightW)x\(height),\(rightX),0,\(rightId)}"
        }
    }

    let csum = layoutChecksum(body)
    return String(format: "%04x,%@", csum, body)
}

/// Build tmux layout string for 3-pane right-full variant.
/// Slot order: left-top, left-bottom, full-right.
public func buildLayoutString3Right(
    width: Int,
    height: Int,
    paneIds: [Int],
    borderTop: Int
) -> String? {
    if paneIds.count != 3 {
        return nil
    }

    // Same geometry as odd >= 5 path but with balancedCols = 1
    let totalCols = 2
    let available = width - (totalCols - 1)
    let colW = available / totalCols

    let leftW = colW
    let rightX = leftW + 1
    let rightW = width - rightX

    let (th, bh) = splitTwoRows(height: height, borderTop: borderTop)
    let by = th + 1

    // left-top, left-bottom, full-right
    let body = "\(width)x\(height),0,0{\(leftW)x\(height),0,0[\(leftW)x\(th),0,0,\(paneIds[0]),\(leftW)x\(bh),0,\(by),\(paneIds[1])],\(rightW)x\(height),\(rightX),0,\(paneIds[2])}"

    let csum = layoutChecksum(body)
    return String(format: "%04x,%@", csum, body)
}

/// Build a tmux layout string from positioned panes.
///
/// This function takes the output of `computeLayout` — panes with their
/// exact positions — and generates the tmux layout string. It delegates to
/// `buildLayoutStringDirect` or `buildLayoutString3Right` based on
/// the pane positions (detecting the right-full variant by checking if the
/// rightmost pane is full-height).
///
/// `borderTop` is applied to the layout string to compensate for
/// pane-border-status. `windowW` and `windowH` are the raw window
/// dimensions (before border subtraction).
public func buildLayoutString(
    panes: [Pane],
    windowW: Int,
    windowH: Int,
    borderTop: Int
) -> String? {
    if panes.isEmpty {
        return nil
    }

    // Extract ordered IDs (panes are already in slot order from computeLayout)
    let ids = panes.map { $0.id }

    // Detect 3-pane right-full variant: rightmost pane is full height
    if panes.count == 3 {
        let rightmost = panes.max(by: { $0.x < $1.x })!
        let effectiveH = max(windowH - borderTop, 0)
        if rightmost.h == effectiveH {
            return buildLayoutString3Right(width: windowW, height: windowH, paneIds: ids, borderTop: borderTop)
        }
    }

    return buildLayoutStringDirect(width: windowW, height: windowH, paneIds: ids, borderTop: borderTop)
}

/// Split height into two rows, compensating for borderTop.
///
/// With pane-border-status top, the first row of panes loses `borderTop`
/// rows to the title bar. To make visible content equal, the first row gets
/// `borderTop` extra rows in the layout string.
private func splitTwoRows(height: Int, borderTop: Int) -> (Int, Int) {
    let effective = max(height - borderTop, 0)
    let bhBase = max(effective - 1, 0) / 2
    let thBase = max(effective - 1, 0) - bhBase
    let th = thBase + borderTop
    let bh = bhBase
    // th + 1 (divider) + bh == height
    return (th, bh)
}

/// Split height into three rows, compensating for borderTop.
private func splitThreeRows(height: Int, borderTop: Int) -> (Int, Int, Int) {
    let effective = max(height - borderTop, 0)
    let content = max(effective - 2, 0) // minus 2 dividers
    let perRow = content / 3
    let remainder = content - perRow * 3
    let h1 = perRow + borderTop + (remainder >= 1 ? 1 : 0)
    let h2 = perRow + (remainder >= 2 ? 1 : 0)
    let h3 = max(height - 2 - h1 - h2, 0)
    return (h1, h2, h3)
}

/// Compute tmux layout checksum — matches tmux's layout_checksum() exactly.
/// Algorithm: rotate right 1 bit, then add each byte.
private func layoutChecksum(_ layout: String) -> UInt16 {
    var csum: UInt16 = 0
    for b in layout.utf8 {
        csum = (csum >> 1) | ((csum & 1) << 15)
        csum = csum &+ UInt16(b)
    }
    return csum
}

private func layoutRowString(ids: [Int], x: Int, y: Int, width: Int, height: Int) -> String {
    if ids.count == 1 {
        return "\(width)x\(height),\(x),\(y),\(ids[0])"
    }
    let dividers = ids.count - 1
    let available = width - dividers
    let colW = available / ids.count

    var parts: [String] = []
    var cx = x
    for (i, id) in ids.enumerated() {
        let w = (i == ids.count - 1) ? (x + width - cx) : colW
        parts.append("\(w)x\(height),\(cx),\(y),\(id)")
        cx += w + 1
    }

    return "\(width)x\(height),\(x),\(y){\(parts.joined(separator: ","))}"
}

// MARK: - Tests

#if DEBUG
public enum LayoutTests {
    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // one_pane_full_screen
        do {
            let rects = gridPositions(count: 1, width: 280, height: 80)
            check("one_pane count", rects.count == 1)
            check("one_pane rect", rects[0] == Rect(x: 0, y: 0, w: 280, h: 80))
        }

        // two_panes_left_right
        do {
            let rects = gridPositions(count: 2, width: 280, height: 80)
            check("two_panes count", rects.count == 2)
            check("two_panes left x", rects[0].x == 0)
            check("two_panes left y", rects[0].y == 0)
            check("two_panes right x", rects[1].x > 0)
            check("two_panes right y", rects[1].y == 0)
            check("two_panes left full height", rects[0].h == 80)
            check("two_panes right full height", rects[1].h == 80)
            check("two_panes total width", rects[0].w + 1 + rects[1].w == 280)
        }

        // three_panes_left_full_right_split
        do {
            let rects = gridPositions(count: 3, width: 280, height: 80)
            check("three_panes count", rects.count == 3)
            check("three_panes left x", rects[0].x == 0)
            check("three_panes left full height", rects[0].h == 80)
            check("three_panes top-right x", rects[1].x > 0)
            check("three_panes top-right y", rects[1].y == 0)
            check("three_panes bottom-right x", rects[2].x > 0)
            check("three_panes bottom-right y", rects[2].y > 0)
            check("three_panes right panes share x", rects[1].x == rects[2].x)
        }

        // three_panes_right_full_left_split
        do {
            let rects = gridPositions3Right(width: 280, height: 80)
            check("three_right count", rects.count == 3)
            check("three_right top-left x", rects[0].x == 0)
            check("three_right top-left y", rects[0].y == 0)
            check("three_right top-left partial height", rects[0].h < 80)
            check("three_right bottom-left x", rects[1].x == 0)
            check("three_right bottom-left y", rects[1].y > 0)
            check("three_right bottom-left partial height", rects[1].h < 80)
            check("three_right full-right x", rects[2].x > 0)
            check("three_right full-right y", rects[2].y == 0)
            check("three_right full-right full height", rects[2].h == 80)
            check("three_right left panes share x", rects[0].x == rects[1].x)
            check("three_right no overlap", rects[2].x > rects[0].w)
            check("three_right left covers height", rects[0].h + 1 + rects[1].h == 80)
        }

        // four_panes_2x2
        do {
            let rects = gridPositions(count: 4, width: 280, height: 80)
            check("four_panes count", rects.count == 4)
            check("four_panes TL x", rects[0].x == 0)
            check("four_panes TL y", rects[0].y == 0)
            check("four_panes TR x", rects[1].x > 0)
            check("four_panes TR y", rects[1].y == 0)
            check("four_panes BL x", rects[2].x == 0)
            check("four_panes BL y", rects[2].y > 0)
            check("four_panes BR x", rects[3].x > 0)
            check("four_panes BR y", rects[3].y > 0)
        }

        // five_panes_2x2_plus_column
        do {
            let rects = gridPositions(count: 5, width: 280, height: 80)
            check("five_panes count", rects.count == 5)
            check("five_panes TL y", rects[0].y == 0)
            check("five_panes TR y", rects[1].y == 0)
            check("five_panes BL y", rects[2].y > 0)
            check("five_panes BR y", rects[3].y > 0)
            check("five_panes TL x", rects[0].x == 0)
            check("five_panes BL x", rects[2].x == 0)
            check("five_panes TR BR share x", rects[1].x == rects[3].x)
            check("five_panes right col y", rects[4].y == 0)
            check("five_panes right col full height", rects[4].h == 80)
            check("five_panes right col x", rects[4].x > rects[1].x)
        }

        // six_panes_3x2
        do {
            let rects = gridPositions(count: 6, width: 282, height: 80)
            check("six_panes count", rects.count == 6)
            check("six_panes row1 p0 y", rects[0].y == 0)
            check("six_panes row1 p1 y", rects[1].y == 0)
            check("six_panes row1 p2 y", rects[2].y == 0)
            check("six_panes row2 p3 y", rects[3].y > 0)
            check("six_panes row2 p4 y", rects[4].y > 0)
            check("six_panes row2 p5 y", rects[5].y > 0)
            check("six_panes 3 cols a", rects[0].x < rects[1].x)
            check("six_panes 3 cols b", rects[1].x < rects[2].x)
        }

        // seven_panes_3x2_plus_column
        do {
            let rects = gridPositions(count: 7, width: 280, height: 80)
            check("seven_panes count", rects.count == 7)
            check("seven_panes top row p0 y", rects[0].y == 0)
            check("seven_panes top row p1 y", rects[1].y == 0)
            check("seven_panes top row p2 y", rects[2].y == 0)
            check("seven_panes bot row p3 y", rects[3].y > 0)
            check("seven_panes bot row p4 y", rects[4].y > 0)
            check("seven_panes bot row p5 y", rects[5].y > 0)
            check("seven_panes right col y", rects[6].y == 0)
            check("seven_panes right col full height", rects[6].h == 80)
            check("seven_panes right col x", rects[6].x > rects[2].x)
        }

        // two_panes_never_top_bottom
        do {
            for w in [80, 120, 200, 300] {
                for h in [24, 40, 60, 80] {
                    let rects = gridPositions(count: 2, width: w, height: h)
                    check("never_top_bottom p0 y \(w)x\(h)", rects[0].y == 0)
                    check("never_top_bottom p1 y \(w)x\(h)", rects[1].y == 0)
                    check("never_top_bottom p0 h \(w)x\(h)", rects[0].h == h)
                    check("never_top_bottom p1 h \(w)x\(h)", rects[1].h == h)
                }
            }
        }

        // layout_string_one_pane
        do {
            let s = buildLayoutStringDirect(width: 280, height: 80, paneIds: [5], borderTop: 0)!
            check("layout_string_one_pane", s.contains("280x80,0,0,5"))
        }

        // layout_string_two_panes
        do {
            let s = buildLayoutStringDirect(width: 280, height: 80, paneIds: [5, 6], borderTop: 0)!
            check("layout_string_two has 5", s.contains(",5"))
            check("layout_string_two has 6", s.contains(",6"))
            check("layout_string_two has brace", s.contains("{"))
        }

        // layout_string_four_panes
        do {
            let s = buildLayoutStringDirect(width: 280, height: 80, paneIds: [5, 6, 7, 8], borderTop: 0)!
            check("layout_string_four has 5", s.contains(",5"))
            check("layout_string_four has 6", s.contains(",6"))
            check("layout_string_four has 7", s.contains(",7"))
            check("layout_string_four has 8", s.contains(",8"))
        }

        // layout_string_empty
        do {
            let s = buildLayoutStringDirect(width: 280, height: 80, paneIds: [], borderTop: 0)
            check("layout_string_empty", s == nil)
        }

        // split_two_rows_invariant
        do {
            for h in [24, 40, 60, 80, 81] {
                for bt in [0, 1] {
                    let (th, bh) = splitTwoRows(height: h, borderTop: bt)
                    check("split_two_rows invariant \(h),\(bt)",
                          th + 1 + bh == h,
                          "split_two_rows(\(h), \(bt)): \(th) + 1 + \(bh) != \(h)")
                    if bt > 0 {
                        let visibleTop = th - bt
                        check("split_two_rows visible \(h),\(bt)",
                              abs(visibleTop - bh) <= 1,
                              "split_two_rows(\(h), \(bt)): visible \(visibleTop) vs \(bh) differ by >1")
                    }
                }
            }
        }

        // split_three_rows_invariant
        do {
            for h in [24, 40, 60, 80, 81] {
                for bt in [0, 1] {
                    let (h1, h2, h3) = splitThreeRows(height: h, borderTop: bt)
                    check("split_three_rows invariant \(h),\(bt)",
                          h1 + 1 + h2 + 1 + h3 == h,
                          "split_three_rows(\(h), \(bt)): \(h1) + 1 + \(h2) + 1 + \(h3) != \(h)")
                    if bt > 0 {
                        let v1 = h1 - bt
                        let vals = [v1, h2, h3]
                        let maxV = vals.max()!
                        let minV = vals.min()!
                        check("split_three_rows visible \(h),\(bt)",
                              maxV - minV <= 1,
                              "split_three_rows(\(h), \(bt)): visible \(vals) spread > 1")
                    }
                }
            }
        }

        // layout_string_pane_order_matches_grid_positions
        do {
            for count in 1...9 {
                let ids: [Int] = Array(1000..<(1000 + count))
                let layout = buildLayoutStringDirect(width: 280, height: 80, paneIds: ids, borderTop: 0)!
                let found = extractPaneIdsInOrder(layout)
                check("pane_order_\(count)_panes", found == ids,
                      "Expected \(ids), got \(found)\nLayout: \(layout)")
            }
        }

        // four_pane_columns_equal_width
        do {
            for w in [80, 120, 200, 280, 281] {
                let rects = gridPositions(count: 4, width: w, height: 80)
                let leftW = rects[0].w
                let rightW = rects[1].w
                check("four_pane_cols_equal \(w)",
                      abs(leftW - rightW) <= 1,
                      "left=\(leftW), right=\(rightW)")
            }
        }

        // layout_string_four_panes_with_border
        do {
            let s = buildLayoutStringDirect(width: 80, height: 24, paneIds: [1, 2, 3, 4], borderTop: 1)!
            check("four_border has 1", s.contains(",1"))
            check("four_border has 2", s.contains(",2"))
            check("four_border has 3", s.contains(",3"))
            check("four_border has 4", s.contains(",4"))
            check("four_border top row 12", s.contains("80x12,0,0"), "top row should be 12 high: \(s)")
            check("four_border bot row 11", s.contains("80x11,0,13"), "bottom row should be 11 high at y=13: \(s)")
        }

        // build_layout_string_from_panes_4
        do {
            let rects = gridPositions(count: 4, width: 280, height: 80)
            let panes: [Pane] = rects.enumerated().map { (i, r) in
                Pane(id: 100 + i, x: r.x, y: r.y, w: r.w, h: r.h)
            }
            let s = buildLayoutString(panes: panes, windowW: 280, windowH: 80, borderTop: 0)!
            check("from_panes_4 has 100", s.contains(",100"), "missing pane 100: \(s)")
            check("from_panes_4 has 101", s.contains(",101"), "missing pane 101: \(s)")
            check("from_panes_4 has 102", s.contains(",102"), "missing pane 102: \(s)")
            check("from_panes_4 has 103", s.contains(",103"), "missing pane 103: \(s)")
            check("from_panes_4 checksum prefix", s.count > 5)
            let idx = s.index(s.startIndex, offsetBy: 4)
            check("from_panes_4 comma at 4", String(s[idx]) == ",")
        }

        // build_layout_string_from_panes_matches_direct
        do {
            for count in 1...8 {
                let ids: [Int] = Array(100..<(100 + count))
                let rects = gridPositions(count: count, width: 280, height: 80)
                let panes: [Pane] = zip(rects, ids).map { (r, id) in
                    Pane(id: id, x: r.x, y: r.y, w: r.w, h: r.h)
                }
                let fromPanes = buildLayoutString(panes: panes, windowW: 280, windowH: 80, borderTop: 0)
                let fromDirect = buildLayoutStringDirect(width: 280, height: 80, paneIds: ids, borderTop: 0)
                check("panes_matches_direct \(count)", fromPanes == fromDirect,
                      "panes: \(fromPanes ?? "nil"), direct: \(fromDirect ?? "nil")")
            }
        }

        print("Layout tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("Layout tests failed") }
    }

    /// Extract pane IDs from a layout string in tree-walk order.
    /// Uses IDs >= 1000 to distinguish from coordinates.
    private static func extractPaneIdsInOrder(_ layout: String) -> [Int] {
        var ids: [Int] = []
        let bytes = Array(layout.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: ",") {
                let start = i + 1
                var end = start
                while end < bytes.count && bytes[end] >= UInt8(ascii: "0") && bytes[end] <= UInt8(ascii: "9") {
                    end += 1
                }
                if end > start {
                    if let n = Int(String(bytes: Array(bytes[start..<end]), encoding: .utf8) ?? "") {
                        if n >= 1000 {
                            ids.append(n)
                        }
                    }
                }
            }
            i += 1
        }
        return ids
    }
}
#endif
