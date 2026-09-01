/// Integration test runner for amux.
///
/// Standalone executable that runs all integration tests against the
/// compiled amux binary and tmux. No XCTest dependency.
///
/// ## Isolation
///
/// Tests run on an isolated tmux server via a custom socket (`-L`)
/// so they cannot leak messages or sessions to the user's live tmux.
/// Without this, tests that deliberately trigger error paths
/// (e.g. ZoomTests calling `zoom 6` with only 3 panes) would display
/// "Pane 7 does not exist" in the user's active session via
/// `tmux display-message`.
///
/// Both the Tmux library (via Tmux.executor = LiveTmux(socket:)) and
/// direct shell calls from tests (via TestHelpers.tmux()) use the
/// same isolated socket. The server is killed on process exit.
///
/// Usage: amux-integration-tests
/// Exit code: 0 if all pass, 1 if any fail.

import Foundation
import AmuxLib

// Line-buffer stdout so progress is visible when output is redirected
// (e.g., `amux-integration-tests > log.txt`).
setlinebuf(stdout)

// Isolate tests on a unique tmux socket tied to this test process's PID.
Tmux.executor = LiveTmux(socket: testTmuxSocket)

// Clean up the isolated tmux server on exit, no matter what.
atexit {
    _ = try? Process.run(
        URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["tmux", "-L", testTmuxSocket, "kill-server"]
    )
}

var totalPassed = 0
var totalFailed = 0

func run(_ name: String, _ block: () -> (passed: Int, failed: Int)) {
    let result = block()
    totalPassed += result.passed
    totalFailed += result.failed
}

run("Smoke", SmokeTests.runAll)
run("Config", ConfigTests.runAll)
run("Zoom", ZoomTests.runAll)
run("Amux", AmuxTests.runAll)
run("Alert", AlertTests.runAll)
run("E2EAttention", E2EAttentionTests.runAll)
run("Send", SendTests.runAll)
run("HookScoping", HookScopingTests.runAll)
run("SplitVisual", SplitVisualTests.runAll)
run("SplitMode", SplitModeTests.runAll)
run("SessionResolution", SessionResolutionTests.runAll)
run("CmdLScenario", CmdLScenarioTests.runAll)
run("Help", HelpTests.runAll)
run("PermissionCapture", PermissionCaptureTests.runAll)
run("SessionRestore", SessionRestoreTests.runAll)

// Border format tests verify per-pane pane-border-format colors for all 4 states
// (active/teal, alert/amber, split-selected/red, inactive/no override)
// and all state transitions. These tests run against real tmux.
run("BorderFormat", BorderFormatTests.runAll)

// Dev bundle assembly tests: verify `make build-dev-bundle` produces a
// valid .app with the bundle identifier UNUserNotificationCenter needs.
// Covers the exact regression where raw Mach-O launch silently disabled
// every notification post.
run("DevBundle", DevBundleTests.runAll)

print("\n=== Integration Tests: \(totalPassed) passed, \(totalFailed) failed ===")

if totalFailed > 0 {
    exit(1)
}
