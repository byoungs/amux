import AppKit
import AmuxLib
import CoreText
import CVterm

/// A cell position in the terminal grid.
struct CellPos: Equatable {
    let row: Int
    let col: Int
}

/// NSScroller variant that passes mouse hits through to its superview.
/// Used as a read-only scroll position indicator without intercepting
/// wheel events that should reach TerminalView.scrollWheel.
final class PassthroughScroller: NSScroller {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Pure helper for computing the scrollbar's display state from terminal +
/// tmux state. Extracted so the math is unit-testable without AppKit / a
/// running tmux server. Inputs are immutable; output drives NSScroller.
enum ScrollerState {
    struct Result: Equatable {
        let hidden: Bool
        let knobProportion: Double  // 0.0..1.0; visible fraction
        let doubleValue: Double      // 0.0..1.0; 1.0 = at bottom (live tail)
    }

    /// - Parameters:
    ///   - isAltScreen: true while the pane is in alt-screen — scrollbar
    ///     hides (alt-screen apps own their own scrollback).
    ///   - visibleRows: the pane's visible row count.
    ///   - tmuxState: parsed `display-message` output, or nil if the query
    ///     failed (no server, malformed reply, etc).
    static func compute(
        isAltScreen: Bool,
        visibleRows: Int,
        tmuxState: (historySize: Int, scrollPosition: Int?)?
    ) -> Result {
        if isAltScreen {
            return Result(hidden: true, knobProportion: 1.0, doubleValue: 1.0)
        }
        guard let state = tmuxState else {
            // Tmux query failed — show a neutral indicator pinned to bottom.
            return Result(hidden: false, knobProportion: 1.0, doubleValue: 1.0)
        }
        let visible = Double(max(1, visibleRows))
        let history = Double(max(0, state.historySize))
        let total = history + visible
        let knob = max(0.02, visible / max(visible, total))
        let value: Double
        if let pos = state.scrollPosition, state.historySize > 0 {
            // scroll_position counts lines above the viewport; 0 = at bottom.
            value = 1.0 - (Double(pos) / history)
        } else {
            value = 1.0
        }
        return Result(hidden: false, knobProportion: knob, doubleValue: value)
    }
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
    private var pendingDraw: Bool = false
    // CTLine cache: avoids recreating CoreText layout for identical cells.
    // Key: "char|bold|italic|r,g,b" — Value: CTLine
    private var lineCache: [String: CTLine] = [:]
    private var lineCacheGeneration: Int = 0

    private let defaultBg = CGColor(gray: 0, alpha: 1)

    // Read-only vertical scroll indicator. Sized from tmux history_size +
    // scroll_position; hidden in alt-screen (industry standard — no
    // scrollback in alt-screen apps). Wheel + keys remain the only scroll
    // inputs; the scroller is a position indicator, not a draggable control.
    // PassthroughScroller returns nil from hitTest so mouse events over
    // the scroller still reach TerminalView (otherwise the right-edge
    // strip would silently swallow scroll-wheel events).
    private let scroller: PassthroughScroller = {
        let s = PassthroughScroller(frame: .zero)
        s.scrollerStyle = .overlay
        s.controlSize = .regular
        s.knobStyle = .default
        s.isEnabled = false
        s.doubleValue = 1.0
        s.knobProportion = 1.0
        s.isHidden = true
        return s
    }()
    private var scrollerTimer: Timer?

    // Cmd-Click link detection (uses LinkDetector for testable regex scanning)
    private var detectedLinks: [DetectedLink] = []
    private var cmdHeld = false

    /// The tmux session name. Set by AppDelegate after construction.
    /// Used to update @amux-cmd-held when Cmd is pressed/released.
    var session: String = ""

    // Pane border color overlay.
    // Overrides border cell foreground colors for panes with colored states.
    struct PaneBorderOverlay {
        let top: Int, left: Int, width: Int, height: Int
        let r: UInt8, g: UInt8, b: UInt8  // RGB color for this pane's borders
    }
    var borderOverlays: [PaneBorderOverlay] = []

    // Legacy single-pane property (kept for AppDelegate callback compatibility)
    struct PaneBounds {
        let top: Int, left: Int, width: Int, height: Int
    }
    var splitSelectedPaneBounds: PaneBounds? = nil {
        didSet { rebuildOverlays() }
    }

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

        addSubview(scroller)
        // Drive scrollbar updates while the view is alive. Cheap tmux query
        // (~1 fork per 250ms); skipped early in `refreshScrollerState` when
        // the alt-screen flag is set.
        scrollerTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshScrollerState()
        }

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
            // Feed data to libvterm (updates cell grid in memory)
            self.terminal.write(data: data)

            // Coalesce rapid output chunks into a single draw.
            // tmux often sends a keystroke echo in 2-3 chunks 0.5-2ms apart.
            // Without coalescing, each chunk triggers a separate draw() — the
            // jitter between "1 draw" and "2-3 draws" is perceptible.
            if !self.pendingDraw {
                self.pendingDraw = true
                // Schedule draw at the end of the current run loop pass.
                // All onOutput calls within this pass accumulate damage,
                // then one draw happens with all changes combined.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.pendingDraw = false
                    self.terminal.flushDamage()

                    if self.terminal.fullRedrawNeeded || self.terminal.dirtyRows.count > self.terminal.rows / 2 {
                        self.terminal.fullRedrawNeeded = false
                        self.terminal.dirtyRows.removeAll()
                        self.needsDisplay = true
                    } else if !self.terminal.dirtyRows.isEmpty {
                        for row in self.terminal.dirtyRows {
                            let y = CGFloat(row) * self.cellHeight
                            self.setNeedsDisplay(NSRect(x: 0, y: y, width: self.bounds.width, height: self.cellHeight))
                        }
                        let cursorY = CGFloat(self.terminal.cursorRow) * self.cellHeight
                        self.setNeedsDisplay(NSRect(x: 0, y: cursorY, width: self.bounds.width, height: self.cellHeight))
                        self.terminal.dirtyRows.removeAll()
                    }
                    self.displayIfNeeded()
                }
            }
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
            // Clear Cmd-held state if the app loses focus (Cmd-Tab away).
            // Without this, the underlines + bright status bar persist after
            // returning because the app misses the Cmd-up while inactive.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidResignActive),
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
        } else if window == nil {
            displayLink?.invalidate()
            displayLink = nil
            NotificationCenter.default.removeObserver(self)
        }
    }

    @objc private func appDidResignActive() {
        guard cmdHeld else { return }
        cmdHeld = false
        if !session.isEmpty {
            setCmdHeld(session: session, held: false)
        }
        if !detectedLinks.isEmpty {
            detectedLinks = []
            NSCursor.pop()
            needsDisplay = true
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

    deinit {
        displayLink?.invalidate()
        scrollerTimer?.invalidate()
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutScroller()
        refreshScrollerState()
        guard cellWidth > 0, cellHeight > 0 else { return }
        let newCols = max(1, Int(newSize.width / cellWidth))
        let newRows = max(1, Int(newSize.height / cellHeight))
        if newRows != terminal.rows || newCols != terminal.cols {
            // Debounce resize: only notify tmux after the window stops being dragged.
            // This prevents flooding tmux with SIGWINCH during live resize.
            terminal.resize(rows: newRows, cols: newCols)  // sets fullRedrawNeeded internally
            resizeTimer?.invalidate()
            resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.pty.resize(rows: UInt16(self.terminal.rows), cols: UInt16(self.terminal.cols))
            }
            needsDisplay = true
        }
    }

    private func layoutScroller() {
        let width: CGFloat = 15
        let inset: CGFloat = 2
        scroller.frame = NSRect(
            x: bounds.maxX - width - inset,
            y: inset,
            width: width,
            height: max(0, bounds.height - inset * 2)
        )
    }

    /// Query tmux for the active pane's history size and scroll position.
    /// Targets the default client (no -t flag): tmux's display-message
    /// resolves to the active pane the user is viewing.
    /// scrollPosition is nil when the pane is not in copy-mode.
    private func queryTmuxScrollState() -> (historySize: Int, scrollPosition: Int?)? {
        let out = Tmux.runRaw([
            "display-message", "-p",
            "#{history_size} #{?pane_in_mode,#{scroll_position},}"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return nil }
        let parts = out.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let hist = Int(parts[0]) else { return nil }
        let posStr = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespaces)
            : ""
        let pos: Int? = posStr.isEmpty ? nil : Int(posStr)
        return (hist, pos)
    }

    private func refreshScrollerState() {
        let result = ScrollerState.compute(
            isAltScreen: terminal.isAltScreen,
            visibleRows: terminal.rows,
            tmuxState: queryTmuxScrollState()
        )
        scroller.isHidden = result.hidden
        scroller.knobProportion = CGFloat(result.knobProportion)
        scroller.doubleValue = result.doubleValue
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

        // Only redraw rows that intersect the dirty rect.
        // When a single character is typed, this redraws 1-2 rows instead of all 40+.
        let firstRow = max(0, Int(dirtyRect.origin.y / cellHeight))
        let lastRow = min(terminal.rows - 1, Int((dirtyRect.origin.y + dirtyRect.height) / cellHeight))

        // Clear only the dirty region's background
        ctx.setFillColor(defaultBg)
        ctx.fill(dirtyRect)

        for row in firstRow...lastRow {
            for col in 0..<terminal.cols {
                let cell = terminal.cell(row: row, col: col)
                if cell.width < 1 { continue }
                drawCell(cell, row: row, col: col, ctx: ctx)
            }
        }

        if terminal.cursorVisible && terminal.cursorRow >= firstRow && terminal.cursorRow <= lastRow {
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

    /// Rebuild border overlays from current state.
    ///
    /// Queries tmux for pane positions and alert/split-selected state.
    /// Creates overlays that color the TOP BORDER ROW ONLY for:
    ///   - split-selected panes → red
    ///   - alert panes → amber
    ///
    /// tmux handles active (teal) vs inactive (gray) via pane-border-format.
    /// This overlay recolors the tmux-rendered title text for alert/split
    /// states without affecting side or bottom borders.
    func rebuildOverlays() {
        var overlays: [PaneBorderOverlay] = []

        // Split-selected pane (from AppController callback).
        // Color decision delegated to AmuxLib.overlayColor — single source of
        // truth so integration tests can pin the exact RGB values without
        // constructing a TerminalView.
        if let bounds = splitSelectedPaneBounds,
           let color = overlayColor(alert: false, splitSelected: true, active: false) {
            overlays.append(PaneBorderOverlay(
                top: bounds.top, left: bounds.left,
                width: bounds.width, height: bounds.height,
                r: color.r, g: color.g, b: color.b))
        }

        // Alert panes (query tmux for positions + alert + active state).
        let panesStr = Tmux.runRaw(["list-panes", "-F",
            "#{pane_top} #{pane_left} #{pane_width} #{pane_height} #{@amux-alert} #{pane_active}"])
        for line in panesStr.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 6,
                  let top = Int(parts[0]), let left = Int(parts[1]),
                  let width = Int(parts[2]), let height = Int(parts[3]) else { continue }
            let alert = String(parts[4]) == "1"
            let active = String(parts[5]) == "1"

            // Don't stack amber on a pane already painted red by split-selected
            // (the pure decision function already returns red for splitSelected,
            // but splitSelectedPaneBounds is tracked out-of-band so we compare
            // bounds directly here).
            let alreadyRed = splitSelectedPaneBounds.map {
                $0.top == top && $0.left == left
            } ?? false
            if alreadyRed { continue }

            if let color = overlayColor(alert: alert, splitSelected: false, active: active) {
                overlays.append(PaneBorderOverlay(
                    top: top, left: left, width: width, height: height,
                    r: color.r, g: color.g, b: color.b))
            }
        }

        borderOverlays = overlays
    }

    /// Find the overlay color for a border cell, if any.
    ///
    /// Only matches the TOP border row of each overlay pane. Side and bottom
    /// borders are not colored — this keeps the visual indicator on the title
    /// bar without extending into adjacent panes.
    private func borderOverlayColor(row: Int, col: Int) -> (UInt8, UInt8, UInt8)? {
        for overlay in borderOverlays {
            let t = overlay.top
            let l = overlay.left
            let r = l + overlay.width

            // Top border row only (the title bar row is one row above pane content)
            if row == t - 1 && col >= l - 1 && col <= r {
                return (overlay.r, overlay.g, overlay.b)
            }
        }
        return nil
    }

    private func drawCell(_ cell: VTermScreenCell, row: Int, col: Int, ctx: CGContext) {
        let x = CGFloat(col) * cellWidth
        let y = CGFloat(row) * cellHeight
        let w = cellWidth * CGFloat(max(1, cell.width))
        let rect = CGRect(x: x, y: y, width: w, height: cellHeight)

        let isReverse = cell.attrs.reverse != 0
        var (fgR, fgG, fgB) = VTerminal.colorRGB(cell.fg, screen: terminal.screen)
        let (bgR, bgG, bgB) = VTerminal.colorRGB(cell.bg, screen: terminal.screen)

        // Override border cell color for panes with colored states
        if let color = borderOverlayColor(row: row, col: col) {
            fgR = color.0; fgG = color.1; fgB = color.2
        }

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

        // Cmd-held link underline (blue, like iTerm2)
        if cmdHeld && isLinkCell(row: row, col: col) {
            let underY = y + fontAscent + 2
            let linkBlue = CGColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)
            ctx.setStrokeColor(linkBlue)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: underY))
            ctx.addLine(to: CGPoint(x: x + w, y: underY))
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
        // Cmd-Click: open link at cursor position
        if event.modifierFlags.contains(.command) {
            let pos = cellPosition(for: event)
            // Always scan fresh on click (don't rely on flagsChanged having fired)
            let freshLinks = scanForLinks()
            if let link = freshLinks.first(where: { $0.row == pos.row && pos.col >= $0.startCol && pos.col <= $0.endCol }) {
                openLink(link.url)
                return
            }
        }

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

    // MARK: - Cmd-Click link detection

    override func flagsChanged(with event: NSEvent) {
        let cmdNow = event.modifierFlags.contains(.command)
        if cmdNow && !cmdHeld {
            // Cmd pressed — scan for links, show underlines, brighten status bar
            cmdHeld = true
            if !session.isEmpty {
                setCmdHeld(session: session, held: true)
            }
            detectedLinks = scanForLinks()
            if !detectedLinks.isEmpty {
                NSCursor.pointingHand.push()
                needsDisplay = true
            }
        } else if !cmdNow && cmdHeld {
            // Cmd released — clear underlines, dim status bar
            cmdHeld = false
            if !session.isEmpty {
                setCmdHeld(session: session, held: false)
            }
            if !detectedLinks.isEmpty {
                detectedLinks = []
                NSCursor.pop()
                needsDisplay = true
            }
        }
        super.flagsChanged(with: event)
    }

    /// Scan all visible rows for URL/path patterns using LinkDetector.
    /// Uses per-cell color info so colored filenames (e.g., from Claude or
    /// `make`) with spaces in them are detected correctly.
    private func scanForLinks() -> [DetectedLink] {
        var rows: [String] = []
        var colors: [[LinkDetector.CellColor]] = []
        for row in 0..<terminal.rows {
            let (text, rowColors) = extractRow(row)
            rows.append(text)
            colors.append(rowColors)
        }
        return LinkDetector.scanRows(rows, colors: colors)
    }

    /// Extract text + per-cell color info from a terminal row.
    private func extractRow(_ row: Int) -> (String, [LinkDetector.CellColor]) {
        var text = ""
        var colors: [LinkDetector.CellColor] = []
        colors.reserveCapacity(terminal.cols)
        for col in 0..<terminal.cols {
            let cell = terminal.cell(row: row, col: col)
            let ch = VTerminal.cellString(cell)
            text += ch.isEmpty ? " " : ch
            let (r, g, b) = VTerminal.colorRGB(cell.fg, screen: terminal.screen)
            // VTERM_COLOR_DEFAULT_FG = 0x02
            let isDefault = (cell.fg.type & 0x02) != 0
            let rgb = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            colors.append(LinkDetector.CellColor(rgb: rgb, isDefault: isDefault))
        }
        // Trim trailing spaces from text only (keep colors aligned by index)
        while text.hasSuffix(" ") { text.removeLast() }
        return (text, colors)
    }

    /// Text-only row extraction (used for click logging).
    private func extractRowText(_ row: Int) -> String {
        extractRow(row).0
    }

    /// Find a detected link at the given cell position.
    private func linkAt(row: Int, col: Int) -> DetectedLink? {
        // If we haven't scanned yet (Cmd might not have triggered flagsChanged before click),
        // scan now
        let links = detectedLinks.isEmpty ? scanForLinks() : detectedLinks
        return links.first(where: { $0.row == row && col >= $0.startCol && col <= $0.endCol })
    }

    /// Check if a cell is part of a detected link (for rendering underline).
    private func isLinkCell(row: Int, col: Int) -> Bool {
        detectedLinks.contains(where: { $0.row == row && col >= $0.startCol && col <= $0.endCol })
    }

    /// Open a detected link.
    private func openLink(_ url: String) {
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            if let nsURL = URL(string: url) {
                NSWorkspace.shared.open(nsURL)
            }
        } else if url.hasPrefix("file:") {
            let filePath = String(url.dropFirst(5))

            // Resolve relative paths against the active pane's working directory
            let paneCwd = Tmux.runRaw(["display-message", "-p", "#{pane_current_path}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let basePath = paneCwd.isEmpty ? FileManager.default.currentDirectoryPath : paneCwd
            let resolvedPath = filePath.hasPrefix("/") ? filePath : basePath + "/" + filePath

            // Open in VS Code (works for all file types)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["code", resolvedPath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let pos = cellPosition(for: event)
        let shiftHeld = event.modifierFlags.contains(.shift)
        let sequences = KeyInput.scrollBytes(
            deltaY: event.scrollingDeltaY,
            col: pos.col,
            row: pos.row,
            cellHeight: cellHeight,
            precise: event.hasPreciseScrollingDeltas,
            shiftHeld: shiftHeld,
            isAltScreen: terminal.isAltScreen,
            mouseMode: terminal.mouseMode
        )
        for data in sequences {
            pty.write(data)
        }
        refreshScrollerState()
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
