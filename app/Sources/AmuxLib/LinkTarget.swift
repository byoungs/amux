// LinkTarget.swift -- What a Cmd-click on a link should open.
//
// Everything goes to macOS, the way iTerm or Ghostty do it: web links open in
// the default browser, files in their default app, any other scheme (mailto:,
// vscode:, ...) in whatever handles it. A link the terminal *detected* in plain
// text ("file:" + path, see LinkDetector) is only a guess, so it becomes a
// link only when it names a file that exists — resolved against the cwd of
// the pane that was clicked, not whichever pane tmux considers current.

import Foundation

public enum LinkTarget {
    /// A pane's rectangle in window cells, and its working directory.
    public struct PaneRect: Equatable {
        public let left, top, width, height: Int
        public let cwd: String
        public let active: Bool

        public init(left: Int, top: Int, width: Int, height: Int, cwd: String, active: Bool) {
            self.left = left
            self.top = top
            self.width = width
            self.height = height
            self.cwd = cwd
            self.active = active
        }
    }

    /// The URL to hand to macOS for a clicked link, or nil when it isn't one.
    /// Pure: the filesystem check is a parameter.
    public static func resolve(_ link: String, cwd: String, home: String,
                               exists: (String) -> Bool) -> URL? {
        if link.hasPrefix("file:"), !link.hasPrefix("file://") {
            return detectedFile(String(link.dropFirst("file:".count)),
                                cwd: cwd, home: home, exists: exists)
        }
        guard let url = URL(string: link), url.scheme != nil else { return nil }
        return url
    }

    private static func detectedFile(_ path: String, cwd: String, home: String,
                                     exists: (String) -> Bool) -> URL? {
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else if path == "~" || path.hasPrefix("~/") {
            absolute = home + path.dropFirst()
        } else {
            guard !cwd.isEmpty else { return nil }
            absolute = cwd + "/" + path
        }
        let normalized = (absolute as NSString).standardizingPath
        return exists(normalized) ? URL(fileURLWithPath: normalized) : nil
    }

    /// Extensions macOS launches rather than opens: bundles, and scripts
    /// Finder runs in Terminal.
    static let launchableExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "pkg", "mpkg", "workflow", "scpt", "applescript",
    ]

    /// Whether a local file link should be revealed in Finder instead of
    /// opened. A link's label is arbitrary text, so a click must never launch
    /// an app or run a program. Folders (executable bit notwithstanding) open
    /// normally. Pure.
    public static func shouldReveal(path: String, isDirectory: Bool, isExecutable: Bool) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if launchableExtensions.contains(ext) { return true }
        return isExecutable && !isDirectory
    }

    /// The cwd of the pane containing a cell, or of the active pane when the
    /// cell is on a border or status line. Pure.
    public static func cwd(atRow row: Int, col: Int, panes: [PaneRect]) -> String? {
        let hit = panes.first {
            row >= $0.top && row < $0.top + $0.height && col >= $0.left && col < $0.left + $0.width
        }
        return (hit ?? panes.first(where: \.active))?.cwd
    }

    /// Parse `list-panes -F paneFormat` output, read UNtrimmed. The path is
    /// last (it may contain tabs, so it takes the remainder); the caller must
    /// not trim stdout or an empty last cwd drops its row. Pure.
    public static func parsePanes(_ stdout: String) -> [PaneRect] {
        stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard f.count == 6, let l = Int(f[0]), let t = Int(f[1]),
                  let w = Int(f[2]), let h = Int(f[3]) else { return nil }
            return PaneRect(left: l, top: t, width: w, height: h, cwd: String(f[5]), active: f[4] == "1")
        }
    }

    public static let paneFormat =
        "#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{pane_active}\t#{pane_current_path}"
}
