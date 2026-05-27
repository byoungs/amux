// PermissionWatcher.swift — polls managed panes for permission prompts.
//
// Imperative shell around the pure PermissionPrompt parser + PromptQueue.
// Every `interval` seconds (on a background queue so tmux I/O never blocks the
// render/main thread) it lists managed sessions, captures each pane (skipping
// the focused pane of the attached session), detects prompts, then hops to
// main to reconcile the queue and fire `onChange` for the UI.

import Foundation
import AmuxLib

final class PermissionWatcher {
    /// The queue is touched on the main thread only.
    private(set) var queue: PromptQueue
    private var timer: Timer?
    private let interval: TimeInterval
    private let pollQueue = DispatchQueue(label: "amux.permissionWatcher")
    /// Clock for the queue's suppress-window. Injectable so tests pin time.
    private let now: () -> TimeInterval

    /// Returns the attached session + its active pane so the pane already on
    /// screen is skipped. Invoked on the background poll queue.
    var attachedSession: () -> (session: String, activePane: Int)?
    var onChange: () -> Void = {}

    init(interval: TimeInterval = 4.0,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
         attachedSession: @escaping () -> (session: String, activePane: Int)?) {
        self.interval = interval
        self.now = now
        self.attachedSession = attachedSession
        // Suppress a re-detected just-answered prompt for ~2 poll intervals.
        self.queue = PromptQueue(suppressWindow: interval * 2)
    }

    func start() {
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollQueue.async { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// One poll pass (background queue): gather detections, then apply on main.
    func poll() {
        let detections = Self.gather(attached: attachedSession())
        let now = self.now()
        DispatchQueue.main.async { [weak self] in
            self?.queue.update(detections: detections, now: now)
            self?.onChange()
        }
    }

    /// Synchronous single-threaded poll for tests (no thread hops): gather +
    /// reconcile on the calling thread. Production uses `poll()`.
    func pollSync() {
        queue.update(detections: Self.gather(attached: attachedSession()), now: now())
    }

    /// Issue the tmux reads and return detections. Static so it cannot touch
    /// `queue` off the main thread.
    private static func gather(attached: (session: String, activePane: Int)?) -> [QueuedPrompt] {
        let sessions = (try? Tmux.listFocusSessions()) ?? []
        var detections: [QueuedPrompt] = []
        for session in sessions {
            let panes = (try? Tmux.listPanes(session)) ?? []
            for pane in panes {
                if let a = attached, a.session == session, a.activePane == pane.index {
                    continue   // user is looking at this pane already
                }
                // Visible screen only (lines: 0) — a prompt answered directly
                // in the pane scrolls into history and must stop alerting.
                let text = Tmux.capturePane(session, paneIndex: pane.index, lines: 0)
                if let prompt = detectPermissionPrompt(text) {
                    detections.append(QueuedPrompt(session: session, pane: pane.index, prompt: prompt))
                }
            }
        }
        return detections
    }

    // MARK: - Actions (main thread)

    /// Answer the head prompt's option in place, then advance the queue.
    func answerCurrent(optionNumber: Int) {
        guard let head = queue.current,
              let opt = head.prompt.options.first(where: { $0.number == optionNumber }) else { return }
        try? Tmux.sendKeys(head.session, paneIndex: head.pane, keys: answerKeys(for: opt))
        queue.advance(now: now())
        onChange()
    }

    /// Engage the reject option: switch to that session, full-screen (zoom)
    /// the pane, and send the option's key — so the user lands there with
    /// Claude awaiting "what should I do instead?" ready for typed follow-up.
    ///
    /// `selectPane` to a different pane auto-unzooms in tmux (verified), so the
    /// `isZoomed` check then re-zooms the now-selected target pane; selecting
    /// the same (already-zoomed) pane leaves it zoomed. Either way we land
    /// full-screen on the target.
    func engageReject(optionNumber: Int) {
        guard let head = queue.current,
              let opt = head.prompt.options.first(where: { $0.number == optionNumber }) else { return }
        try? Tmux.switchSession(head.session)
        try? Tmux.selectPane(head.session, paneIndex: head.pane)
        if (try? Tmux.isZoomed(head.session)) != true { try? Tmux.toggleZoom(head.session) }
        try? Tmux.sendKeys(head.session, paneIndex: head.pane, keys: answerKeys(for: opt))
        queue.advance(now: now())
        onChange()
    }

    /// Dismiss the whole queue to background (Esc).
    func dismissAll() { queue.dismissAll(); onChange() }
}
