import XCTest
@testable import Synapty

/// The requirement is not "show an error" — it is that a sync which is NOT
/// running must never render as one that is. Those two fail differently:
/// an unshown error is a bug someone eventually finds, while a stopped
/// sync that looks healthy is a human trusting a host list that quietly
/// stopped updating months ago. The second is why CloudKit was chosen over
/// NSUbiquitousKeyValueStore in the first place.
@MainActor
final class SyncMonitorTests: XCTestCase {

    override func tearDown() {
        SyncMonitor.statusOverride = nil
        super.tearDown()
    }

    /// EXACTLY ONE state may render as working. Driven over every case so
    /// a future addition has to decide rather than default into "fine".
    func testOnlyAvailableCountsAsSyncing() {
        let notWorking: [SyncPreflight.Status] = [
            .notSignedIn, .restricted, .networkUnavailable,
            .schemaMissing, .notEntitled("x"), .failed("y"),
        ]
        XCTAssertTrue(SyncPreflight.Status.available.isSyncing)
        for s in notWorking {
            XCTAssertFalse(s.isSyncing, "\(s) must not read as syncing")
        }
    }

    /// Every non-working state says something DIFFERENT, and says what to
    /// do. "Sync failed" for all six would be typed internally and
    /// untyped where it matters.
    func testEachFailureIsDistinguishableToAHuman() {
        let all: [SyncPreflight.Status] = [
            .notSignedIn, .restricted, .networkUnavailable,
            .schemaMissing, .notEntitled("x"), .failed("y"),
        ]
        let descriptions = all.map(\.humanDescription)
        XCTAssertEqual(Set(descriptions).count, all.count,
                       "two different failures share one sentence, so the human cannot tell them apart")
        // Not signed in and no network are the pair most easily collapsed,
        // and the remedies are opposite: act, versus wait.
        XCTAssertTrue(SyncPreflight.Status.notSignedIn.humanDescription.contains("sign in"))
        XCTAssertTrue(SyncPreflight.Status.networkUnavailable.humanDescription.contains("network"))
    }

    /// A working capability is INVISIBLE by working — the same rule
    /// RFC-0010 C-DIAGNOSABILITY sets for peer capabilities. Chrome that
    /// says "everything is fine" trains people to stop reading it.
    func testAWorkingSyncShowsNothing() async {
        let m = SyncMonitor()
        SyncMonitor.statusOverride = .available
        await m.refresh()
        XCTAssertTrue(m.isSyncing)
        XCTAssertNil(m.compactLabel)
    }

    func testAStoppedSyncShowsSomethingSpecific() async {
        let m = SyncMonitor()
        SyncMonitor.statusOverride = .notSignedIn
        await m.refresh()
        XCTAssertFalse(m.isSyncing)
        XCTAssertEqual(m.compactLabel, "iCloud sign-in needed")
        XCTAssertTrue(m.accessibilityLabel.contains("not syncing"))
    }

    /// A status with no timestamp cannot be told from a fresh one — the
    /// same lie as serving a stale relayed presence as current
    /// (RFC-0009 C-PRESENCE).
    func testTheStatusCarriesWhenItWasEstablished() async {
        let m = SyncMonitor()
        XCTAssertNil(m.lastChecked, "an unchecked monitor must not claim a time")
        SyncMonitor.statusOverride = .available
        await m.refresh()
        XCTAssertNotNil(m.lastChecked)
    }

    /// The UI string and the log string must differ (AppLog two-channel
    /// rule): the human gets a consequence and a remedy, the log gets the
    /// typed case.
    func testTheHumanStringIsNotTheDiagnosticString() {
        for s in [SyncPreflight.Status.notSignedIn, .schemaMissing, .notEntitled("CKError 9")] {
            let human = s.humanDescription
            let diagnostic = String(describing: s)
            XCTAssertNotEqual(human, diagnostic)
            XCTAssertFalse(human.contains("CKError"), "the UI must not carry the log's answer")
        }
    }
}

extension SyncMonitorTests {

    /// CKContainer(identifier:) TRAPS in a process whose entitlements do
    /// not carry that container. It does not throw and it does not return
    /// an error — the first version of this crashed the app and the test
    /// host on launch, which is how the guard came to exist.
    ///
    /// This test runs in the Debug host, which is ad-hoc signed with no
    /// profile, so it asserts the honest answer for exactly that build.
    func testAnUnentitledBuildReportsItRatherThanCrashing() async {
        XCTAssertFalse(SyncPreflight.hasContainerEntitlement(),
                       "the Debug test host has no iCloud entitlement — if this ever passes, the premise below changed")

        SyncMonitor.statusOverride = nil
        let status = await SyncPreflight.check()
        guard case .notEntitled = status else {
            return XCTFail("an unentitled build must say so, got \(status)")
        }
        XCTAssertFalse(status.isSyncing)
        XCTAssertTrue(status.humanDescription.contains("not set up for iCloud"))
    }
}
