// AtomicFile.swift -- Crash-safe file writes.
//
// A snapshot or state file that is half-written is worse than one that is
// missing: load() would decode garbage or the caller would restore a
// truncated session list. Every writer in amux goes through here, which
// writes to a sibling temp file and swaps it into place in one step.

import Foundation

public enum AtomicFile {
    /// Write data to a path atomically: temp file in the same directory,
    /// then `replaceItemAt`. Parent directories are created if missing.
    public static func write(_ data: Data, to path: URL) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let tmpPath = path.deletingPathExtension()
            .appendingPathExtension("\(path.pathExtension).tmp")
        try data.write(to: tmpPath)

        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmpPath)
        } else {
            // replaceItemAt requires an existing original on some volumes;
            // a plain move is already atomic when nothing is there to swap.
            try FileManager.default.moveItem(at: tmpPath, to: path)
        }
    }
}
