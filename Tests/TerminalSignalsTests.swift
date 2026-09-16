import XCTest
import AppKit
@testable import Synapty

/// [[TerminalSignals]] — the arithmetic and the mappings behind the core
/// signals that used to be dropped ([[WI-2026-09-02-002]]).
final class TerminalSignalsTests: XCTestCase {

    // MARK: shell-integration

    /// THE WRAPPER HIDES THE SHELL FROM DETECTION, so the value has to be
    /// derived from the human's own $SHELL and written out.
    func testShellIntegrationFollowsTheShellPath() {
        XCTAssertEqual(TerminalSignals.shellIntegrationValue(forShellPath: "/bin/zsh"), "zsh")
        XCTAssertEqual(TerminalSignals.shellIntegrationValue(forShellPath: "/opt/homebrew/bin/fish"), "fish")
        XCTAssertEqual(TerminalSignals.shellIntegrationValue(forShellPath: "/usr/local/bin/bash"), "bash")
    }

    /// A shell ghostty has no integration for leaves the default alone
    /// rather than naming something the core will reject.
    func testUnknownShellsLeaveDetectAlone() {
        XCTAssertNil(TerminalSignals.shellIntegrationValue(forShellPath: "/usr/bin/nu"))
        XCTAssertNil(TerminalSignals.shellIntegrationValue(forShellPath: nil))
        XCTAssertNil(TerminalSignals.shellIntegrationValue(forShellPath: ""))
    }

    // MARK: finished commands

    func testDurationReadsAtAGlance() {
        XCTAssertEqual(TerminalSignals.durationText(0.85), "850ms")
        XCTAssertEqual(TerminalSignals.durationText(4.24), "4.2s")
        XCTAssertEqual(TerminalSignals.durationText(83), "1m 23s")
        XCTAssertEqual(TerminalSignals.durationText(3725), "1h 2m")
    }

    // MARK: split snapping

    func testSnapLandsOnCellBoundaries() {
        XCTAssertEqual(TerminalSignals.snap(103, toCell: 10), 100)
        XCTAssertEqual(TerminalSignals.snap(106, toCell: 10), 110)
        XCTAssertEqual(TerminalSignals.snap(103, toCell: 0), 103, "no cell size = free drag")
    }

    // MARK: pointer

    /// The shapes a terminal actually shows: text, links, the default.
    func testPointerShapes() {
        XCTAssertTrue(TerminalSignals.cursor(for: GHOSTTY_MOUSE_SHAPE_TEXT) === NSCursor.iBeam)
        XCTAssertTrue(TerminalSignals.cursor(for: GHOSTTY_MOUSE_SHAPE_POINTER) === NSCursor.pointingHand)
        XCTAssertTrue(TerminalSignals.cursor(for: GHOSTTY_MOUSE_SHAPE_DEFAULT) === NSCursor.arrow)
        XCTAssertTrue(TerminalSignals.cursor(for: GHOSTTY_MOUSE_SHAPE_WAIT) === NSCursor.arrow,
                      "shapes with no macOS equivalent fall back to the arrow")
    }

    // MARK: live chrome follow

    /// A PROGRAM'S BACKGROUND WINS OVER THE THEME for the appearance it
    /// was set under, and a theme reload clears it.
    func testFollowedBackgroundOverridesTheThemeUntilReload() throws {
        ChromeTint.reload(lightTheme: nil, darkTheme: nil)
        let before = ChromeTint.current(for: NSAppearance(named: .aqua)!)
        XCTAssertEqual(before, ChromeTint.warmLight)

        // Simulate the follow under whatever appearance the test host has.
        let blue = try XCTUnwrap(ChromeTint.color(fromHex: "#22272e"))
        ChromeTint.follow(background: blue)
        let now = NSApp.effectiveAppearance
        XCTAssertEqual(ChromeTint.current(for: now), ChromeTint.tint(fromBackground: blue))

        ChromeTint.reload(lightTheme: nil, darkTheme: nil)
        XCTAssertEqual(ChromeTint.current(for: now),
                       now.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ChromeTint.warmDark : ChromeTint.warmLight,
                       "a reload forgets the program's color")
    }
}

/// [[TabLayout]] — equal-width tabs, decided by count and nothing else.
final class TabLayoutTests: XCTestCase {
    func testShareIsEqualAndAccountsForGaps() {
        // 4 tabs, 3 gaps of 4pt, 612pt available -> 150 each
        XCTAssertEqual(TabLayout.width(available: 612, count: 4, spacing: 4), 150, accuracy: 0.01)
    }
    func testALoneTabDoesNotSprawl() {
        XCTAssertEqual(TabLayout.width(available: 2000, count: 1, spacing: 4), TabLayout.maxWidth)
    }
    func testACrowdDoesNotVanish() {
        XCTAssertEqual(TabLayout.width(available: 300, count: 12, spacing: 4), TabLayout.minWidth)
    }
    func testNoTabsIsNotADivisionByZero() {
        XCTAssertEqual(TabLayout.width(available: 300, count: 0, spacing: 4), TabLayout.minWidth)
    }
}
