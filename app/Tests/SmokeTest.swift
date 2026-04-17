/// Smoke tests to verify the Swift integration test infrastructure works.

enum SmokeTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition {
                passed += 1
            } else {
                failed += 1
                print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")")
            }
        }

        // Test 1: Session starts with one pane
        do {
            let ts = TestSession(paneCount: 1)
            check("startCreatesSessionWithOnePane",
                  paneCount(ts.name) == 1,
                  "expected 1 pane, got \(paneCount(ts.name))")
        }

        // Test 2: Adding a pane increases count
        do {
            let ts = TestSession(paneCount: 2)
            check("createPaneIncreasesCount-initial",
                  paneCount(ts.name) == 2,
                  "expected 2 panes, got \(paneCount(ts.name))")

            tmux("split-window", "-t", ts.name, "-d")
            check("createPaneIncreasesCount-after",
                  paneCount(ts.name) == 3,
                  "expected 3 panes, got \(paneCount(ts.name))")
        }

        print("Smoke tests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
