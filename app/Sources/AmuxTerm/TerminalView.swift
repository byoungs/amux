import AppKit
import AmuxLib
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
    private var pendingDraw: Bool = false
    // CTLine cache: avoids recreating CoreText layout for identical cells.
    // Key: "char|bold|italic|r,g,b" — Value: CTLine
    private var lineCache: [String: CTLine] = [:]
    private var lineCacheGeneration: Int = 0

    private let defaultBg = CGColor(gray: 0, alpha: 1)

    // Cmd-Click link detection (uses LinkDetector for testable regex scanning)
    private var detectedLinks: [DetectedLink] = []
    private var cmdHeld = false

    // Wheel direction the user last drove (events with momentumPhase empty).
    // Used to suppress macOS trackpad inertia bounce-back: when the user
    // scrolls firmly down and lifts off, AppKit emits a brief sequence of
    // upward inertia frames as velocity decays. Without filtering, those
    // upward frames re-enter tmux copy-mode the instant we just exited
    // it (the "scroll-down jumps back up" bug).
    private var lastUserWheelDirection: Int = 0  // -1 down, +1 up, 0 none

    // Fractional pixel accumulator for the scroll wheel. NSEvent's
    // scrollingDeltaY arrives in pixel units for precise (trackpad) events and
    // in pre-multiplied tick units for imprecise (wheel) events. We accumulate
    // pixel-equivalents here; on each NSEvent the whole-cell portion converts
    // to that many SGR mouse events (each scrolls one line in tmux per
    // Config.swift), and the sub-cell remainder carries into the next event.
    // This matches Ghostty's `pending_scroll_y` and iTerm's accumulator.
    // Reset on direction change so a quick reverse doesn't replay leftover
    // momentum in the opposite direction.
    private var pendingScrollY: CGFloat = 0

    // Set when amux's wheel handling may have entered tmux copy-mode (i.e.
    // a wheel-up event in main screen). Reset on next keyDown — at which
    // point we write an Esc byte to the PTY (tmux's emacs copy-mode
    // default cancel binding) to return the pane to its live tail before
    // forwarding the typed key. This is what users mean by "typing should
    // jump me back to the bottom so I can see what I'm typing."
    //
    // Note: with `copy-mode -eu` on WheelUpPane, scrolling all the way
    // down to the live tail auto-exits copy-mode without needing a
    // keystroke. This flag still matters when the user types while
    // scrolled up.
    private var wheelMayHaveEnteredCopyMode: Bool = false

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

    // Permission-peek popup state (Cmd-Y prompt overlay). The pending-count
    // indicator lives in the tmux status bar (Config.statusRightFormat, driven
    // by @amux-peek-count), not an on-top overlay. The popup is drawn last in
    // draw(_:) so partial-dirty redraws under it don't clip it.
    private var peekPopupPrompt: PermissionPrompt?
    private var peekHighlight: Int = 0
    var peekPopupOpen: Bool { peekPopupPrompt != nil }

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
            setCmdHeldAsync(session: session, held: false)
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
            terminal.resize(rows: newRows, cols: newCols)  // sets fullRedrawNeeded internally
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

        // Permission-peek overlay, painted last (over cells) every pass.
        drawPeekOverlay()

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

    // MARK: - Permission-peek overlay

    /// Called by PermissionWatcher.onChange (on main). Updates the badge count
    /// and, if the popup is open, the prompt it shows (nil drains → close).
    func updatePeekState(_ queue: PromptQueue?) {
        // Only the open popup needs the view; the pending count is rendered by
        // tmux in the status bar (@amux-peek-count). Skip the redraw when closed.
        guard peekPopupOpen else { return }
        let next = queue?.current?.prompt
        // When the popup advances to a different prompt, seed the highlight
        // from that prompt's selected option (matching togglePeekPopup) so a
        // stale index doesn't carry onto the next prompt.
        if next != peekPopupPrompt {
            peekHighlight = next?.options.firstIndex(where: { $0.selected }) ?? 0
        }
        peekPopupPrompt = next
        needsDisplay = true
    }

    /// Cmd-Y: open the popup on the current prompt (or close it if open).
    func togglePeekPopup(current: PermissionPrompt?) {
        if peekPopupOpen {
            peekPopupPrompt = nil
        } else {
            peekPopupPrompt = current
            peekHighlight = current?.options.firstIndex(where: { $0.selected }) ?? 0
        }
        needsDisplay = true
    }

    func closePeekPopup() {
        peekPopupPrompt = nil
        needsDisplay = true
    }

    /// Move the popup highlight (clamped). Arrow keys call this.
    func movePeekHighlight(_ delta: Int) {
        guard let opts = peekPopupPrompt?.options, !opts.isEmpty else { return }
        peekHighlight = max(0, min(opts.count - 1, peekHighlight + delta))
        needsDisplay = true
    }

    /// The option number under the highlight, for Enter resolution.
    func highlightedOptionNumber(in prompt: PermissionPrompt) -> Int? {
        guard peekHighlight < prompt.options.count else { return nil }
        return prompt.options[peekHighlight].number
    }

    private func peekFont(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let name = bold ? "Menlo-Bold" : "Menlo"
        return NSFont(name: name, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// Draw the Cmd-Y popup if open. Painted last in draw(_:) every pass so
    /// partial redraws never clip it. The pending-count indicator is rendered
    /// by tmux in the status bar (@amux-peek-count), not here.
    private func drawPeekOverlay() {
        if let prompt = peekPopupPrompt {
            drawPeekPopup(prompt)
        }
    }

    private func drawPeekPopup(_ prompt: PermissionPrompt) {
        let titleFont = peekFont(13, bold: true)
        let optFont = peekFont(13)
        let footFont = peekFont(11)
        let light = NSColor(calibratedWhite: 0.85, alpha: 1)
        let teal = NSColor(calibratedRed: 0.40, green: 0.78, blue: 0.74, alpha: 1)
        let amber = NSColor(calibratedRed: 0.96, green: 0.68, blue: 0.18, alpha: 1)
        let dim = NSColor(calibratedWhite: 0.62, alpha: 1)
        let footColor = NSColor(calibratedWhite: 0.55, alpha: 1)

        // Layout constants. Long text soft-wraps onto multiple lines (no clip);
        // sectionGap gives breathing room between details / question / options /
        // footer; the box is sized generously so labels don't wrap as eagerly.
        let padding: CGFloat = 20
        let lineGap: CGFloat = 6
        let sectionGap: CGFloat = 12
        let maxBoxW = bounds.width - 24
        let boxW = max(360, min(maxBoxW, max(540, bounds.width * 0.6)))
        let textWidth = boxW - padding * 2

        enum Section { case detail, question, option, footer }
        struct Line {
            let text: String
            let font: NSFont
            let color: NSColor
            let highlight: Bool
            let section: Section
            let headIndent: CGFloat       // continuation lines wrap under this offset
        }

        func optionPrefixWidth(marker: String, number: Int) -> CGFloat {
            let prefix = "\(marker)\(number). "
            return (prefix as NSString).size(withAttributes: [.font: optFont]).width
        }

        var lines: [Line] = []
        for d in prompt.details.prefix(8) {
            lines.append(Line(text: d, font: optFont, color: dim,
                              highlight: false, section: .detail, headIndent: 0))
        }
        lines.append(Line(text: prompt.question, font: titleFont, color: light,
                          highlight: false, section: .question, headIndent: 0))
        for (i, opt) in prompt.options.enumerated() {
            let isReject = (opt.number == prompt.rejectOption?.number)
            let marker = i == peekHighlight ? "❯ " : "  "
            let suffix = isReject ? "   → open" : ""
            lines.append(Line(
                text: "\(marker)\(opt.number). \(opt.label)\(suffix)",
                font: optFont,
                color: isReject ? amber : light,
                highlight: i == peekHighlight,
                section: .option,
                headIndent: optionPrefixWidth(marker: marker, number: opt.number)
            ))
        }
        lines.append(Line(text: "↑↓ / digit select · Enter confirm · Esc dismiss",
                          font: footFont, color: footColor,
                          highlight: false, section: .footer, headIndent: 0))

        // Per-line wrapped attributed string + size; track per-line extra gap
        // (a sectionGap is added the first time a new section appears).
        func paragraph(headIndent: CGFloat) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.headIndent = headIndent      // continuation lines indent under the label
            p.firstLineHeadIndent = 0
            p.lineBreakMode = .byWordWrapping
            return p
        }
        var attrs: [NSAttributedString] = []
        var sizes: [CGSize] = []
        var gapsBefore: [CGFloat] = []
        var contentH: CGFloat = 0
        var prevSection: Section? = nil
        for (idx, l) in lines.enumerated() {
            let attr = NSAttributedString(string: l.text, attributes: [
                .font: l.font,
                .foregroundColor: l.color,
                .paragraphStyle: paragraph(headIndent: l.headIndent),
            ])
            attrs.append(attr)
            let r = attr.boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            sizes.append(CGSize(width: ceil(r.width), height: ceil(r.height)))
            let extra: CGFloat = (idx > 0 && l.section != prevSection) ? sectionGap : 0
            gapsBefore.append(extra)
            contentH += sizes[idx].height + (idx == 0 ? 0 : lineGap) + extra
            prevSection = l.section
        }

        let boxH = contentH + padding * 2
        let box = NSRect(x: (bounds.width - boxW) / 2,
                         y: (bounds.height - boxH) / 2,
                         width: boxW, height: boxH)

        let bg = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.10, alpha: 0.97).setFill()
        bg.fill()
        teal.setStroke()
        bg.lineWidth = 1
        bg.stroke()

        var y = box.minY + padding
        for (i, _) in lines.enumerated() {
            if i > 0 { y += lineGap + gapsBefore[i] }
            if lines[i].highlight {
                let bar = NSRect(x: box.minX + padding / 2, y: y - 2,
                                 width: boxW - padding, height: sizes[i].height + 4)
                NSColor(calibratedRed: 0.40, green: 0.78, blue: 0.74, alpha: 0.18).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
            }
            let rect = NSRect(x: box.minX + padding, y: y,
                              width: textWidth, height: sizes[i].height)
            attrs[i].draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            y += sizes[i].height
        }
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
                // Async: this is the key-event path — the sync subprocess can
                // park main behind a PermissionWatcher capture-pane burst.
                setCmdHeldAsync(session: session, held: true)
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
                setCmdHeldAsync(session: session, held: false)
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
        let dy = event.scrollingDeltaY
        if dy == 0 { return }
        let dir = dy > 0 ? 1 : -1
        let isMomentum = event.momentumPhase != []
        if !isMomentum {
            lastUserWheelDirection = dir
        }
        // Suppress momentum frames that reverse direction — these are
        // trackpad-inertia bounce-back, not user intent.
        if isMomentum && dir != lastUserWheelDirection {
            scrollDebug("wheel suppressed (momentum reverse) dir=\(dir) lastUser=\(lastUserWheelDirection)")
            return
        }

        let shiftMult: CGFloat = event.modifierFlags.contains(.shift) ? 3 : 1
        let result = ScrollAccumulator.step(
            deltaY: dy,
            precise: event.hasPreciseScrollingDeltas,
            currentAccumulator: pendingScrollY,
            cellHeight: cellHeight,
            shiftMult: shiftMult
        )
        let cells = result.cells
        pendingScrollY = result.newAccumulator

        if cells == 0 {
            scrollDebug("wheel dy=\(dy) accum=\(pendingScrollY) (no cell crossed)")
            return
        }

        // Wheel events on the main screen may trigger tmux copy-mode entry.
        if !terminal.isAltScreen {
            wheelMayHaveEnteredCopyMode = true
        }

        let pos = cellPosition(for: event)
        let sequences = KeyInput.scrollBytes(
            count: abs(cells),
            up: cells > 0,
            col: pos.col,
            row: pos.row,
            isAltScreen: terminal.isAltScreen,
            mouseMode: terminal.mouseMode
        )
        scrollDebug("wheel dy=\(dy) precise=\(event.hasPreciseScrollingDeltas) momentum=\(isMomentum) cells=\(cells) accum=\(pendingScrollY) bytes=\(sequences.count)")
        for data in sequences {
            pty.write(data)
        }
    }

    private func scrollDebug(_ message: String) {
        if ProcessInfo.processInfo.environment["AMUX_SCROLL_DEBUG"] != nil {
            FileHandle.standardError.write("amux-scroll: \(message)\n".data(using: .utf8)!)
        }
    }

    /// If a wheel event may have entered tmux copy-mode, query tmux's
    /// pane_in_mode state and send an Esc byte via PTY to trigger
    /// copy-mode's default cancel binding. Esc + key bytes go through
    /// the same PTY channel so tmux processes them in order.
    ///
    /// Why not `tmux send-keys -X cancel`? That command goes via the
    /// tmux socket while key bytes go via PTY. Tmux processes them on
    /// independent paths and the key can hit copy-mode before the
    /// socket command runs. Default emacs copy-mode silently swallows
    /// most keys, so the typed character is lost.
    ///
    /// Why not always send Esc unconditionally? Esc bytes outside
    /// copy-mode flow to the pane app. For the shell, `Esc f` is
    /// `Alt-f` in readline (move forward by word) — corrupts input.
    /// So we query pane_in_mode first; only send Esc if true.
    /// Subprocess query is ~5ms; it only fires on the first keystroke
    /// after a wheel event.
    private func handleCopyModeExit() {
        guard wheelMayHaveEnteredCopyMode else { return }
        wheelMayHaveEnteredCopyMode = false
        // Target the session explicitly. An untargeted display-message
        // resolves to whatever tmux considers the "current" pane on the
        // server, which is unreliable when a fresh non-attached client
        // (this subprocess) issues the query — it can return the wrong
        // pane's state and skip the needed Esc.
        let args = session.isEmpty
            ? ["display-message", "-p", "#{pane_in_mode}"]
            : ["display-message", "-t", session, "-p", "#{pane_in_mode}"]
        let mode = Tmux.runRaw(args)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == "1" {
            pty.write(Data([0x1B]))
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
        // First keystroke after a wheel event: if tmux is in copy-mode,
        // send Esc via PTY first to exit. Esc and the key bytes share
        // the PTY channel so tmux processes them in order.
        handleCopyModeExit()
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
