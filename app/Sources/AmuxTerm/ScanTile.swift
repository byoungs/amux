// ScanTile.swift — model for one snapshot tile in scan mode.

import Foundation

public struct ScanTile {
    /// tmux pane id (e.g. "%123").
    public let paneId: String
    /// 1-based slot index in the current space's pane order.
    public let slot: Int
    /// Title for the tile header.
    public let title: String
    /// Captured content as raw bytes (includes ANSI escapes).
    public var capturedContent: Data
    /// When the snapshot was captured (for cache invalidation).
    public var capturedAt: Date

    public init(paneId: String, slot: Int, title: String,
                capturedContent: Data, capturedAt: Date) {
        self.paneId = paneId
        self.slot = slot
        self.title = title
        self.capturedContent = capturedContent
        self.capturedAt = capturedAt
    }
}
