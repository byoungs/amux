import AppKit
import AmuxLib

/// One native window, one tmux client, and its own ordered input queue.
/// A queued key retains its destination even if another window gains focus.
final class TerminalWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow!
    private(set) var termView: TerminalView?
    let controller: AppController
    weak var permissionWatcher: PermissionWatcher?
    var onClose: (() -> Void)?
    var onFocus: (() -> Void)?
    private var closed = false
    private enum InputEvent { case key(NSEvent), copy, paste, command(AmuxCommand) }
    private var keyDispatcher: OrderedDispatcher<InputEvent>?

    init(controller: AppController, tmuxPath: String, enhancedPath: String,
         actionQueue: DispatchQueue, attachArgs: [String]? = nil) {
        self.controller = controller
        let session = controller.session
        super.init()
        let rows: UInt16 = 40
        let cols: UInt16 = 120
        let terminal = VTerminal(rows: Int(rows), cols: Int(cols))

        // Attach to the tmux session via PTY (NOT launching amux binary)
        guard let pty = PTY(executable: tmuxPath,
                            args: attachArgs ?? AppDelegate.tmuxAttachArgs(session: session),
                            rows: rows, cols: cols,
                            env: ["PATH": enhancedPath]) else {
            fatalError("Failed to create PTY for tmux attach")
        }

        let termView = TerminalView(terminal: terminal, pty: pty)
        termView.currentSession = { [weak controller] in controller?.session ?? session }
        termView.lookUpSession = { [weak controller] in controller?.attachedSession() }
        controller.clientTTY = pty.slavePath
        self.termView = termView

        // Wire up split-selected border overlay. Fired from the action
        // queue, so hop to main before touching the view.
        controller.onSplitSelectedChanged = { [weak termView] bounds in
            DispatchQueue.main.async {
                guard let tv = termView else { return }
                if let (top, left, width, height) = bounds {
                    tv.splitSelectedPaneBounds = TerminalView.PaneBounds(
                        top: top, left: left, width: width, height: height)
                } else {
                    tv.splitSelectedPaneBounds = nil
                }
                tv.needsDisplay = true
            }
        }

        // Window setup
        let defaults = UserDefaults.standard
        var width = defaults.double(forKey: "amux-window-width")
        var height = defaults.double(forKey: "amux-window-height")
        if width < 400 || height < 300 {
            width = 960
            height = 640
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "amux — \(session)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = termView
        window.center()

        self.window = window

        pty.onExit = { [weak self] in self?.window.close() }
        keyDispatcher = OrderedDispatcher<InputEvent>(
            plan: { [weak self] event in
                guard let self = self, !self.closed else { return .inline {} }
                switch event {
                case .key(let key): return self.dispatchStep(for: key, controller: self.controller)
                case .command(let command): return .offMain { self.controller.handleAction(command) }
                case .copy: return self.termView?.copyStep() ?? .inline {}
                case .paste: return self.termView?.pasteStep() ?? .inline {}
                }
            },
            runOffMain: { [actionQueue] work in actionQueue.async(execute: work) },
            returnToMain: { DispatchQueue.main.async(execute: $0) })
        termView.onCopyRequested = { [weak self] in self?.keyDispatcher?.submit(.copy) }
        termView.onPasteRequested = { [weak self] in self?.keyDispatcher?.submit(.paste) }

    }

    func handleKey(_ event: NSEvent) -> NSEvent? {
        if closed || window.attachedSheet != nil { return event }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            window.performClose(nil)
            return nil
        }
        if KeyInput.isNativeWindowShortcut(event) { return event }
        #if DEBUG
        if let chars = event.charactersIgnoringModifiers,
           chars == "d" && event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) {
            if let tv = self.termView {
                tv.profilingEnabled.toggle()
                fputs("=== Latency profiling \(tv.profilingEnabled ? "ON" : "OFF") ===\n", stderr)
                fputs("Type to see: PTY roundtrip + draw time + total key→pixel\n", stderr)
            }
            return nil
        }
        #endif

        // Permission-peek popup: while open it owns the keyboard.
        if let tv = self.termView, tv.peekPopupOpen,
           let watcher = self.permissionWatcher,
           let prompt = watcher.queue.current?.prompt {
            // Resolve a chosen option: the reject option (the "No" option,
            // identified by label not position) engages (full-screen + send
            // key); all others answer in place.
            let resolve: (Int) -> Void = { num in
                if num == prompt.rejectOption?.number {
                    watcher.engageReject(optionNumber: num, clientTTY: self.controller.clientTTY)
                    tv.closePeekPopup()
                } else {
                    watcher.answerCurrent(optionNumber: num)
                    tv.updatePeekState(watcher.queue)
                    if watcher.queue.current == nil { tv.closePeekPopup() }
                }
            }
            switch event.keyCode {
            case 53: // Escape → dismiss whole queue to background
                watcher.dismissAll(); tv.closePeekPopup(); return nil
            case 126: tv.movePeekHighlight(-1); return nil   // Up
            case 125: tv.movePeekHighlight(+1); return nil   // Down
            case 36:                                          // Enter → highlighted
                if let num = tv.highlightedOptionNumber(in: prompt) { resolve(num) }
                return nil
            default:
                let chars = event.charactersIgnoringModifiers ?? ""
                // Cmd-Y toggles the popup closed but KEEPS the queue (unlike
                // Esc, which dismisses the whole queue); Cmd-Y reopens it.
                if event.modifierFlags.contains(.command), chars == "y" {
                    tv.closePeekPopup(); return nil
                }
                if let d = Int(chars), prompt.options.contains(where: { $0.number == d }) {
                    resolve(d)
                }
                return nil // swallow all other keys while popup is open
            }
        }

        // Quit goes straight to AppKit. Everything else — Copy and Paste
        // included — goes through the dispatcher, which runs it now or
        // holds it until an in-flight action finishes, so a paste right
        // after Cmd-N lands in the new pane. (Planning also reads
        // controller.mode, which only the dispatcher may do safely.)
        if KeyInput.isQuit(event) {
            return event
        }
        self.keyDispatcher?.submit(.key(event))
        return nil
    }

    /// Map a key event to how the dispatcher should run it. Planned at run
    /// time on main, so `controller.mode` reflects every earlier action.
    private func dispatchStep(for event: NSEvent, controller: AppController) -> DispatchStep {
        switch KeyInput.action(for: event, mode: controller.mode) {
        case .amux(.peek):
            return .inline { [weak self] in
                self?.termView?.togglePeekPopup(current: self?.permissionWatcher?.queue.current?.prompt)
            }
        case .amux(let command):
            return .offMain { controller.handleAction(command) }
        case .sendToPTY(let data):
            guard let tv = termView else { return .inline {} }
            // First keystroke after a wheel scroll: if that left the pane in
            // copy-mode, cancel it before sending the key.
            // Finding out is a tmux round-trip, so it runs off main; keys
            // typed meanwhile are held behind it and stay in order.
            if tv.mayBeInCopyMode {
                tv.clearCopyModeFlag()
                let cached = controller.session
                let pty = tv.pty
                return .offMain {
                    // Ask tmux, not the cache: the spaces picker switches the
                    // client without an amux action to refresh it.
                    let session = controller.attachedSession() ?? cached
                    TerminalView.exitCopyMode(session: session)
                    pty.write(data)
                }
            }
            return .inline { tv.pty.write(data) }
        case .system:
            return systemStep(for: event)
        case .ignore:
            return .inline {}
        }
    }

    /// Copy and Paste share the ordered path with menu actions and keystrokes.
    /// Selection/copy-mode checks run off main before any PTY write.
    private func systemStep(for event: NSEvent) -> DispatchStep {
        guard let tv = termView else { return .inline {} }
        switch event.charactersIgnoringModifiers {
        case "c":
            return tv.copyStep()
        case "v":
            return tv.pasteStep()
        default:
            return .inline {}
        }
    }


    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(termView)
    }

    func submit(_ command: AmuxCommand) { keyDispatcher?.submit(.command(command)) }

    func windowDidBecomeKey(_ notification: Notification) { onFocus?() }

    func windowDidResize(_ notification: Notification) {
        let defaults = UserDefaults.standard
        defaults.set(window.frame.width, forKey: "amux-window-width")
        defaults.set(window.frame.height, forKey: "amux-window-height")
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        termView?.pty.onExit = nil
        // Only detach this client. The shells and any other window stay alive.
        termView?.pty.stop()
        onClose?()
    }
}
