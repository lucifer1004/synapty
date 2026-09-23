import XCTest
@testable import Synapty

/// WI-2026-08-11-008: OSC notification forwarding decision logic.
/// (The UNUserNotificationCenter side is system-integration, verified
/// live; only the pure gate is unit-testable.)
final class NotificationForwarderTests: XCTestCase {

    func testForwardsOnlyWhenInactiveWithPayload() {
        // Human elsewhere + payload → forward.
        XCTAssertTrue(NotificationForwarder.shouldForward(appActive: false, hasPayload: true))
        // App active → the badge is enough; no system notification.
        XCTAssertFalse(NotificationForwarder.shouldForward(appActive: true, hasPayload: true))
        // Bell has no payload → badge-only regardless of focus.
        XCTAssertFalse(NotificationForwarder.shouldForward(appActive: false, hasPayload: false))
        XCTAssertFalse(NotificationForwarder.shouldForward(appActive: true, hasPayload: false))
    }
}
