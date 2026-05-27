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
    return 1
}

private func onSetTermProp(_ prop: VTermProp, _ val: UnsafeMutablePointer<VTermValue>?, _ user: UnsafeMutableRawPointer?) -> Int32 {
    guard let val = val, let user = user else { return 1 }
    let terminal = Unmanaged<VTerminal>.fromOpaque(user).takeUnretainedValue()
    switch prop {
    case VTERM_PROP_ALTSCREEN:
        terminal.isAltScreen = val.pointee.boolean != 0
    case VTERM_PROP_MOUSE:
        let raw = Int(val.pointee.number)
        terminal.mouseMode = VTerminal.MouseMode(rawValue: raw) ?? .none
    default:
        break
    }
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
        self.vt = vterm_new(Int32(rows), Int32(cols))
        vterm_set_utf8(self.vt, 1)
        self.screen = vterm_obtain_screen(self.vt)
        self.selectionBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: selectionBufferLen)

        callbacks.damage = onDamage
        callbacks.movecursor = onMoveCursor
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

    /// Clear all screen state. Used by scan-mode tile rendering to replay a
    /// fresh snapshot into an existing VTerminal without re-allocating.
    func reset() {
        vterm_screen_reset(screen, 1)
        fullRedrawNeeded = true
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
        vterm_set_size(vt, Int32(rows), Int32(cols))
        fullRedrawNeeded = true
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
