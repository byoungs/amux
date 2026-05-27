// PromptQueue.swift — pure FIFO state machine over detected permission
// prompts across panes. No tmux dependency.

import Foundation

public struct QueuedPrompt: Equatable {
    public let session: String
    public let pane: Int
    public let prompt: PermissionPrompt
    public init(session: String, pane: Int, prompt: PermissionPrompt) {
        self.session = session; self.pane = pane; self.prompt = prompt
    }
    /// Identity = which pane it lives in (not the prompt text).
    var key: String { "\(session):\(pane)" }
}

public struct PromptQueue {
    private var items: [QueuedPrompt] = []
    /// Panes whose prompt was just answered: the answered prompt + the time it
    /// was answered. Guards the optimistic-advance race — after we send the
    /// answer and drop the head, the next poll can still capture the
    /// not-yet-redrawn prompt and `update` would re-queue it as a "new" pane.
    /// An entry suppresses re-adding only the *identical* prompt, and only
    /// within `suppressWindow`: a genuinely different prompt in that pane is
    /// not suppressed, and the entry expires so a legitimately re-shown prompt
    /// reappears.
    private var recentlyAnswered: [String: (prompt: PermissionPrompt, at: TimeInterval)] = [:]
    private let suppressWindow: TimeInterval

    /// `suppressWindow` should comfortably exceed the poll interval so the race
    /// window (answer → next poll before redraw) is always covered.
    public init(suppressWindow: TimeInterval = 8.0) {
        self.suppressWindow = suppressWindow
    }

    public var count: Int { items.count }
    public var current: QueuedPrompt? { items.first }
    public var all: [QueuedPrompt] { items }

    /// Reconcile against a fresh full snapshot of detected prompts:
    ///  - drop detections that are the identical prompt just answered in that
    ///    pane (stale capture before Claude redrew),
    ///  - keep existing items still present (preserving FIFO order, updating body),
    ///  - append newly detected panes at the tail,
    ///  - drop panes no longer detected (answered elsewhere / closed).
    /// Identity is per-pane.
    public mutating func update(detections: [QueuedPrompt], now: TimeInterval) {
        recentlyAnswered = recentlyAnswered.filter { now - $0.value.at < suppressWindow }
        let live = detections.filter { d in
            if let answered = recentlyAnswered[d.key], answered.prompt == d.prompt {
                return false   // same prompt we just answered, not yet redrawn
            }
            return true
        }
        let byKey = Dictionary(live.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [QueuedPrompt] = []
        var kept = Set<String>()
        for item in items {
            if let fresh = byKey[item.key] {
                next.append(fresh)        // update body, keep position
                kept.insert(item.key)
            }
        }
        for d in live where !kept.contains(d.key) {
            next.append(d)                // new pane → tail
            kept.insert(d.key)
        }
        items = next
    }

    /// Remove the head (after it's been answered), recording it so the next
    /// poll doesn't re-queue the same not-yet-redrawn prompt. See `update`.
    public mutating func advance(now: TimeInterval) {
        guard let head = items.first else { return }
        recentlyAnswered[head.key] = (head.prompt, now)
        items.removeFirst()
    }

    /// Clear the whole queue (Esc → dismiss to background). Does NOT suppress
    /// re-detection — a dismissed prompt should reappear on the next poll.
    public mutating func dismissAll() {
        items.removeAll()
    }
}
