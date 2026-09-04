import XCTest
@testable import Synapty

/// A reference that travels is not a resource that travels. A host names
/// an SSH key path; appearance settings name a font family. Neither exists
/// on the second Mac merely because the setting reached it.
///
/// This is where Synapty differs from Termius, which ships its own font
/// and so has nothing to be missing. Using installed fonts is better and
/// it means a synced setting can name one that is absent — after which
/// ghostty substitutes silently and the human sees different type with
/// nothing explaining it.
final class SettingsReadinessTests: XCTestCase {

    private let installed: Set<String> = ["SF Mono", "Menlo", "Maple Mono NF CN"]

    func testAnInstalledFontSaysNothing() {
        let gaps = SettingsReadiness.evaluate(
            fontFamily: "Maple Mono NF CN", fallbackFamilies: [], installed: installed)
        XCTAssertTrue(gaps.isEmpty, "a font that is present is invisible by working")
    }

    /// THE CASE SYNC PRODUCES. The setting arrives from a Mac that has the
    /// font; this one does not.
    func testAMissingTerminalFontIsReported() {
        let gaps = SettingsReadiness.evaluate(
            fontFamily: "Berkeley Mono", fallbackFamilies: [], installed: installed)
        XCTAssertEqual(gaps, [.terminalFontMissing("Berkeley Mono")])
        XCTAssertTrue(gaps[0].summary.contains("not installed on this Mac"))
        // And it says what is happening INSTEAD, because "missing" without
        // "a substitute is being used" leaves the human wondering whether
        // the terminal is broken.
        XCTAssertTrue(gaps[0].summary.contains("substitute"))
    }

    /// A missing FALLBACK is less severe and must read that way — the
    /// chain still works, it is just shorter. Reporting both at the same
    /// weight would train the human to ignore the pair.
    func testMissingFallbacksAreReportedSeparately() {
        let gaps = SettingsReadiness.evaluate(
            fontFamily: "Menlo", fallbackFamilies: ["Noto Sans CJK", "Symbols Nerd Font"],
            installed: installed)
        XCTAssertEqual(gaps, [.fallbackFontMissing(["Noto Sans CJK", "Symbols Nerd Font"])])
        XCTAssertFalse(gaps[0].summary.contains("substitute"))
    }

    /// An empty or unset font is not a missing font — it means "use the
    /// default", which is a choice rather than a gap.
    func testNoFontConfiguredIsNotAGap() {
        XCTAssertTrue(SettingsReadiness.evaluate(
            fontFamily: nil, fallbackFamilies: [], installed: installed).isEmpty)
        XCTAssertTrue(SettingsReadiness.evaluate(
            fontFamily: "", fallbackFamilies: [""], installed: installed).isEmpty)
    }

    /// Both at once, each named, so the human fixes the right thing.
    func testBothKindsAreReportedIndependently() {
        let gaps = SettingsReadiness.evaluate(
            fontFamily: "Berkeley Mono", fallbackFamilies: ["Noto Sans CJK"],
            installed: installed)
        XCTAssertEqual(gaps.count, 2)
    }
}

/// EVERY writer into the shared domain must tell the sync engine.
///
/// This was got wrong twice in a row — hosts first, then settings — and
/// both times the symptom was identical and misleading: the data was on
/// disk, both machines held the same bytes eventually, and only the
/// TIMING was wrong. So the rule is checked rather than remembered.
@MainActor
final class SyncNotificationWiringTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try setUpSettingsStorage()
        SyncEngine.shared.resetOfferedPathsForTesting()
    }

    override func tearDownWithError() throws {
        SynaptySettings.storageOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        SyncEngine.shared.resetOfferedPathsForTesting()
    }

    /// Changing a preference must reach the engine, or it leaves this Mac
    /// only at the next relaunch — which looks like "sync is slow" and is
    /// actually "sync never heard about it".
    func testChangingASettingOffersItToTheEngine() async throws {
        let settings = SynaptySettings()
        settings.fontSize = 17

        // settings.json is written on a DEBOUNCE — slider drags coalesce
        // into one disk write instead of one per tick. So the engine is
        // told late, which is correct, and a test that checked immediately
        // would be asserting the debounce away.
        //
        // POLLED, NOT SLEPT. This waited a flat 1.2s against a 500ms
        // debounce, which reads like ample headroom and is really a
        // wall-clock bet on an asynchronous chain — debounce, then write,
        // then offer. It lost that bet on a loaded machine and passed on
        // the next run, which is the worst way for a test to fail: it
        // teaches the reader that red means "run it again".
        let offered = await eventually {
            SyncEngine.shared.offeredPaths.contains("settings.json")
        }
        XCTAssertTrue(offered,
                      "a preference the engine is never told about waits for a relaunch")
    }

    /// THE FRAGMENT IS NOT A RECORD. It is derived from settings.json and
    /// this machine's shell, so the setting is what syncs and the fragment
    /// is regenerated where it lands. Offered as its own record, a fresh
    /// machine's default fragment beat the remote copy and the terminal
    /// ignored the synced theme ([[WI-2026-09-02-005]]).
    func testTheGhosttyFragmentIsNeverOffered() {
        SyncEngine.shared.resetOfferedPathsForTesting()
        let settings = SynaptySettings()
        settings.fontFamily = "Menlo"
        settings.flushPersistence()

        XCTAssertFalse(SyncEngine.shared.offeredPaths.contains("ghostty.conf"),
                       "a derived machine file must not be offered as a record")
    }
}
