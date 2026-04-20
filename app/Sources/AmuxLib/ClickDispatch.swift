// ClickDispatch.swift — execute a ClickAction returned by routeNotificationClick.
//
// The pure decision layer (AlertNotification.swift) turns a click's
// userInfo + the current set of managed sessions into one of four
// actions. This file is the tiny imperative shell that carries those
// actions out: it drives tmux and, if appropriate, activates the app
// so the user's next keypress lands in the now-focused pane.
//
// App activation is abstracted behind AppActivator so tests don't
// need AppKit. The live delegate passes an activator that calls
// NSApp.activate(ignoringOtherApps: true); tests pass a recorder.
//
// tmux calls go through the static Tmux API, which routes through
// Tmux.executor — so tests point that at a FakeTmux and assert on
// the resulting in-memory state (clientSession, activePaneIndex).

import Foundation

/// Abstraction so ClickDispatch can be tested without AppKit.
public protocol AppActivator {
    func activateApp()
}

/// Carry out the routed click decision.
///
/// This is a thin orchestration layer — one tmux call per action,
/// plus optionally raising the app. It throws only what the underlying
/// `Tmux.switchSession` / `Tmux.selectPane` throw.
public func performClickAction(
    _ action: ClickAction,
    activator: AppActivator
) throws {
    switch action {
    case .switchToSessionPane(let session, let pane):
        try Tmux.switchSession(session)
        try Tmux.selectPane(session, paneIndex: pane)
        activator.activateApp()
    case .switchToManaged(let session):
        try Tmux.switchSession(session)
        activator.activateApp()
    case .bringAppForeground:
        activator.activateApp()
    case .noop:
        break
    }
}

// MARK: - Test double

#if DEBUG
/// Counts how many times activateApp() was called, so tests can assert
/// on "did the app come forward?" without touching NSApp.
public final class RecordingActivator: AppActivator {
    public private(set) var activated: Int = 0
    public init() {}
    public func activateApp() { activated += 1 }
}

public enum ClickDispatchTests {
    public static func runAll() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else {
                failed += 1
                print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")")
            }
        }

        // Each sub-case builds its own FakeTmux so state doesn't leak
        // across tests and the executor is set exactly once per case.

        // --- switchToSessionPane → tmux switch + select + activate ---
        do {
            let fake = FakeTmux()
            fake.addSession("other", panes: 3)  // becomes clientSession first
            fake.addSession("work", panes: 4)
            Tmux.executor = fake
            let activator = RecordingActivator()
            do {
                try performClickAction(
                    .switchToSessionPane(session: "work", pane: 2),
                    activator: activator)
                check("switchToSessionPane-clientMoved",
                      fake.clientSession == "work",
                      "expected clientSession=work, got \(fake.clientSession ?? "nil")")
                check("switchToSessionPane-paneSelected",
                      fake.sessions["work"]?.windows.first?.activePaneIndex == 2,
                      "expected activePaneIndex=2, got \(fake.sessions["work"]?.windows.first?.activePaneIndex ?? -1)")
                check("switchToSessionPane-activated",
                      activator.activated == 1,
                      "expected 1 activation, got \(activator.activated)")
            } catch {
                check("switchToSessionPane-threw", false, "\(error)")
            }
        }

        // --- switchToManaged → tmux switch + activate, pane unchanged ---
        do {
            let fake = FakeTmux()
            fake.addSession("home", panes: 2)
            fake.addSession("other", panes: 1)
            // Pre-set activePaneIndex to 1 so we can assert it did NOT move.
            fake.sessions["home"]?.windows.first?.activePaneIndex = 1
            Tmux.executor = fake
            let activator = RecordingActivator()
            do {
                try performClickAction(
                    .switchToManaged(session: "home"),
                    activator: activator)
                check("switchToManaged-clientMoved",
                      fake.clientSession == "home")
                check("switchToManaged-paneUnchanged",
                      fake.sessions["home"]?.windows.first?.activePaneIndex == 1,
                      "switchToManaged must not change pane selection")
                check("switchToManaged-activated",
                      activator.activated == 1)
            } catch {
                check("switchToManaged-threw", false, "\(error)")
            }
        }

        // --- bringAppForeground → no tmux, just activate ---
        do {
            let fake = FakeTmux()
            fake.addSession("anything", panes: 1)
            // Clear clientSession so we can detect any accidental switch-client.
            let originalClient = fake.clientSession
            Tmux.executor = fake
            let activator = RecordingActivator()
            do {
                try performClickAction(
                    .bringAppForeground,
                    activator: activator)
                check("bringAppForeground-clientUntouched",
                      fake.clientSession == originalClient,
                      "bringAppForeground must not issue switch-client")
                check("bringAppForeground-activated",
                      activator.activated == 1)
            } catch {
                check("bringAppForeground-threw", false, "\(error)")
            }
        }

        // --- noop → nothing happens ---
        do {
            let fake = FakeTmux()
            fake.addSession("anything", panes: 2)
            // Pin the current activePaneIndex so we can detect any
            // accidental selectPane call even if it happened to target
            // the current session; it would shift the index.
            fake.sessions["anything"]?.windows.first?.activePaneIndex = 1
            let originalClient = fake.clientSession
            Tmux.executor = fake
            let activator = RecordingActivator()
            do {
                try performClickAction(.noop, activator: activator)
                check("noop-clientUntouched",
                      fake.clientSession == originalClient)
                check("noop-notActivated",
                      activator.activated == 0,
                      "noop must not activate the app")
                check("noop-activePaneUntouched",
                      fake.sessions["anything"]?.windows.first?.activePaneIndex == 1,
                      "noop must not call selectPane on any session")
                check("noop-noUnhandled",
                      fake.unhandledCommands.isEmpty,
                      "noop must not emit any tmux commands; got: \(fake.unhandledCommands)")
            } catch {
                check("noop-threw", false, "\(error)")
            }
        }

        // Reset executor for later suites that expect LiveTmux.
        Tmux.executor = LiveTmux()

        print("ClickDispatch tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("ClickDispatch tests failed") }
    }
}
#endif
