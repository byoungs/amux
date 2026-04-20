/// Session resolution: zoom operations target the given session, not
/// whichever session happens to be the environment's default.
///
/// Ported from tests/session_resolution_test.rs.
///
/// Architecture note: the original Rust `amux` CLI had a global `--session`
/// flag that overrode `$AMUX_SESSION` for any subcommand. In the Swift port,
/// user-facing commands (zoom, split, etc.) are no longer invoked through a
/// shell CLI — they go through `AppController.handleAction` and
/// `Tmux.applyLayout(session:event:)`, which takes the session as an
/// explicit parameter. This test verifies the same end-to-end guarantee
/// ("the requested session is the one operated on, even when another
/// session exists") via the new Swift API.

import Foundation
import AmuxLib

enum SessionResolutionTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // sessionFlagPriority: applying a layout event to session A must
        // affect only session A, even when session B also exists and env
        // variables point to B. In the old Rust CLI this was enforced by
        // the --session flag winning over $AMUX_SESSION. In the new Swift
        // API, `session` is a required parameter on applyLayout; there is
        // no env fallback at the layout layer, so the guarantee is
        // structural rather than runtime-resolved.
        do {
            let tsTarget = TestSession(paneCount: 3)   // session A — the target
            let tsOther  = TestSession(paneCount: 2)   // session B — must be untouched

            // Environment points at a different session; the layout call
            // should ignore it and operate on tsTarget.name.
            setenv("AMUX_SESSION", tsOther.name, 1)
            defer { unsetenv("AMUX_SESSION") }

            var zoomInSucceeded = false
            do {
                try Tmux.applyLayout(tsTarget.name, event: .zoomIn)
                zoomInSucceeded = true
            } catch {
                zoomInSucceeded = false
            }
            check("sessionFlagPriority-succeeds", zoomInSucceeded,
                  "applyLayout(zoomIn) should succeed for the target session")
            check("sessionFlagPriority-zoomed", isZoomed(tsTarget.name),
                  "target session should be zoomed")
            check("sessionFlagPriority-otherUntouched", !isZoomed(tsOther.name),
                  "other session must NOT be zoomed (env must not override the explicit parameter)")
        }

        print("SessionResolutionTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
