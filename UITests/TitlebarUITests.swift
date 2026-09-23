import XCTest

/// Double-clicking the title-bar strip does what the human told macOS it
/// should ([[WI-2026-09-03-015]]).
///
/// THIS IS A UI TEST BECAUSE THE DEFECT IS A HIT TEST. The catcher is
/// complete, correct and wired every time this breaks; what changes is
/// whether a click can reach it, and no model test can see a layer
/// swallowing an event. It has now broken twice — once behind `DS.chrome`
/// and once behind a panel that runs to the window top — and neither was
/// caught by anything but a human noticing the window would not zoom.
final class TitlebarUITests: UITestCase {

    /// THE PREFERENCE IS FORCED, and it is forced to MINIMISE.
    ///
    /// Zoom looked like the obvious choice and is not observable here: the
    /// window restores a saved frame that already fills the screen, so
    /// `performZoom` has nowhere to go and "the frame did not change"
    /// says nothing about whether the click arrived. Minimise is binary —
    /// the window is on screen or it is not — and it exercises the same
    /// path, because what is under test is whether a double click reaches
    /// [[TitlebarDoubleClickCatcher]] at all, not which action it then
    /// performs. NSUserDefaults reads the command line as its
    /// highest-priority domain, which is how the preference arrives.
    private func launchMinimising(_ extra: [String] = []) {
        launch(["-AppleActionOnDoubleClick", "Minimize"] + extra)
    }

    private func doubleClickStrip(_ window: XCUIElement, dx: CGFloat) {
        window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 10))
            .doubleClick()
    }

    private func expectMinimised(_ window: XCUIElement, _ what: String) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !window.isHittable { return }
            usleep(100_000)
        }
        XCTFail("the window stayed on screen: \(what)")
    }

    func testADoubleClickOnTheStripReachesTheCatcher() {
        launchMinimising()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.isHittable, "the window was not on screen to begin with")
        doubleClickStrip(window, dx: 0.55)
        expectMinimised(window, "a double click mid-strip did nothing")
    }

    /// OVER THE PANEL'S COLUMN. HostContextPanel runs to the window top by
    /// its own comment, and both its inset and its chrome take clicks —
    /// so this is the region a layer would take the click in.
    func testADoubleClickOverThePanelColumnReachesTheCatcher() {
        launchMinimising(["--page", "hosts"])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.isHittable, "the window was not on screen to begin with")
        doubleClickStrip(window, dx: 0.93)
        expectMinimised(window, "a double click over the panel column did nothing")
    }
}
