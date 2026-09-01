#if DEBUG
import Foundation

/// Reading transcript metadata off disk.
///
/// Capture runs on every pane focus change, and a project directory can hold
/// hundreds of megabytes of transcripts, so the cheap pass must stay cheap:
/// the first timestamp is all that `.resumeArg` and `.startTime` need, and
/// topic text is only read for the panes those two signals failed to settle.
public enum ClaudeScanTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amux-scan-tests-\(UUID().uuidString)")
        let slug = "-Users-b-src-amux"
        let dir = root.appendingPathComponent(slug)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = """
        {"type":"summary","summary":"Scroll reflow in copy mode"}
        {"timestamp":"2026-09-01T06:29:24.123Z","message":{"role":"user","content":[{"type":"text","text":"the christmas tree effect on resize"}]}}
        {"timestamp":"2026-09-01T06:31:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"looking"}]}}
        {"timestamp":"2026-09-01T07:02:11.000Z","message":{"role":"user","content":[{"type":"text","text":"check the notification hooks"}]}}
        """
        try? Data(transcript.utf8).write(to: dir.appendingPathComponent("abc-123.jsonl"))

        // Cheap pass: the id and when the conversation started, nothing else.
        let heads = ClaudeScan.transcriptHeads(slugs: [slug], projectsDir: root)
        check("head-count", heads.count == 1, "\(heads.count)")
        let head = heads.first
        check("head-session-id", head?.sessionID == "abc-123", head?.sessionID ?? "nil")
        check("head-slug", head?.slug == slug, head?.slug ?? "nil")
        check("head-first-timestamp",
              head?.firstTimestamp == ClaudeScan.parseISO8601UTC("2026-09-01T06:29:24"),
              String(describing: head?.firstTimestamp))
        check("head-no-topic-work", head?.topicBlob.isEmpty == true, head?.topicBlob ?? "nil")

        // Expensive pass, only for the slugs that still need it.
        let enriched = ClaudeScan.withTopics(heads, slugs: [slug], projectsDir: root)
        let full = enriched.first
        check("topics-keep-first-timestamp", full?.firstTimestamp == head?.firstTimestamp)
        check("topics-last-timestamp",
              full?.lastTimestamp == ClaudeScan.parseISO8601UTC("2026-09-01T07:02:11"),
              String(describing: full?.lastTimestamp))
        check("topics-summary", full?.topicBlob.contains("Scroll reflow") == true, full?.topicBlob ?? "nil")
        check("topics-first-user",
              full?.topicBlob.contains("christmas tree") == true, full?.topicBlob ?? "nil")
        check("topics-last-user",
              full?.topicBlob.contains("notification hooks") == true, full?.topicBlob ?? "nil")

        // Slugs outside the request are left alone, so an unrelated 400MB
        // project directory is never touched.
        let untouched = ClaudeScan.withTopics(heads, slugs: [], projectsDir: root)
        check("topics-scoped-to-slugs", untouched.first?.topicBlob.isEmpty == true,
              untouched.first?.topicBlob ?? "nil")

        // Which slugs still need topic text: only those with a Claude pane the
        // deterministic signals could not settle.
        let unresolved = PaneProcesses(session: "amux", index: 0, cwd: "/Users/b/src/amux",
                                       title: "t", paneCommand: "claude", processes: [])
        let resolved = PaneProcesses(session: "amux", index: 1, cwd: "/Users/b/src/other",
                                     title: "t", paneCommand: "claude", processes: [])
        let needed = ClaudeSession.slugsNeedingTopics(
            panes: [unresolved, resolved],
            resolutions: [
                PaneRef(session: "amux", index: 0): ClaudePaneID(sessionID: nil, confidence: .none),
                PaneRef(session: "amux", index: 1): ClaudePaneID(sessionID: "x", confidence: .startTime),
            ])
        check("needy-slugs", needed == [slug], needed.joined(separator: ","))

        print("ClaudeScan tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("ClaudeScan tests failed") }
    }
}
#endif
