import XCTest
@testable import Synapty

/// [[ChromeTint]] — the chrome borrows the terminal theme's temperature.
/// The ladder's look is a screenshot's job; what a test can hold is the
/// arithmetic: what gets read out of a theme file, and how much of its
/// color the chrome is allowed to keep.
final class ChromeTintTests: XCTestCase {

    // MARK: - Reading the theme file

    /// The measured pair this feature was built against.
    func testItReadsTheBackgroundLine() throws {
        let dimmed = """
        palette = 0=#545d68
        background = #22272e
        foreground = #adbac7
        """
        let color = try XCTUnwrap(ChromeTint.parseBackground(dimmed))
        XCTAssertEqual(Int(round(color.redComponent * 255)), 0x22)
        XCTAssertEqual(Int(round(color.greenComponent * 255)), 0x27)
        XCTAssertEqual(Int(round(color.blueComponent * 255)), 0x2e)
    }

    /// PALETTE LINES ALSO CONTAIN HEX COLORS, sixteen of them before
    /// `background` appears — a looser match would return palette 0.
    func testPaletteLinesAreNotBackgrounds() {
        XCTAssertNil(ChromeTint.parseBackground("palette = 0=#545d68"))
        XCTAssertNil(ChromeTint.parseBackground("selection-background = #303a49"),
                     "a SUFFIX match would take selection-background")
    }

    func testHexParsing() {
        XCTAssertNotNil(ChromeTint.color(fromHex: "#f4f4f4"))
        XCTAssertNotNil(ChromeTint.color(fromHex: "f4f4f4"), "ghostty allows the bare form")
        XCTAssertNil(ChromeTint.color(fromHex: "#fff"), "shorthand is not in theme files")
        XCTAssertNil(ChromeTint.color(fromHex: "#gggggg"))
    }

    // MARK: - The cast

    /// A NEUTRAL THEME YIELDS NEUTRAL CHROME — GitHub light's gray must
    /// strip the warm cast entirely, because warm paper around a neutral
    /// terminal is the exact collision this exists to remove.
    func testANeutralThemeStripsTheCast() throws {
        let github = try XCTUnwrap(ChromeTint.color(fromHex: "#f4f4f4"))
        XCTAssertEqual(ChromeTint.tint(fromBackground: github).chroma, 0, accuracy: 0.001)
    }

    /// CHROME IS NEVER MORE THAN A CAST: a saturated theme is capped, so
    /// the toolbar cannot come out purple.
    func testASaturatedThemeIsCapped() throws {
        // Dracula-class background: strongly colored.
        let loud = try XCTUnwrap(ChromeTint.color(fromHex: "#1a1a5e"))
        let tint = ChromeTint.tint(fromBackground: loud)
        XCTAssertEqual(tint.chroma, ChromeTint.chromaCap, accuracy: 0.001,
                       "saturation 0.72 must not pass the cap")
    }

    /// GitHub Dark Dimmed lands under the cap and keeps its own hue —
    /// the chrome comes out cool, which is the whole point.
    func testTheMeasuredDarkThemeKeepsItsHue() throws {
        let dimmed = try XCTUnwrap(ChromeTint.color(fromHex: "#22272e"))
        let tint = ChromeTint.tint(fromBackground: dimmed)
        XCTAssertEqual(tint.hue, 0.60, accuracy: 0.02, "blue, not warm")
        XCTAssertLessThan(tint.chroma, ChromeTint.chromaCap)
        XCTAssertGreaterThan(tint.chroma, 0.2)
    }

    /// THE FALLBACK REPRODUCES THE WARM PAPER this replaces: the spend
    /// factors and warm defaults multiply out to the saturations the old
    /// hardcoded palette had, so a host with no theme sees no change.
    func testTheWarmDefaultsReproduceTheOldPaper() {
        XCTAssertEqual(ChromeTint.warmLight.chroma * ChromeTint.lightSpend, 0.0375,
                       accuracy: 0.002, "old light paper sat ≈0.037")
        XCTAssertEqual(ChromeTint.warmDark.chroma * ChromeTint.darkSpend, 0.084,
                       accuracy: 0.002, "old dark chrome sat ≈0.085")
    }

    /// A theme nobody can read answers with the warm defaults rather than
    /// with stale state from the previous theme.
    func testAMissingThemeFallsBackWarm() {
        ChromeTint.reload(lightTheme: "No Such Theme 9Z", darkTheme: nil)
        XCTAssertEqual(ChromeTint.light, ChromeTint.warmLight)
        XCTAssertEqual(ChromeTint.dark, ChromeTint.warmDark)
    }
}
