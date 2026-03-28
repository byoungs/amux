import AppKit
import CoreText
import CVterm

/// A cell position in the terminal grid.
struct CellPos: Equatable {
    let row: Int
    let col: Int
}

final class TerminalView: NSView {
    let terminal: VTerminal
    let pty: PTY
    private var displayLink: CADisplayLink?
    private var font: CTFont
    private var boldFont: CTFont
    private var italicFont: CTFont
    private var boldItalicFont: CTFont
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    private var fontAscent: CGFloat = 0
    private var resizeTimer: Timer?
    // CTLine cache: avoids recreating CoreText layout for identical cells.
    // Key: "char|bold|italic|r,g,b" — Value: CTLine
    private var lineCache: [String: CTLine] = [:]
    private var lineCacheGeneration: Int = 0

    private let defaultBg = CGColor(gray: 0, alpha: 1)

    // Latency profiling (stderr output, #if DEBUG only)
    #if DEBUG
    var lastKeyTime: CFAbsoluteTime = 0
    var lastOutputTime: CFAbsoluteTime = 0
    var profilingEnabled = false
    var profileSampleCount = 0
    #endif

    init(terminal: VTerminal, pty: PTY) {
        self.terminal = terminal
        self.pty = pty
        let baseFont = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        self.font = baseFont
        self.boldFont = CTFontCreateCopyWithSymbolicTraits(baseFont, 0, nil, .boldTrait, .boldTrait) ?? baseFont
        self.italicFont = CTFontCreateCopyWithSymbolicTraits(baseFont, 0, nil, .italicTrait, .italicTrait) ?? baseFont
        self.boldItalicFont = CTFontCreateCopyWithSymbolicTraits(baseFont, 0, nil, [.boldTrait, .italicTrait], [.boldTrait, .italicTrait]) ?? baseFont
        super.init(frame: .zero)
        wantsLayer = true

        // Right-click context menu with Copy and Paste
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        self.menu = menu

        updateFontMetrics()

        pty.onOutput = { [weak self] data in
            guard let self = self else { return }
            #if DEBUG
            if self.profilingEnabled {
                self.lastOutputTime = CFAbsoluteTimeGetCurrent()
                if self.lastKeyTime > 0 {
                    let ptyRoundtrip = (self.lastOutputTime - self.lastKeyTime) * 1000
                    fputs(String(format: "  PTY roundtrip: %.1fms\n", ptyRoundtrip), stderr)
                }
            }
            #endif
            self.terminal.write(data: data)
            self.terminal.flushDamage()
            self.needsDisplay = true
        }
        pty.startReading()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateFontMetrics() {
        fontAscent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        cellHeight = ceil(fontAscent + descent + leading)

        var chars: [UniChar] = [0x4D] // 'M'
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
        cellWidth = ceil(advance.width)
    }

    // MARK: - Display Link

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
        let dl = self.displayLink(target: self, selector: #selector(displayLinkFired))
        dl.add(to: .main, forMode: .common)
        self.displayLink = dl
    }

    @objc private func displayLinkFired() {
        lineCacheGeneration += 1
        if lineCacheGeneration % 60 == 0 {
            lineCache.removeAll(keepingCapacity: true)
        }
        if terminal.isDirty {
            terminal.flushDamage()
            needsDisplay = true
        }
    }

    deinit { displayLink?.invalidate() }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard cellWidth > 0, cellHeight > 0 else { return }
        let newCols = max(1, Int(newSize.width / cellWidth))
        let newRows = max(1, Int(newSize.height / cellHeight))
        if newRows != terminal.rows || newCols != terminal.cols {
            // Debounce resize: only notify tmux after the window stops being dragged.
            // This prevents flooding tmux with SIGWINCH during live resize.
            terminal.resize(rows: newRows, cols: newCols)
            resizeTimer?.invalidate()
            resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.pty.resize(rows: UInt16(self.terminal.rows), cols: UInt16(self.terminal.cols))
            }
            needsDisplay = true
        }
    }

    // MARK: - Rendering

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        #if DEBUG
        let drawStart = CFAbsoluteTimeGetCurrent()
        #endif

        // Fix CoreText in flipped coordinates
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)

        ctx.setFillColor(defaultBg)
        ctx.fill(bounds)

        for row in 0..<terminal.rows {
            for col in 0..<terminal.cols {
                let cell = terminal.cell(row: row, col: col)
                if cell.width < 1 { continue }
                drawCell(cell, row: row, col: col, ctx: ctx)
            }
        }

        // Selection rendering is now handled by tmux (yellow highlight).
        // Our native blue selection is disabled.

        if terminal.cursorVisible {
            drawCursor(row: terminal.cursorRow, col: terminal.cursorCol, ctx: ctx)
        }

        #if DEBUG
        if profilingEnabled {
            let drawEnd = CFAbsoluteTimeGetCurrent()
            let drawMs = (drawEnd - drawStart) * 1000
            if lastKeyTime > 0 {
                let totalMs = (drawEnd - lastKeyTime) * 1000
                profileSampleCount += 1
                fputs(String(format: "  draw: %.1fms | total key→pixel: %.1fms (#%d)\n", drawMs, totalMs, profileSampleCount), stderr)
                lastKeyTime = 0  // reset for next keypress
            }
        }
        #endif
    }

    private func cachedLine(for str: String, font: CTFont, color: NSColor, r: UInt8, g: UInt8, b: UInt8, bold: Bool, italic: Bool) -> CTLine {
        let key = "\(str)|\(bold)|\(italic)|\(r),\(g),\(b)"

        if let cached = lineCache[key] {
            return cached
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attrStr = NSAttributedString(string: str, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        lineCache[key] = line
        return line
    }

    private func drawCell(_ cell: VTermScreenCell, row: Int, col: Int, ctx: CGContext) {
        let x = CGFloat(col) * cellWidth
        let y = CGFloat(row) * cellHeight
        let w = cellWidth * CGFloat(max(1, cell.width))
        let rect = CGRect(x: x, y: y, width: w, height: cellHeight)

        let isReverse = cell.attrs.reverse != 0
        let (fgR, fgG, fgB) = VTerminal.colorRGB(cell.fg, screen: terminal.screen)
        let (bgR, bgG, bgB) = VTerminal.colorRGB(cell.bg, screen: terminal.screen)

        let bgNSColor = isReverse
            ? VTerminal.cachedColor(r: fgR, g: fgG, b: fgB)
            : VTerminal.cachedColor(r: bgR, g: bgG, b: bgB)
        let bgColor = bgNSColor.cgColor
        let (fgNSR, fgNSG, fgNSB) = isReverse ? (bgR, bgG, bgB) : (fgR, fgG, fgB)
        let fgColor = isReverse
            ? VTerminal.cachedColor(r: bgR, g: bgG, b: bgB)
            : VTerminal.cachedColor(r: fgR, g: fgG, b: fgB)

        if bgColor != defaultBg {
            ctx.setFillColor(bgColor)
            ctx.fill(rect)
        }

        let str = VTerminal.cellString(cell)
        guard !str.isEmpty, str != " " else { return }

        let isBold = cell.attrs.bold != 0
        let isItalic = cell.attrs.italic != 0
        let drawFont: CTFont
        switch (isBold, isItalic) {
        case (true, true): drawFont = boldItalicFont
        case (true, false): drawFont = boldFont
        case (false, true): drawFont = italicFont
        case (false, false): drawFont = font
        }

        let line = cachedLine(for: str, font: drawFont, color: fgColor, r: fgNSR, g: fgNSG, b: fgNSB, bold: isBold, italic: isItalic)
        ctx.textPosition = CGPoint(x: x, y: y + fontAscent)
        CTLineDraw(line, ctx)

        if cell.attrs.underline != 0 {
            let underY = y + fontAscent + 2
            ctx.setStrokeColor(fgColor.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: underY))
            ctx.addLine(to: CGPoint(x: x + w, y: underY))
            ctx.strokePath()
        }

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
        ctx.setFillColor(CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 0.5))
        ctx.fill(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
    }

    // MARK: - Selection

    private func cellPosition(for event: NSEvent) -> CellPos {
        let point = convert(event.locationInWindow, from: nil)
        let row = max(0, min(terminal.rows - 1, Int(point.y / cellHeight)))
        let col = max(0, min(terminal.cols - 1, Int(point.x / cellWidth)))
        return CellPos(row: row, col: col)
    }

    // Forward ALL mouse events to tmux via SGR encoding.
    // tmux handles pane selection, text selection (yellow highlight), and copy.
    // This replaces our native blue selection — tmux's selection is pane-aware
    // and integrates with tmux's copy mode.

    override func mouseDown(with event: NSEvent) {
        let pos = cellPosition(for: event)
        let col = pos.col + 1  // SGR is 1-indexed
        let row = pos.row + 1
        let press = "\u{1B}[<0;\(col);\(row)M"
        if let data = press.data(using: .utf8) {
            pty.write(data)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pos = cellPosition(for: event)
        let col = pos.col + 1
        let row = pos.row + 1
        // Button 32 = motion with button 0 held (SGR drag encoding)
        let drag = "\u{1B}[<32;\(col);\(row)M"
        if let data = drag.data(using: .utf8) {
            pty.write(data)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pos = cellPosition(for: event)
        let col = pos.col + 1
        let row = pos.row + 1
        let release = "\u{1B}[<0;\(col);\(row)m"  // lowercase 'm' = release
        if let data = release.data(using: .utf8) {
            pty.write(data)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let pos = cellPosition(for: event)
        let sequences = KeyInput.scrollBytes(
            deltaY: event.scrollingDeltaY,
            col: pos.col,
            row: pos.row,
            cellHeight: cellHeight,
            precise: event.hasPreciseScrollingDeltas
        )
        for data in sequences {
            pty.write(data)
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        #if DEBUG
        if profilingEnabled {
            lastKeyTime = CFAbsoluteTimeGetCurrent()
        }
        #endif
        if let data = KeyInput.bytes(for: event) {
            pty.write(data)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Most Cmd-key handling is done by the local event monitor in AppDelegate.
        // This is a fallback for any Cmd keys that slip through.
        if event.modifierFlags.contains(.command) {
            if let data = KeyInput.bytes(for: event) {
                pty.write(data)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Copy / Paste

    @objc func copy(_ sender: Any?) {
        // Read tmux's paste buffer and put on system clipboard.
        let tmuxPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/tmux")
            ? "/opt/homebrew/bin/tmux" : "/usr/local/bin/tmux"
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["show-buffer"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        // Read data FIRST, then wait — avoids deadlock when pipe buffer fills
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        // Strip any embedded bracket paste end sequences (ESC[201~) from the
        // clipboard data to prevent injection of terminal escape sequences.
        let endMarker = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]) // ESC[201~
        var pasteData = str.data(using: .utf8) ?? Data()
        // Remove all occurrences of the end marker from the payload
        while let range = pasteData.range(of: endMarker) {
            pasteData.removeSubrange(range)
        }
        // Combine bracket paste markers + sanitized data into a single write
        // to ensure atomic delivery and avoid main-thread blocking
        var combined = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~
        combined.append(pasteData)
        combined.append(endMarker)
        pty.write(combined)
    }
}
