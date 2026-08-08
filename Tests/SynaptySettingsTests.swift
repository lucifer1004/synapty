import XCTest
@testable import Synapty

/// Persistence round-trip tests for SynaptySettings, isolated from the
/// developer's real ~/.config/synapty via the storageOverride seam
/// (WI-2026-08-08-020, WI-2026-08-08-022).
@MainActor
final class SynaptySettingsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try setUpSettingsStorage()
    }

    override func tearDownWithError() throws {
        restoreStorageOverrides(tempDir)
    }

    func testSaveThenLoadRoundTrip() throws {
        let settings = SynaptySettings()
        settings.lightThemeName = "GitHub"
        settings.darkThemeName = "Black Metal (Burzum)"
        settings.fontFamily = "Maple Mono NF CN"
        settings.fontFallbackFamilies = ["JetBrains Mono"]
        settings.fontSize = 13
        settings.scrollbackLimit = 5000
        settings.copyOnSelect = true
        settings.clipboardRead = true
        settings.clipboardWrite = false
        settings.hubPort = 9000
        settings.tunnelPort = 9001

        let reloaded = SynaptySettings()
        XCTAssertEqual(reloaded.lightThemeName, "GitHub")
        XCTAssertEqual(reloaded.darkThemeName, "Black Metal (Burzum)")
        XCTAssertEqual(reloaded.fontFamily, "Maple Mono NF CN")
        XCTAssertEqual(reloaded.fontFallbackFamilies, ["JetBrains Mono"])
        XCTAssertEqual(reloaded.fontSize, 13)
        XCTAssertEqual(reloaded.scrollbackLimit, 5000)
        XCTAssertEqual(reloaded.copyOnSelect, true)
        XCTAssertEqual(reloaded.clipboardRead, true)
        XCTAssertEqual(reloaded.clipboardWrite, false)
        XCTAssertEqual(reloaded.hubPort, 9000)
        XCTAssertEqual(reloaded.tunnelPort, 9001)

        // Keep the host app's appearance untouched by the test.
        settings.appearanceMode = .system
    }

    func testDefaultsWhenNoFile() {
        let settings = SynaptySettings()
        XCTAssertNil(settings.lightThemeName)
        XCTAssertNil(settings.fontFamily)
        XCTAssertEqual(settings.hubPort, 9000)
        XCTAssertEqual(settings.tunnelPort, 9000)
        XCTAssertEqual(settings.fontFallbackFamilies, [])
    }

    func testLegacyThemeNameMigration() throws {
        // Legacy settings.json carried a single themeName (pre-2026-08-06).
        let json = #"{"themeName":"GitHub"}"#
        try json.write(to: tempDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let settings = SynaptySettings()
        XCTAssertEqual(settings.lightThemeName, "GitHub")
        XCTAssertEqual(settings.darkThemeName, "GitHub")
    }

    func testGhosttyFragmentContent() throws {
        let settings = SynaptySettings()
        settings.lightThemeName = "GitHub"
        settings.darkThemeName = "Black Metal (Burzum)"
        settings.fontFamily = "Maple Mono NF CN"
        settings.fontSize = 13

        let fragment = try String(contentsOf: tempDir.appendingPathComponent("ghostty.conf"), encoding: .utf8)
        // font-family is repeatable — the clear must come before the set so
        // the user's own ghostty config cannot win (WI-2026-08-06-003).
        let clearIndex = fragment.range(of: "font-family = \"\"")?.lowerBound
        let setIndex = fragment.range(of: "font-family = Maple Mono NF CN")?.lowerBound
        XCTAssertNotNil(clearIndex)
        XCTAssertNotNil(setIndex)
        XCTAssertLessThan(clearIndex!, setIndex!)
        // Theme pair resolves through ghostty's light/dark conditionals.
        XCTAssertTrue(fragment.contains("theme = light:GitHub,dark:Black Metal (Burzum)"))
        XCTAssertTrue(fragment.contains("font-size = 13"))
        // The scrollback bound is always present.
        XCTAssertTrue(fragment.contains("scrollback-limit-lines = 10000"))
    }

    func testThemeLineForms() {
        XCTAssertEqual(SynaptySettings.themeLine(light: "A", dark: "B"), "theme = light:A,dark:B")
        XCTAssertEqual(SynaptySettings.themeLine(light: "A", dark: nil), "theme = A")
        XCTAssertEqual(SynaptySettings.themeLine(light: nil, dark: "B"), "theme = B")
        XCTAssertNil(SynaptySettings.themeLine(light: nil, dark: nil))
        XCTAssertNil(SynaptySettings.themeLine(light: " ", dark: ""))
    }
}
