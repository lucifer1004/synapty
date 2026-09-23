import XCTest
@testable import Synapty

/// The window is .hiddenTitleBar with fullSizeContentView, so the system
/// never sees a double-click on that strip — the app's content occupies
/// it. Every other Mac app does this, so its absence reads as the window
/// being broken rather than as a feature nobody wrote.
final class TitlebarDoubleClickTests: XCTestCase {

    /// THE ACTION IS THE USER'S, NOT OURS. System Settings offers zoom,
    /// minimise or nothing, and hardcoding zoom overrides an explicit
    /// preference — failing for exactly the people who went and changed
    /// it, which is worse than not implementing this at all.
    func testEachPreferenceMapsToWhatTheHumanAskedFor() {
        XCTAssertEqual(TitlebarAction.kind(from: "Maximize"), .zoom)
        XCTAssertEqual(TitlebarAction.kind(from: "Minimize"), .minimise)
        XCTAssertEqual(TitlebarAction.kind(from: "None"), .none)
    }

    /// An ABSENT key means the macOS default, which is zoom. Reading a
    /// missing value as "do nothing" would silently disable the feature
    /// for everyone who never opened that settings pane — which is most
    /// people.
    func testAMissingPreferenceMeansTheDefaultNotNothing() {
        XCTAssertEqual(TitlebarAction.kind(from: nil), .zoom)
    }

    /// A value we do not recognise is a newer macOS, not a reason to stop
    /// working. Falling back to the default beats falling back to nothing.
    func testAnUnknownValueFallsBackToTheDefault() {
        XCTAssertEqual(TitlebarAction.kind(from: "SomethingApplePutInLater"), .zoom)
    }
}
