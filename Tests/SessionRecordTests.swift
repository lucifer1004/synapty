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

    /// A RECORD WITH NO CLAIM BESIDE IT IS NOT A TOMBSTONE. That is what
    /// a session still starting up looks like — the holder takes the
    /// claim before it writes the record — and sweeping it deletes a
    /// session on its way to being born. `free` is a tombstone; `absent`
    /// is not ([[holder.sweepEnded]]).
    func testARecordWithNoClaimBesideItIsLeftAlone() throws {
        try #"{"pid":1}"#.write(to: SessionRecord.url(for: "starting"), atomically: true,
                                encoding: .utf8)
        XCTAssertEqual(SessionRecord.claim("starting"), .absent)
        XCTAssertEqual(SessionRecord.live(), ["starting"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SessionRecord.url(for: "starting").path),
            "a session that had not yet taken its claim was swept as a tombstone")
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
