import XCTest

/// The fourth pane kind, on screen ([[WI-2026-08-19-004]]).
///
/// Two of this WI's criteria are SECURITY criteria, and both are about
/// what a human can see: that the pane is visibly not this application,
/// and that a refused address is refused where they can see it. Neither is
/// checkable from the model — which is the class this suite exists for.
final class BrowserPaneUITests: UITestCase {

    func testABrowserPaneIsMarkedAsAPageAndOpensNothingUntilAddressed() {
        launch(["--pane", "browser"])
        let field = app.textFields["browser-address"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no browser pane appeared")

        // THE POSITIVE MARK: chrome of its own that says what this is,
        // rather than the absence of ours.
        XCTAssertTrue(app.staticTexts["Web page"].exists,
                      "nothing marks the pane as a rendered page")
        XCTAssertTrue(app.staticTexts["Nothing addressed yet"].exists,
                      "a leaf with nothing to show must say what to do")
        photograph("browser-empty")
    }

    /// WHAT IT REFUSES, REFUSED WHERE THE HUMAN CAN SEE IT. A refusal
    /// nobody sees is a feature that silently does nothing.
    func testARefusedAddressSaysSoInThePane() {
        launch(["--pane", "browser"])
        let field = app.textFields["browser-address"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))

        field.click()
        app.typeText("file:///etc/passwd\n")

        let refusal = app.staticTexts["This pane shows web pages, not files on your machine. Open a file pane for those."]
        XCTAssertTrue(refusal.waitForExistence(timeout: 5),
                      "a file: address was refused silently")
        photograph("browser-refusal")
        // AND THE PANE DID NOT MOVE.
        XCTAssertTrue(app.staticTexts["Nothing addressed yet"].exists,
                      "a refused address still changed what the pane was showing")
    }
}
