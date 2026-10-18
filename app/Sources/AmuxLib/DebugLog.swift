// DebugLog.swift -- An always-on, size-capped trail of layout decisions.
//
// Layout bugs (panes that don't re-tile after a window resize) happen in
// short-lived amux-cli hook processes and on the app's action queue, where
// stderr goes nowhere. This appends one line per event to
// ~/.amux/debug.log (or $AMUX_HOME), from any process, so a bug seen once
// can be reconstructed afterwards. The file rotates to debug.log.1 at 2MB.

import Foundation

public enum DebugLog {
    static let maxBytes: UInt64 = 2 * 1024 * 1024

    public static var path: URL { AmuxPaths.home().appendingPathComponent("debug.log") }

    /// Format one log line. Pure.
    static func line(_ message: String, at date: Date, process: String, pid: Int32) -> String {
        let stamp = ISO8601DateFormatter.string(
            from: date, timeZone: .current,
            formatOptions: [.withFullDate, .withFullTime, .withFractionalSeconds])
        return "\(stamp) \(process)[\(pid)] \(message)\n"
    }

    /// Append a line. Never throws and never blocks on anything but the
    /// write itself: logging must not be able to break what it observes.
    public static func log(_ message: String) {
        let info = ProcessInfo.processInfo
        let text = line(message, at: Date(), process: info.processName, pid: info.processIdentifier)
        let url = path
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        // O_APPEND: concurrent writers (app + several hook processes) each
        // land whole lines; a single small write is atomic.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}

// MARK: - Summaries (pure)

extension LayoutState {
    /// "win=191x80 zoomed=0 active=2 panes=[%9@0,1:47x39 ...]"
    public var debugSummary: String {
        let rects = panes.map { "%\($0.id)@\($0.x),\($0.y):\($0.w)x\($0.h)" }.joined(separator: " ")
        return "win=\(windowW)x\(windowH) zoomed=\(zoomed ? 1 : 0) active=\(activePane) panes=[\(rects)]"
    }

    /// Whether the panes reach the window's right and bottom edges — i.e.
    /// nothing is left blank after a re-tile. A zoomed pane counts too.
    public var panesFillWindow: Bool {
        guard !panes.isEmpty else { return true }
        let right = panes.map { $0.x + $0.w }.max() ?? 0
        let bottom = panes.map { $0.y + $0.h }.max() ?? 0
        return right == windowW && bottom == windowH
    }
}

extension LayoutAction {
    /// Only the fields that are set, e.g. "layout zoom=false select=2".
    public var debugSummary: String {
        var parts: [String] = []
        if layoutString != nil { parts.append("layout") }
        if let order = paneOrder { parts.append("order=\(order)") }
        if let zoom { parts.append("zoom=\(zoom)") }
        if let selectPane { parts.append("select=\(selectPane)") }
        if let dismissAlert { parts.append("dismiss=\(dismissAlert)") }
        if openSpaces { parts.append("spaces") }
        if let errorMessage { parts.append("error=\"\(errorMessage)\"") }
        if let notice { parts.append("notice=\"\(notice)\"") }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }
}
