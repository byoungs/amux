// UNNotificationPoster.swift — live NotificationPoster backed by
// UNUserNotificationCenter. This is the piece that fixes bug (1): by
// posting here (from the bundled amux-app process), macOS routes
// clicks to our UNUserNotificationCenterDelegate rather than to
// AppleScript / Script Editor like osascript did.
//
// All failure paths surface to stderr rather than silently dropping.
// This matters because the previous regression ("I don't get any
// notifications now") had exactly zero diagnostics — the real cause
// (raw Mach-O launch, no bundle identifier) was invisible.

import AmuxLib
import Foundation
import UserNotifications

public final class UNNotificationPoster: NotificationPoster {
    public init() {
        // UNUserNotificationCenter requires Bundle.main.bundleIdentifier.
        // When the app is launched as a raw Mach-O (`swift run amux-app`
        // or the debug binary directly from .build/), that returns nil
        // and every UN call silently no-ops. Surface it so the failure
        // mode is visible instead of invisible.
        if Bundle.main.bundleIdentifier == nil {
            fputs(
                "amux: WARNING: running without a bundle identifier; " +
                "macOS system notifications are disabled. " +
                "Launch via the .app bundle (see `make dev`).\n",
                stderr)
        }
    }

    public func post(_ payload: AlertNotificationPayload) {
        // Log the attempt synchronously BEFORE the async UN call. Gives
        // tests (and users watching Console.app or stderr) a single
        // grep anchor for "did the app try to post a notification for
        // this event?", which is separate from "did the OS deliver it."
        fputs(
            "amux: posting notification: body=\"\(payload.body)\" " +
            "session=\"\(payload.session)\" pane=\(payload.pane)\n",
            stderr)

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.userInfo = payload.userInfo
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                fputs("amux: notification post failed: \(error)\n", stderr)
            }
        }
    }

    /// Ask the user (once, OS-prompt) for permission to post alerts.
    /// Safe to call on every launch — the OS caches the decision.
    public func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error = error {
                fputs("amux: notification authorization error: \(error)\n", stderr)
            } else if !granted {
                fputs(
                    "amux: notification permission denied — system alerts disabled. " +
                    "Enable in System Settings → Notifications → amux.\n",
                    stderr)
            }
        }
    }
}
