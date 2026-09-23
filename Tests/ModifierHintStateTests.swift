import AppKit
import XCTest
@testable import Synapty

/// [[ModifierHintState]] — the badges a held modifier puts on workspace
/// rows, tabs and panes, and the ways they used to fail to come off
/// ([[WI-2026-09-21-001]]).
@MainActor
final class ModifierHintStateTests: XCTestCase {

    /// Poll rather than sleep a fixed amount: the appearance delay is a
    /// timer, and what a test wants to know is whether it has fired.
    private func settle(until: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !until(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Wait past the appearance delay whatever happens, for the cases that
    /// assert nothing appeared.
    private func waitOutTheDelay() {
        let deadline = Date().addingTimeInterval(ModifierHintState.appearanceDelay * 3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - What the modifiers mean

    func testEachTierHasItsOwnExactCombination() {
        XCTAssertEqual(ModifierHintState.level(for: [.command]), .session)
        XCTAssertEqual(ModifierHintState.level(for: [.command, .option]), .tab)
        XCTAssertEqual(ModifierHintState.level(for: [.command, .control]), .pane)
    }

    /// EXACT SETS, NOT `contains`. A badge shown for ⌘⇧ would promise that
    /// ⌘⇧1 goes somewhere, and it does not.
    func testACombinationThisAppDoesNotClaimShowsNothing() {
        XCTAssertNil(ModifierHintState.level(for: []))
        XCTAssertNil(ModifierHintState.level(for: [.command, .shift]))
        XCTAssertNil(ModifierHintState.level(for: [.command, .option, .control]))
        XCTAssertNil(ModifierHintState.level(for: [.option]))
    }

    /// The flags AppKit delivers carry device-dependent bits; a hold is
    /// still a hold.
    func testDeviceDependentBitsDoNotDefeatTheMatch() {
        let noisy: NSEvent.ModifierFlags = [.command, NSEvent.ModifierFlags(rawValue: 0x8)]
        XCTAssertEqual(ModifierHintState.level(for: noisy), .session,
                       "a real flagsChanged carries left/right key bits alongside the mask")
    }

    // MARK: - Holding and letting go

    func testAHeldModifierShowsItsBadgesAfterTheDelay() {
        let state = ModifierHintState()
        state.modifiersChanged(to: [.command])
        XCTAssertNil(state.level, "an ordinary chord must not flash badges")
        settle { state.level != nil }
        XCTAssertEqual(state.level, .session)
    }

    func testLettingGoHidesThemAtOnce() {
        let state = ModifierHintState()
        state.modifiersChanged(to: [.command])
        settle { state.level != nil }
        state.modifiersChanged(to: [])
        XCTAssertNil(state.level, "release is not delayed")
    }

    func testAddingAModifierWhileShowingRetargetsWithoutWaitingAgain() {
        let state = ModifierHintState()
        state.modifiersChanged(to: [.command])
        settle { state.level != nil }
        state.modifiersChanged(to: [.command, .option])
        XCTAssertEqual(state.level, .tab, "the hold already earned its badges")
    }

    // MARK: - Leaving the app ([[WI-2026-09-21-001]])

    /// THE DEFECT. ⌘Tab, ⌘Space, ⌘`, ⌘H — every one of them leaves the app
    /// with ⌘ still down, and the release is delivered to whatever took
    /// over. A local monitor hears none of it, so the numbers stayed on
    /// every workspace row until the human pressed and released ⌘ again
    /// inside the app.
    func testLeavingTheAppWithTheModifierStillDownTakesTheBadgesOff() {
        let state = ModifierHintState()
        state.modifiersChanged(to: [.command])
        settle { state.level != nil }
        XCTAssertEqual(state.level, .session, "precondition: the badges are up")

        state.applicationResignedActive()

        XCTAssertNil(state.level,
                     "the badges survived leaving the app, and nothing that could take "
                     + "them off will be heard again until the human presses ⌘ in here")
    }

    /// AND THE HALF THAT IS NOT VISIBLE YET. A hold that had not reached
    /// its delay would otherwise land its badges after the human had
    /// already gone, with nothing left to take them away.
    func testAHoldInterruptedByLeavingNeverLandsItsBadges() {
        let state = ModifierHintState()
        state.modifiersChanged(to: [.command])
        state.applicationResignedActive()

        waitOutTheDelay()

        XCTAssertNil(state.level, "badges appeared on a window nobody was looking at")
    }

    /// COMING BACK ASKS THE KEYBOARD. Finishing a ⌘Tab is arriving with ⌘
    /// still held, and no flagsChanged describes it — the press was heard
    /// by another app.
    func testReturningStillHoldingTheModifierShowsTheBadgesAgain() {
        let state = ModifierHintState()
        state.modifiersChanged(to: [.command])
        settle { state.level != nil }
        state.applicationResignedActive()

        state.applicationBecameActive(holding: [.command])
        settle { state.level != nil }

        XCTAssertEqual(state.level, .session)
    }

    /// AND THROUGH THE DELAY, NOT AROUND IT: ⌘ comes up within a few dozen
    /// milliseconds at the end of a ⌘Tab, and badges flashing on the way in
    /// are the noise the delay exists to prevent.
    func testReturningDoesNotFlashBadgesOnTheWayIn() {
        let state = ModifierHintState()
        state.applicationBecameActive(holding: [.command])
        XCTAssertNil(state.level, "the badges appeared the instant the app came forward")
    }

    /// AND THE WIRING, NOT ONLY THE RULE. Every test above drives the
    /// methods directly, so all of them stay green if the observer that
    /// calls them is never registered — which is the shape of failure
    /// [[WorkspaceRowRenderingTests]] was written about: a decision that
    /// was right and a channel that had been removed. This posts the
    /// notification AppKit posts.
    func testTheRealDeactivationNotificationIsWhatTakesThemOff() {
        let state = ModifierHintState()
        state.install()
        state.modifiersChanged(to: [.command])
        settle { state.level != nil }
        XCTAssertEqual(state.level, .session, "precondition: the badges are up")

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification, object: NSApp)
        settle { state.level == nil }

        XCTAssertNil(state.level,
                     "the app said it lost the keyboard and nothing was listening")
    }

    func testReturningWithNothingHeldShowsNothing() {
        let state = ModifierHintState()
        state.modifiersChanged(to: [.command])
        settle { state.level != nil }
        state.applicationResignedActive()

        state.applicationBecameActive(holding: [])
        waitOutTheDelay()

        XCTAssertNil(state.level)
    }
}
