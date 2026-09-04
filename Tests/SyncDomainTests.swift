import XCTest
@testable import Synapty

/// THE GUARD the sync feature is built behind (WI-2026-08-13-005).
///
/// [[RFC-0010]] C-COLLISION names a copied disk image or a restored backup
/// as one of exactly two ways two machines end up holding one peer id; the
/// symptom is that every message between them is misrouted and the only
/// remedy is a manual re-mint. A directory sync that reached `machine/`
/// would be that scenario automated and running continuously — so this is
/// the test that has to fail before anything ships, not after.
final class SyncDomainTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-syncdomain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigPaths.rootOverride = tempRoot
        for d in [ConfigPaths.shared, ConfigPaths.machine] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        ConfigPaths.rootOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Every machine-scoped path is outside the domain. Driven from the
    /// CLASSIFICATION rather than a hand-written list, so a future entry
    /// is covered the moment it is classified.
    func testNothingMachineScopedIsInsideTheSyncDomain() {
        var checkedMachine = 0
        for entry in ConfigPaths.allEntries {
            let url = ConfigPaths.url(entry.kind, entry.name)
            switch entry.kind {
            case .machine:
                checkedMachine += 1
                XCTAssertFalse(SyncDomain.contains(url),
                               "\(entry.name) is machine-scoped and must never be syncable")
            case .shared:
                XCTAssertTrue(SyncDomain.contains(url),
                              "\(entry.name) is shared and must be syncable")
            }
        }
        XCTAssertGreaterThan(checkedMachine, 0, "the classification must actually contain machine entries")
    }

    /// THE FRAGMENT SPECIFICALLY, because it used to be shared and the
    /// reason it moved is a measurement, not a taste: derived from the
    /// settings and the local shell, synced as its own record it lost to
    /// a fresh machine's default and the terminal ignored the synced
    /// theme ([[WI-2026-09-02-005]]).
    func testTheGhosttyFragmentIsAMachineFile() {
        XCTAssertFalse(SyncDomain.contains(ConfigPaths.ghosttyConfig))
        XCTAssertNil(SyncDomain.recordID(for: ConfigPaths.ghosttyConfig))
    }

    /// The one that is easy to get wrong: identity.json specifically.
    func testTheIdentityFileCanNeverBeSynced() {
        XCTAssertFalse(SyncDomain.contains(ConfigPaths.identity))
        XCTAssertNil(SyncDomain.recordID(for: ConfigPaths.identity))
    }

    /// A SYMLINK OUT OF THE DOMAIN. Nothing creates one today — the point
    /// is that nothing has to for this to be the hole someone finds later.
    /// A string-prefix check passes this and hands the sync engine the
    /// exact file the split exists to keep off the wire.
    func testASymlinkEscapingTheDomainIsRefused() throws {
        let secret = ConfigPaths.identity
        try Data(#"{"peer_id":"deskmac-2630"}"#.utf8).write(to: secret)

        let trap = ConfigPaths.shared.appendingPathComponent("looks-innocent.json")
        try FileManager.default.createSymbolicLink(at: trap, withDestinationURL: secret)

        XCTAssertFalse(SyncDomain.contains(trap),
                       "a link that resolves into machine/ is not inside the domain")
        XCTAssertFalse(SyncDomain.files().contains { $0.lastPathComponent == "looks-innocent.json" },
                       "the walk must not hand back a file that escapes the domain")
    }

    // MARK: - A record with no fields is not a record

    /// FOUND ON THE OPERATOR'S OWN MACHINE: 64 host records containing
    /// `{}`, written on 2026-08-14 by a test suite that was still using
    /// the real config root, and every one of them tracked in sync-base —
    /// so all 64 had been offered to CloudKit and would land on a second
    /// Mac as 64 empty files.
    ///
    /// The store steps over them (`try?` inside a `compactMap`), which is
    /// why four days passed unnoticed. The sync domain did not: it
    /// enumerated anything shaped like a file.
    func testARecordWithNoFieldsIsNotOffered() throws {
        let dir = ConfigPaths.shared.appendingPathComponent("hosts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let junk = dir.appendingPathComponent("empty.json")
        let real = dir.appendingPathComponent("real.json")
        try Data("{}".utf8).write(to: junk)
        try Data(#"{"label":"remotehost"}"#.utf8).write(to: real)

        let offered = SyncDomain.files().map(\.lastPathComponent)
        XCTAssertFalse(offered.contains("empty.json"),
                       "sending a record with no fields can only create or overwrite nothing")
        XCTAssertTrue(offered.contains("real.json"))
    }

    /// A half-written record is not a record either, and a sync that
    /// caught one mid-write would replicate the truncation.
    func testAMalformedRecordIsNotOffered() throws {
        let dir = ConfigPaths.shared.appendingPathComponent("hosts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"label":"greenc"#.utf8).write(to: dir.appendingPathComponent("torn.json"))

        XCTAssertFalse(SyncDomain.files().map(\.lastPathComponent).contains("torn.json"))
    }

    /// THE RULE IS ABOUT RECORDS, NOT ABOUT FILES. `ghostty.conf` and
    /// `config.toml` are not JSON and must keep syncing; a rule phrased as
    /// "must parse" would have quietly stopped replicating the human's
    /// terminal configuration.
    func testFilesThatAreNotRecordsAreUnaffected() throws {
        let conf = ConfigPaths.shared.appendingPathComponent("ghostty.conf")
        try Data("font-size = 18\n".utf8).write(to: conf)
        XCTAssertTrue(SyncDomain.files().map(\.lastPathComponent).contains("ghostty.conf"))
    }

    /// A settings file with real content is a record and keeps syncing.
    func testAPopulatedRecordIsStillOffered() throws {
        let settings = ConfigPaths.shared.appendingPathComponent("settings.json")
        try Data(#"{"fontSize":18}"#.utf8).write(to: settings)
        XCTAssertTrue(SyncDomain.files().map(\.lastPathComponent).contains("settings.json"))
    }

    // MARK: - What arrives is held to the same rule

    /// THE END THAT MATTERS. An outbound guard alone still lets a record
    /// with no fields reach a second Mac, and still lets one deleted
    /// locally come back — `apply` treats an absent local file as licence
    /// to write whatever the wire offered.
    func testARecordWithNoFieldsIsRefusedOnArrival() {
        XCTAssertFalse(
            SyncDomain.isSendableRecord(Data("{}".utf8), named: "hosts/x.json"))
        XCTAssertTrue(
            SyncDomain.isSendableRecord(Data(#"{"label":"remotehost"}"#.utf8),
                                        named: "hosts/x.json"))
    }

    func testANonRecordArrivingIsUnaffected() {
        XCTAssertTrue(
            SyncDomain.isSendableRecord(Data("font-size = 18\n".utf8), named: "ghostty.conf"))
    }

    /// A sibling directory whose name merely STARTS with the domain's is
    /// not inside it. `shared-backup` vs `shared` — the classic prefix bug.
    func testAPrefixSiblingIsNotInsideTheDomain() {
        let sibling = ConfigPaths.root.appendingPathComponent("shared-backup/hosts/x.json")
        XCTAssertFalse(SyncDomain.contains(sibling))
    }

    /// Record ids are relative paths, so two machines key the same host
    /// identically — which is what makes a set-union merge possible.
    func testRecordIDsAreStableRelativePaths() throws {
        let hosts = ConfigPaths.shared.appendingPathComponent("hosts")
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        let f = hosts.appendingPathComponent("ABC-123.json")
        // A real record: an empty one is refused by the domain now, and
        // what this test is about is the id, not the contents.
        try Data(#"{"label":"remotehost"}"#.utf8).write(to: f)

        XCTAssertEqual(SyncDomain.recordID(for: f), "hosts/ABC-123.json")
        // By record id, not by URL: files() returns resolved paths and a
        // hand-built URL under the temp dir is not resolved.
        XCTAssertTrue(SyncDomain.files().compactMap(SyncDomain.recordID).contains("hosts/ABC-123.json"))
    }
}
