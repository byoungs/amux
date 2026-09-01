#if DEBUG
import Foundation

/// Claude session-id resolution. A wrong id resumes the wrong conversation,
/// so every test here is about which signal wins and when the resolver must
/// refuse to answer rather than guess.
public enum ClaudeSessionTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let cwd = "/Users/b/src/amux"
        let slug = ClaudeSession.slugFor(cwd)
        check("slug", slug == "-Users-b-src-amux", slug)

        func pane(_ index: Int, title: String, starts: [Double],
                  command: String = "claude", cwd: String = cwd) -> PaneProcesses {
            PaneProcesses(
                session: "amux", index: index, cwd: cwd, title: title,
                paneCommand: "zsh",
                processes: starts.map { ProcSample(startTime: $0, command: command) })
        }
        func transcript(_ id: String, first: Double, last: Double, blob: String,
                        cwd: String = cwd) -> TranscriptMeta {
            TranscriptMeta(sessionID: id, slug: ClaudeSession.slugFor(cwd),
                           firstTimestamp: first, lastTimestamp: last, topicBlob: blob)
        }
        let ref = { (i: Int) in PaneRef(session: "amux", index: i) }

        // 1. An explicit `--resume <uuid>` argv beats a nearer start-time match.
        let resumeID = "11111111-2222-3333-4444-555555555555"
        let nearID = "99999999-8888-7777-6666-555555555555"
        let resumed = resolveOne(
            panes: [pane(0, title: "amux", starts: [1_000],
                         command: "claude --resume \(resumeID)")],
            transcripts: [transcript(nearID, first: 1_000, last: 2_000, blob: "amux layout")])
        check("resume-arg-wins", resumed[ref(0)] == ClaudePaneID(sessionID: resumeID, confidence: .resumeArg),
              String(describing: resumed[ref(0)]))

        // 2. Start time inside tolerance resolves; nearest transcript wins.
        let inTol = resolveOne(
            panes: [pane(0, title: "amux", starts: [1_000])],
            transcripts: [transcript("far", first: 1_290, last: 1_500, blob: "x"),
                          transcript("near", first: 1_040, last: 1_500, blob: "y")])
        check("start-time-nearest", inTol[ref(0)] == ClaudePaneID(sessionID: "near", confidence: .startTime),
              String(describing: inTol[ref(0)]))

        // 3. Outside the 300s tolerance is not a match — and with no topic
        //    overlap the pane resolves to nothing rather than to the only
        //    transcript lying around.
        let outTol = resolveOne(
            panes: [pane(0, title: "amux", starts: [1_000])],
            transcripts: [transcript("stale", first: 1_400, last: 1_500, blob: "unrelated words")])
        check("start-time-outside-tolerance",
              outTol[ref(0)] == ClaudePaneID(sessionID: nil, confidence: .none),
              String(describing: outTol[ref(0)]))

        // 4. Two panes in one project dir, neither pinned: topic overlap
        //    assigns them uniquely and labels both as heuristic matches.
        let two = resolveOne(
            panes: [pane(0, title: "scroll reflow", starts: [5_000]),
                    pane(1, title: "notification hooks", starts: [5_000])],
            transcripts: [transcript("t-notify", first: 90_000, last: 91_000,
                                     blob: "notification hooks posting alerts"),
                          transcript("t-scroll", first: 90_000, last: 91_000,
                                     blob: "scroll reflow copy mode")])
        check("topic-unique-0", two[ref(0)] == ClaudePaneID(sessionID: "t-scroll", confidence: .topicMatch),
              String(describing: two[ref(0)]))
        check("topic-unique-1", two[ref(1)] == ClaudePaneID(sessionID: "t-notify", confidence: .topicMatch),
              String(describing: two[ref(1)]))

        // 5. An id already pinned exactly is off the table for topic matching,
        //    so the second pane cannot steal it.
        let scrollID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let pinned = resolveOne(
            panes: [pane(0, title: "scroll", starts: [5_000],
                         command: "claude --resume \(scrollID)"),
                    pane(1, title: "scroll reflow", starts: [5_000])],
            transcripts: [transcript(scrollID, first: 90_000, last: 91_000,
                                     blob: "scroll reflow copy mode")])
        check("pinned-not-reused", pinned[ref(1)]?.sessionID == nil,
              String(describing: pinned[ref(1)]))

        // 6. No transcripts at all → .none, never a fabricated id.
        let empty = resolveOne(panes: [pane(0, title: "amux", starts: [1_000])], transcripts: [])
        check("no-candidate-none", empty[ref(0)] == ClaudePaneID(sessionID: nil, confidence: .none),
              String(describing: empty[ref(0)]))

        // 7. A non-Claude pane is not in the result at all — the process scan,
        //    not pane_current_command, decides. (A pane at Claude's "resume
        //    from summary?" prompt still reports its shell, hence the scan.)
        let shellPane = PaneProcesses(session: "amux", index: 0, cwd: cwd, title: "amux",
                                      paneCommand: "zsh",
                                      processes: [ProcSample(startTime: 1_000, command: "vim notes.md")])
        let shellOnly = ClaudeSession.resolveSessionIDs(panes: [shellPane], transcripts: [])
        check("shell-pane-absent", shellOnly[ref(0)] == nil, String(describing: shellOnly[ref(0)]))
        check("claude-detected-by-process",
              ClaudeSession.isClaudePane(paneCommand: "zsh",
                                         processes: [ProcSample(startTime: 1, command: "claude")]))
        check("claude-detected-by-version-cmd",
              ClaudeSession.isClaudePane(paneCommand: "2.1.156", processes: []))

        // 8. Transcripts from another project dir are never candidates.
        let otherDir = resolveOne(
            panes: [pane(0, title: "amux", starts: [1_000])],
            transcripts: [transcript("elsewhere", first: 1_000, last: 1_100,
                                     blob: "amux", cwd: "/Users/b/src/other")])
        check("slug-scoped", otherDir[ref(0)]?.sessionID == nil, String(describing: otherDir[ref(0)]))

        print("ClaudeSession tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("ClaudeSession tests failed") }
    }

    private static func resolveOne(panes: [PaneProcesses],
                                   transcripts: [TranscriptMeta]) -> [PaneRef: ClaudePaneID] {
        ClaudeSession.resolveSessionIDs(panes: panes, transcripts: transcripts)
    }
}
#endif
