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
        let field = app.textFields["Search hosts, or user@host:port to connect"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the palette never opened")

        field.click()

        // ASKED OF THE SYSTEM PASTEBOARD AND OF THE FIELD SEPARATELY, so
        // a broken copy cannot make a broken paste look like it worked.
        NSPasteboard.general.clearContents()
        app.typeText("copyme")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "copyme",
                       "copy put nothing on the pasteboard: the chord went somewhere else")

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
