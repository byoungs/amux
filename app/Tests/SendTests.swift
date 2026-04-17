/// Tests for sending panes between spaces.
///
/// Ported from tests/send_test.rs.

import Foundation

enum SendTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // send_to_new_space_has_one_pane
        // This tests: create target session, send pane, kill phantom, verify 1 pane.
        // The Rust test calls library functions (create_session, send_pane_to_session,
        // kill_phantom_pane). We replicate via tmux commands.
        do {
            let ts = TestSession(paneCount: 2)
            let target = "\(ts.name)-target"

            // Create target session
            tmux("new-session", "-d", "-s", target, "-x", "200", "-y", "50")
            // Apply amux config
            amuxCmd(session: target, args: ["--session", target, "refresh"])

            // Get active pane ID from source before sending
            let sentIDResult = tmux("display-message", "-t", ts.name, "-p", "#{pane_id}")
            let sentID = sentIDResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            // Send active pane from source to target (join-pane)
            tmux("join-pane", "-s", ts.name, "-t", target)

            // Kill the phantom pane (the default pane created with new-session).
            // The phantom is whichever pane is NOT the one we sent.
            let listResult = tmux("list-panes", "-t", target, "-F", "#{pane_id}")
            let paneIDs = listResult.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
            let phantomIDs = paneIDs.filter { $0 != sentID }
            for phantomID in phantomIDs {
                tmux("kill-pane", "-t", phantomID)
            }

            let count = paneCount(target)
            check("sendToNewSpaceHasOnePane", count == 1,
                  "target space should have 1 pane after send, got \(count)")

            // Clean up target session
            tmux("kill-session", "-t", target)
        }

        // send_to_existing_space_preserves_panes
        do {
            let ts1 = TestSession(paneCount: 2)
            let ts2 = TestSession(paneCount: 2)

            // Send active pane from ts1 to ts2
            tmux("join-pane", "-s", ts1.name, "-t", ts2.name)

            let count = paneCount(ts2.name)
            check("sendToExistingSpacePreservesPanes", count == 3,
                  "existing space should gain 1 pane: 2 + 1 = 3, got \(count)")
        }

        // relayout_on_nonexistent_session_is_graceful_noop
        // Deferred to Phase 4: calls amux::tmux::apply_layout() directly (pure library function).
        // The CLI equivalent would be `amux refresh` on a nonexistent session, but that
        // tests error handling in the binary, not the library function.

        print("SendTests: \(passed) passed, \(failed) failed (1 deferred to Phase 4)")
        return (passed, failed)
    }
}
