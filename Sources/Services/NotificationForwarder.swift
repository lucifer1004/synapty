import AppKit
import UserNotifications
import os

/// Forwards OSC desktop notifications (ghostty's DESKTOP_NOTIFICATION
/// action — OSC 777/9/99) to Notification Center when the app is NOT
/// active, so a harness ping reaches the human who is in another app
/// (WI-2026-08-11-008). The in-app attention badge behavior is
/// unchanged; the bell (no payload) stays badge-only.
///
/// Authorization is requested provisionally on first use: quiet
/// delivery to Notification Center, no modal permission prompt.
/// Tapping a notification activates the app (default macOS behavior —
/// no delegate needed for V1).
enum NotificationForwarder {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "synapty", category: "notify")
    private static var authRequested = false

    /// Pure decision: forward only when the human is elsewhere AND the
    /// event actually carries a payload (bell does not).
    static func shouldForward(appActive: Bool, hasPayload: Bool) -> Bool {
        !appActive && hasPayload
    }

    // ------------------------------------------------------------------
    // Two shapes: EVENTS and STATES
    //
    // An OSC ping is an EVENT — it happened, at a moment, and "was the
    // human here when it happened" is a sensible question about it. That
    // is what shouldForward asks, and a random identifier is right
    // because there is nothing to replace or take back.
    //
    // A failure is a STATE. It is entered and later left. Asking whether
    // the human was present at the instant it began is the wrong
    // question, and a random identifier is actively harmful: a peer that
    // returns thirty seconds later leaves "remotehost stopped responding"
    // sitting in Notification Center as a lie. So state notifications are
    // keyed by SUBJECT — posting again replaces, and recovery withdraws.
    // ------------------------------------------------------------------

    /// Post a FAILURE STATE, keyed by its subject.
    ///
    /// Not gated on app-active, deliberately: authorization is
    /// provisional, so delivery is quiet, and a state should reflect the
    /// state rather than where the human happened to be standing when it
    /// began. Gating would also leave a hole — frontmost but on another
    /// page — which is exactly the case a chip alone does not cover.
    ///
    /// The in-app mark is the durable record and this is a retractable
    /// nudge; the two are not alternatives, because a withdrawn
    /// notification must leave something behind or a human who was away
    /// when it cleared learns that nothing ever happened.
    static func postFailure(id: String, title: String, body: String) {
        ensureAuthorized()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // NOT .timeSensitive: that needs an entitlement and is for
        // genuinely critical things. A machine being unreachable is not
        // one, and spending a Focus-mode override on it is how an app
        // teaches people to turn its notifications off.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
        log.error("failure notified id=\(id, privacy: .public)")
    }

    /// The state ended. Take the notification back.
    static func clearFailure(id: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Stable identifier for a peer that stopped answering.
    static func peerFailureID(_ peerID: String) -> String { "peer-failed-\(peerID)" }

    private static func ensureAuthorized() {
        guard !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    /// Post to Notification Center. Call on the main queue.
    static func forward(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        ensureAuthorized()
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Synapty" : title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
        log.debug("forwarded OSC notification title=\(title, privacy: .private) bodyLen=\(body.count, privacy: .public)")
    }
}
