// ScanModeController.swift — owns scan-mode state, polling, hover, key forwarding.
//
// Scan mode is the new bird's-eye view. Instead of resizing tmux panes into
// a grid, the controller captures each pane's content via tmux capture-pane
// and TerminalView overlays the snapshots as tiles. Underlying panes stay
// full-width — never shrink — so no christmas tree scrollback.

import Foundation
import AmuxLib

public final class ScanModeController {
    public private(set) var active = false
    public private(set) var tiles: [ScanTile] = []
    public private(set) var hoveredSlot: Int? = nil
    private var pollTimer: Timer?
    public let session: String  // public so TileView click handler can read it
    private let onTilesChanged: () -> Void

    /// Polling interval in seconds. 200ms = 5Hz. Tunable.
    public var pollInterval: TimeInterval = 0.2

    public init(session: String, onTilesChanged: @escaping () -> Void) {
        self.session = session
        self.onTilesChanged = onTilesChanged
    }

    public func enter() {
        guard !active else { return }
        active = true
        rebuildTiles()
        startPolling()
    }

    public func exit() {
        guard active else { return }
        active = false
        stopPolling()
        tiles = []
        hoveredSlot = nil
    }

    public func setHovered(slot: Int?) {
        hoveredSlot = slot
    }

    /// Forward a keystroke to the underlying tmux pane of the hovered tile.
    public func forwardKey(_ keysym: String) {
        guard let slot = hoveredSlot, slot < tiles.count else { return }
        let paneId = tiles[slot].paneId
        _ = try? Tmux.executor.execute(["send-keys", "-t", paneId, keysym])
    }

    private func rebuildTiles() {
        let panes = (try? Tmux.listPanes(session)) ?? []
        var newTiles: [ScanTile] = []
        for (i, p) in panes.enumerated() {
            guard let paneId = try? Tmux.paneIdAt(session, index: p.index) else { continue }
            let content = (try? Tmux.capturePane(paneId: paneId)) ?? Data()
            newTiles.append(ScanTile(
                paneId: paneId, slot: i, title: p.title,
                capturedContent: content, capturedAt: Date()))
        }
        tiles = newTiles
        onTilesChanged()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval,
                                          repeats: true) { [weak self] _ in
            self?.rebuildTiles()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
