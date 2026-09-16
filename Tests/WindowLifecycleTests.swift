import SwiftUI
import XCTest
@testable import Synapty

/// What a scenePhase transition does to the services ([[WI-2026-09-02-032]]).
/// Measured on the real app: Cmd-Tab produces no transition; Cmd-H goes
/// to .background and used to tear every connection and the hub down.
final class WindowLifecycleTests: XCTestCase {

    func testBecomingActiveStartsOnce() {
        XCTAssertEqual(WindowLifecycle.decide(phase: .active, hidden: false, windowAlive: true, running: false), .start)
        XCTAssertEqual(WindowLifecycle.decide(phase: .active, hidden: false, windowAlive: true, running: true), .none,
                       "an unhide must not start the services on top of themselves")
    }

    func testHidingOrMinimisingKeepsTheWorldAlive() {
        XCTAssertEqual(WindowLifecycle.decide(phase: .background, hidden: true, windowAlive: true, running: true), .none)
        XCTAssertEqual(WindowLifecycle.decide(phase: .background, hidden: false, windowAlive: true, running: true), .none)
        XCTAssertEqual(WindowLifecycle.decide(phase: .inactive, hidden: false, windowAlive: true, running: true), .none)
    }

    func testAWindowThatIsGoneStopsTheServices() {
        XCTAssertEqual(WindowLifecycle.decide(phase: .background, hidden: false, windowAlive: false, running: true), .stop)
        XCTAssertEqual(WindowLifecycle.decide(phase: .background, hidden: false, windowAlive: false, running: false), .none,
                       "nothing to stop twice")
    }
}
