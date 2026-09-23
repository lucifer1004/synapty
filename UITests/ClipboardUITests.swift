import AppKit
import XCTest

/// COPY AND PASTE IN THE WORKBENCH'S OWN TEXT FIELDS.
///
/// Reported against the host editor; asserted here in the quick-connect
/// palette, which is the same shape — a SwiftUI `TextField` in workbench
/// chrome, resolving as [[RFC-0016]] C-DISPATCH row 4. If the chord is
/// being taken before the field sees it, the taker is not in either view.
final class ClipboardUITests: UITestCase {

    func testCopyAndPasteWorkInAWorkbenchTextField() {
        launch()
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["Search hosts, or type user@host:port"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the palette never opened")

        field.click()

        // ASKED OF THE SYSTEM PASTEBOARD AND OF THE FIELD SEPARATELY, so
        // a broken copy cannot make a broken paste look like it worked.
        NSPasteboard.general.clearContents()
        app.typeText("copyme")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.4)
        // AND WHAT THE FIELD HOLDS, IN THE MESSAGE RATHER THAN IN A
        // SECOND ASSERTION BEFORE THE COPY.
        //
        // THIS SUITE DRIVES THE REAL KEYBOARD, so a keystroke from
        // anywhere on this machine lands in the application under test.
        // Measured on a failing run, with the dispatcher traced: three
        // plain characters arrived BETWEEN the select-all and the copy —
        // `x`, `i`, `a`, none of them sent from here. Typing replaces a
        // selection, so by the time the copy chord arrived there was
        // nothing selected, and `copy:` correctly copied nothing. The
        // dispatcher's own trace was identical to a passing run's: the
        // chord resolved to the responder chain, the field editor was
        // found, and the platform verb reported success.
        //
        // Reading the field HERE and not before the copy is deliberate:
        // a read between the two chords inserts a delay, and a delay is
        // the one thing that would hide a real race if there is one. So
        // the happy path is untouched, and a contaminated run explains
        // itself instead of blaming the product ([[WI-2026-09-08-010]]).
        let after = field.value as? String ?? "<nothing>"
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "copyme",
                       "copy put nothing on the pasteboard. The field now reads "
                       + "'\(after)' — if that is not 'copyme', something outside "
                       + "this test typed into it and destroyed the selection.")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("pasteme", forType: .string)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(field.value as? String, "pasteme",
                       "paste did not reach the field; the terminal took it")

        // PUT THE WINDOW BACK. A palette left open is inherited by
        // whatever runs next, which then fails for a reason that has
        // nothing to do with it.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "the palette stayed open")
    }
}
