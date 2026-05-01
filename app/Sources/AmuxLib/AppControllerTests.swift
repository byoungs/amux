#if DEBUG
import Foundation
import Darwin

public enum AppControllerTests {
    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; fputs("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")\n", stderr) }
        }

        // Helper: create a controller with FakeTmux and N panes
        func setup(panes: Int = 3, zoomed: Bool = false) -> (AppController, FakeTmux) {
            let fake = FakeTmux()
            fake.addSession("test", panes: panes)
            if zoomed { fake.setZoomed("test", true) }
            Tmux.executor = fake
            let controller = AppController(session: "test")
            return (controller, fake)
        }

        func paneOption(_ fake: FakeTmux, _ pane: Int, _ key: String) -> String {
            (try? fake.execute(["show-options", "-p", "-t", "test:.\(pane)", "-v", key])) ?? ""
        }

        func sessionOption(_ fake: FakeTmux, _ key: String) -> String {
            (try? fake.execute(["show-options", "-t", "test", "-v", key])) ?? ""
        }

        func env(_ fake: FakeTmux, _ key: String) -> String? {
            let result = (try? fake.execute(["show-environment", "-t", "test", key])) ?? ""
            guard let eqIdx = result.firstIndex(of: "=") else { return nil }
            return String(result[result.index(after: eqIdx)...])
        }

        func isZoomed(_ fake: FakeTmux) -> Bool {
            ((try? fake.execute(["display-message", "-t", "test", "-p", "#{window_zoomed_flag}"])) ?? "0") == "1"
        }

        func windowCount(_ fake: FakeTmux) -> Int {
            fake.sessions["test"]?.windows.count ?? 0
        }

        // ============================================================
        // Cmd-- (zoom out) — context dependent
        // ============================================================

        do {
            let (controller, fake) = setup(zoomed: true)
            controller.handleAction(.zoomOut)
            check("zoomOut-zoomed-unzooms", !isZoomed(fake),
                  "should unzoom")
        }

        do {
            let (controller, fake) = setup()
            check("zoomOut-working-precheck", !isZoomed(fake))
            controller.handleAction(.zoomOut)
            // At working level, zoom-out opens spaces (which is a display-message for now)
            check("zoomOut-working-noZoom", !isZoomed(fake),
                  "should stay unzoomed")
        }

        // ============================================================
        // Cmd-+ (zoom in)
        // ============================================================

        do {
            let (controller, fake) = setup()
            controller.handleAction(.zoomIn)
            check("zoomIn-working-zooms", isZoomed(fake),
                  "should zoom in")
        }

        do {
            let (controller, fake) = setup(zoomed: true)
            controller.handleAction(.zoomIn)
            check("zoomIn-alreadyZoomed-stays", isZoomed(fake),
                  "should stay zoomed")
        }

        // ============================================================
        // Cmd-1..9 (zoom to pane)
        // ============================================================

        do {
            let (controller, _) = setup(panes: 4)
            controller.handleAction(.zoomTo(2))
            check("zoomTo-valid-noError", true)
        }

        // Zoom to pane with no @amux-alert set (regression: was crashing)
        do {
            let (controller, _) = setup(panes: 4)
            // Don't set @amux-alert on any pane — fresh panes have no alert option
            controller.handleAction(.zoomTo(0))
            check("zoomTo-unsetAlert-noError", true,
                  "should not crash when @amux-alert is unset")
        }

        do {
            let (controller, _) = setup(panes: 3)
            controller.handleAction(.zoomTo(10))
            // Should show error, not crash
            check("zoomTo-invalid-noError", true)
        }

        // ============================================================
        // Cmd-L (split start)
        // ============================================================

        do {
            let (controller, fake) = setup(panes: 4)
            controller.handleAction(.splitStart)

            // Pane 0 should be split-selected (red border)
            check("splitStart-splitSelected",
                  paneOption(fake, 0, "@amux-split-selected") == "1",
                  "active pane should have @amux-split-selected=1")

            // Session should be in picking mode
            check("splitStart-picking",
                  sessionOption(fake, "@amux-picking") == "1",
                  "session should have @amux-picking=1")

            // Label should be 1-based
            let label = sessionOption(fake, "@amux-split-first-label")
            check("splitStart-label1Based",
                  label.hasPrefix("1"),
                  "label should start with '1' (1-based), got '\(label)'")

            // AMUX_SPLIT_FIRST env var should be set
            check("splitStart-envSet",
                  env(fake, "AMUX_SPLIT_FIRST") == "0",
                  "AMUX_SPLIT_FIRST should be '0'")

            // Mode should be picking
            check("splitStart-mode",
                  controller.mode == .picking)

            // Title should have been set from cwd
            let title = paneOption(fake, 0, "@amux-title")
            check("splitStart-titleSet",
                  !title.isEmpty,
                  "pane title should be set from auto_title")
        }

        // ============================================================
        // Split start from zoomed
        // ============================================================

        do {
            let (controller, fake) = setup(panes: 4, zoomed: true)
            controller.handleAction(.splitStart)

            check("splitStart-zoomed-unzoomed", !isZoomed(fake),
                  "should unzoom on split-start")
            check("splitStart-zoomed-savedState",
                  env(fake, "AMUX_SPLIT_WAS_ZOOMED") == "1",
                  "should save was-zoomed state")
        }

        // ============================================================
        // Split start with too few panes
        // ============================================================

        do {
            let (controller, fake) = setup(panes: 2)
            controller.handleAction(.splitStart)

            check("splitStart-tooFew-noPicking",
                  sessionOption(fake, "@amux-picking") != "1",
                  "should not enter picking with < 3 panes")
            check("splitStart-tooFew-mode",
                  controller.mode == .normal)
        }

        // ============================================================
        // Split cancel
        // ============================================================

        do {
            let (controller, fake) = setup(panes: 4)
            controller.handleAction(.splitStart)
            check("splitCancel-prePicking", controller.mode == .picking)

            controller.handleAction(.splitCancel)

            check("splitCancel-cleared-selected",
                  paneOption(fake, 0, "@amux-split-selected") != "1",
                  "split-selected should be cleared")
            check("splitCancel-cleared-picking",
                  sessionOption(fake, "@amux-picking") != "1",
                  "picking should be cleared")
            check("splitCancel-cleared-env",
                  env(fake, "AMUX_SPLIT_FIRST") == nil,
                  "AMUX_SPLIT_FIRST should be removed")
            check("splitCancel-mode",
                  controller.mode == .normal)
        }

        // ============================================================
        // Split cancel restores zoom
        // ============================================================

        do {
            let (controller, fake) = setup(panes: 4, zoomed: true)
            controller.handleAction(.splitStart)
            check("splitCancel-zoom-unzoomedDuring", !isZoomed(fake))

            controller.handleAction(.splitCancel)
            check("splitCancel-zoom-restored", isZoomed(fake),
                  "should restore zoom on cancel")
        }

        // ============================================================
        // Split cancel does NOT zoom if wasn't zoomed
        // ============================================================

        do {
            let (controller, fake) = setup(panes: 4)
            controller.handleAction(.splitStart)
            controller.handleAction(.splitCancel)
            check("splitCancel-noZoom-staysUnzoomed", !isZoomed(fake),
                  "should not zoom if wasn't zoomed before")
        }

        // ============================================================
        // Arrow keys in pick mode
        // ============================================================

        do {
            let (controller, _) = setup(panes: 4)
            controller.handleAction(.splitStart)

            controller.handleAction(.selectPaneRight)
            check("arrow-pickMode-works", controller.mode == .picking,
                  "should stay in picking mode after arrow")
        }

        do {
            let (controller, _) = setup(panes: 4)
            // NOT in pick mode
            controller.handleAction(.selectPaneRight)
            check("arrow-normalMode-ignored", controller.mode == .normal,
                  "arrows in normal mode should be no-op")
        }

        // ============================================================
        // Pane navigation
        // ============================================================

        do {
            let (controller, _) = setup(panes: 3)
            controller.handleAction(.paneNext)
            check("paneNext-noError", true) // verify no crash
        }

        do {
            let (controller, _) = setup(panes: 3)
            controller.handleAction(.panePrev)
            check("panePrev-noError", true)
        }

        // ============================================================
        // New pane
        // ============================================================

        do {
            let (controller, fake) = setup(panes: 2)
            controller.handleAction(.newPane)
            let count = fake.sessions["test"]?.windows.first?.panes.count ?? 0
            check("newPane-increases",
                  count == 3,
                  "should have 3 panes after adding one, got \(count)")
            let active = fake.sessions["test"]?.windows.first?.activePaneIndex ?? -1
            check("newPane-focusesNewPane",
                  active == count - 1,
                  "new pane should be active, got index \(active) of \(count) panes")
        }

        // ============================================================
        // Startup
        // ============================================================

        do {
            let fake = FakeTmux()
            Tmux.executor = fake
            let controller = AppController(session: "startup-test")

            try? controller.startup()

            check("startup-createsSession",
                  fake.sessions["startup-test"] != nil,
                  "should create session")
            check("startup-managed",
                  fake.sessions["startup-test"]?.environment["AMUX_MANAGED"] == "1",
                  "should mark as managed")
        }

        // ============================================================
        // Spaces / Send — use launch (fire-and-forget), not runRaw
        // ============================================================

        do {
            let (controller, fake) = setup()
            controller.handleAction(.spaces)
            check("spaces-uses-launch",
                  fake.launchedCommands.contains(where: { $0.first == "display-popup" }),
                  "spaces should use launch for display-popup")
        }

        do {
            let (controller, fake) = setup()
            controller.handleAction(.send)
            check("send-uses-launch",
                  fake.launchedCommands.contains(where: { $0.first == "display-popup" }),
                  "send should use launch for display-popup")
        }

        // ============================================================
        // sendPaneToSession — last pane doesn't crash
        // ============================================================

        do {
            let fake = FakeTmux()
            fake.addSession("src", panes: 1)
            fake.addSession("dst", panes: 1)
            Tmux.executor = fake

            // Moving the only pane from src destroys the session in tmux.
            // sendPaneToSession must handle this gracefully.
            do {
                try Tmux.sendPaneToSession(from: "src", to: "dst")
                check("sendLastPane-nocrash", true)
            } catch {
                check("sendLastPane-nocrash", false,
                      "should not throw when source session is destroyed: \(error)")
            }

            check("sendLastPane-srcGone",
                  fake.sessions["src"] == nil,
                  "source session should be destroyed after losing its last pane")
            let dstPanes = fake.sessions["dst"]?.windows.first?.panes.count ?? 0
            check("sendLastPane-dstHas2",
                  dstPanes == 2,
                  "destination should have 2 panes, got \(dstPanes)")
        }

        // ============================================================
        // Session resolution — follows client after space switch
        // ============================================================

        do {
            let fake = FakeTmux()
            fake.addSession("spaceA", panes: 3)
            fake.addSession("spaceB", panes: 2)
            Tmux.executor = fake

            let controller = AppController(session: "spaceA")
            check("sessionResolution-initial",
                  controller.session == "spaceA")

            // Simulate the user switching spaces via the picker.
            // The picker calls switch-client, which updates FakeTmux.clientSession.
            try? Tmux.switchSession("spaceB")
            check("sessionResolution-clientMoved",
                  fake.clientSession == "spaceB",
                  "switch-client should update clientSession")

            // Next handleAction should detect the client moved to spaceB.
            controller.handleAction(.zoomIn)
            check("sessionResolution-followed",
                  controller.session == "spaceB",
                  "controller should follow client to spaceB, got \(controller.session)")
        }

        // Session resolution — follows client when session is destroyed
        do {
            let fake = FakeTmux()
            fake.addSession("original", panes: 2)
            fake.addSession("other", panes: 1)
            Tmux.executor = fake

            let controller = AppController(session: "original")

            // Destroy the original session (simulates sending last pane).
            // Client auto-follows to "other".
            fake.sessions.removeValue(forKey: "original")
            fake.clientSession = "other"

            controller.handleAction(.spaces)
            check("sessionRecovery-followed",
                  controller.session == "other",
                  "controller should follow client to other, got \(controller.session)")
            check("sessionRecovery-launchFired",
                  fake.launchedCommands.contains(where: { $0.first == "display-popup" }),
                  "should launch popup targeting recovered session")
        }

        // Reset executor to LiveTmux for any subsequent tests
        Tmux.executor = LiveTmux()

        print("AppController tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("AppController tests failed") }
    }
}
#endif
