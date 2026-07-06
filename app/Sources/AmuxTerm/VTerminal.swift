import AppKit
import Foundation
import CVterm

// MARK: - C callbacks (must be top-level @convention(c) functions, not closures)

private func onDamage(_ rect: VTermRect, _ user: UnsafeMutableRawPointer?) -> Int32 {
    let terminal = Unmanaged<VTerminal>.fromOpaque(user!).takeUnretainedValue()
    terminal.isDirty = true
    // Track which rows changed for partial redraw
    for row in rect.start_row..<rect.end_row {
        terminal.dirtyRows.insert(Int(row))
    }
    return 1
}

private func onMoveCursor(_ pos: VTermPos, _ oldpos: VTermPos, _ visible: Int32, _ user: UnsafeMutableRawPointer?) -> Int32 {
    let terminal = Unmanaged<VTerminal>.fromOpaque(user!).takeUnretainedValue()
    terminal.cursorRow = Int(pos.row)
    terminal.cursorCol = Int(pos.col)
    terminal.cursorVisible = visible != 0
    // Hyperlink stamping: libvterm fires movecursor synchronously after each
    // text chunk, so a same-row forward move is the cells just written.
    terminal.hyperlinks.cursorMoved(
        fromRow: Int(oldpos.row), fromCol: Int(oldpos.col),
        toRow: Int(pos.row), toCol: Int(pos.col))
    // A cursor move repaints two rows: the one it left (to erase the old
    // cursor block) and the one it entered (to draw the new one). libvterm
    // reports cursor motion separately from cell damage, so a pure
    // reposition (CUP, arrow keys, TUI redraws) would otherwise leave
    // dirtyRows empty and the renderer would schedule no repaint — the
    // on-screen cursor froze at its previous position.
    terminal.isDirty = true
    terminal.dirtyRows.insert(Int(oldpos.row))
    terminal.dirtyRows.insert(Int(pos.row))
    return 1
}

private func onSetTermProp(_ prop: VTermProp, _ val: UnsafeMutablePointer<VTermValue>?, _ user: UnsafeMutableRawPointer?) -> Int32 {
    guard let val = val, let user = user else { return 1 }
    let terminal = Unmanaged<VTerminal>.fromOpaque(user).takeUnretainedValue()
    switch prop {
    case VTERM_PROP_ALTSCREEN:
        terminal.isAltScreen = val.pointee.boolean != 0
        // The buffer switch replaces every cell and the application redraws
        // (re-emitting any OSC 8 links); stale stamps must not carry over.
        terminal.hyperlinks.clearAll()
    case VTERM_PROP_MOUSE:
        let raw = Int(val.pointee.number)
        terminal.mouseMode = VTerminal.MouseMode(rawValue: raw) ?? .none
    default:
        break
    }
    return 1
}

private func onMoveRect(_ dest: VTermRect, _ src: VTermRect, _ user: UnsafeMutableRawPointer?) -> Int32 {
    let terminal = Unmanaged<VTerminal>.fromOpaque(user!).takeUnretainedValue()
    terminal.hyperlinks.moveRect(
        destStartRow: Int(dest.start_row), destStartCol: Int(dest.start_col),
        srcStartRow: Int(src.start_row), srcStartCol: Int(src.start_col),
        rowCount: Int(dest.end_row - dest.start_row),
        colCount: Int(dest.end_col - dest.start_col))
    // Return 0 so libvterm still damages the destination rect — this hook
    // only mirrors the move for hyperlink stamps; the renderer's existing
    // damage-driven repaint path must stay exactly as before.
    return 0
}

// OSC 8 hyperlinks arrive via libvterm's unrecognised-OSC fallback (libvterm
// has no native handler for command 8). Bodies may be fragmented; the
// HyperlinkGrid accumulates and applies them.
private func onUnrecognisedOSC(_ command: Int32, _ frag: VTermStringFragment, _ user: UnsafeMutableRawPointer?) -> Int32 {
    guard command == 8, let user = user else { return 0 }
    let terminal = Unmanaged<VTerminal>.fromOpaque(user).takeUnretainedValue()
    terminal.hyperlinks.feed(
        bytes: frag.str, length: Int(frag.len),
        initial: frag.initial, final: frag.final)
    return 1
}

// OSC 52 set-selection: libvterm has already parsed `OSC 52 ; <targets> ; <b64>`
// and base64-decoded the payload into the buffer we registered. Fragments
// arrive in order; we accumulate and flush to the macOS pasteboard on the
// final fragment. We do not implement the query callback — OSC 52 read is
// the security-sensitive half and stays off.
private func onSelectionSet(_ mask: VTermSelectionMask, _ frag: VTermStringFragment, _ user: UnsafeMutableRawPointer?) -> Int32 {
    guard let user = user else { return 1 }
    let terminal = Unmanaged<VTerminal>.fromOpaque(user).takeUnretainedValue()
    if frag.initial {
        terminal.selectionAccum.removeAll(keepingCapacity: true)
    }
    if let str = frag.str, frag.len > 0 {
        str.withMemoryRebound(to: UInt8.self, capacity: Int(frag.len)) { p in
            terminal.selectionAccum.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(frag.len)))
        }
    }
    if frag.final {
        let bytes = terminal.selectionAccum
        terminal.selectionAccum.removeAll(keepingCapacity: true)
        // Skip empty payloads. libvterm fires `set` with an empty final
        // fragment when the OSC 52 was malformed or the "clear" form was
        // used; clobbering the existing pasteboard would surprise the user.
        if !bytes.isEmpty {
            terminal.onSetClipboard(String(decoding: bytes, as: UTF8.self))
        }
    }
    return 1
}

final class VTerminal {
    enum MouseMode: Int {
        case none = 0
        case click = 1
        case drag = 2
        case move = 3
    }

    let vt: OpaquePointer
    let screen: OpaquePointer
    private(set) var rows: Int
    private(set) var cols: Int
    fileprivate(set) var cursorRow: Int = 0
    fileprivate(set) var cursorCol: Int = 0
    fileprivate(set) var cursorVisible: Bool = true
    fileprivate(set) var isAltScreen: Bool = false
    fileprivate(set) var mouseMode: MouseMode = .none
    var isDirty: Bool = false
    var dirtyRows: Set<Int> = []
    var fullRedrawNeeded: Bool = true  // first draw is always full

    /// Per-cell OSC 8 hyperlink stamps (libvterm cells can't carry them).
    let hyperlinks: HyperlinkGrid

    // Accumulator for fragments delivered by libvterm's OSC 52 set callback.
    fileprivate var selectionAccum: [UInt8] = []

    // OSC 52 -> system clipboard sink. Tests override to observe without
    // touching NSPasteboard.
    var onSetClipboard: (String) -> Void = { text in
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private var callbacks = VTermScreenCallbacks()
    private var selectionCallbacks = VTermSelectionCallbacks()
    private var fallbacks = VTermStateFallbacks()
    // libvterm decodes the OSC 52 base64 payload into this buffer before
    // calling our set callback. Sized to hold typical clipboard contents in
    // one fragment; larger payloads are delivered in multiple fragments and
    // accumulated in selectionAccum.
    private let selectionBuffer: UnsafeMutablePointer<CChar>
    private let selectionBufferLen = 65536

    private var passthrough = PassthroughDecoder()

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.hyperlinks = HyperlinkGrid(rows: rows, cols: cols)
        self.vt = vterm_new(Int32(rows), Int32(cols))
        vterm_set_utf8(self.vt, 1)
        self.screen = vterm_obtain_screen(self.vt)
        self.selectionBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: selectionBufferLen)

        callbacks.damage = onDamage
        callbacks.movecursor = onMoveCursor
        callbacks.moverect = onMoveRect
        callbacks.settermprop = onSetTermProp

        // LIFETIME: selfPtr is an unretained pointer to self. VTerminal must
        // outlive the vterm screen — ensured because vterm_free(vt) is called in
        // deinit, which runs only after all C callbacks have been unregistered.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        vterm_screen_set_callbacks(screen, &callbacks, selfPtr)

        selectionCallbacks.set = onSelectionSet
        // query intentionally left nil — OSC 52 read is the security-sensitive
        // half and we do not implement it.
        let state = vterm_obtain_state(vt)
        vterm_state_set_selection_callbacks(state, &selectionCallbacks, selfPtr,
                                            selectionBuffer, selectionBufferLen)

        // OSC 8 hyperlinks: libvterm routes OSCs it doesn't handle here.
        fallbacks.osc = onUnrecognisedOSC
        vterm_screen_set_unrecognised_fallbacks(screen, &fallbacks, selfPtr)

        vterm_screen_set_damage_merge(screen, VTERM_DAMAGE_SCROLL)
        // Allocate alt-screen buffer so DECSET 1049/1047/47 actually engage
        // and libvterm fires VTERM_PROP_ALTSCREEN settermprop callbacks.
        vterm_screen_enable_altscreen(screen, 1)
        vterm_screen_reset(screen, 1)
    }

    deinit {
        vterm_free(vt)
        selectionBuffer.deallocate()
    }

    func write(data: Data) {
        // Unwrap any tmux DCS passthrough wrappers (`\ePtmux;…\e\\`) before
        // feeding bytes to libvterm. libvterm's parser mishandles the doubled
        // ESCs inside the body, so the contained sequence (e.g. OSC 52) would
        // be lost otherwise. Bytes outside a passthrough are forwarded
        // verbatim.
        let processed = passthrough.process(data)
        guard !processed.isEmpty else { return }
        processed.withUnsafeBufferPointer { buf in
            _ = buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                vterm_input_write(vt, ptr, buf.count)
            }
        }
    }

    func flushDamage() {
        vterm_screen_flush_damage(screen)
        isDirty = false
    }

    func cell(row: Int, col: Int) -> VTermScreenCell {
        let pos = VTermPos(row: Int32(row), col: Int32(col))
        var cell = VTermScreenCell()
        vterm_screen_get_cell(screen, pos, &cell)
        return cell
    }

    func resize(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        // Stamps don't survive a resize; tmux fully redraws (re-emitting
        // OSC 8 for visible links) after the size change.
        hyperlinks.resize(rows: rows, cols: cols)
        vterm_set_size(vt, Int32(rows), Int32(cols))
        fullRedrawNeeded = true
    }

    /// The OSC 8 hyperlink id stamped on a cell (0 = none).
    func hyperlinkID(row: Int, col: Int) -> UInt32 {
        hyperlinks.id(row: row, col: col)
    }

    /// The OSC 8 hyperlink target stamped on a cell.
    func hyperlinkURI(row: Int, col: Int) -> String? {
        hyperlinks.uri(row: row, col: col)
    }

    /// Extract the Unicode string from a VTermScreenCell.
    /// cell.chars is a tuple of 6 UInt32 values (VTERM_MAX_CHARS_PER_CELL = 6).
    static func cellString(_ cell: VTermScreenCell) -> String {
        let first = cell.chars.0
        if first == 0 { return "" }
        // Fast path: single ASCII character (vast majority of terminal content)
        if first < 128 && cell.chars.1 == 0 {
            return String(Character(Unicode.Scalar(first)!))
        }
        // Slow path: multi-codepoint or non-ASCII
        var chars = cell.chars
        return withUnsafePointer(to: &chars) { ptr in
            ptr.withMemoryRebound(to: UInt32.self, capacity: 6) { p in
                var s = ""
                for i in 0..<6 {
                    let cp = p[i]
                    if cp == 0 { break }
                    if let scalar = Unicode.Scalar(cp) {
                        s.append(Character(scalar))
                    }
                }
                return s
            }
        }
    }

    /// Convert a VTermColor to RGB values, resolving indexed colors via the screen palette.
    static func colorRGB(_ color: VTermColor, screen: OpaquePointer) -> (UInt8, UInt8, UInt8) {
        var c = color
        vterm_screen_convert_color_to_rgb(screen, &c)
        return (c.rgb.red, c.rgb.green, c.rgb.blue)
    }

    // Cache NSColor objects to avoid per-cell allocation
    private static var colorCache: [UInt32: NSColor] = [:]

    static func cachedColor(r: UInt8, g: UInt8, b: UInt8) -> NSColor {
        let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        if let cached = colorCache[key] {
            return cached
        }
        let color = NSColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
        colorCache[key] = color
        return color
    }
}
