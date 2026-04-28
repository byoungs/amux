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
    guard let val = val else { return 1 }
    let terminal = Unmanaged<VTerminal>.fromOpaque(user!).takeUnretainedValue()
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

    private var callbacks = VTermScreenCallbacks()

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.vt = vterm_new(Int32(rows), Int32(cols))
        vterm_set_utf8(self.vt, 1)
        self.screen = vterm_obtain_screen(self.vt)

        callbacks.damage = onDamage
        callbacks.movecursor = onMoveCursor
        callbacks.settermprop = onSetTermProp

        // LIFETIME: selfPtr is an unretained pointer to self. VTerminal must
        // outlive the vterm screen — ensured because vterm_free(vt) is called in
        // deinit, which runs only after all C callbacks have been unregistered.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        vterm_screen_set_callbacks(screen, &callbacks, selfPtr)

        vterm_screen_set_damage_merge(screen, VTERM_DAMAGE_SCROLL)
        // Allocate the alt-screen buffer so DECSET 1049/1047/47 actually
        // engage. Without this, libvterm's screen settermprop short-circuits
        // when the alt-screen buffer is missing and isAltScreen never flips.
        vterm_screen_enable_altscreen(screen, 1)
        vterm_screen_reset(screen, 1)
    }

    deinit { vterm_free(vt) }

    func write(data: Data) {
        data.withUnsafeBytes { buf in
            if let ptr = buf.baseAddress?.assumingMemoryBound(to: CChar.self) {
                vterm_input_write(vt, ptr, data.count)
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
