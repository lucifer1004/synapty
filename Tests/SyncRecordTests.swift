import CloudKit
import XCTest
@testable import Synapty

/// The encoding half is pure and therefore testable; the engine half needs
/// an account, a network and a second Mac. The bugs that hide HERE — a
/// name that does not round-trip, a path that escapes — upload fine and
/// land in the wrong file, which looks like data loss rather than a bug.
final class SyncRecordTests: XCTestCase {

    /// CKRecord names reject `/`, and every relative path in the domain
    /// has one. The true path travels as a FIELD, so sanitization only has
    /// to be stable and collision-free, not reversible.
    func testRecordNamesSurviveThePathSeparator() {
        XCTAssertEqual(SyncRecord.recordName(for: "hosts/ABC-123.json"), "hosts_ABC-123.json")
        XCTAssertNotEqual(
            SyncRecord.recordName(for: "hosts/x.json"),
            SyncRecord.recordName(for: "groups/x.json"),
            "two kinds of record must not collide on one name")
    }

    func testARecordCarriesItsRealPathAsAField() throws {
        let record = SyncRecord.makeRecord(path: "hosts/ABC.json", contents: Data("{}".utf8))
        let decoded = try XCTUnwrap(SyncRecord.decode(record))
        XCTAssertEqual(decoded.path, "hosts/ABC.json")
        XCTAssertEqual(decoded.contents, Data("{}".utf8))
    }

    /// A record with no path is not routable, and guessing it back from
    /// the sanitized name is how a file lands somewhere else.
    func testARecordWithoutAPathIsRefusedRatherThanGuessed() {
        let r = CKRecord(recordType: SyncRecord.recordType,
                         recordID: CKRecord.ID(recordName: "hosts_ABC.json", zoneID: SyncRecord.zoneID))
        r[SyncRecord.dataKey] = Data("{}".utf8) as CKRecordValue
        XCTAssertNil(SyncRecord.decode(r))
    }

    /// THE ONE THAT MATTERS. A record arriving from our own account is
    /// still a record from ANOTHER MACHINE, which may run an older or
    /// modified build. `../../machine/identity.json` is the attack, and
    /// RFC-0010 C-COLLISION names what landing it would cost: two machines
    /// holding one peer id, every message between them misrouted, and a
    /// manual re-mint as the only remedy.
    func testAPathThatEscapesTheDomainIsRefused() {
        let bad = [
            "../machine/identity.json",
            "hosts/../../machine/identity.json",
            "/etc/passwd",
            "./hosts/x.json",
            "",
            "hosts//x.json",
        ]
        for p in bad {
            XCTAssertFalse(SyncRecord.isSafeRelativePath(p), "\(p) must be refused")
        }
        for p in ["hosts/ABC.json", "settings.json", "groups/G.json"] {
            XCTAssertTrue(SyncRecord.isSafeRelativePath(p), "\(p) is legitimate")
        }
    }

    func testDecodeRefusesAnEscapingPathEvenWhenWellFormed() {
        let r = CKRecord(recordType: SyncRecord.recordType,
                         recordID: CKRecord.ID(recordName: "evil", zoneID: SyncRecord.zoneID))
        r[SyncRecord.pathKey] = "../machine/identity.json" as CKRecordValue
        r[SyncRecord.dataKey] = Data(#"{"peer_id":"stolen"}"#.utf8) as CKRecordValue
        XCTAssertNil(SyncRecord.decode(r),
                     "a well-formed record with a traversing path must still be refused")
    }
}

/// The base is what makes a three-way merge possible, and it is
/// machine-scoped bookkeeping that must never itself sync — a WRONG
/// ancestor produces a confident merge where none was warranted, which is
/// worse than having no ancestor at all.
final class SyncBaseStoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigPaths.rootOverride = tempRoot
    }

    override func tearDownWithError() throws {
        ConfigPaths.rootOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testTheBaseIsOutsideTheSyncDomain() {
        XCTAssertFalse(SyncDomain.contains(SyncBaseStore.root),
                       "syncing the base would tell another Mac it had agreed to something it never saw")
    }

    func testABaseRoundTripsAndCanBeForgotten() {
        XCTAssertNil(SyncBaseStore.base(for: "hosts/A.json"), "never synced is a real answer")

        SyncBaseStore.setBase(for: "hosts/A.json", contents: Data(#"{"label":"gc"}"#.utf8))
        XCTAssertEqual(SyncBaseStore.base(for: "hosts/A.json")?["label"], .string("gc"))

        SyncBaseStore.forget("hosts/A.json")
        XCTAssertNil(SyncBaseStore.base(for: "hosts/A.json"))
    }

    /// Two records must not share one base file, or a merge would judge a
    /// host against a group's ancestor.
    func testTwoRecordsDoNotShareABase() {
        SyncBaseStore.setBase(for: "hosts/X.json", contents: Data(#"{"a":1}"#.utf8))
        SyncBaseStore.setBase(for: "groups/X.json", contents: Data(#"{"a":2}"#.utf8))
        XCTAssertEqual(SyncBaseStore.base(for: "hosts/X.json")?["a"], .number(1))
        XCTAssertEqual(SyncBaseStore.base(for: "groups/X.json")?["a"], .number(2))
    }
}

/// The gap that "converges" hid: the engine only ever saw what was on
/// disk when it STARTED, so an edit made after launch sat locally until
/// the next relaunch. Two Macs still appeared to converge — on startup —
/// and no test noticed, because a test that restarts the app between
/// writing and reading cannot tell the difference.
@MainActor
final class SyncPropagationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try setUpHostStoreStorage()
        SyncEngine.shared.resetOfferedPathsForTesting()
    }

    override func tearDownWithError() throws {
        restoreStorageOverrides(tempDir)
        SyncEngine.shared.resetOfferedPathsForTesting()
    }

    func testAddingAHostOffersItToTheEngine() {
        let store = HostStore()
        let host = HostEntry(label: "gc", address: "gc.example", username: "u")
        store.addHost(host)

        XCTAssertTrue(
            SyncEngine.shared.offeredPaths.contains("hosts/\(host.id.uuidString).json"),
            "an edit the engine is never told about does not leave this Mac until relaunch")
    }

    /// A deletion that only happens locally is a host that comes back
    /// from the other Mac — the one failure mode worse than not syncing.
    func testDeletingAHostOffersTheDeletion() {
        let store = HostStore()
        let host = HostEntry(label: "gone", address: "g", username: "u")
        store.addHost(host)
        SyncEngine.shared.resetOfferedPathsForTesting()

        store.removeHost(host)
        XCTAssertTrue(
            SyncEngine.shared.offeredPaths.contains("hosts/\(host.id.uuidString).json"),
            "a local-only deletion means the host returns from the other machine")
    }

    /// A record that failed to persist must NOT be offered: sending a
    /// version this Mac could not even write would push a half-truth to
    /// every other machine.
    func testARecordThatDidNotReachDiskIsNotOffered() throws {
        let store = HostStore()
        let hostsDir = tempDir.appendingPathComponent("hosts")
        try FileManager.default.createDirectory(at: hostsDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: hostsDir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: hostsDir.path)
        }
        SyncEngine.shared.resetOfferedPathsForTesting()

        let doomed = HostEntry(label: "lost", address: "l", username: "u")
        store.addHost(doomed)

        XCTAssertTrue(store.unpersistedRecordIDs.contains(doomed.id.uuidString))
        XCTAssertFalse(
            SyncEngine.shared.offeredPaths.contains("hosts/\(doomed.id.uuidString).json"),
            "a record that never reached disk must not be pushed to other machines")
    }
}
