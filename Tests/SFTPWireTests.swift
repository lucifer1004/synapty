import XCTest
@testable import Synapty

/// [[WI-2026-08-15-009]]. A framing bug in a protocol reader is a SILENT
/// wrong answer — a listing that is short, or shifted by one entry, still
/// renders. These test against bytes rather than against a host, because a
/// live listing that happens to look plausible proves nothing.
final class SFTPWireTests: XCTestCase {

    // MARK: - Encoding

    func testTheInitPacketAnnouncesVersionThree() {
        let packet = SFTPWire.initPacket()
        // uint32 length = 5, byte type = 1, uint32 version = 3
        XCTAssertEqual([UInt8](packet), [0, 0, 0, 5, 1, 0, 0, 0, 3])
    }

    /// The length prefix counts the type byte and the payload, and nothing
    /// else. An off-by-one here desynchronises the whole stream.
    func testTheLengthPrefixCoversTheTypeByteAndThePayload() {
        let packet = SFTPWire.request(.openDir, id: 7, string: "/tmp")
        var reader = ByteReader(packet)
        let length = reader.readUInt32()
        // 1 type + 4 id + (4 + 4) string
        XCTAssertEqual(length, 13)
        XCTAssertEqual(packet.count, 4 + 13)
    }

    /// A path is bytes with a length, never a terminator — so a name
    /// containing anything at all survives it.
    func testAPathWithASpaceAndAQuoteIsCarriedAsBytes() {
        let nasty = "/home/z/it's a \"file\"\n"
        let packet = SFTPWire.request(.realPath, id: 1, string: nasty)
        var reader = ByteReader(packet)
        _ = reader.readUInt32()
        _ = reader.readByte()
        _ = reader.readUInt32()
        XCTAssertEqual(reader.readString(), nasty)
    }

    // MARK: - Decoding

    func testAVersionReplyIsRecognised() {
        var payload = Data()
        payload.appendUInt32(3)
        var buffer = SFTPWire.frame(.version, payload)
        XCTAssertEqual(SFTPWire.decode(from: &buffer), .version(3))
        XCTAssertTrue(buffer.isEmpty, "a consumed packet leaves nothing behind")
    }

    /// A READ IS NOT A PACKET. The stream delivers whatever arrived, which
    /// for a real listing is regularly a partial packet followed by the rest
    /// — and treating one read as one packet works right up until a
    /// directory is big enough to be split.
    func testAPartialPacketIsLeftAloneUntilTheRestArrives() {
        var payload = Data()
        payload.appendUInt32(3)
        let whole = SFTPWire.frame(.version, payload)

        var buffer = whole.prefix(5)
        XCTAssertNil(SFTPWire.decode(from: &buffer), "half a packet is not a packet")
        XCTAssertEqual(buffer.count, 5, "and it must not be consumed")

        buffer.append(whole.suffix(from: 5))
        XCTAssertEqual(SFTPWire.decode(from: &buffer), .version(3))
    }

    /// Two packets in one read must both come out, in order.
    func testTwoPacketsInOneReadAreBothDecoded() {
        var payload = Data()
        payload.appendUInt32(3)
        var buffer = SFTPWire.frame(.version, payload)
        buffer.append(statusPacket(id: 9, code: 1, message: "EOF"))

        XCTAssertEqual(SFTPWire.decode(from: &buffer), .version(3))
        XCTAssertEqual(SFTPWire.decode(from: &buffer), .status(id: 9, code: 1, message: "EOF"))
        XCTAssertNil(SFTPWire.decode(from: &buffer))
    }

    /// A directory listing carries name, the server's own `ls -l` rendering,
    /// and typed attributes. The rendering is stepped over and discarded —
    /// it is the thing this codec exists in order not to parse.
    func testANameReplyYieldsTypedEntriesAndDiscardsTheServersRendering() {
        var body = Data()
        body.appendUInt32(42)
        body.appendUInt32(2)
        // A directory.
        body.appendString("projects")
        body.appendString("drwxr-xr-x  2 z z 4096 Aug 15 10:00 projects")
        body.appendUInt32(0x04)          // permissions only
        body.appendUInt32(0o040755)
        // A file with a size and an mtime.
        body.appendString("out.tar")
        body.appendString("-rw-r--r--  1 z z 1024 Aug 15 10:00 out.tar")
        body.appendUInt32(0x01 | 0x04 | 0x08)
        body.appendUInt64(1024)
        body.appendUInt32(0o100644)
        body.appendUInt32(1_755_000_000)  // atime
        body.appendUInt32(1_755_000_001)  // mtime

        var buffer = SFTPWire.frame(.name, body)
        guard case .names(let id, let entries) = SFTPWire.decode(from: &buffer) else {
            return XCTFail("expected a name reply")
        }
        XCTAssertEqual(id, 42)
        XCTAssertEqual(entries.count, 2)

        XCTAssertEqual(entries[0].name, "projects")
        XCTAssertTrue(entries[0].attributes.isDirectory, "a listing that cannot see a directory cannot be navigated")
        XCTAssertNil(entries[0].attributes.size, "no size was sent, so none may be shown")

        XCTAssertEqual(entries[1].name, "out.tar")
        XCTAssertFalse(entries[1].attributes.isDirectory)
        XCTAssertEqual(entries[1].attributes.size, 1024)
        XCTAssertEqual(entries[1].attributes.modified,
                       Date(timeIntervalSince1970: 1_755_000_001))
    }

    /// EXTENDED ATTRIBUTES MUST BE STEPPED OVER, NOT IGNORED. Leaving them
    /// in the stream shifts every following entry — the first file looks
    /// right and the rest of the directory is garbage.
    func testExtendedAttributesDoNotShiftTheEntriesAfterThem() {
        var body = Data()
        body.appendUInt32(1)
        body.appendUInt32(2)
        body.appendString("first")
        body.appendString("")
        body.appendUInt32(0x04 | 0x8000_0000)
        body.appendUInt32(0o100644)
        body.appendUInt32(1)                     // one extension
        body.appendString("acl@openssh.com")
        body.appendString("some opaque value")
        body.appendString("second")
        body.appendString("")
        body.appendUInt32(0x01)
        body.appendUInt64(77)

        var buffer = SFTPWire.frame(.name, body)
        guard case .names(_, let entries) = SFTPWire.decode(from: &buffer) else {
            return XCTFail("expected a name reply")
        }
        XCTAssertEqual(entries.map(\.name), ["first", "second"])
        XCTAssertEqual(entries[1].attributes.size, 77)
    }

    /// A name that is not valid UTF-8 keeps its entry. Dropping it would
    /// hide a file that exists, which is worse than showing it under a
    /// substituted character — the human can still see it and select it.
    func testAFileNameThatIsNotValidUnicodeStaysInTheListing() {
        var body = Data()
        body.appendUInt32(1)
        body.appendUInt32(1)
        body.appendUInt32(3)
        body.append(contentsOf: [0xFF, 0xFE, 0x41])  // invalid, then 'A'
        body.appendString("")
        body.appendUInt32(0x04)
        body.appendUInt32(0o100644)

        var buffer = SFTPWire.frame(.name, body)
        guard case .names(_, let entries) = SFTPWire.decode(from: &buffer) else {
            return XCTFail("expected a name reply")
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].name.hasSuffix("A"))
    }

    /// A truncated packet must fail the listing, not trap. These bytes come
    /// from another machine.
    func testATruncatedPacketDoesNotTrap() {
        var body = Data()
        body.appendUInt32(1)
        body.appendUInt32(5)      // claims five entries
        body.appendString("only-one")
        // and then stops.
        var buffer = SFTPWire.frame(.name, body)
        guard case .names(_, let entries) = SFTPWire.decode(from: &buffer) else {
            return XCTFail("expected a name reply")
        }
        XCTAssertEqual(entries.count, 0, "an entry without attributes is not an entry")
    }

    /// A packet claiming a length longer than what arrived is not decoded
    /// and not consumed — it may simply be incomplete.
    func testALengthLongerThanTheBufferIsTreatedAsIncomplete() {
        var buffer = Data()
        buffer.appendUInt32(9999)
        buffer.append(SFTPWire.PacketType.version.rawValue)
        let before = buffer.count
        XCTAssertNil(SFTPWire.decode(from: &buffer))
        XCTAssertEqual(buffer.count, before)
    }

    /// An unmodelled reply is reported rather than silently skipped, so a
    /// peer answering something unexpected surfaces instead of hanging.
    func testAnUnknownPacketTypeIsReportedAndConsumed() {
        var buffer = SFTPWire.frame(.attrs, Data([0, 0, 0, 1]))
        XCTAssertEqual(SFTPWire.decode(from: &buffer), .other(type: 105))
        XCTAssertTrue(buffer.isEmpty)
    }

    // MARK: - Helpers

    private func statusPacket(id: UInt32, code: UInt32, message: String) -> Data {
        var body = Data()
        body.appendUInt32(id)
        body.appendUInt32(code)
        body.appendString(message)
        body.appendString("")
        return SFTPWire.frame(.status, body)
    }
}

private extension Data {
    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}

/// A LINK IS TYPED BY WHAT IT POINTS AT ([[WI-2026-08-29-002]]).
///
/// SSH_FXP_READDIR reports each entry as `lstat` does, so a symlink to a
/// directory arrives with the link's own type and nothing about its
/// target. The file pane showed it as a plain file that nothing could
/// open. The listing now asks SSH_FXP_STAT — which follows the link — for
/// each symlink it finds, and only for those.
final class SFTPSymlinkTests: XCTestCase {

    private func attributes(mode: UInt32) -> Data {
        var payload = Data()
        payload.appendUInt32(0x04)      // flags: permissions only
        payload.appendUInt32(mode)
        return payload
    }

    /// What a directory read says about a link, before anything resolves it.
    func testAReaddirEntryForALinkIsNotADirectory() {
        var attrs = SFTPWire.Attributes()
        attrs.permissions = 0xA1FF      // S_IFLNK | 0777
        XCTAssertTrue(attrs.isSymlink)
        XCTAssertFalse(attrs.isDirectory,
                       "a link's own type says nothing about what it points at")
    }

    /// And what the listing does with the answer.
    func testAResolvedLinkToADirectoryCanBeEntered() {
        var attrs = SFTPWire.Attributes()
        attrs.permissions = 0xA1FF
        attrs.resolvedIsDirectory = true
        XCTAssertTrue(attrs.isDirectory, "a link to a directory must be enterable")
        XCTAssertTrue(attrs.isSymlink, "and must still be known to BE a link")

        attrs.resolvedIsDirectory = false
        XCTAssertFalse(attrs.isDirectory, "a link to a file is not enterable")
    }

    /// A BROKEN LINK KEEPS ITS OWN TYPE. Nothing answers for the target, so
    /// the entry stays as the directory read described it rather than
    /// disappearing — the one file a human most needs to see.
    func testAnUnresolvedLinkKeepsWhatTheListingSaid() {
        var attrs = SFTPWire.Attributes()
        attrs.permissions = 0xA1FF
        XCTAssertNil(attrs.resolvedIsDirectory)
        XCTAssertFalse(attrs.isDirectory)
    }

    /// THE ANSWER TO A STAT IS READ AT ALL. `SSH_FXP_ATTRS` was in the
    /// packet-type table and had no branch in the decoder, so it came back
    /// as `.other(105)` and the resolution could not have worked.
    func testAnAttrsReplyIsRecognised() {
        var payload = Data()
        payload.appendUInt32(7)
        payload.append(attributes(mode: 0x41ED))   // S_IFDIR | 0755
        var buffer = SFTPWire.frame(.attrs, payload)

        guard case .attributes(let id, let attrs)? = SFTPWire.decode(from: &buffer) else {
            return XCTFail("a STAT reply decoded as something else")
        }
        XCTAssertEqual(id, 7)
        XCTAssertTrue(attrs.isDirectory)
        XCTAssertTrue(buffer.isEmpty, "a consumed packet leaves nothing behind")
    }

    /// The request the listing sends for a link, which must be STAT and not
    /// LSTAT — LSTAT would answer about the link again.
    func testTheResolutionAsksTheFollowingKind() {
        let packet = SFTPWire.request(.stat, id: 3, string: "/srv/link")
        XCTAssertEqual(packet[4], 17, "SSH_FXP_STAT follows a link; LSTAT (7) does not")
        XCTAssertTrue(String(decoding: packet, as: UTF8.self).contains("/srv/link"))
    }
}
