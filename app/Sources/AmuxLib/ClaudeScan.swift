// ClaudeScan.swift -- The imperative shell around ClaudeSession's pure core.
//
// Reads the two things the resolver needs and nothing else:
//   - the processes under each tmux pane (`pgrep -P` walk + `ps`)
//   - metadata for each ~/.claude/projects/<slug>/<id>.jsonl transcript
//
// Transcripts can be tens of megabytes, so nothing here reads a whole file:
// the head gives the first timestamp, the first user message and any early
// summaries; the tail gives the last timestamp and the latest user message.

import Foundation

public enum ClaudeScan {
    /// Levels of descendants to walk from the pane's pid. Claude sits one
    /// level under the pane shell, two when wrapped in `sh -c`.
    public static let descendantDepth = 3

    private static let headBytes = 256 * 1024
    private static let tailBytes = 64 * 1024

    // MARK: - Processes

    /// Every process running under a pane: its shell plus descendants.
    public static func processes(paneProcessID pid: Int) -> [ProcSample] {
        let pids = [pid] + descendants(of: pid)
        guard !pids.isEmpty else { return [] }
        let out = run("/bin/ps", ["-o", "lstart=,command=", "-p", pids.map(String.init).joined(separator: ",")])
        return out.split(separator: "\n").compactMap { parsePSLine(String($0)) }
    }

    /// pids of pid's children, grandchildren, ...
    public static func descendants(of pid: Int) -> [Int] {
        var out: [Int] = []
        var frontier = [pid]
        for _ in 0..<descendantDepth {
            var next: [Int] = []
            for p in frontier {
                let listed = run("/usr/bin/pgrep", ["-P", String(p)])
                next += listed.split(whereSeparator: { $0 == "\n" || $0 == " " }).compactMap { Int($0) }
            }
            if next.isEmpty { break }
            out += next
            frontier = next
        }
        return out
    }

    /// `ps -o lstart=,command=` line → sample. lstart is a fixed-width 24-char
    /// ctime string ("Tue Sep  1 06:29:24 2026") in local time.
    public static func parsePSLine(_ line: String) -> ProcSample? {
        guard line.count > 24 else { return nil }
        let stampEnd = line.index(line.startIndex, offsetBy: 24)
        guard let start = parseLstart(String(line[line.startIndex..<stampEnd])) else { return nil }
        let command = String(line[stampEnd...]).trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        return ProcSample(startTime: start, command: command)
    }

    /// "Tue Sep  1 06:29:24 2026" (local time) → epoch seconds.
    public static func parseLstart(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5,
              let month = monthNumber(parts[1]),
              let day = Int(parts[2]),
              let year = Int(parts[4]) else { return nil }
        let clock = parts[3].split(separator: ":").compactMap { Int($0) }
        guard clock.count == 3 else { return nil }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = clock[0]; c.minute = clock[1]; c.second = clock[2]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal.date(from: c)?.timeIntervalSince1970
    }

    private static func monthNumber(_ name: String) -> Int? {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return months.firstIndex(of: name).map { $0 + 1 }
    }

    // MARK: - Transcripts

    /// Directory holding Claude Code's per-project transcripts.
    public static var projectsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    /// Metadata for every transcript in the given project slugs.
    public static func transcripts(slugs: Set<String>, projectsDir: URL = projectsDir) -> [TranscriptMeta] {
        var out: [TranscriptMeta] = []
        for slug in slugs {
            let dir = projectsDir.appendingPathComponent(slug)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                     includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                if let meta = transcriptMeta(file: file, slug: slug) { out.append(meta) }
            }
        }
        return out
    }

    private static func transcriptMeta(file: URL, slug: String) -> TranscriptMeta? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        try? handle.seek(toOffset: 0)
        let head = String(decoding: (try? handle.read(upToCount: headBytes)) ?? Data(), as: UTF8.self)
        var tail = ""
        if size > headBytes {
            try? handle.seek(toOffset: UInt64(max(0, size - tailBytes)))
            tail = String(decoding: (try? handle.read(upToCount: tailBytes)) ?? Data(), as: UTF8.self)
        }

        let firstTimestamp = firstTimestamp(in: head)
        let lastTimestamp = lastTimestamp(in: tail.isEmpty ? head : tail) ?? firstTimestamp
        return TranscriptMeta(
            sessionID: file.deletingPathExtension().lastPathComponent,
            slug: slug,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            topicBlob: topicBlob(head: head, tail: tail))
    }

    /// Epoch of the first `"timestamp":"…"` in a chunk of transcript.
    public static func firstTimestamp(in chunk: String) -> Double? {
        for line in chunk.split(separator: "\n") {
            if let t = timestampValue(in: String(line)) { return t }
        }
        return nil
    }

    /// Epoch of the last complete `"timestamp":"…"` in a chunk.
    public static func lastTimestamp(in chunk: String) -> Double? {
        var found: Double?
        for line in chunk.split(separator: "\n") {
            if let t = timestampValue(in: String(line)) { found = t }
        }
        return found
    }

    private static func timestampValue(in line: String) -> Double? {
        guard let range = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return parseISO8601UTC(String(rest[rest.startIndex..<end]))
    }

    /// "2026-09-01T06:29:24.123Z" → epoch seconds. Transcript stamps are UTC.
    public static func parseISO8601UTC(_ s: String) -> Double? {
        guard s.count >= 19 else { return nil }
        let chars = Array(s)
        func num(_ lo: Int, _ hi: Int) -> Int? { Int(String(chars[lo..<hi])) }
        guard let year = num(0, 4), let month = num(5, 7), let day = num(8, 10),
              let hour = num(11, 13), let minute = num(14, 16), let second = num(17, 19)
        else { return nil }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal.date(from: c)?.timeIntervalSince1970
    }

    /// Summaries + first user message + last user message — enough signal for
    /// topic matching without holding a whole transcript in memory.
    public static func topicBlob(head: String, tail: String) -> String {
        var summaries: [String] = []
        var firstUser = ""
        var lastUser = ""
        for (isHead, chunk) in [(true, head), (false, tail)] {
            for line in chunk.split(separator: "\n") {
                let s = String(line)
                if s.contains("\"summary\""), let summary = jsonStringValue(key: "summary", in: s) {
                    summaries.append(summary)
                }
                if s.contains("\"role\":\"user\""), let text = userText(in: s) {
                    if isHead && firstUser.isEmpty { firstUser = text }
                    lastUser = text
                }
            }
        }
        return (summaries + [firstUser, lastUser]).joined(separator: " ")
    }

    /// The plain text of a user message line, skipping tool results and the
    /// XML-ish system reminders that carry no topic signal.
    private static func userText(in line: String) -> String? {
        guard let text = jsonStringValue(key: "text", in: line) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("<") { return nil }
        return trimmed
    }

    /// First `"key":"value"` string for a key, with \" unescaped.
    public static func jsonStringValue(key: String, in line: String) -> String? {
        guard let range = line.range(of: "\"\(key)\":\"") else { return nil }
        var out = ""
        var escaped = false
        for ch in line[range.upperBound...] {
            if escaped {
                out.append(ch == "n" ? " " : ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return out
            } else {
                out.append(ch)
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Process helper

    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Wait on a semaphore, never `waitUntilExit()`: that pumps the calling
        // thread's run loop, which re-enters amux's own timers and tmux calls.
        // See the deadlock note in CLAUDE.md / LiveTmux.execute.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        try? pipe.fileHandleForReading.close()
        return String(decoding: data, as: UTF8.self)
    }
}
