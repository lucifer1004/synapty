import XCTest
@testable import Synapty

/// [[PaneFocusPresentation]] — who steps back and which tab wears the
/// accent. The look is a screenshot's job; the decisions are arithmetic.
final class PaneFocusPresentationTests: XCTestCase {

    private let a = UUID(), b = UUID()

    // MARK: - The wash

    func testOneSlotWashesNothing() {
        XCTAssertFalse(PaneFocusPresentation.dims(paneID: a, focusedPaneID: b,
                                                  slotCount: 1, awaitingAttention: false),
                       "with one position there is nothing to tell apart")
    }

    func testTheFocusedPaneIsLeftAlone() {
        XCTAssertFalse(PaneFocusPresentation.dims(paneID: a, focusedPaneID: a,
                                                  slotCount: 2, awaitingAttention: false))
    }

    func testTheOthersStepBack() {
        XCTAssertTrue(PaneFocusPresentation.dims(paneID: b, focusedPaneID: a,
                                                 slotCount: 2, awaitingAttention: false))
    }

    /// No focused pane at all (the window has just split, or focus is in
    /// the sidebar) still washes: every pane is "not the focused one".
    func testNoFocusWashesEveryPane() {
        XCTAssertTrue(PaneFocusPresentation.dims(paneID: b, focusedPaneID: nil,
                                                 slotCount: 3, awaitingAttention: false))
    }

    /// A PANE THAT WANTS THE HUMAN MUST NOT RECEDE — the wash is exactly
    /// what would hide the one thing they should look at.
    func testAttentionExemptsAPaneFromTheWash() {
        XCTAssertFalse(PaneFocusPresentation.dims(paneID: b, focusedPaneID: a,
                                                  slotCount: 2, awaitingAttention: true))
    }

    /// Under ghostty's own default (0.3) — the other panes are being
    /// watched — and above the level where nothing visibly happened
    /// (0.12, measured).
    func testTheWashIsLighterThanGhosttysAndStillVisible() {
        XCTAssertLessThan(PaneFocusPresentation.dimOpacity, 0.3)
        XCTAssertGreaterThan(PaneFocusPresentation.dimOpacity, 0.12)
    }

    // MARK: - The accent tab

    func testOnlyTheFocusedSlotsActiveTabWearsTheAccent() {
        XCTAssertTrue(PaneFocusPresentation.tabWearsAccent(isActive: true, inFocusedSlot: true))
        XCTAssertFalse(PaneFocusPresentation.tabWearsAccent(isActive: true, inFocusedSlot: false),
                       "another slot's front tab keeps the neutral pill")
        XCTAssertFalse(PaneFocusPresentation.tabWearsAccent(isActive: false, inFocusedSlot: true),
                       "a stacked tab in the focused slot is not the one with the keyboard")
    }

    // MARK: - The wash's color comes from the theme

    /// A theme nobody can read gives no background, and the wash falls
    /// back rather than smearing a stale color from the previous theme.
    func testAMissingThemeGivesNoBackground() {
        ChromeTint.reload(lightTheme: "No Such Theme 9Z", darkTheme: "No Such Theme 9Z")
        XCTAssertNil(ChromeTint.terminalBackground(for: NSAppearance(named: .aqua)!))
        XCTAssertNil(ChromeTint.terminalBackground(for: NSAppearance(named: .darkAqua)!))
    }

    /// The fallback is what an unthemed terminal actually shows: dark, in
    /// either appearance.
    func testTheFallbackIsGhosttysOwnBackground() {
        let rgb = ChromeTint.ghosttyDefaultBackground.usingColorSpace(.deviceRGB)!
        XCTAssertLessThan(rgb.brightnessComponent, 0.3)
    }

    /// A program's OSC 11 is what is actually on screen, and the wash over
    /// the neighbours of that pane should be made of it.
    func testAFollowedBackgroundIsTheWashForItsAppearance() throws {
        ChromeTint.reload(lightTheme: nil, darkTheme: nil)
        let blue = try XCTUnwrap(ChromeTint.color(fromHex: "#1a1a5e"))
        ChromeTint.follow(background: blue)
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let current = NSAppearance(named: isDark ? .darkAqua : .aqua)!
        let other = NSAppearance(named: isDark ? .aqua : .darkAqua)!
        XCTAssertEqual(ChromeTint.terminalBackground(for: current), blue)
        XCTAssertNil(ChromeTint.terminalBackground(for: other),
                     "the other appearance has no theme loaded and no followed color")
        ChromeTint.reload(lightTheme: nil, darkTheme: nil)
    }
}
