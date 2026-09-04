import XCTest
@testable import Synapty

/// "A concurrent edit to the same host is merged or surfaced, never
/// silently resolved by discarding one side" ([[WI-2026-08-13-005]]).
///
/// Last-writer-wins is one line and it loses an edit the human made and
/// watched succeed. That is the failure that made
/// NSUbiquitousKeyValueStore the wrong choice, so re-creating it inside
/// the replacement would be the whole exercise wasted.
final class RecordMergeTests: XCTestCase {

    private func obj(_ d: [String: Any]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (k, v) in d { out[k] = JSONValue(any: v)! }
        return out
    }

    /// THE CASE THE WHOLE THING EXISTS FOR. Two Macs edit the SAME host,
    /// different fields. Both edits survive — that is a merge, and a
    /// last-writer-wins store cannot do it.
    func testEditsToDifferentFieldsBothSurvive() {
        let base = obj(["label": "gc", "port": 22, "username": "u"])
        let ours = obj(["label": "remotehost", "port": 22, "username": "u"])
        let theirs = obj(["label": "gc", "port": 2222, "username": "u"])

        let r = RecordMerge.threeWay(base: base, ours: ours, theirs: theirs)
        XCTAssertTrue(r.isClean, "different fields are not a conflict")
        XCTAssertEqual(r.merged["label"], .string("remotehost"))
        XCTAssertEqual(r.merged["port"], .number(2222))
    }

    /// The same field, moved by both. NOT silently resolved: ours is kept
    /// so the human's edit stays where they are looking, and the field is
    /// named so they can be told.
    func testTheSameFieldChangedOnBothSidesIsSurfacedNotPicked() {
        let base = obj(["label": "gc"])
        let ours = obj(["label": "remotehost"])
        let theirs = obj(["label": "green-cloud"])

        let r = RecordMerge.threeWay(base: base, ours: ours, theirs: theirs)
        XCTAssertFalse(r.isClean)
        XCTAssertEqual(r.conflicts, ["label"])
        XCTAssertEqual(r.merged["label"], .string("remotehost"),
                       "a local edit must not be replaced under the human's cursor")
        XCTAssertEqual(r.theirs["label"], .string("green-cloud"),
                       "the other value must be carried, or the choice cannot be offered")
    }

    /// Only they moved: take theirs. This is convergence, not a conflict —
    /// treating it as one would make every remote edit an interruption.
    func testAFieldOnlyTheyChangedIsTaken() {
        let base = obj(["port": 22])
        let r = RecordMerge.threeWay(base: base, ours: obj(["port": 22]), theirs: obj(["port": 2222]))
        XCTAssertTrue(r.isClean)
        XCTAssertEqual(r.merged["port"], .number(2222))
    }

    func testAFieldOnlyWeChangedIsKept() {
        let base = obj(["port": 22])
        let r = RecordMerge.threeWay(base: base, ours: obj(["port": 2222]), theirs: obj(["port": 22]))
        XCTAssertTrue(r.isClean)
        XCTAssertEqual(r.merged["port"], .number(2222))
    }

    /// WITHOUT A BASE, NOTHING CAN BE INFERRED. CloudKit hands back two
    /// versions and no ancestor; from those alone "I changed it" and "they
    /// changed it" are indistinguishable. Degrading to last-writer-wins
    /// here would be the silent loss wearing a merge's clothes.
    func testWithNoBaseEveryDifferenceIsAConflict() {
        let r = RecordMerge.threeWay(
            base: nil,
            ours: obj(["label": "remotehost", "port": 22]),
            theirs: obj(["label": "gc", "port": 22]))
        XCTAssertEqual(r.conflicts, ["label"], "the agreeing field is not a conflict")
        XCTAssertFalse(r.isClean)
    }

    /// A field one side REMOVED is an edit like any other, and must not be
    /// resurrected just because the other side still has it.
    func testARemovedFieldIsAnEditNotAnAbsence() {
        let base = obj(["sshKeyPath": "/k", "label": "x"])
        let ours = obj(["sshKeyPath": "/k", "label": "x"])
        let theirs = obj(["label": "x"])

        let r = RecordMerge.threeWay(base: base, ours: ours, theirs: theirs)
        XCTAssertTrue(r.isClean)
        XCTAssertNil(r.merged["sshKeyPath"], "they deleted it and we did not touch it")
    }

    /// Identical edits on both sides are agreement, not conflict — two
    /// Macs fixing the same typo must not produce a question.
    func testTheSameEditOnBothSidesIsAgreement() {
        let base = obj(["label": "gc"])
        let same = obj(["label": "remotehost"])
        let r = RecordMerge.threeWay(base: base, ours: same, theirs: same)
        XCTAssertTrue(r.isClean)
    }

    /// A field ADDED by one side only is taken, not treated as a conflict
    /// against its own absence.
    func testAFieldAddedByOneSideIsTaken() {
        let base = obj(["label": "x"])
        let r = RecordMerge.threeWay(
            base: base, ours: obj(["label": "x"]), theirs: obj(["label": "x", "tags": ["prod"]]))
        XCTAssertTrue(r.isClean)
        XCTAssertEqual(r.merged["tags"], .array([.string("prod")]))
    }

    /// Booleans must not bridge into numbers. `true` and `1` are different
    /// edits, and NSNumber will happily conflate them.
    func testTrueIsNotOne() {
        XCTAssertNotEqual(JSONValue(any: true), JSONValue(any: 1))
        XCTAssertEqual(JSONValue(any: true), .bool(true))
        XCTAssertEqual(JSONValue(any: 1), .number(1))
    }

    /// A real host record survives a round trip, so the merge operates on
    /// what is actually stored rather than a simplified shape.
    func testARealHostRecordRoundTrips() throws {
        let json = """
        {"username":"operator","tags":[],"label":"windows-box","port":22,\
        "id":"0141C498-BDF1-492B-86CD-CC9019D8AAC0","address":"windows-box","forwardings":[]}
        """
        let parsed = try XCTUnwrap(JSONValue.object(fromJSON: Data(json.utf8)))
        let data = try XCTUnwrap(JSONValue.data(from: parsed))
        let again = try XCTUnwrap(JSONValue.object(fromJSON: data))
        XCTAssertEqual(parsed, again)
        XCTAssertEqual(again["port"], .number(22))
    }
}

/// A conflict that is recorded and never shown is the same silent loss
/// with an audit trail nobody reads.
@MainActor
final class ConflictSurfacingTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws { tempDir = try setUpHostStoreStorage() }
    override func tearDownWithError() throws { restoreStorageOverrides(tempDir) }

    func testAConflictReachesTheHostItHappenedTo() {
        let store = HostStore()
        let host = HostEntry(label: "remotehost", address: "gc", username: "u")
        store.addHost(host)

        XCTAssertNil(store.conflict(for: host), "a clean host says nothing")

        store.noteConflict(recordID: "hosts/\(host.id.uuidString).json", fields: ["label", "port"])
        XCTAssertEqual(store.conflict(for: host), ["label", "port"])

        store.clearConflict(recordID: "hosts/\(host.id.uuidString).json")
        XCTAssertNil(store.conflict(for: host))
    }

    /// The record id the store keys on must be the one SyncDomain
    /// produces, or the conflict lands on nothing and the mark never
    /// appears — a failure that would look exactly like "no conflicts".
    func testTheKeyMatchesWhatTheSyncDomainProduces() throws {
        let root = ConfigPaths.shared
        let hosts = root.appendingPathComponent("hosts")
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        let host = HostEntry(label: "x", address: "x", username: "u")
        let file = hosts.appendingPathComponent("\(host.id.uuidString).json")
        try Data("{}".utf8).write(to: file)

        let previous = ConfigPaths.rootOverride
        ConfigPaths.rootOverride = tempDir
        defer { ConfigPaths.rootOverride = previous }

        let store = HostStore()
        store.noteConflict(recordID: "hosts/\(host.id.uuidString).json", fields: ["label"])
        XCTAssertEqual(store.conflict(for: host), ["label"])
    }

    /// A conflict is NOT an error: the merge worked and both edits are
    /// real. Rendering it in red next to genuine failures would teach the
    /// human to read every mark as breakage.
    func testAConflictIsAWarningNotAFailure() throws {
        let mark = try XCTUnwrap(HostFailureMarks.conflict(["label"]))
        XCTAssertEqual(mark.1, DS.warning)
        XCTAssertTrue(mark.2.contains("another Mac"))
        XCTAssertTrue(mark.2.contains("Your version is shown"))
        XCTAssertNil(HostFailureMarks.conflict([]), "an empty list is not a conflict")
        XCTAssertNil(HostFailureMarks.conflict(nil))
    }
}
