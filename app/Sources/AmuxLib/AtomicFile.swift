// AtomicFile.swift -- Crash-safe file writes.
//
// A snapshot or state file that is half-written is worse than one that is
// missing: load() would decode garbage or the caller would restore a
// truncated session list. Every writer in amux goes through here, which
// writes to a sibling temp file and swaps it into place in one step.

import Foundation

public enum AtomicFile {
    /// Write data to a path atomically: a temp file unique to this write in
    /// the same directory, then rename(2) over the destination. Parent
    /// directories are created if missing.
    ///
    /// The temp name must be per-write: the app and amux-cli can save the
    /// same file concurrently, and a shared temp path lets one writer rename
    /// another's half-written bytes into place. rename(2) rather than
    /// `replaceItemAt`: it atomically replaces or creates in one call (no
    /// exists-check race), and concurrent `replaceItemAt` swaps onto one
    /// destination were observed to hang in renamex_np.
    public static func write(_ data: Data, to path: URL) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let tmpPath = parent.appendingPathComponent(".\(path.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmpPath)
        } catch {
            // A partial write (disk full) must not leave debris behind.
            try? FileManager.default.removeItem(at: tmpPath)
            throw error
        }

        guard rename(tmpPath.path, path.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tmpPath)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSFilePathErrorKey: path.path])
        }
    }
}
