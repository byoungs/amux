// AlertNotification.swift — pure logic for cross-session alert notifications.
//
// Two bugs motivate this file:
//
//   1) Clicking a macOS alert opens the wrong application. Today amux-cli
//      shells `osascript -e 'display notification ...'`; AppleScript owns
//      the posted notification, so macOS routes clicks to Script Editor
//      (or drops them on newer OS versions), not to amux. Fix: post via
//      UNUserNotificationCenter from the persistent `amux-app` process
//      and carry userInfo that routes clicks back to the originating
//      session + pane.
//
//   2) Notification body reports per-session count, not global. If three
//      Claudes in three different amux spaces all go ready, the user sees
//      "1 agent is ready for you" three times in a row, not "3 agents
//      are ready for you".
//
// The code in this file is the pure decision layer that the fix needs:
// how to sum counts across sessions, whether a given alert event should
// produce a notification, how to compose the payload, and how to route
// the click back to tmux. No AppKit, no tmux, no OS APIs. The live app
// wires these to `UNUserNotificationCenter`; tests wire them to
// `RecordingNotificationPoster`.

import Foundation

// MARK: - Cross-session count

/// Total "ready for you" agents across all amux-managed tmux sessions.
///
/// Takes the per-session `@amux-alert-count` map produced by
/// `Tmux.listSpacesWithAlerts()` and sums it. Callers should pass only
/// managed sessions; `listSpacesWithAlerts` already filters.
public func globalAlertCount(_ perSessionCounts: [String: Int]) -> Int {
    perSessionCounts.values.reduce(0, +)
}

// MARK: - Notification payload

/// What a posted alert notification carries. The userInfo map is the
/// contract the click router consumes.
public struct AlertNotificationPayload: Equatable {
    public let title: String
    public let body: String
    public let session: String
    public let pane: Int

    public init(title: String, body: String, session: String, pane: Int) {
        self.title = title
        self.body = body
        self.session = session
        self.pane = pane
    }

    /// Serialized form for UNNotificationContent.userInfo.
    public var userInfo: [String: String] {
        ["session": session, "pane": String(pane)]
    }
}

/// Compose the notification payload for an alert event.
///
/// `globalCount` is summed across all managed sessions — NOT the
/// originating session's count alone. That is the observable fix for
/// bug (2) above.
public func composeAlertNotification(
    globalCount: Int,
    triggerSession: String,
    triggerPane: Int
) -> AlertNotificationPayload {
    AlertNotificationPayload(
        title: "amux",
        body: Notify.formatMessage(count: globalCount),
        session: triggerSession,
        pane: triggerPane
    )
}

// MARK: - Send decision

/// Should we post a macOS notification for this alert event?
///
/// Rules (the live app just applies these; it doesn't decide):
///   - Terminal frontmost → suppress. The user sees the amber overlay
///     directly; a system notification would be redundant noise.
///   - Current count is zero → suppress. Nothing to notify about.
///   - Current count equals the last count we posted → suppress. This
///     is the re-assertion case: applyAlertState is idempotent, so a
///     second alert event on an already-alerted pane leaves the global
///     count unchanged; that's the one scenario where we want silence.
///     (We intentionally do NOT require `current > previous` — after the
///     user dismisses everything, a new alert may arrive with count 1
///     while the last posted count was larger; that's still news.)
///   - Inside the 30-second debounce window → suppress. The previous
///     notification already surfaced the situation; ping storms are
///     hostile.
public func shouldSendAlertNotification(
    previousGlobalCount: Int,
    currentGlobalCount: Int,
    elapsedSecondsSinceLast: UInt64,
    terminalFrontmost: Bool
) -> Bool {
    if terminalFrontmost { return false }
    if currentGlobalCount == 0 { return false }
    if currentGlobalCount == previousGlobalCount { return false }
    if elapsedSecondsSinceLast < 30 { return false }
    return true
}

// MARK: - Click routing

/// What the live delegate does in response to a user clicking a
/// notification amux posted. Enum so tests can pin the decision.
public enum ClickAction: Equatable {
    /// Switch the tmux client to the originating session and select
    /// the originating pane. This is the happy path.
    case switchToSessionPane(session: String, pane: Int)
    /// Originating session was destroyed before the click landed. Fall
    /// back to whichever managed session still exists.
    case switchToManaged(session: String)
    /// No managed sessions remain at all; just bring the amux window
    /// to front so the user sees something.
    case bringAppForeground
    /// The notification userInfo is missing or malformed. Do nothing.
    case noop
}

/// Pure click router. Given the userInfo the app received and the list
/// of currently managed sessions, produce the action to take.
public func routeNotificationClick(
    userInfo: [String: String],
    managedSessions: [String]
) -> ClickAction {
    guard let sessionName = userInfo["session"],
          let paneStr = userInfo["pane"],
          let paneIndex = Int(paneStr) else {
        return .noop
    }
    if managedSessions.contains(sessionName) {
        return .switchToSessionPane(session: sessionName, pane: paneIndex)
    }
    if let fallback = managedSessions.first {
        return .switchToManaged(session: fallback)
    }
    return .bringAppForeground
}

// MARK: - Poster abstraction

/// Abstraction over `UNUserNotificationCenter` so unit tests can inject
/// a recording double without linking AppKit or running inside a
/// bundled app. The live implementation lives in the `amux-app` target
/// where `UNUserNotificationCenter` is available and the bundle is the
/// one clicks route to.
public protocol NotificationPoster {
    func post(_ payload: AlertNotificationPayload)
}

/// Test double: records every post() call for later assertion.
public final class RecordingNotificationPoster: NotificationPoster {
    public private(set) var posted: [AlertNotificationPayload] = []
    public init() {}
    public func post(_ payload: AlertNotificationPayload) {
        posted.append(payload)
    }
}

// MARK: - Alert-pane flow (split across IPC boundary)

/// amux-cli path: update tmux state for a new alert on this pane.
///
/// Idempotent — re-asserting on an already-alerted pane is a no-op.
/// Does NOT post notifications; that is amux-app's job, reached via the
/// `AlertEvent` transport (see `AlertEventTransport.swift`). Splitting
/// the mutation from the decision lets each side of the IPC boundary
/// own exactly one responsibility.
///
/// Called from the CLI process whenever a bell or Claude-Code hook
/// fires. Must be safe to call repeatedly with the same arguments.
public func applyAlertState(session: String, pane: Int) throws {
    // Idempotent on already-alerted panes.
    if (try? Tmux.getAlert(session, paneIndex: pane)) == true { return }

    // Spec (docs/attention-management.md, Alert flow step 4): skip if
    // pane is the active pane. The user is parked on it; when they next
    // look at amux they will see the output directly. Setting the flag
    // anyway leaves a stale alert that no focus event will clear, which
    // inflates `@amux-alert-count` and produces phantom-count
    // notifications later.
    if (try? Tmux.activePaneIndex(session)) == pane { return }

    // Mark the pane as alerted.
    try Tmux.setAlert(session, paneIndex: pane, alert: true)

    // Recompute the triggering session's `@amux-alert-count` (the
    // status-bar badge reads this).
    let sessionStates = (try? Tmux.alertStates(session)) ?? []
    Tmux.setAlertCount(session, count: countAlerts(sessionStates))
}

/// amux-app path: decide whether to post a macOS notification for an
/// incoming `AlertEvent`, and if so, post it.
///
/// Assumes `applyAlertState` has already been applied by the CLI side;
/// this function only reads tmux state, never mutates alert flags.
/// It does, however, write the last-notification time and
/// last-notified-global-count markers when it posts — that bookkeeping
/// is inherent to the post decision.
///
/// Suppression rules, in order:
///   1. Terminal is frontmost AND the event pane is the active pane →
///      skip. The user is already looking at it.
///   2. Global count did not increase beyond what we last notified, or
///      we are inside the 30-second debounce window, or terminal is
///      frontmost (and pane is not active) — all handled by
///      `shouldSendAlertNotification`.
///
/// Dependencies are injected: `nowSeconds` is the wall clock in seconds
/// (the live caller passes `UInt64(Date().timeIntervalSince1970)`) and
/// `poster` is the `NotificationPoster` abstraction. Tests wire
/// `FakeTmux` via `Tmux.executor` and a `RecordingNotificationPoster`.
public func processAlertTrigger(
    _ event: AlertEvent,
    nowSeconds: UInt64,
    poster: NotificationPoster
) throws {
    // 1. Don't interrupt the user if they're looking at this very pane.
    if event.terminalFrontmost {
        let active = (try? Tmux.activePaneIndex(event.session)) ?? -1
        if event.pane == active { return }
    }

    // 2. Global count across all amux-managed sessions. This is the
    //    number the user cares about — it matches what the
    //    per-terminal amber indicators collectively show.
    let spaces = (try? Tmux.listSpacesWithAlerts()) ?? (sessions: [], alertCounts: [:])
    let currentGlobal = globalAlertCount(spaces.alertCounts)

    // 3. Deduplication: compare against last global count we posted
    //    for. Stored on the triggering session because the post-time
    //    is also per-session (tmux gives us one env per session).
    let previousGlobal = (try? Tmux.getLastNotifiedGlobalCount(event.session)) ?? 0
    let elapsed = (try? Tmux.getLastNotificationElapsed(event.session, now: nowSeconds)) ?? UInt64.max

    if shouldSendAlertNotification(
        previousGlobalCount: previousGlobal,
        currentGlobalCount: currentGlobal,
        elapsedSecondsSinceLast: elapsed,
        terminalFrontmost: event.terminalFrontmost
    ) {
        let payload = composeAlertNotification(
            globalCount: currentGlobal,
            triggerSession: event.session,
            triggerPane: event.pane)
        poster.post(payload)

        // Record what we posted so the next call in this window
        // knows the "previous" global and won't re-fire.
        Tmux.setLastNotificationTime(event.session, at: nowSeconds)
        Tmux.setLastNotifiedGlobalCount(event.session, count: currentGlobal)
    }
}

// MARK: - Tests

#if DEBUG
public enum AlertNotificationTests {
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

        // --- globalAlertCount: the bug-fix spec ---

        check("globalAlertCount-empty",
              globalAlertCount([:]) == 0)
        check("globalAlertCount-single",
              globalAlertCount(["a": 3]) == 3)
        check("globalAlertCount-multi",
              globalAlertCount(["a": 2, "b": 1, "c": 4]) == 7,
              "count across all sessions must be the SUM; one-agent-per-space alarm floods are the bug we are fixing")
        check("globalAlertCount-zeros",
              globalAlertCount(["a": 0, "b": 0]) == 0)
        check("globalAlertCount-mixed",
              globalAlertCount(["a": 0, "b": 2]) == 2)

        // --- composeAlertNotification ---

        let p1 = composeAlertNotification(
            globalCount: 1, triggerSession: "work", triggerPane: 2)
        check("compose-title", p1.title == "amux")
        check("compose-body-singular",
              p1.body == "1 agent is ready for you")
        check("compose-session", p1.session == "work")
        check("compose-pane", p1.pane == 2)
        check("compose-userInfo-session",
              p1.userInfo["session"] == "work",
              "userInfo must carry session name so click routing can target the source")
        check("compose-userInfo-pane",
              p1.userInfo["pane"] == "2")

        let p3 = composeAlertNotification(
            globalCount: 3, triggerSession: "x", triggerPane: 0)
        check("compose-body-plural",
              p3.body == "3 agents are ready for you")

        let p0 = composeAlertNotification(
            globalCount: 0, triggerSession: "x", triggerPane: 0)
        check("compose-body-zero",
              p0.body == "All agents are working",
              "zero still returns a defined message; shouldSend suppresses it separately")

        // --- shouldSendAlertNotification ---

        check("shouldSend-happyPath",
              shouldSendAlertNotification(
                  previousGlobalCount: 0, currentGlobalCount: 1,
                  elapsedSecondsSinceLast: 9999, terminalFrontmost: false))

        check("shouldSend-frontmostSuppressed",
              !shouldSendAlertNotification(
                  previousGlobalCount: 0, currentGlobalCount: 1,
                  elapsedSecondsSinceLast: 9999, terminalFrontmost: true),
              "terminal frontmost → user sees overlay, no notification")

        check("shouldSend-sameCountSuppressed",
              !shouldSendAlertNotification(
                  previousGlobalCount: 2, currentGlobalCount: 2,
                  elapsedSecondsSinceLast: 9999, terminalFrontmost: false),
              "count didn't change (re-assert on alerted pane) → no notification")

        // Dismissal-then-new-alert: this is the real-world regression
        // that previously left users silent. Scenario: user had N alerts,
        // we posted (stored previous=N), user dismissed everything
        // (dismissal itself fires no event), then a new pane becomes
        // ready (current=1). `current < previous` but this IS news to
        // the user — they explicitly worked through everything and now
        // there's a fresh thing.
        check("shouldSend-decreasedStillPosts",
              shouldSendAlertNotification(
                  previousGlobalCount: 3, currentGlobalCount: 2,
                  elapsedSecondsSinceLast: 9999, terminalFrontmost: false),
              "count differs from last posted (even if smaller) → notify; " +
              "this is the post-dismissal fresh-alert case that used to stay silent")
        check("shouldSend-afterFullDismissalAndNewAlert",
              shouldSendAlertNotification(
                  previousGlobalCount: 5, currentGlobalCount: 1,
                  elapsedSecondsSinceLast: 9999, terminalFrontmost: false),
              "user dismissed everything (count was 5, now fresh 1) → notify")

        check("shouldSend-zeroSuppressed",
              !shouldSendAlertNotification(
                  previousGlobalCount: 3, currentGlobalCount: 0,
                  elapsedSecondsSinceLast: 9999, terminalFrontmost: false),
              "nothing waiting → no notification even if different from last posted")

        check("shouldSend-debounceActive",
              !shouldSendAlertNotification(
                  previousGlobalCount: 0, currentGlobalCount: 1,
                  elapsedSecondsSinceLast: 15, terminalFrontmost: false),
              "within 30s of previous post → debounced")

        check("shouldSend-debounceBoundary",
              shouldSendAlertNotification(
                  previousGlobalCount: 0, currentGlobalCount: 1,
                  elapsedSecondsSinceLast: 30, terminalFrontmost: false),
              "exactly 30s → just allowed (>= 30)")

        check("shouldSend-countJumpAfterDebounce",
              shouldSendAlertNotification(
                  previousGlobalCount: 1, currentGlobalCount: 3,
                  elapsedSecondsSinceLast: 45, terminalFrontmost: false),
              "count jumped by 2 after debounce window → notify")

        // --- routeNotificationClick ---

        check("route-validSessionExists",
              routeNotificationClick(
                  userInfo: ["session": "work", "pane": "2"],
                  managedSessions: ["work", "home"])
              == .switchToSessionPane(session: "work", pane: 2))

        check("route-sessionGoneFallsBackToManaged",
              routeNotificationClick(
                  userInfo: ["session": "gone", "pane": "0"],
                  managedSessions: ["home"])
              == .switchToManaged(session: "home"))

        check("route-noSessionsBringsForeground",
              routeNotificationClick(
                  userInfo: ["session": "gone", "pane": "0"],
                  managedSessions: [])
              == .bringAppForeground)

        check("route-missingSessionNoop",
              routeNotificationClick(
                  userInfo: ["pane": "0"],
                  managedSessions: ["work"])
              == .noop,
              "malformed userInfo should not panic the click handler")

        check("route-missingPaneNoop",
              routeNotificationClick(
                  userInfo: ["session": "work"],
                  managedSessions: ["work"])
              == .noop)

        check("route-nonIntegerPaneNoop",
              routeNotificationClick(
                  userInfo: ["session": "work", "pane": "abc"],
                  managedSessions: ["work"])
              == .noop)

        // --- RecordingNotificationPoster ---

        let poster = RecordingNotificationPoster()
        check("recorder-emptyAtStart", poster.posted.isEmpty)
        poster.post(AlertNotificationPayload(
            title: "amux", body: "2 agents are ready for you",
            session: "space-a", pane: 0))
        poster.post(AlertNotificationPayload(
            title: "amux", body: "3 agents are ready for you",
            session: "space-b", pane: 1))
        check("recorder-recordsCount", poster.posted.count == 2)
        check("recorder-preservesOrder",
              poster.posted[0].session == "space-a"
              && poster.posted[1].session == "space-b")
        check("recorder-preservesPayload",
              poster.posted[1].body == "3 agents are ready for you"
              && poster.posted[1].pane == 1)

        // --- applyAlertState (amux-cli path) ---

        // Helper: build a FakeTmux with N managed sessions, `panes` panes each.
        func setupFake(_ sessions: [(name: String, panes: Int)]) -> FakeTmux {
            let fake = FakeTmux()
            for s in sessions {
                fake.addSession(s.name, panes: s.panes)
                Tmux.executor = fake
                Tmux.markAsManaged(s.name)
            }
            Tmux.executor = fake
            return fake
        }

        // Fresh session + single call: flag set, per-session count = 1.
        do {
            let fake = setupFake([("s", 3)])
            try! applyAlertState(session: "s", pane: 1)
            check("apply-setsAlertFlag",
                  (try? Tmux.getAlert("s", paneIndex: 1)) == true,
                  "applyAlertState should flip @amux-alert on the target pane")
            check("apply-otherPanesUntouched",
                  (try? Tmux.getAlert("s", paneIndex: 0)) != true
                  && (try? Tmux.getAlert("s", paneIndex: 2)) != true,
                  "applyAlertState must only touch the target pane")
            check("apply-sessionCountFromTmux",
                  sessionOptionValue(fake, session: "s", key: "@amux-alert-count") == "1",
                  "session count must be recomputed from alertStates, not hard-coded")
        }

        // Idempotent: calling twice on the same pane does not double-count.
        do {
            let fake = setupFake([("s", 3)])
            try! applyAlertState(session: "s", pane: 1)
            try! applyAlertState(session: "s", pane: 1)
            check("apply-idempotentFlag",
                  (try? Tmux.getAlert("s", paneIndex: 1)) == true)
            check("apply-idempotentCountIs1",
                  sessionOptionValue(fake, session: "s", key: "@amux-alert-count") == "1",
                  "second apply on an already-alerted pane must not grow the count to 2")
        }

        // Two different panes in the same session accumulate.
        do {
            let fake = setupFake([("s", 3)])
            // Park the active pane on a third index so neither alert
            // target hits the "skip if active" rule (spec, Alert-flow
            // step 4).
            fake.sessions["s"]?.windows.first?.activePaneIndex = 1
            try! applyAlertState(session: "s", pane: 0)
            try! applyAlertState(session: "s", pane: 2)
            check("apply-twoPanesCount",
                  sessionOptionValue(fake, session: "s", key: "@amux-alert-count") == "2",
                  "distinct panes should sum into the session count")
        }

        // Spec, Alert-flow step 4: a bell on the active pane must NOT
        // set the alert flag. The user is parked on it; setting the
        // flag with no focus event to clear it would leave a stale
        // alert that inflates `@amux-alert-count` and produces phantom
        // count notifications later.
        do {
            let fake = setupFake([("s", 3)])
            fake.sessions["s"]?.windows.first?.activePaneIndex = 2
            try! applyAlertState(session: "s", pane: 2)
            check("apply-skipsActivePaneFlag",
                  (try? Tmux.getAlert("s", paneIndex: 2)) != true,
                  "alert on active pane must be skipped per spec — " +
                  "got @amux-alert=\((try? Tmux.getAlert("s", paneIndex: 2)) ?? false)")
            check("apply-skipsActivePaneCount",
                  sessionOptionValue(fake, session: "s", key: "@amux-alert-count") == ""
                  || sessionOptionValue(fake, session: "s", key: "@amux-alert-count") == "0",
                  "skipping the flag must NOT bump the session count — " +
                  "got '\(sessionOptionValue(fake, session: "s", key: "@amux-alert-count"))'")
        }

        // Companion to the above: a bell on a non-active pane in the
        // same window does set the flag normally. Guards against an
        // overzealous skip rule (e.g. checking the wrong session).
        do {
            let fake = setupFake([("s", 3)])
            fake.sessions["s"]?.windows.first?.activePaneIndex = 2
            try! applyAlertState(session: "s", pane: 1)
            check("apply-setsNonActivePaneFlag",
                  (try? Tmux.getAlert("s", paneIndex: 1)) == true,
                  "alert on a non-active pane must still be set; only the " +
                  "active pane is skipped")
        }

        // --- processAlertTrigger (amux-app path) ---

        // Cross-session count is what gets notified (bug 2 fix).
        do {
            let fake = setupFake([("alpha", 2), ("beta", 2)])
            // Park each session's active pane on a non-target index so
            // neither alert hits the "skip if active" rule. (Each session
            // tracks its own activePaneIndex; default is 0 in FakeTmux.)
            fake.sessions["alpha"]?.windows.first?.activePaneIndex = 0
            fake.sessions["beta"]?.windows.first?.activePaneIndex = 1
            // Simulate the CLI having already applied state for beta/0
            // (pre-existing alert) and alpha/1 (the newly-triggered pane).
            try! applyAlertState(session: "beta", pane: 0)
            try! applyAlertState(session: "alpha", pane: 1)

            let poster = RecordingNotificationPoster()
            try! processAlertTrigger(
                AlertEvent(session: "alpha", pane: 1, terminalFrontmost: false),
                nowSeconds: 1000,
                poster: poster)

            check("trigger-postedOnce", poster.posted.count == 1,
                  "one alert event → one notification")
            check("trigger-bodyGlobal",
                  poster.posted.first?.body == "2 agents are ready for you",
                  "body must use global count (2 across two sessions), not per-session — got '\(poster.posted.first?.body ?? "nil")'")
            check("trigger-userInfoTriggerSession",
                  poster.posted.first?.session == "alpha")
            check("trigger-userInfoTriggerPane",
                  poster.posted.first?.pane == 1)
        }

        // Frontmost + active pane = no post (user already looking).
        // applyAlertState still runs (it's the CLI side); the trigger
        // just chooses not to post.
        do {
            let fake = setupFake([("s", 2)])
            fake.sessions["s"]?.windows.first?.activePaneIndex = 0
            try! applyAlertState(session: "s", pane: 0)
            let poster = RecordingNotificationPoster()
            try! processAlertTrigger(
                AlertEvent(session: "s", pane: 0, terminalFrontmost: true),
                nowSeconds: 1000,
                poster: poster)
            check("trigger-frontmostActiveNoPost",
                  poster.posted.isEmpty,
                  "frontmost + active pane → suppress the notification")
        }

        // Frontmost + non-active pane: also suppressed.
        do {
            let fake = setupFake([("s", 2)])
            fake.sessions["s"]?.windows.first?.activePaneIndex = 0
            try! applyAlertState(session: "s", pane: 1)
            let poster = RecordingNotificationPoster()
            try! processAlertTrigger(
                AlertEvent(session: "s", pane: 1, terminalFrontmost: true),
                nowSeconds: 1000,
                poster: poster)
            check("trigger-frontmostOtherNoPost",
                  poster.posted.isEmpty,
                  "frontmost → no macOS notification regardless of which pane")
        }

        // Two triggers 15s apart → debounced to one.
        do {
            let _ = setupFake([("s", 3)])
            let poster = RecordingNotificationPoster()

            try! applyAlertState(session: "s", pane: 1)
            try! processAlertTrigger(
                AlertEvent(session: "s", pane: 1, terminalFrontmost: false),
                nowSeconds: 1000,
                poster: poster)

            try! applyAlertState(session: "s", pane: 2)
            try! processAlertTrigger(
                AlertEvent(session: "s", pane: 2, terminalFrontmost: false),
                nowSeconds: 1015,
                poster: poster)

            check("trigger-debounceWithinWindow",
                  poster.posted.count == 1,
                  "two triggers 15s apart → one notification (debounce)")
        }

        // After 30s AND count increased → post again.
        do {
            let _ = setupFake([("s", 3)])
            let poster = RecordingNotificationPoster()

            try! applyAlertState(session: "s", pane: 1)
            try! processAlertTrigger(
                AlertEvent(session: "s", pane: 1, terminalFrontmost: false),
                nowSeconds: 1000,
                poster: poster)

            try! applyAlertState(session: "s", pane: 2)
            try! processAlertTrigger(
                AlertEvent(session: "s", pane: 2, terminalFrontmost: false),
                nowSeconds: 1031,
                poster: poster)

            check("trigger-postsAfterDebounceAndIncrease",
                  poster.posted.count == 2
                  && poster.posted[1].body == "2 agents are ready for you",
                  "after 31s AND count increased to 2 → post; got \(poster.posted.count) posts, last body '\(poster.posted.last?.body ?? "nil")'")
        }

        // Re-trigger on already-alerted pane: no re-post even past debounce,
        // because applyAlertState is idempotent so the global count never
        // moved past what was last notified.
        do {
            let _ = setupFake([("s", 2)])
            let poster = RecordingNotificationPoster()

            try! applyAlertState(session: "s", pane: 1)
            try! processAlertTrigger(
                AlertEvent(session: "s", pane: 1, terminalFrontmost: false),
                nowSeconds: 1000,
                poster: poster)

            // Apply again (idempotent no-op) and trigger well past the
            // 30s debounce. Should not fire a second notification because
            // the global count didn't grow.
            try! applyAlertState(session: "s", pane: 1)
            try! processAlertTrigger(
                AlertEvent(session: "s", pane: 1, terminalFrontmost: false),
                nowSeconds: 5000,
                poster: poster)

            check("trigger-idempotentNoRepost",
                  poster.posted.count == 1,
                  "re-trigger on same already-alerted pane → still one notification even past debounce")
        }

        // Reset executor for later suites that expect LiveTmux.
        Tmux.executor = LiveTmux()

        print("AlertNotification tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("AlertNotification tests failed") }
    }

    /// Read a session option from a FakeTmux (test helper).
    private static func sessionOptionValue(
        _ fake: FakeTmux, session: String, key: String
    ) -> String {
        (try? fake.execute(["show-options", "-t", session, "-v", key])) ?? ""
    }
}
#endif
