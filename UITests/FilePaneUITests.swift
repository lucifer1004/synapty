import XCTest

/// WHAT ONLY A RUNNING WINDOW CAN ANSWER: did the view follow the model.
///
/// The back button was correct in the manager and did nothing on screen —
/// the view read the leaf's directory once, at `onAppear`, and never again.
/// Every model test passed. That class of defect has now reached the human
/// three times in this application (the reference sheet instantiated
/// nowhere, the find bar likewise, and this), and it is the whole reason
/// this suite exists.
///
/// The rest of what went wrong in this pane is pinned in
/// `FileBrowsingTests`, against a value, where it belongs.
final class FilePaneUITests: UITestCase {

    private var fixture: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synapty-browse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fixture.appendingPathComponent("child"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
        try super.tearDownWithError()
    }

    func testBackMovesThePaneOnScreenAndNotOnlyInTheModel() {
        launch(["--pane", "files"])
        let address = app.textFields["file-pane-path"]
        XCTAssertTrue(address.waitForExistence(timeout: 20), "no file pane appeared")

        go(to: fixture.path, in: address)
        XCTAssertTrue(shows(fixture.path, address), "typing a path did not move the pane")

        let child = fixture.appendingPathComponent("child").path
        go(to: child, in: address)
        XCTAssertTrue(shows(child, address), "the pane did not descend")
        photograph("file-pane-in-child")

        app.buttons["Back"].click()
        XCTAssertTrue(shows(fixture.path, address),
                      "back moved the model and left the address bar where it was")
        photograph("file-pane-after-back")
    }

    /// A DRAFT ENDS AT DEPARTURE — the visible half. Half a path typed and
    /// left there pinned the address bar for good; ended on arrival
    /// instead, it pinned it for as long as the machine took to answer.
    func testAHalfTypedPathDoesNotSurviveANavigation() {
        launch(["--pane", "files"])
        let address = app.textFields["file-pane-path"]
        XCTAssertTrue(address.waitForExistence(timeout: 20))

        // TWO HOPS, because back walks the HISTORY and not the tree — one
        // hop from home would send it back to home, which this test once
        // asserted was the fixture and was right to fail.
        go(to: fixture.path, in: address)
        XCTAssertTrue(shows(fixture.path, address))
        let child = fixture.appendingPathComponent("child").path
        go(to: child, in: address)
        XCTAssertTrue(shows(child, address))

        // Typed, never submitted.
        address.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("/no/such/plac")
        photograph("file-pane-draft")

        app.buttons["Back"].click()
        XCTAssertTrue(shows(fixture.path, address),
                      "the abandoned draft outlived the navigation that left it behind")
        photograph("file-pane-draft-abandoned")
    }

    /// WHAT A ROW IS DRAWN AS, asked of the screen because the whole chain
    /// — listing, `BrowsedFile`, `FileKind`, the icon — only exists to put
    /// a glyph in front of a human ([[WI-2026-08-29-005]]). `FileKindTests`
    /// pins the mapping; this pins that the pane actually uses it.
    func testAListingDrawsWhatEachRowIs() throws {
        let base = fixture.appendingPathComponent("kinds")
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        for leaf in ["README.md", "main.zig", "main.swift", "main.rs", "main.go",
                     "build.sh", "hosts.json", "config.yaml", "shot.png", "clip.mov",
                     "release.zip", "manual.pdf", "Dockerfile", "core.7913"] {
            try Data().write(to: base.appendingPathComponent(leaf))
        }
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("current").path,
                                  withDestinationPath: fixture.appendingPathComponent("child").path)
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("gone.txt").path,
                                  withDestinationPath: "/nowhere/at/all")

        launch(["--pane", "files"])
        let address = app.textFields["file-pane-path"]
        XCTAssertTrue(address.waitForExistence(timeout: 20), "no file pane appeared")
        go(to: base.path, in: address)
        XCTAssertTrue(shows(base.path, address), "typing a path did not move the pane")

        // A ROW IS ONE BUTTON, and its accessibility label is everything
        // the row says — the kind first, then the name.
        for (kind, name) in [("File", "README.md"),
                             ("A link to a folder", "current"),
                             ("A link with nothing on the end of it", "gone.txt")] {
            let row = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", kind, name))
            XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 10),
                          "'\(name)' was not drawn as '\(kind)'")
        }
        photograph("file-pane-row-kinds")
    }

    private func go(to path: String, in address: XCUIElement) {
        address.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(path + "\n")
    }

    /// The address bar is asked repeatedly rather than once: a listing is a
    /// round trip even locally, and a single read would be a race the test
    /// wins or loses by machine speed.
    private func shows(_ path: String, _ address: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let says = expectation(for: NSPredicate(format: "value == %@", path),
                               evaluatedWith: address)
        return XCTWaiter().wait(for: [says], timeout: timeout) == .completed
    }
}
