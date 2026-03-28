# amux-term: Native macOS Terminal (libvterm + CoreText)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS terminal app ("amux-term") that renders tmux output via libvterm + CoreText, with Cmd-key shortcuts remapped to Ctrl so tmux handles them natively. No flickering, no third-party terminal library.

**Architecture:** Vendor libvterm (C, MIT, ~9 files) as an SPM C target. A thin Swift wrapper feeds PTY bytes to libvterm and reads the cell grid. A CoreText NSView renders the grid. Keyboard input remaps Cmd to Ctrl before sending raw bytes to the PTY. CADisplayLink-driven redraw (main thread, 60fps) eliminates flicker. The binary is named "amux-term" and is completely separate from the "amux" Rust binary — no changes to main-line amux code.

**Tech Stack:** Swift 5.9+, AppKit (NSView + CoreText), libvterm (vendored C), macOS 14+

**Anti-flicker strategy:** Feed bytes to libvterm continuously (it updates cells in memory). A CADisplayLink fires on the main run loop at display refresh rate. When dirty, flush libvterm damage and redraw — all on the main thread, no race conditions. Rapid tmux updates are naturally batched into single frames.

**Session isolation:** During development, the app attaches to `amux-dev` (not `amux`) to avoid fighting with the existing iTerm2 workflow. This can be changed to `amux` when the app is ready for daily use.

---

## Known Limitations (deferred to future tasks)

These are intentionally omitted from this plan to keep scope minimal:

- **Mouse support** — clicking panes, scroll wheel, resize handles
- **Text selection** — click-drag to select, Cmd-C to copy
- **Scrollback buffer** — libvterm's `sb_pushline`/`sb_popline` callbacks
- **Focus events** — `\e[I` / `\e[O` sequences for tmux focus-events
- **Custom terminfo** — TERM=xterm-256color is a reasonable default but a custom entry may improve accuracy later

---

## File Structure

```
app/
  Package.swift                    # SPM manifest: CVterm C target + AmuxTerm Swift target
  Sources/
    CVterm/                        # Vendored libvterm (C library)
      include/
        vterm.h                    # Public API
        vterm_keycodes.h           # Key code enums
      src/
        vterm.c                    # Core VTerm management
        parser.c                   # Byte stream -> escape sequence parser
        state.c                    # Terminal state machine
        screen.c                   # Cell grid with damage tracking
        pen.c                      # Text attributes (bold, color, etc.)
        encoding.c                 # Character set encoding
        keyboard.c                 # Keyboard input -> escape sequences
        mouse.c                    # Mouse input handling
        unicode.c                  # Unicode width tables
        vterm_internal.h           # Internal structs
        utf8.h                     # UTF-8 helpers
        rect.h                     # Rectangle helpers
        fullwidth.inc              # Pre-generated width tables
        encoding/
          DECdrawing.inc           # DEC drawing characters
          uk.inc                   # UK character set
    AmuxTerm/
      AppDelegate.swift            # NSApplicationDelegate, window setup, lifecycle
      TerminalView.swift           # NSView subclass: CoreText cell-grid renderer
      VTerminal.swift              # Swift wrapper around libvterm C API
      PTY.swift                    # forkpty(), DispatchIO read/write, resize
      KeyInput.swift               # NSEvent -> PTY bytes, Cmd->Ctrl remapping
      KeyInputTests.swift          # Unit tests for key encoding (CSI u sequences)
Makefile                           # Add `make app` target (existing file, append)
```

---

## Task 1: Vendor libvterm as SPM C Target

**Files:**
- Create: `app/Package.swift`
- Create: `app/Sources/CVterm/include/vterm.h` (from neovim/libvterm)
- Create: `app/Sources/CVterm/include/vterm_keycodes.h` (from neovim/libvterm)
- Create: `app/Sources/CVterm/src/*.c` and support files (from neovim/libvterm)
- Create: `app/Sources/AmuxTerm/AppDelegate.swift`
- Modify: `Makefile`

- [ ] **Step 1: Download libvterm source from Neovim's fork**

```bash
cd /tmp
git clone https://github.com/neovim/libvterm.git
cd libvterm
# Pin to a known-good commit for reproducible builds.
# Check the latest commit hash and record it here before proceeding.
git log --oneline -1
```

Record the commit hash in a comment in Package.swift for reproducibility.

- [ ] **Step 2: Create the SPM directory structure**

```bash
mkdir -p app/Sources/CVterm/include
mkdir -p app/Sources/CVterm/src/encoding
mkdir -p app/Sources/AmuxTerm
```

- [ ] **Step 3: Copy libvterm source files**

```bash
# Public headers
cp /tmp/libvterm/include/vterm.h app/Sources/CVterm/include/
cp /tmp/libvterm/include/vterm_keycodes.h app/Sources/CVterm/include/

# Source files
for f in vterm.c parser.c state.c screen.c pen.c encoding.c keyboard.c mouse.c unicode.c; do
  cp /tmp/libvterm/src/$f app/Sources/CVterm/src/
done

# Internal headers
cp /tmp/libvterm/src/vterm_internal.h app/Sources/CVterm/src/
cp /tmp/libvterm/src/utf8.h app/Sources/CVterm/src/
cp /tmp/libvterm/src/rect.h app/Sources/CVterm/src/

# Pre-generated tables
cp /tmp/libvterm/src/fullwidth.inc app/Sources/CVterm/src/
cp /tmp/libvterm/src/encoding/DECdrawing.inc app/Sources/CVterm/src/encoding/
cp /tmp/libvterm/src/encoding/uk.inc app/Sources/CVterm/src/encoding/
```

- [ ] **Step 4: Inspect vterm.h for exact API signatures**

Before writing any Swift code, read `app/Sources/CVterm/include/vterm.h` and document:
1. The exact signature of `VTermScreenCallbacks` (parameter types for damage, movecursor, settermprop)
2. The exact layout of `VTermValue` union (is `string` a `char*` or `VTermStringFragment`?)
3. Whether `VTermPos` and `VTermRect` are passed by value or pointer in callbacks

This is CRITICAL — the Swift wrapper code must match these signatures exactly. The plan's code below is based on the expected API; adapt if the actual header differs.

- [ ] **Step 5: Create Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmuxTerm",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CVterm",
            path: "Sources/CVterm",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
            ]
        ),
        .executableTarget(
            name: "AmuxTerm",
            dependencies: ["CVterm"],
            path: "Sources/AmuxTerm"
        ),
    ]
)
```

- [ ] **Step 6: Create minimal Swift entry point to verify linking**

Create `app/Sources/AmuxTerm/AppDelegate.swift`:

```swift
import AppKit
import CVterm

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Verify libvterm links correctly
        let vt = vterm_new(24, 80)!
        vterm_free(vt)
        print("libvterm linked successfully")
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
```

- [ ] **Step 7: Build and verify**

Run: `cd app && swift build`
Expected: Compiles libvterm C sources + Swift entry point, links successfully, prints "libvterm linked successfully".

- [ ] **Step 8: Add Makefile targets**

Append to the existing Makefile (before the `# -- Convenience` section):

```makefile
# -- Native App ------------------------------------------------

app:
	cd app && swift build -c release
	@echo "Built amux-term -- run: app/.build/release/AmuxTerm"

app-dev:
	cd app && swift build
	@echo "Built amux-term (debug) -- run: app/.build/debug/AmuxTerm"

app-test: app-dev
	@echo "Running KeyInput tests..."
	app/.build/debug/AmuxTerm --run-tests 2>&1 || true
	@echo "(Tests run at debug launch via #if DEBUG block)"

app-clean:
	cd app && swift package clean
```

Add `app app-dev app-test app-clean` to the `.PHONY` line.

- [ ] **Step 9: Clean up and commit**

```bash
rm -rf /tmp/libvterm
git add app/ Makefile
git commit -m "vendor libvterm as SPM C target, add make app targets"
```

---

## Task 2: Swift Wrapper Around libvterm

**Files:**
- Create: `app/Sources/AmuxTerm/VTerminal.swift`
- Modify: `app/Sources/AmuxTerm/AppDelegate.swift` (test the wrapper)

Wraps the C API in a Swift class. Feeds bytes via `write(data:)`, reads cells via `cell(row:col:)`. Uses `@convention(c)` top-level functions for callbacks (NOT closures — Swift closures cannot be used as C function pointers).

**IMPORTANT:** Before writing this code, the implementer MUST:

1. Read `app/Sources/CVterm/include/vterm.h` to verify:
   - The exact field types in `VTermScreenCallbacks` (are positions passed by value or pointer?)
   - The exact layout of `VTermValue` (is the string member a `VTermStringFragment` or `const char*`?)
   - Adapt the callback signatures below to match the actual header.

2. After building CVterm, inspect the **Swift module interface** to see how Clang imported the C types:
   - Run: `cd app && swift build` then check how Swift sees the types by writing a small test
   - `VTermScreenCellAttrs` uses C bitfields — Swift may import field names differently (e.g., `bold` might become a computed property or be mangled). Test access with `var a = VTermScreenCellAttrs(); print(a.bold)` to verify.
   - `VTermColor` is a C union — Swift may not expose `.rgb.red` directly. You may need `withUnsafePointer` + memory reinterpretation. Test: `var c = VTermColor(); print(c.rgb.red)` — if this doesn't compile, use unsafe access.
   - `VTERM_DAMAGE_SCROLL` — verify this constant exists in Swift's import. It may be imported as an enum case or raw value. Test: `print(VTERM_DAMAGE_SCROLL)`.

3. Adapt ALL code in this task AND Task 4 (renderer) to match the actual Swift imports. The code below is a best-guess based on the C header — the real Swift interface may differ.

4. **If a callback assignment doesn't compile** (e.g., `callbacks.damage = onDamage`), use this technique to discover the expected type:
   ```swift
   print(type(of: callbacks.damage))  // prints the exact function pointer type Swift expects
   ```
   Then adjust the free function's signature to match exactly.

- [ ] **Step 1: Create `app/Sources/AmuxTerm/VTerminal.swift`**

```swift
import Foundation
import CVterm

// MARK: - C callbacks (must be top-level @convention(c) functions, not closures)

private func onDamage(_ rect: VTermRect, _ user: UnsafeMutableRawPointer?) -> Int32 {
    let terminal = Unmanaged<VTerminal>.fromOpaque(user!).takeUnretainedValue()
    terminal.isDirty = true
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
    // NOTE: Check vterm.h for VTermValue layout. If string is a VTermStringFragment,
    // you need to check val.pointee.string.initial and accumulate fragments.
    // If string is a simple const char*, use val.pointee.string directly.
    // Adapt this code to match the actual header.
    return 1
}

/// Swift wrapper around libvterm. Owns a VTerm instance and its screen.
/// Feed PTY output via write(data:), read cells via cell(row:col:).
/// Thread-unsafe — all calls must happen on the main thread.
final class VTerminal {
    let vt: OpaquePointer
    let screen: OpaquePointer
    private(set) var rows: Int
    private(set) var cols: Int
    private(set) var cursorRow: Int = 0
    private(set) var cursorCol: Int = 0
    private(set) var cursorVisible: Bool = true
    var isDirty: Bool = false

    // Must be stored as an instance property to keep the struct alive
    private var callbacks = VTermScreenCallbacks()

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.vt = vterm_new(Int32(rows), Int32(cols))
        vterm_set_utf8(self.vt, 1)
        self.screen = vterm_obtain_screen(self.vt)

        // Set up screen callbacks — @convention(c) functions defined above
        callbacks.damage = onDamage
        callbacks.movecursor = onMoveCursor
        callbacks.settermprop = onSetTermProp

        // IMPORTANT: passUnretained is safe here because VTerminal outlives the
        // vterm instance (we free vterm in deinit). But the display link or PTY
        // must NOT hold unretained refs that could outlive this object.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        vterm_screen_set_callbacks(screen, &callbacks, selfPtr)

        // Hold all damage until we explicitly flush (for frame batching)
        vterm_screen_set_damage_merge(screen, VTERM_DAMAGE_SCROLL)
        vterm_screen_reset(screen, 1)
    }

    deinit {
        vterm_free(vt)
    }

    /// Feed raw bytes from the PTY into the terminal.
    func write(data: Data) {
        data.withUnsafeBytes { buf in
            if let ptr = buf.baseAddress?.assumingMemoryBound(to: CChar.self) {
                vterm_input_write(vt, ptr, data.count)
            }
        }
    }

    /// Flush pending damage — call before reading cells for rendering.
    /// Must be called on the main thread.
    func flushDamage() {
        vterm_screen_flush_damage(screen)
        isDirty = false
    }

    /// Read a cell at the given position.
    func cell(row: Int, col: Int) -> VTermScreenCell {
        var pos = VTermPos(row: Int32(row), col: Int32(col))
        var cell = VTermScreenCell()
        vterm_screen_get_cell(screen, pos, &cell)
        return cell
    }

    /// Resize the terminal grid.
    func resize(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        vterm_set_size(vt, Int32(rows), Int32(cols))
    }

    /// Get the Unicode character(s) for a cell as a String.
    static func cellString(_ cell: VTermScreenCell) -> String {
        var chars = cell.chars
        return withUnsafePointer(to: &chars) { ptr in
            ptr.withMemoryRebound(to: UInt32.self, capacity: Int(VTERM_MAX_CHARS_PER_CELL)) { p in
                var s = ""
                for i in 0..<Int(VTERM_MAX_CHARS_PER_CELL) {
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

    /// Extract RGB color from a VTermColor.
    static func colorRGB(_ color: VTermColor, screen: OpaquePointer) -> (UInt8, UInt8, UInt8) {
        var c = color
        vterm_screen_convert_color_to_rgb(screen, &c)
        return (c.rgb.red, c.rgb.green, c.rgb.blue)
    }
}
```

- [ ] **Step 2: Update AppDelegate.swift to test the wrapper**

```swift
import AppKit
import CVterm

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let term = VTerminal(rows: 24, cols: 80)

        // Feed some text
        let hello = "Hello, amux-term!\r\n"
        term.write(data: hello.data(using: .utf8)!)
        term.flushDamage()

        // Read back cells
        var line = ""
        for col in 0..<80 {
            let c = term.cell(row: 0, col: col)
            let s = VTerminal.cellString(c)
            if !s.isEmpty { line += s }
        }
        print("Row 0: '\(line.trimmingCharacters(in: .whitespaces))'")
        print("Cursor at: (\(term.cursorRow), \(term.cursorCol))")
        print("VTerminal wrapper works")
        NSApplication.shared.terminate(nil)
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `cd app && swift build && .build/debug/AmuxTerm`
Expected: Prints "Row 0: 'Hello, amux-term!'" and cursor position (1, 0).

- [ ] **Step 4: Commit**

```bash
git add app/Sources/AmuxTerm/VTerminal.swift app/Sources/AmuxTerm/AppDelegate.swift
git commit -m "add Swift wrapper around libvterm C API"
```

---

## Task 3: PTY Management

**Files:**
- Create: `app/Sources/AmuxTerm/PTY.swift`
- Modify: `app/Sources/AmuxTerm/AppDelegate.swift` (test PTY + VTerminal together)

Spawns tmux via forkpty(), reads output with DispatchIO on the main queue, provides a write method for keyboard input. Sets TERM=xterm-256color.

- [ ] **Step 1: Create `app/Sources/AmuxTerm/PTY.swift`**

```swift
import Foundation
import Darwin

/// Manages a pseudo-terminal connected to a child process (tmux).
/// Reads output asynchronously via DispatchIO on the main queue.
/// All callbacks fire on main thread — no synchronization needed.
final class PTY {
    let masterFd: Int32
    let childPid: pid_t
    private var dispatchIO: DispatchIO?
    var onOutput: ((Data) -> Void)?
    var onExit: (() -> Void)?

    /// Spawn a process in a new PTY.
    init?(executable: String, args: [String], rows: UInt16, cols: UInt16, env: [String: String] = [:]) {
        var master: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        let pid = forkpty(&master, nil, nil, &ws)
        guard pid >= 0 else { return nil }

        if pid == 0 {
            // Child process — set env vars and exec
            // TERM must be xterm-256color for tmux to enable extended-keys, truecolor, etc.
            setenv("TERM", "xterm-256color", 1)
            for (key, value) in env {
                setenv(key, value, 1)
            }
            let cArgs = args.map { strdup($0) } + [nil]
            execv(executable, cArgs)
            _exit(127)
        }

        self.masterFd = master
        self.childPid = pid
    }

    /// Start reading output asynchronously on the main queue.
    func startReading() {
        let io = DispatchIO(type: .stream, fileDescriptor: masterFd,
                            queue: .main, cleanupHandler: { [weak self] _ in
            self?.onExit?()
        })
        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: .max, queue: .main) { [weak self] done, data, error in
            if let data = data, !data.isEmpty {
                self?.onOutput?(Data(data))
            }
            // NOTE: onExit is called by the cleanupHandler above, not here.
            // Calling it in both places would fire it twice.
        }
        self.dispatchIO = io
    }

    /// Write keyboard input to the PTY.
    func write(_ data: Data) {
        data.withUnsafeBytes { buf in
            if let ptr = buf.baseAddress {
                Darwin.write(masterFd, ptr, data.count)
            }
        }
    }

    /// Resize the PTY (sends SIGWINCH to child).
    func resize(rows: UInt16, cols: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(masterFd, TIOCSWINSZ, &ws)
    }

    deinit {
        dispatchIO?.close()
        close(masterFd)
    }
}
```

- [ ] **Step 2: Update AppDelegate.swift to test PTY + VTerminal**

```swift
import AppKit
import CVterm

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var pty: PTY?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Find tmux
        let tmuxPath: String
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/tmux") {
            tmuxPath = "/opt/homebrew/bin/tmux"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/tmux") {
            tmuxPath = "/usr/local/bin/tmux"
        } else {
            fatalError("tmux not found. Install with: brew install tmux --HEAD")
        }

        let rows: UInt16 = 24
        let cols: UInt16 = 80
        let terminal = VTerminal(rows: Int(rows), cols: Int(cols))

        // Use amux-dev session to avoid fighting with iTerm2's amux session
        guard let pty = PTY(executable: tmuxPath,
                            args: ["tmux", "new", "-A", "-s", "amux-dev"],
                            rows: rows, cols: cols) else {
            fatalError("Failed to create PTY")
        }
        self.pty = pty

        pty.onOutput = { data in
            terminal.write(data: data)
            terminal.flushDamage()
            // Print first non-empty row
            var line = ""
            for col in 0..<Int(cols) {
                let c = terminal.cell(row: 0, col: col)
                let s = VTerminal.cellString(c)
                if !s.isEmpty { line += s }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                print("Row 0: '\(trimmed)'")
            }
        }

        pty.onExit = {
            print("PTY exited")
            NSApplication.shared.terminate(nil)
        }

        pty.startReading()
        print("PTY + VTerminal integration running (2 second test)...")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("PTY + VTerminal integration works")
            // Kill test session
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: tmuxPath)
            kill.arguments = ["kill-session", "-t", "amux-dev"]
            try? kill.run()
            kill.waitUntilExit()
            NSApplication.shared.terminate(nil)
        }
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `cd app && swift build && .build/debug/AmuxTerm`
Expected: Prints row content from tmux, then "PTY + VTerminal integration works" after 2 seconds.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/AmuxTerm/PTY.swift app/Sources/AmuxTerm/AppDelegate.swift
git commit -m "add PTY management with forkpty and DispatchIO"
```

---

## Task 4: CoreText Terminal Renderer

**Files:**
- Create: `app/Sources/AmuxTerm/TerminalView.swift`
- Modify: `app/Sources/AmuxTerm/AppDelegate.swift` (launch as a real GUI app)

The NSView subclass that renders the libvterm cell grid using CoreText. Uses `NSView.displayLink(target:selector:)` (macOS 14+, main run loop) for frame-driven redraw — all on the main thread, no race conditions.

**IMPORTANT API NOTE:** `CADisplayLink(target:selector:)` is iOS-only (`API_UNAVAILABLE(macos)`). On macOS 14+, use `NSView.displayLink(target:selector:)` instead. This can only be called when the view has a window, so display link setup is deferred to `viewDidMoveToWindow()`.

- [ ] **Step 1: Create `app/Sources/AmuxTerm/TerminalView.swift`**

```swift
import AppKit
import CoreText
import CVterm

/// Renders a VTerminal cell grid using CoreText.
/// Redraws at display refresh rate via NSView.displayLink — all on main thread.
final class TerminalView: NSView {
    let terminal: VTerminal
    let pty: PTY
    private var displayLink: CADisplayLink?
    private var font: CTFont
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    private var fontAscent: CGFloat = 0

    // Default terminal colors (match amux's dark theme)
    private let defaultBg = CGColor(gray: 0, alpha: 1)

    init(terminal: VTerminal, pty: PTY) {
        self.terminal = terminal
        self.pty = pty
        self.font = CTFontCreateWithName("Menlo" as CFString, 14, nil)

        super.init(frame: .zero)
        wantsLayer = true

        updateFontMetrics()

        // Wire PTY output -> VTerminal (all on main thread via DispatchIO)
        pty.onOutput = { [weak self] data in
            self?.terminal.write(data: data)
        }

        // NOTE: Display link starts in viewDidMoveToWindow (needs a screen)
        pty.startReading()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateFontMetrics() {
        fontAscent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        cellHeight = ceil(fontAscent + descent + leading)

        // Measure advance width of 'M' for cell width
        var chars: [UniChar] = [0x4D] // 'M'
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
        cellWidth = ceil(advance.width)
    }

    // MARK: - Display Link (main thread, display refresh rate)
    // IMPORTANT: CADisplayLink(target:selector:) is iOS-only.
    // On macOS 14+, use NSView.displayLink(target:selector:) which requires
    // the view to be attached to a window (have a screen).

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && displayLink == nil {
            startDisplayLink()
        } else if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func startDisplayLink() {
        // NSView.displayLink(target:selector:) — macOS 14+ only
        let dl = self.displayLink(target: self, selector: #selector(displayLinkFired))
        dl.add(to: .main, forMode: .common)
        self.displayLink = dl
    }

    @objc private func displayLinkFired() {
        if terminal.isDirty {
            terminal.flushDamage()
            needsDisplay = true
        }
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard cellWidth > 0, cellHeight > 0 else { return }

        let newCols = max(1, Int(newSize.width / cellWidth))
        let newRows = max(1, Int(newSize.height / cellHeight))

        if newRows != terminal.rows || newCols != terminal.cols {
            terminal.resize(rows: newRows, cols: newCols)
            pty.resize(rows: UInt16(newRows), cols: UInt16(newCols))
            needsDisplay = true
        }
    }

    // MARK: - Rendering

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Fix CoreText in flipped coordinates — without this, text renders upside down
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)

        // Fill background
        ctx.setFillColor(defaultBg)
        ctx.fill(bounds)

        for row in 0..<terminal.rows {
            for col in 0..<terminal.cols {
                let cell = terminal.cell(row: row, col: col)
                if cell.width < 1 { continue } // skip continuation cells (wide chars)
                drawCell(cell, row: row, col: col, ctx: ctx)
            }
        }

        // Draw cursor
        if terminal.cursorVisible {
            drawCursor(row: terminal.cursorRow, col: terminal.cursorCol, ctx: ctx)
        }
    }

    private func drawCell(_ cell: VTermScreenCell, row: Int, col: Int, ctx: CGContext) {
        let x = CGFloat(col) * cellWidth
        let y = CGFloat(row) * cellHeight
        let w = cellWidth * CGFloat(cell.width)
        let rect = CGRect(x: x, y: y, width: w, height: cellHeight)

        // Colors
        // NOTE: cell.attrs.reverse, cell.attrs.bold, etc. are C bitfields.
        // If Swift doesn't expose them as simple properties, use the technique
        // discovered in Task 2 Step 2 (inspecting the Swift module interface).
        // Similarly, VTerminal.colorRGB may need adaptation if VTermColor
        // union access doesn't work through Swift's automatic import.
        let isReverse = cell.attrs.reverse != 0
        let (fgR, fgG, fgB) = VTerminal.colorRGB(cell.fg, screen: terminal.screen)
        let (bgR, bgG, bgB) = VTerminal.colorRGB(cell.bg, screen: terminal.screen)

        let bgColor = isReverse
            ? CGColor(red: CGFloat(fgR)/255, green: CGFloat(fgG)/255, blue: CGFloat(fgB)/255, alpha: 1)
            : CGColor(red: CGFloat(bgR)/255, green: CGFloat(bgG)/255, blue: CGFloat(bgB)/255, alpha: 1)
        let fgColor = isReverse
            ? NSColor(red: CGFloat(bgR)/255, green: CGFloat(bgG)/255, blue: CGFloat(bgB)/255, alpha: 1)
            : NSColor(red: CGFloat(fgR)/255, green: CGFloat(fgG)/255, blue: CGFloat(fgB)/255, alpha: 1)

        // Background (skip if default black to avoid overdraw)
        if bgColor != defaultBg {
            ctx.setFillColor(bgColor)
            ctx.fill(rect)
        }

        // Character
        let str = VTerminal.cellString(cell)
        guard !str.isEmpty, str != " " else { return }

        // Font variant for bold/italic
        var traits: CTFontSymbolicTraits = []
        if cell.attrs.bold != 0 { traits.insert(.boldTrait) }
        if cell.attrs.italic != 0 { traits.insert(.italicTrait) }
        let drawFont: CTFont
        if !traits.isEmpty, let variant = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) {
            drawFont = variant
        } else {
            drawFont = font
        }

        // Draw text — baseline is fontAscent below top of cell
        let attrs: [NSAttributedString.Key: Any] = [
            .font: drawFont,
            .foregroundColor: fgColor,
        ]
        let attrStr = NSAttributedString(string: str, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.textPosition = CGPoint(x: x, y: y + fontAscent)
        CTLineDraw(line, ctx)

        // Underline
        if cell.attrs.underline != 0 {
            let underY = y + fontAscent + 2
            ctx.setStrokeColor(fgColor.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: underY))
            ctx.addLine(to: CGPoint(x: x + w, y: underY))
            ctx.strokePath()
        }

        // Strikethrough
        if cell.attrs.strike != 0 {
            let strikeY = y + cellHeight / 2
            ctx.setStrokeColor(fgColor.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: strikeY))
            ctx.addLine(to: CGPoint(x: x + w, y: strikeY))
            ctx.strokePath()
        }
    }

    private func drawCursor(row: Int, col: Int, ctx: CGContext) {
        let x = CGFloat(col) * cellWidth
        let y = CGFloat(row) * cellHeight
        let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
        ctx.setFillColor(CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 0.5))
        ctx.fill(rect)
    }

    // MARK: - Keyboard Input

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let data = KeyInput.bytes(for: event) {
            pty.write(data)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if let data = KeyInput.bytes(for: event) {
                pty.write(data)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Paste support

    override func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string),
              let data = str.data(using: .utf8) else { return }
        // Bracket paste mode: wrap in ESC [200~ ... ESC [201~
        let start = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~
        let end = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])   // ESC[201~
        pty.write(start)
        pty.write(data)
        pty.write(end)
    }
}
```

- [ ] **Step 2: Update AppDelegate.swift to launch as a real GUI app**

```swift
import AppKit
import CVterm

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var termView: TerminalView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Find tmux
        let tmuxPath: String
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/tmux") {
            tmuxPath = "/opt/homebrew/bin/tmux"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/tmux") {
            tmuxPath = "/usr/local/bin/tmux"
        } else {
            fatalError("tmux not found. Install with: brew install tmux --HEAD")
        }

        let rows: UInt16 = 40
        let cols: UInt16 = 120
        let terminal = VTerminal(rows: Int(rows), cols: Int(cols))

        // Use amux-dev session to avoid fighting with iTerm2
        guard let pty = PTY(executable: tmuxPath,
                            args: ["tmux", "new", "-A", "-s", "amux-dev"],
                            rows: rows, cols: cols) else {
            fatalError("Failed to create PTY")
        }

        let termView = TerminalView(terminal: terminal, pty: pty)
        self.termView = termView

        pty.onExit = {
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }

        // Window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "amux-term"
        window.contentView = termView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(termView)
        self.window = window

        // Menu bar (suppress system Cmd-N/P/S and add Cmd-Q, Cmd-V)
        let menuBar = NSMenu()
        let appMenuItem = NSMenuItem()
        menuBar.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit amux-term", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        menuBar.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = menuBar
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `cd app && swift build`
Expected: Compiles without errors.

- [ ] **Step 4: Manual test**

Run: `app/.build/debug/AmuxTerm`
Expected: A native window appears showing a tmux session (amux-dev). Text renders with colors. Typing works. Window resize reflows. No flickering. Cmd-Q quits. Cmd-V pastes.

**TEXT RENDERING DEBUG:** CoreText in a flipped NSView is tricky. If text appears upside down:
1. Try `ctx.textMatrix = .identity` (remove the flip) and position baseline at `y + cellHeight - fontDescent` instead of `y + fontAscent`
2. Or use `ctx.saveGState()` / `ctx.translateBy(x: x, y: y + cellHeight)` / `ctx.scaleBy(x: 1, y: -1)` per cell and draw at baseline (0, fontDescent)
3. Test with a simple string first: feed `"ABC\r\n"` to VTerminal, render, verify A/B/C are right-side up
This WILL need interactive debugging — commit a working version even if the approach differs from the plan.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/AmuxTerm/TerminalView.swift app/Sources/AmuxTerm/AppDelegate.swift
git commit -m "add CoreText terminal renderer with CADisplayLink anti-flicker"
```

---

## Task 5: Keyboard Input with Cmd-to-Ctrl Remapping

**Files:**
- Create: `app/Sources/AmuxTerm/KeyInput.swift`

All keyboard encoding logic in one file. Remaps Cmd+key to Ctrl+key using CSI u encoding (`ESC [ codepoint ; 5 u`), which tmux understands when `extended-keys always` is set.

**IMPORTANT:** The CSI u encoding must match what tmux expects. Before finalizing, test by running `cat -v` inside tmux in iTerm2, pressing Ctrl-1, Ctrl-=, Ctrl--, and recording the exact byte sequences. The plan uses CSI u encoding below; adapt if tmux expects something different.

- [ ] **Step 1: Create `app/Sources/AmuxTerm/KeyInput.swift`**

```swift
import AppKit

/// Translates NSEvents into bytes for the PTY.
/// Remaps Cmd+key -> Ctrl+key so tmux handles shortcuts natively via CSI u encoding.
enum KeyInput {

    /// Convert a keyDown NSEvent to PTY bytes.
    /// Returns nil if the event should not be sent (e.g., Cmd-Q for app quit).
    static func bytes(for event: NSEvent) -> Data? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmd = flags.contains(.command)
        let hasCtrl = flags.contains(.control)

        guard let chars = event.charactersIgnoringModifiers else { return nil }
        guard !chars.isEmpty else { return nil }

        // Cmd-Q: let the system handle app quit
        if hasCmd && chars == "q" { return nil }
        // Cmd-V: let the system handle paste via menu
        if hasCmd && chars == "v" { return nil }

        // Cmd+key -> remap to Ctrl+key
        if hasCmd {
            return ctrlBytes(for: chars)
        }

        // Ctrl+key (user pressed Ctrl directly)
        if hasCtrl {
            return ctrlBytes(for: chars)
        }

        // Special keys (no modifiers)
        switch event.keyCode {
        case 36:  return Data([0x0D])                       // Return
        case 48:  return Data([0x09])                       // Tab
        case 53:  return Data([0x1B])                       // Escape
        case 51:  return Data([0x7F])                       // Backspace
        case 117: return "\u{1B}[3~".data(using: .utf8)     // Forward Delete
        case 123: return "\u{1B}[D".data(using: .utf8)      // Left
        case 124: return "\u{1B}[C".data(using: .utf8)      // Right
        case 125: return "\u{1B}[B".data(using: .utf8)      // Down
        case 126: return "\u{1B}[A".data(using: .utf8)      // Up
        case 115: return "\u{1B}[H".data(using: .utf8)      // Home
        case 119: return "\u{1B}[F".data(using: .utf8)      // End
        case 116: return "\u{1B}[5~".data(using: .utf8)     // Page Up
        case 121: return "\u{1B}[6~".data(using: .utf8)     // Page Down
        default: break
        }

        // Normal character input
        return event.characters?.data(using: .utf8)
    }

    /// Convert a character to Ctrl-modified bytes using CSI u encoding.
    /// CSI u format: ESC [ <codepoint> ; <modifier> u
    /// Ctrl modifier = 5 (1 + 4)
    ///
    /// tmux with `extended-keys always` expects this encoding for C-1..C-9, C-=, C--, etc.
    /// For letters (C-a through C-z), we send the traditional control character (0x01-0x1A)
    /// since that's universally supported.
    static func ctrlBytes(for chars: String) -> Data {
        guard let scalar = chars.unicodeScalars.first else { return Data() }
        let codepoint = scalar.value

        // Ctrl + letter: traditional control character (0x01-0x1A)
        if codepoint >= 0x61 && codepoint <= 0x7A { // a-z
            return Data([UInt8(codepoint - 0x60)])
        }
        if codepoint >= 0x41 && codepoint <= 0x5A { // A-Z
            return Data([UInt8(codepoint - 0x40)])
        }

        // Everything else: CSI u encoding
        // ESC [ <codepoint> ; 5 u
        return csiU(codepoint: Int(codepoint), modifier: 5)
    }

    /// Generate a CSI u sequence: ESC [ <codepoint> ; <modifier> u
    static func csiU(codepoint: Int, modifier: Int) -> Data {
        return "\u{1B}[\(codepoint);\(modifier)u".data(using: .utf8)!
    }
}
```

This encodes:
- Cmd-1 -> `ESC[49;5u` (codepoint 49 = '1', modifier 5 = Ctrl)
- Cmd-= -> `ESC[61;5u` (codepoint 61 = '=')
- Cmd-- -> `ESC[45;5u` (codepoint 45 = '-')
- Cmd-n -> `0x0E` (traditional Ctrl-N)
- Cmd-p -> `0x10` (traditional Ctrl-P)

- [ ] **Step 2: Build and verify**

Run: `cd app && swift build`
Expected: Compiles without errors.

- [ ] **Step 3: Manual test**

Run: `app/.build/debug/AmuxTerm`
Test in the amux-dev session:
- Type normally — characters appear
- Arrow keys, Enter, Tab, Escape work
- Cmd-1..9 (zoom to pane — needs amux configured on the session)
- Cmd-= (zoom in)
- Cmd-- (zoom out)
- Cmd-V (paste from clipboard)
- Cmd-Q (quits app, tmux session stays alive)

**If Cmd-number shortcuts don't work:** Run `cat -v` inside tmux in iTerm2 and press Ctrl-1. Compare the output with `ESC[49;5u`. If tmux expects a different encoding, update the `ctrlBytes` function.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/AmuxTerm/KeyInput.swift
git commit -m "add keyboard input with Cmd-to-Ctrl remapping via CSI u encoding"
```

---

## Task 6: KeyInput Unit Tests

**Files:**
- Create: `app/Sources/AmuxTerm/KeyInputTests.swift`

The keyboard encoding is where the SwiftTerm version failed. These tests verify the exact byte sequences without needing to launch the app or a tmux session.

The tests use a `#if DEBUG` runner function called from AppDelegate during debug builds. This avoids SPM testTarget complexity (which would require splitting KeyInput into a library target). The test function runs assertions at app launch and prints results to stdout.

- [ ] **Step 0: Add test runner call to AppDelegate**

In `AppDelegate.swift`, add at the top of `applicationDidFinishLaunching`:

```swift
#if DEBUG
KeyInputTests.runAll()
#endif
```

- [ ] **Step 1: Write tests for CSI u encoding**

Create `app/Sources/AmuxTerm/KeyInputTests.swift`:

```swift
#if DEBUG
import Foundation

enum KeyInputTests {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ actual: Data, _ expected: Data) {
            if actual == expected {
                passed += 1
            } else {
                failed += 1
                print("FAIL: \(name)")
                print("  expected: \(expected.map { String(format: "%02x", $0) }.joined(separator: " "))")
                print("  actual:   \(actual.map { String(format: "%02x", $0) }.joined(separator: " "))")
            }
        }

        // CSI u encoding
        check("csiU(49,5)", KeyInput.csiU(codepoint: 49, modifier: 5),
              "\u{1B}[49;5u".data(using: .utf8)!)

        // Cmd-= -> ESC[61;5u
        check("Cmd-=", KeyInput.ctrlBytes(for: "="),
              "\u{1B}[61;5u".data(using: .utf8)!)

        // Cmd-- -> ESC[45;5u
        check("Cmd--", KeyInput.ctrlBytes(for: "-"),
              "\u{1B}[45;5u".data(using: .utf8)!)

        // Cmd-n -> 0x0E (Ctrl-N)
        check("Cmd-n", KeyInput.ctrlBytes(for: "n"), Data([0x0E]))

        // Cmd-p -> 0x10 (Ctrl-P)
        check("Cmd-p", KeyInput.ctrlBytes(for: "p"), Data([0x10]))

        // Cmd-l -> 0x0C (Ctrl-L)
        check("Cmd-l", KeyInput.ctrlBytes(for: "l"), Data([0x0C]))

        // Cmd-s -> 0x13 (Ctrl-S)
        check("Cmd-s", KeyInput.ctrlBytes(for: "s"), Data([0x13]))

        // Numbers 1-9 use CSI u
        for i in 1...9 {
            let expected = "\u{1B}[\(48 + i);5u".data(using: .utf8)!
            check("Cmd-\(i)", KeyInput.ctrlBytes(for: String(i)), expected)
        }

        print("KeyInput tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("KeyInput tests failed") }
    }
}
#endif
```

- [ ] **Step 2: Run tests**

Expected: All assertions pass.

- [ ] **Step 3: Commit**

```bash
git add app/Sources/AmuxTerm/KeyInputTests.swift
git commit -m "add unit tests for keyboard CSI u encoding"
```

---

## Verification Checklist

After all tasks, confirm:

- [ ] `make test` still passes (no Rust code was changed)
- [ ] `cd app && swift build -c release` succeeds
- [ ] App renders tmux session correctly (colors, bold, borders, italic)
- [ ] No flickering during rapid output (`yes | head -1000` in the terminal)
- [ ] Cmd-key shortcuts work (via Ctrl remapping through tmux)
- [ ] Cmd-V pastes from clipboard
- [ ] Cmd-Q quits app without killing tmux session
- [ ] Relaunch reattaches to existing amux-dev session
- [ ] Window resize reflows the terminal
- [ ] App appears in Cmd-Tab switcher
- [ ] Closing window exits the app
- [ ] The "amux" Rust binary is completely unmodified
- [ ] KeyInput tests pass (printed at debug launch)
- [ ] KeyInput unit tests pass
