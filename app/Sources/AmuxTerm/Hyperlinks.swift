import Foundation

/// Parsed body of an OSC 8 hyperlink sequence (`ESC ] 8 ; params ; URI ST`).
/// libvterm's OSC parser consumes the command number and the first `;`, so
/// the body delivered to the fallback is "params;URI". An empty URI closes
/// the current hyperlink.
struct OSC8Payload: Equatable {
    /// The `id=` parameter, if present and non-empty. Split link fragments
    /// carrying the same id and URI are the same logical link.
    let id: String?
    /// The link target. Empty means "close the current hyperlink".
    let uri: String

    /// Parse an OSC 8 body of the form "params;URI".
    /// Returns nil when malformed (no `;` separator) — malformed sequences
    /// are ignored entirely rather than corrupting the open-link state.
    static func parse(_ body: String) -> OSC8Payload? {
        guard let separator = body.firstIndex(of: ";") else { return nil }
        let params = body[..<separator]
        let uri = String(body[body.index(after: separator)...])
        var id: String?
        for param in params.split(separator: ":") where param.hasPrefix("id=") {
            let value = String(param.dropFirst(3))
            if !value.isEmpty { id = value }
        }
        return OSC8Payload(id: id, uri: uri)
    }
}

/// Per-cell OSC 8 hyperlink state for the terminal screen.
///
/// libvterm has no native OSC 8 support and its screen cells cannot carry a
/// hyperlink, so this parallel grid stamps cells as text is written while a
/// hyperlink is open. VTerminal feeds it from three libvterm callbacks:
///
/// - the unrecognised-OSC fallback delivers OSC 8 bodies (open/close),
/// - cursor moves stamp or clear cells: a same-row forward move is a text
///   write (tmux positions each row explicitly, so client-side autowrap does
///   not occur in practice) — it stamps the traversed cells with the active
///   link, or clears them when no link is open,
/// - moverect mirrors scrolls so stamps follow their rows.
///
/// Erased cells keep a stale stamp but lose their text; span building in
/// TerminalView trims blank cells, so stale stamps on blanks are inert.
final class HyperlinkGrid {
    private(set) var rows: Int
    private(set) var cols: Int
    /// Row-major link ids, one per cell; 0 = no link.
    private var cells: [UInt32]
    private var uris: [UInt32: String] = [:]
    /// Interning table: "id\0uri" → internal id, so re-emissions of the same
    /// link (tmux redraws, split fragments) reuse one id.
    private var internedIDs: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    /// The currently open link's internal id; 0 when no link is open.
    private(set) var activeID: UInt32 = 0

    /// Accumulator for OSC bodies that libvterm delivers in fragments.
    private var pendingBody: [UInt8] = []
    private var pendingOverflowed = false
    /// Longest OSC 8 body accepted; anything larger closes the current link
    /// and is dropped (a truncated URI must never become clickable).
    private let maxBodyBytes = 4096
    /// URI-table size that triggers a sweep of ids no cell references.
    private let sweepThreshold = 4096

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.cells = [UInt32](repeating: 0, count: rows * cols)
    }

    // MARK: - OSC 8 input

    /// Feed one fragment of an OSC 8 body from libvterm's fallback.
    /// `initial`/`final` bracket a complete sequence.
    func feed(bytes: UnsafePointer<CChar>?, length: Int, initial: Bool, final: Bool) {
        if initial {
            pendingBody.removeAll(keepingCapacity: true)
            pendingOverflowed = false
        }
        if let bytes, length > 0 {
            if pendingBody.count + length > maxBodyBytes {
                pendingOverflowed = true
            } else {
                bytes.withMemoryRebound(to: UInt8.self, capacity: length) { p in
                    pendingBody.append(contentsOf: UnsafeBufferPointer(start: p, count: length))
                }
            }
        }
        if final {
            let body = pendingOverflowed ? nil : String(decoding: pendingBody, as: UTF8.self)
            pendingBody.removeAll(keepingCapacity: true)
            pendingOverflowed = false
            if let body {
                feed(body)
            } else {
                activeID = 0
            }
        }
    }

    /// Apply one complete OSC 8 body ("params;URI").
    func feed(_ body: String) {
        guard let payload = OSC8Payload.parse(body) else { return }
        guard !payload.uri.isEmpty else {
            activeID = 0
            return
        }
        let key = (payload.id ?? "") + "\0" + payload.uri
        if let existing = internedIDs[key] {
            activeID = existing
            return
        }
        sweepIfNeeded()
        let id = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        internedIDs[key] = id
        uris[id] = payload.uri
        activeID = id
    }

    // MARK: - Cell stamping

    /// Track a cursor move. Same-row forward moves are text writes: they
    /// stamp the traversed cells with the active link id (0 clears). All
    /// other moves are repositioning and leave the grid untouched.
    func cursorMoved(fromRow: Int, fromCol: Int, toRow: Int, toCol: Int) {
        guard fromRow == toRow, toCol > fromCol, fromRow >= 0, fromRow < rows else { return }
        let lo = max(0, fromCol)
        let hi = min(toCol, cols)
        guard lo < hi else { return }
        for col in lo..<hi {
            cells[fromRow * cols + col] = activeID
        }
    }

    /// Mirror a libvterm moverect (scroll) so stamps follow their rows.
    /// Rects are the same size; cells outside the destination are untouched
    /// (vacated cells are erased by libvterm and become blank, which span
    /// building ignores).
    func moveRect(
        destStartRow: Int, destStartCol: Int,
        srcStartRow: Int, srcStartCol: Int,
        rowCount: Int, colCount: Int
    ) {
        let snapshot = cells
        for r in 0..<rowCount {
            let destRow = destStartRow + r
            let srcRow = srcStartRow + r
            guard destRow >= 0, destRow < rows else { continue }
            for c in 0..<colCount {
                let destCol = destStartCol + c
                let srcCol = srcStartCol + c
                guard destCol >= 0, destCol < cols else { continue }
                let value: UInt32
                if srcRow >= 0, srcRow < rows, srcCol >= 0, srcCol < cols {
                    value = snapshot[srcRow * cols + srcCol]
                } else {
                    value = 0
                }
                cells[destRow * cols + destCol] = value
            }
        }
    }

    /// Drop every stamp (screen switch, resize). The open link survives —
    /// the application closes it, not the screen.
    func clearAll() {
        for i in cells.indices {
            cells[i] = 0
        }
    }

    func resize(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        cells = [UInt32](repeating: 0, count: rows * cols)
    }

    // MARK: - Queries

    func id(row: Int, col: Int) -> UInt32 {
        guard row >= 0, row < rows, col >= 0, col < cols else { return 0 }
        return cells[row * cols + col]
    }

    func uri(row: Int, col: Int) -> String? {
        let cellID = id(row: row, col: col)
        guard cellID != 0 else { return nil }
        return uris[cellID]
    }

    /// Drop interned ids no cell references once the table grows past the
    /// threshold, so long-lived sessions don't accumulate URIs forever.
    private func sweepIfNeeded() {
        guard uris.count >= sweepThreshold else { return }
        var referenced = Set(cells)
        referenced.insert(activeID)
        uris = uris.filter { referenced.contains($0.key) }
        internedIDs = internedIDs.filter { referenced.contains($0.value) }
    }
}
