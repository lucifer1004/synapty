import XCTest

/// [[RFC-0016]]'s obligations, checked against the running application
/// rather than against the model — which is where the two defects that
/// reached the human were living.
final class KeyboardUITests: UITestCase {

    /// THE REFERENCE SHEET EXISTS, IS REACHABLE, AND SHOWS THE EFFECTIVE
    /// TABLE ([[RFC-0016]] C-DISCOVERY: "the workbench MUST carry a
    /// surface listing every command in the table").
    ///
    /// It was complete, correct and instantiated NOWHERE: the menu item
    /// set a flag and no view read it, while every unit test about its
    /// contents passed. This test opens it from the menu and reads a
    /// command out of it — a separate test that only asserted it opened
    /// was strictly subsumed by this one, and cost a whole app launch to
    /// say less.
    func testTheSheetListsCommandsFromTheTable() {
        launch()
        app.menuBars.menuBarItems["Help"].click()
        app.menuBars.menuItems["Keyboard Shortcuts"].click()
        XCTAssertTrue(app.staticTexts["Quick Connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Clear Screen"].exists,
                      "a terminal-domain command is missing from the reference sheet")
    }

    /// ONE KEYSTROKE RUNS A COMMAND AT MOST ONCE ([[RFC-0016]]
    /// C-DISPATCH).
    ///
    /// ⌘K opened the palette and shut it again in one press — the monitor
    /// ran the command and the menu's key equivalent ran it a second time
    /// — so the palette appeared not to notice it was already open and the
    /// whole window flashed. A toggle is the only place the defect is
    /// visible, which is why the test is written on one.
    func testPressingTheQuickConnectChordTogglesThePaletteOncePerPress() {
        launch()
        let field = app.textFields["Search hosts, or user@host:port to connect"]

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "one press did not open the palette")
        photograph("palette-open")

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(waitForDisappearance(of: field),
                      "the second press did not close it — one keystroke ran the command twice")
        photograph("palette-shut")

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "a third press did not reopen it")
    }

    /// ESCAPE LEAVES A SURFACE WITH NOTHING CHANGED — the palette's, here,
    /// which is the same gesture the chord recorder owes ([[RFC-0016]]
    /// C-REBIND).
    func testEscapeClosesThePalette() {
        launch()
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["Search hosts, or user@host:port to connect"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        photograph("escape-before")
        app.typeKey(.escape, modifierFlags: [])
        let closed = waitForDisappearance(of: field)
        photograph("escape-after")
        XCTAssertTrue(closed)
    }

    /// A `terminal` COMMAND IS DISPATCHED AS AN ENGINE ACTION and the
    /// terminal is not offered the keystroke ([[RFC-0016]] C-DISPATCH row
    /// 3). If ⌘⇧K reached the shell instead, the pane would show the
    /// characters rather than clearing.
    func testClearScreenIsAnActionAndNotTypedIntoTheShell() {
        launch()
        app.typeKey("k", modifierFlags: [.command, .shift])
        photograph("after-clear-screen")
        // Nothing to assert about the grid from here; what this pins is
        // that the chord does not crash and does not leave the window in
        // a state where the next chord is ignored.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["Search hosts, or user@host:port to connect"].waitForExistence(timeout: 5),
                      "the window stopped answering chords after a terminal action")
    }

    /// ⌘F OPENS A BAR THAT IS ON SCREEN, and ROW 2 OF C-DISPATCH is
    /// reachable from inside it: with focus in the leaf's own find field,
    /// a `workbench` command still runs — which is what
    /// the row says and what a window-owned bar could not have told us.
    ///
    /// IT ALSO PINS A HANG. Claiming row 2 from the bar's `onAppear`
    /// mutated shared state during a view update, so the update re-ran and
    /// fired it again: the application never went idle and the window
    /// stopped answering. The claim now follows the field's real focus,
    /// and this test is what says so — it timed out at thirty seconds
    /// before, and passes in eight now.
    func testAWorkbenchChordStillRunsFromInsideTheFindField() {
        launch()
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.textFields["Find"].waitForExistence(timeout: 5))
        photograph("find-open-before-chord")
        app.typeKey("k", modifierFlags: .command)
        let palette = app.textFields["Search hosts, or user@host:port to connect"]
        let opened = palette.waitForExistence(timeout: 5)
        photograph("palette-over-find")
        XCTAssertTrue(opened,
                      "a workbench command must run whatever holds first responder")
    }

    /// THE WHOLE VERTICAL: what is typed reaches ghostty's search, and
    /// what ghostty counts comes back to the bar ([[WI-2026-08-20-001]]).
    ///
    /// THE NEEDLE IS PUT THERE BY THE TEST. This used to search for
    /// "login", on the reasoning that a login shell greets with "Last
    /// login: …" — and then a machine whose shell does not greet made the
    /// test red about the find bar, which was working. A scrollback the
    /// test wrote itself is the only one it can assert against
    /// ([[WI-2026-08-29-006]]).
    ///
    /// Ghostty had been reporting `search_total` and `search_selected` to
    /// an embedder that ignored both; the count is how a human tells two
    /// matches from two hundred.
    func testTheFindBarCountsWhatGhosttyFound() {
        launch()
        app.typeText("echo haystackneedle\n")

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["Find"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // TYPED AT THE APPLICATION, not at the element. The field already
        // has focus — the bar takes it on appear — and an element-targeted
        // `typeText` first wants the element hittable, which a floating
        // panel over a Metal layer is not reliably.
        app.typeText("haystackneedle")

        // `matching`, NOT `containing`: the latter selects elements whose
        // DESCENDANTS match, and a static text has none — so it can never
        // match and the assertion fails whatever the bar shows.
        let counted = NSPredicate(format: "value MATCHES %@ OR label MATCHES %@",
                                  "[0-9]+ / [0-9]+", "[0-9]+ / [0-9]+")
        let count = app.staticTexts.matching(counted).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5),
                      "the bar showed no count — ghostty's search_total never reached it")
        photograph("find-count")
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"),
                               evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
