import XCTest
@testable import Synapty

/// The tooltip carries the chord for the eye; the spoken label leaves it
/// out, because VoiceOver reads "(⌘C)" as punctuation
/// ([[WI-2026-09-02-026]]).
final class DSIconButtonLabelTests: XCTestCase {

    func testAChordInParenthesesIsNotSpoken() {
        XCTAssertEqual(DSIconButton.spokenLabel("Copy (⌘C)"), "Copy")
    }

    func testAPlainTooltipIsSpokenAsIs() {
        XCTAssertEqual(DSIconButton.spokenLabel("Refresh tasks"), "Refresh tasks")
    }

    func testAParenthesisMidSentenceIsKept() {
        XCTAssertEqual(DSIconButton.spokenLabel("Open (new) window"), "Open (new) window")
    }

    func testAnAllChordTooltipIsNotEmptied() {
        XCTAssertEqual(DSIconButton.spokenLabel("(⌘K)"), "(⌘K)")
    }
}
