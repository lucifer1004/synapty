import XCTest
import UserNotifications
@testable import Synapty

/// Does a failure notification ACTUALLY reach Notification Center, and does
/// a recovery ACTUALLY take it back?
///
/// The unit tests around WI-2026-08-13-012 cover the state machine and the
/// copy; they do not touch UNUserNotificationCenter, so the one thing they
/// cannot answer is whether the notification exists. That gap matters more
/// here than usual, because the whole design rests on withdrawal working —
/// a notice that cannot be taken back becomes a lie the moment the peer
/// returns, and nothing in the state machine would notice.
///
/// This drives the real API, in the app host, the way the tmux tests drive
/// real tmux. It posts a notification the human may briefly see (quietly:
/// authorization is `.provisional`) and removes it in the same test.
///
/// OPT-IN, because its timing is not ours. Delivery is scheduled by a
/// system service, and under load — a full suite, a running app, real
/// transfers — it missed a five-second window once and passed on the next
/// run. A flaky test in the pre-commit gate is corrosive in a specific
/// way: it teaches the reader that a red result means "run it again"
/// rather than "look", and the day it goes red for a real reason that
/// lesson is already learned. Widening the window would only move the
/// threshold, and mocking the notification centre would delete the one
/// thing this file exists to check.
///
///     SYNAPTY_TEST_NOTIFICATIONS=1 just test-swift
///
/// [[WI-2026-08-13-012]]
final class NotificationDeliveryTests: XCTestCase {

    private let testID = "peer-failed-synapty-selftest"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SYNAPTY_TEST_NOTIFICATIONS"] == nil,
            "delivery tests are opt-in: SYNAPTY_TEST_NOTIFICATIONS=1")
    }

    override func tearDown() {
        // Belt and braces: whatever the test did, take it back.
        NotificationForwarder.clearFailure(id: testID)
        super.tearDown()
    }

    /// Authorization is provisional, so it is granted without a prompt —
    /// but a human who has since turned Synapty's notifications OFF is a
    /// real state, and this test must say so rather than fail as though
    /// the code were broken.
    private func authorizedOrSkip() throws -> Bool {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }

        var settings: UNNotificationSettings?
        let done = expectation(description: "settings")
        center.getNotificationSettings { s in
            settings = s
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let status = try XCTUnwrap(settings).authorizationStatus
        if status == .denied {
            throw XCTSkip(
                "Notifications are turned off for Synapty on this machine — the code path cannot be exercised here. Not a failure.")
        }
        return true
    }

    private func delivered(contains id: String, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var found = false
            let poll = expectation(description: "delivered")
            UNUserNotificationCenter.current().getDeliveredNotifications { notes in
                found = notes.contains { $0.request.identifier == id }
                poll.fulfill()
            }
            wait(for: [poll], timeout: 5)
            if found { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    func testAFailureIsDeliveredAndARecoveryWithdrawsIt() throws {
        _ = try authorizedOrSkip()

        NotificationForwarder.postFailure(
            id: testID,
            title: "Synapty self-test",
            body: "Verifying delivery. This is removed automatically.")

        XCTAssertTrue(delivered(contains: testID, within: 5),
                      "the failure notification never reached Notification Center")

        NotificationForwarder.clearFailure(id: testID)

        // Withdrawal is the property the whole design rests on: without
        // it, a peer that comes back leaves a notice that is now false.
        let stillThere = delivered(contains: testID, within: 2)
        XCTAssertFalse(stillThere, "a recovery must take the notification back")
    }

    /// Posting the same subject twice must REPLACE, not stack — which is
    /// what the derived identifier buys and a random UUID would not.
    func testARepeatedFailureReplacesRatherThanStacks() throws {
        _ = try authorizedOrSkip()

        for i in 1...3 {
            NotificationForwarder.postFailure(
                id: testID, title: "Synapty self-test",
                body: "Attempt \(i). This is removed automatically.")
        }
        XCTAssertTrue(delivered(contains: testID, within: 5))

        var count = 0
        let poll = expectation(description: "count")
        UNUserNotificationCenter.current().getDeliveredNotifications { notes in
            count = notes.filter { $0.request.identifier == self.testID }.count
            poll.fulfill()
        }
        wait(for: [poll], timeout: 5)
        XCTAssertEqual(count, 1, "three failures for one peer must be one notification, not three")

        NotificationForwarder.clearFailure(id: testID)
    }
}

/// [[AppNotifications]]. The module exists because a drag that worked and
/// a drag that silently did nothing looked identical — so what it must
/// never do is make the one number that means "act" say anything else.
@MainActor
final class AppNotificationsTests: XCTestCase {

    /// A SUCCEEDED DELIVERY MUST NOT RAISE THE BADGE. Approvals and
    /// questions were merged into one count for a stated reason: two
    /// badges make "is anything waiting on me" a question with two
    /// answers. Counting outcomes here would bring that straight back.
    func testOutcomesDoNotCountAsThingsWaitingOnTheHuman() {
        let notifications = AppNotifications()
        notifications.isActive = { true }
        let authority = TransferAuthority()
        let questions = QuestionService()

        XCTAssertEqual(
            AppNotifications.waitingCount(authority: authority, questions: questions), 0)

        notifications.post(.done, "Delivered to remotehost", detail: "probe.txt")
        notifications.post(.failed, "Transfer failed", detail: "probe.txt — refused")

        XCTAssertEqual(
            AppNotifications.waitingCount(authority: authority, questions: questions), 0,
            "an outcome is not something to act on")
    }

    /// Blocking items ARE the count, from both sources.
    func testApprovalsAndQuestionsShareTheOneCount() {
        let authority = TransferAuthority()
        let questions = QuestionService()
        authority.requestApproval(
            pair: .init(from: UUID(), to: nil), agent: "api-7f3c", fileName: "out.tar")
        _ = questions.ask(agent: "api-7f3c", text: "Proceed?", options: ["yes", "no"])

        XCTAssertEqual(
            AppNotifications.waitingCount(authority: authority, questions: questions), 2)
    }

    /// A BURST MUST NOT BECOME A COLUMN taller than the window. Several
    /// transfers finishing together is ordinary, not exceptional.
    func testTheStackIsBounded() {
        let notifications = AppNotifications()
        notifications.isActive = { true }
        for i in 0..<12 {
            notifications.post(.done, "Delivered", detail: "file-\(i)")
        }
        XCTAssertLessThanOrEqual(notifications.visible.count, 4)
        // The NEWEST survive: the oldest have been on screen longest and
        // the newest is the one being read.
        XCTAssertEqual(notifications.visible.last?.detail, "file-11")
    }

    func testDismissingRemovesExactlyOne() throws {
        let notifications = AppNotifications()
        notifications.isActive = { true }
        notifications.post(.done, "A", detail: "a")
        notifications.post(.done, "B", detail: "b")
        let first = try XCTUnwrap(notifications.visible.first)
        notifications.dismiss(first.id)
        XCTAssertEqual(notifications.visible.map(\.title), ["B"])
    }
}
