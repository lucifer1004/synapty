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

    /// SETTINGS THAT ARRIVE BY SYNC REACH THE TERMINAL. The fragment
    /// ghostty reads is derived from settings.json, and a reload from disk
    /// — which is how a synced record is applied — must regenerate it
    /// before ghostty is asked to reload. Measured without this: a fresh
    /// machine held the synced theme pair in memory and ghostty's default
    /// theme on screen ([[WI-2026-09-02-005]]).
    func testASyncedSettingsFileRegeneratesTheFragment() throws {
        let settings = SynaptySettings()
        let fragment = tempDir.appendingPathComponent("ghostty.conf")
        XCTAssertFalse(try String(contentsOf: fragment, encoding: .utf8).contains("theme ="),
                       "nothing configured, no theme line")

        let synced = """
        {"lightThemeName":"GitHub","darkThemeName":"GitHub Dark Dimmed"}
        """
        try synced.write(to: tempDir.appendingPathComponent("settings.json"),
                         atomically: true, encoding: .utf8)
        settings.reloadFromDisk()

        XCTAssertTrue(try String(contentsOf: fragment, encoding: .utf8)
                        .contains("theme = light:GitHub,dark:GitHub Dark Dimmed"))
    }

    /// A machine nobody has configured must not write a settings.json.
    ///
    /// It is not a tidiness point. That file is a sync record, and the
    /// receiving machine's three-way merge cannot tell defaults-nobody-set
    /// from a deliberate edit: every field the defaults omit reads as a
    /// field the human deleted. A second Mac quitting once was enough to
    /// erase the first Mac's font, size, opacity and both themes.
    func testUntouchedDefaultsAreNeverPersisted() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let settings = SynaptySettings()
        settings.flushPersistence()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "a machine with no settings of its own must offer nothing to sync")

        // One real edit and it must persist normally.
        settings.fontSize = 18
        settings.flushPersistence()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        settings.appearanceMode = .system
    }

    /// Applying a record that sync delivered must not write it back.
    ///
    /// `reloadFromDisk` used to load without suppressing the didSets, so
    /// every field it assigned persisted itself and was announced to the
    /// engine as this machine's own change — the machine re-uploaded what
    /// it had just received, carrying its merge base with it.
    func testReloadFromDiskDoesNotWriteBackOrChangeTheFile() throws {
        let file = tempDir.appendingPathComponent("settings.json")
        let settings = SynaptySettings()
        settings.fontSize = 18
        settings.lightThemeName = "GitHub"
        settings.flushPersistence()

        // What a peer's record looks like once merged and written to disk.
        let delivered = Data(#"{"fontSize":11,"lightThemeName":"Solarized","tunnelPort":9000}"#.utf8)
        try delivered.write(to: file, options: .atomic)

        settings.reloadFromDisk()

        XCTAssertEqual(settings.fontSize, 11, "the delivered record must reach memory")
        XCTAssertEqual(settings.lightThemeName, "Solarized")
        XCTAssertEqual(
            try Data(contentsOf: file), delivered,
            "applying a synced record must leave the file exactly as delivered")

        settings.appearanceMode = .system
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
        settings.tunnelPort = 9001
        // Persistence is debounced (500 ms) — flush so the file is on disk
        // before the reloaded instance reads it (WI-2026-08-08-049).
        settings.flushPersistence()

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
        XCTAssertEqual(reloaded.tunnelPort, 9001)

        // Keep the host app's appearance untouched by the test.
        settings.appearanceMode = .system
    }

    func testDefaultsWhenNoFile() {
        let settings = SynaptySettings()
        XCTAssertNil(settings.lightThemeName)
        XCTAssertNil(settings.fontFamily)
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
        // The fragment write is async (off-main); flush drains the serial
        // fragment queue so the file deterministically holds the newest
        // fragment before we read it (WI-2026-08-08-049).
        settings.flushPersistence()

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
        // AND NOTHING TOUCHES GHOSTTY'S OWN URL MATCHING. Addresses are
        // its job; what it resolves is compared against the characters
        // under the pointer before anything opens ([[RFC-0015]]
        // C-DERIVED rule two), which is where that protection lives.
        XCTAssertFalse(fragment.contains("link-url"))
    }

    func testThemeLineForms() {
        XCTAssertEqual(SynaptySettings.themeLine(light: "A", dark: "B"), "theme = light:A,dark:B")
        XCTAssertEqual(SynaptySettings.themeLine(light: "A", dark: nil), "theme = A")
        XCTAssertEqual(SynaptySettings.themeLine(light: nil, dark: "B"), "theme = B")
        XCTAssertNil(SynaptySettings.themeLine(light: nil, dark: nil))
        XCTAssertNil(SynaptySettings.themeLine(light: " ", dark: ""))
    }
    /// A SCALE THAT ARRIVES FROM DISK REACHES WHAT DRAWS.
    ///
    /// `reloadFromDisk` used to assign the static and announce nothing, so
    /// a scale synced from another Mac took effect on the next view to
    /// appear and on nothing the human was looking at
    /// ([[WI-2026-08-28-010]]). The announcement is gone because the value
    /// is now observable ([[WI-2026-08-28-021]]) — what this pins is that
    /// the record on disk still reaches the value every body reads, which
    /// is the half a type cannot enforce.
    func testAScaleArrivingFromDiskAnnouncesItself() throws {
        let settings = SynaptySettings()
        settings.uiFontScale = 1.0
        settings.flushPersistence()

        // Another machine's record, written underneath a running app.
        let file = tempDir.appendingPathComponent("settings.json")
        var payload = try JSONSerialization.jsonObject(
            with: Data(contentsOf: file)) as! [String: Any]
        payload["uiFontScale"] = 1.3
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        settings.reloadFromDisk()

        XCTAssertEqual(settings.uiFontScale, 1.3, "the record was not read")
        XCTAssertEqual(DS.uiFontScale, 1.3, accuracy: 0.0001,
                       "the value every view reads did not move")
    }

}

/// A SIZE READ DURING A BODY DEPENDS ON THE SCALE ([[WI-2026-08-28-021]]).
///
/// This is the claim the notification and the tick used to stand in for,
/// and it is testable without a view: `withObservationTracking` is the
/// same machinery SwiftUI uses to decide what to re-evaluate.
@MainActor
final class UIScaleObservationTests: XCTestCase {

    override func tearDown() {
        DS.uiFontScale = 1.0
        super.tearDown()
    }

    func testReadingAFontSizeDependsOnTheScale() {
        var changed = false
        withObservationTracking {
            _ = DS.Typography.body
        } onChange: {
            changed = true
        }

        DS.uiFontScale = 1.3

        XCTAssertTrue(changed,
                      "a body that read a DS font size will not be re-evaluated when the "
                      + "scale changes, so the change reaches only views drawn afterwards")
    }

    /// The same for a scaled LAYOUT dimension — a popover's width grows
    /// with the text in it, and it is read the same way.
    func testReadingAScaledDimensionDependsOnTheScale() {
        var changed = false
        withObservationTracking {
            _ = DS.scaled(16)
        } onChange: {
            changed = true
        }

        DS.uiFontScale = 0.85

        XCTAssertTrue(changed)
    }
}

/// THE WINDOW'S FLOOR FOLLOWS THE SCALE ([[WI-2026-08-28-022]]).
///
/// It is computed from `DS.uiFontScale` and assigned to an NSWindow, which
/// is not a view body — so the observation that redraws everything else
/// cannot re-run it. It was set at launch and in one `onAppear` and never
/// again, so a human who raised the scale afterwards could drag the window
/// smaller than its own content needs until the next launch. At Extra
/// Large the sidebar and inspector floors alone take 572 of a fixed 760.
@MainActor
final class WindowFloorTests: XCTestCase {

    private var tmp: URL!
    private var window: NSWindow!

    override func setUpWithError() throws {
        tmp = try setUpSettingsStorage()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
        // A WINDOW MADE IN CODE RELEASES ITSELF ON CLOSE by default, which
        // ARC then releases again. Left at the default this took the test
        // host down before it had reported anything, and xcodebuild called
        // it "the test runner hung before establishing connection".
        window.isReleasedWhenClosed = false
        WindowChrome.apply(to: window)
    }

    override func tearDownWithError() throws {
        window.orderOut(nil)
        window = nil
        DS.uiFontScale = 1.0
        restoreStorageOverrides(tmp)
    }

    func testRaisingTheScaleRaisesTheFloor() {
        let settings = SynaptySettings()
        settings.uiFontScale = 1.0
        let before = window.minSize

        settings.uiFontScale = 1.3

        XCTAssertGreaterThan(window.minSize.width, before.width,
                             "the window can still be dragged to a size its own content "
                             + "no longer fits, until the next launch")
        XCTAssertEqual(window.minSize.width, 760 * 1.3, accuracy: 0.5)
    }

    /// AND ONLY OURS. `NSApp.windows` also holds sheets, panels and
    /// whatever AppKit made for a popover; a 760-point floor on one of
    /// those is a floor on the wrong thing.
    func testAWindowThatIsNotTheWorkbenchIsLeftAlone() {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { sheet.orderOut(nil) }
        let before = sheet.minSize

        let settings = SynaptySettings()
        settings.uiFontScale = 1.3

        XCTAssertEqual(sheet.minSize, before,
                       "a panel was given the workbench's minimum size")
    }
}
