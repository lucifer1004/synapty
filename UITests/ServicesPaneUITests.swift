import XCTest

/// THE SERVICES LEAF ON THIS MAC ([[WI-2026-08-19-001]]).
///
/// It rendered "Pick a host. Choose one above." — copy left over from the
/// panel that held this view before it became a pane, naming a picker that
/// was deleted with it. So the most reachable instance of this leaf was a
/// dead end pointing at a control that does not exist, and no test could
/// see it: the model was right, the branch was wrong.
final class ServicesPaneUITests: UITestCase {

    func testTheLocalServicesPaneNamesThisMacAndOffersNothingForbidden() {
        launch(["--pane", "services"])

        // Named by what this leaf says when nothing is exposed on it.
        let empty = app.staticTexts["Nothing exposed on this Mac"]
        XCTAssertTrue(empty.waitForExistence(timeout: 20),
                      "the local services pane did not render as a machine of its own")
        photograph("services-local")

        // [[RFC-0015]] C-CONTENT: what this Mac merely listens on MUST NOT
        // be enumerated at all, so the control that would do it is absent
        // — not merely disabled, which reads as "not yet".
        XCTAssertFalse(app.buttons["Look for listening ports"].exists,
                       "the local pane offers an action C-CONTENT forbids")

        // And the copy names no control that does not exist.
        XCTAssertFalse(app.staticTexts["Pick a host"].exists)
    }
}
