import XCTest
@testable import Synapty

/// LISTING SESSIONS IS ALSO SWEEPING THEM.
///
/// A record is a claim about a process, and whether that process exists is
/// not the claim's to make. A record whose holder is gone offers nothing to
/// return to and nothing to end — it is a row that can only be read — and
/// they accumulate: 83 of them on this machine against one live session,
/// which is what [[RFC-0015]] C-SET-ASIDE's list must not become, since
/// being listed is the whole of what makes a live session not a leak.
final class SessionRecordTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-sessions-\(UUID().uuidString)")
        ConfigPaths.rootOverride = root
        try FileManager.default.createDirectory(
            at: SessionRecord.directory(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ConfigPaths.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// A session nobody holds: record, lock and socket all present and
    /// nothing holding any of them — which is what a holder that died
    /// looks like from here.
    private func writeDead(_ name: String) throws {
        try #"{"pid":1}"#.write(to: SessionRecord.url(for: name), atomically: true,
                               encoding: .utf8)
        FileManager.default.createFile(
            atPath: SessionRecord.lockURL(for: name).path, contents: Data())
        FileManager.default.createFile(
            atPath: SessionRecord.socketURL(for: name).path, contents: Data())
    }

    /// The same, with the claim taken and held for the test's duration —
    /// which is what a live holder looks like. ON THE LOCK: see
    /// `SessionRecord.lockURL`.
    private func writeLive(_ name: String) throws -> Int32 {
        try writeDead(name)
        let fd = open(SessionRecord.lockURL(for: name).path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        return fd
    }

    /// THE CASE THAT COST 49 LIVE SESSIONS. An flock binds to an inode,
    /// so a claim taken on the record itself is released by anything that
    /// replaces that file — and `write(to:atomically:)` below is exactly
    /// the temp-plus-rename that does it. Listing must not read that as a
    /// holder having died ([[WI-2026-09-03-009]]).
    func testReplacingTheRecordUnderALiveHolderDoesNotSweepIt() throws {
        let fd = try writeLive("swapped")
        defer { close(fd) }
        XCTAssertEqual(SessionRecord.live(), ["swapped"], "the fixture is not live")

        try #"{"pid":1,"name":"renamed"}"#.write(
            to: SessionRecord.url(for: "swapped"), atomically: true, encoding: .utf8)

        XCTAssertEqual(SessionRecord.live(), ["swapped"],
                       "a live session was swept because its record file was replaced")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SessionRecord.socketURL(for: "swapped").path),
            "the socket went with it, so the session is unreachable as well as unlisted")
    }

    func testADeadRecordIsSweptRatherThanListed() throws {
        try writeDead("gone")
        XCTAssertEqual(SessionRecord.live(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionRecord.url(for: "gone").path))
    }

    func testItsSocketGoesWithIt() throws {
        try writeDead("gone")
        _ = SessionRecord.live()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SessionRecord.socketURL(for: "gone").path),
            "a socket left behind is the leak the record was hiding")
    }

    func testALiveSessionIsListedAndKept() throws {
        let fd = try writeLive("here")
        defer { close(fd) }

        XCTAssertEqual(SessionRecord.live(), ["here"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionRecord.url(for: "here").path))
    }

    func testTheDeadGoAndTheLiveStay() throws {
        let fd = try writeLive("here")
        defer { close(fd) }
        for n in 1...5 { try writeDead("gone-\(n)") }

        XCTAssertEqual(SessionRecord.live(), ["here"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: SessionRecord.directory().path).filter { $0.hasSuffix(".json") },
            ["here.json"])
    }

    func testTheListingIsOrdered() throws {
        // A list that reorders itself between two looks is one a human
        // cannot aim at.
        var fds: [Int32] = []
        for n in ["c", "a", "b"] { fds.append(try writeLive(n)) }
        defer { fds.forEach { close($0) } }

        XCTAssertEqual(SessionRecord.live(), ["a", "b", "c"])
    }

    /// A RECORD WITH NO CLAIM BESIDE IT IS A TOMBSTONE LIKE ANY OTHER.
    ///
    /// THIS TEST ASSERTED THE OPPOSITE, and its own doc comment carried
    /// the disproof: "the holder takes the claim before it writes the
    /// record". If that is the order — and [[holder.Record.write]] says it
    /// is — then a record without a claim is precisely NOT a session on
    /// its way to being born, because being born puts the claim down
    /// first. The premise was right and the conclusion was its reverse.
    ///
    /// WHAT IT COST was a row that could be neither returned to nor
    /// removed: `isLive` wants `held`, the sweep wanted `free`, and a name
    /// whose lock was absent satisfied neither. One sat in a human's
    /// sidebar for six days before anybody could say why
    /// ([[WI-2026-09-07-005]]).
    ///
    /// The ordering that IS dangerous is the socket's — a holder binds
    /// before it writes its record — and nothing here sweeps on a socket.
    func testARecordWithNoClaimBesideItIsSwept() throws {
        try #"{"pid":1}"#.write(to: SessionRecord.url(for: "unclaimed"), atomically: true,
                                encoding: .utf8)
        XCTAssertEqual(SessionRecord.claim("unclaimed"), .absent)

        XCTAssertEqual(SessionRecord.live(), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SessionRecord.url(for: "unclaimed").path),
            "a record no claim vouches for can never be returned to, so leaving it "
            + "leaves a row nothing can act on in either direction")
    }

    /// A CLAIM THAT COULD NOT BE ASKED IS NOT A CLAIM THAT SAID NO.
    ///
    /// `open` failing meant `absent`, and `absent` sweeps — so a workbench
    /// out of descriptors would have deleted the record of every live
    /// session it held, at exactly the moment it had the most of them
    /// (EMFILE arrives when the most surfaces are open). [[RFC-0014]]
    /// C-LIVENESS calls a test that can answer "gone" for a holder that is
    /// merely busy inadmissible "however well it behaves in the ordinary
    /// case" ([[WI-2026-09-07-008]]).
    ///
    /// A SYMLINK LOOP IS THE ERROR THAT IS PORTABLE TO PROVOKE. ELOOP is
    /// not the interesting failure — EMFILE is — but the code cannot tell
    /// them apart and must not: everything that is not ENOENT is one
    /// answer, and that answer is that there is none.
    func testAClaimThatCouldNotBeAskedIsNotSwept() throws {
        try #"{"pid":1}"#.write(to: SessionRecord.url(for: "cannot-ask"), atomically: true,
                                encoding: .utf8)
        let lock = SessionRecord.lockURL(for: "cannot-ask").path
        let other = lock + ".loop"
        try? FileManager.default.removeItem(atPath: lock)
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: other)
        try FileManager.default.createSymbolicLink(atPath: other, withDestinationPath: lock)

        XCTAssertEqual(SessionRecord.claim("cannot-ask"), .unknown)
        XCTAssertFalse(SessionRecord.isLive("cannot-ask"),
                       "it is not evidence of life either")
        XCTAssertEqual(SessionRecord.live(), ["cannot-ask"],
                       "a row that cannot be judged stays; a stale row is litter, "
                       + "a swept record is a live session nothing names")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SessionRecord.url(for: "cannot-ask").path))
    }

    /// A SOCKET WITH NO RECORD IS LEFT ALONE, which is the case the rule
    /// above was confused with. A holder binds and listens BEFORE it
    /// writes its record, so this shape really is a session starting up —
    /// and the sweep never sees it, because it only ever considers names
    /// it found a record for.
    func testASocketWithNoRecordIsLeftAlone() throws {
        FileManager.default.createFile(
            atPath: SessionRecord.socketURL(for: "being-born").path, contents: Data())

        XCTAssertEqual(SessionRecord.live(), [])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SessionRecord.socketURL(for: "being-born").path),
            "a session that has bound its socket and not yet written its record was swept")
    }

    func testAMissingDirectoryIsNotAFailure() {
        try? FileManager.default.removeItem(at: SessionRecord.directory())
        XCTAssertEqual(SessionRecord.live(), [])
    }

    /// Nothing but a record is a record. The directory holds sockets too,
    /// and a sweep that took the whole directory for records would delete
    /// a live session's socket.
    func testOnlyRecordsAreConsidered() throws {
        let fd = try writeLive("here")
        defer { close(fd) }
        XCTAssertEqual(SessionRecord.live(), ["here"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SessionRecord.socketURL(for: "here").path))
    }
}
