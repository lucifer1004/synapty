import Foundation

/// SFTP version 3 packet encoding, as a pure function of bytes.
///
/// WHY A CODEC AND NOT `ls`. The alternative to speaking the protocol is
/// parsing output meant for a person, and remote file names are the human's
/// to choose: a space, a quote, a newline, a name that looks like a column
/// header. Every one of those breaks a parser and none of them break this.
/// The subsystem also answers with types — a size is an integer and a
/// directory is a mode bit — rather than with a rendering of them.
///
/// SPLIT OUT FROM THE PROCESS THAT DRIVES IT so the wire format can be
/// tested against bytes rather than against a host. A framing bug is a
/// silent wrong answer, which is the kind a live test is worst at finding.
///
/// [[RFC-0013]] C-BROKER, [[WI-2026-08-15-009]]
enum SFTPWire {

    static let version: UInt32 = 3

    enum PacketType: UInt8 {
        case initialize = 1
        case version = 2
        case close = 4
        case openDir = 11
        case readDir = 12
        case realPath = 16
        /// FOLLOWS THE LINK, unlike the attributes a READDIR carries.
        /// A directory listing reports each entry as `lstat` does, so a
        /// symlink to a directory arrives typed as a link and nothing
        /// else — which is not enough to know whether it can be entered
        /// ([[WI-2026-08-29-002]]).
        case stat = 17
        // THE WRITE VERBS ([[RFC-0015]] C-PANE-WRITES: create, rename and
        // delete, and nothing else). Over the protocol rather than over a
        // shell, which is what makes a file named `%s\n"` — a real one,
        // found in a home directory on a real host — an ordinary string
        // instead of an injection.
        case remove = 13
        case mkdir = 14
        case rmdir = 15
        case rename = 18
        case status = 101
        case handle = 102
        case name = 104
        case attrs = 105
    }

    enum StatusCode: UInt32 {
        case ok = 0
        case eof = 1
        case noSuchFile = 2
        case permissionDenied = 3
        case failure = 4

        var message: String {
            switch self {
            case .ok: return "OK"
            case .eof: return "End of listing"
            case .noSuchFile: return "No such file or directory"
            case .permissionDenied: return "Permission denied"
            case .failure: return "The remote host refused the request"
            }
        }
    }

    // MARK: - Encoding

    /// Length-prefixed frame: uint32 length, then type and payload.
    static func frame(_ type: PacketType, _ payload: Data) -> Data {
        var out = Data()
        out.appendUInt32(UInt32(payload.count + 1))
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    static func initPacket() -> Data {
        var payload = Data()
        payload.appendUInt32(version)
        return frame(.initialize, payload)
    }

    static func request(_ type: PacketType, id: UInt32, string: String) -> Data {
        var payload = Data()
        payload.appendUInt32(id)
        payload.appendString(string)
        return frame(type, payload)
    }

    /// A request naming two paths — rename is the only one.
    static func request(_ type: PacketType, id: UInt32, from: String, to: String) -> Data {
        var payload = Data()
        payload.appendUInt32(id)
        payload.appendString(from)
        payload.appendString(to)
        return frame(type, payload)
    }

    /// MKDIR carries an attribute block; an empty one means "the defaults
    /// this account would get", which is what a human making a folder in a
    /// browser expects rather than a mode this application invented.
    static func mkdirRequest(id: UInt32, path: String) -> Data {
        var payload = Data()
        payload.appendUInt32(id)
        payload.appendString(path)
        payload.appendUInt32(0)   // flags: no attributes supplied
        return frame(.mkdir, payload)
    }

    // MARK: - Decoding

    struct Attributes: Equatable, Sendable {
        var size: Int64?
        var permissions: UInt32?
        var modified: Date?

        /// POSIX file-type bits. A listing that cannot tell a directory from
        /// a file cannot be navigated, and the type is in the mode rather
        /// than in a flag of its own.
        /// What a symlink POINTS AT, filled in by the listing after a
        /// second question the directory read cannot answer. `nil` on
        /// anything that is not a link, and on a link whose target is
        /// gone.
        var resolvedIsDirectory: Bool?

        /// Whether this entry can be ENTERED — the question a listing has
        /// to answer. A link is what it points at; everything else is
        /// itself.
        var isDirectory: Bool {
            if let resolvedIsDirectory { return resolvedIsDirectory }
            return (permissions.map { $0 & 0xF000 } ?? 0) == 0x4000
        }

        var isSymlink: Bool { (permissions.map { $0 & 0xF000 } ?? 0) == 0xA000 }
    }

    struct Entry: Equatable, Sendable {
        var name: String
        var attributes: Attributes
    }

    enum Response: Equatable, Sendable {
        case version(UInt32)
        case handle(id: UInt32, handle: Data)
        case names(id: UInt32, entries: [Entry])
        case status(id: UInt32, code: UInt32, message: String)
        /// One item's attributes, the answer to a STAT.
        case attributes(id: UInt32, attributes: Attributes)
        /// A type this reader does not model. Carried rather than thrown so
        /// a peer that answers something unexpected is a reportable fact and
        /// not a hang.
        case other(type: UInt8)
    }

    /// Pull one complete packet off the front of `buffer`, or return nil if
    /// there is not one there yet.
    ///
    /// A STREAM IS NOT A SEQUENCE OF PACKETS. A read returns whatever
    /// arrived, which may be half a packet or three of them; treating one
    /// read as one packet works until a listing is large enough to be split,
    /// which is exactly when it matters.
    static func decode(from buffer: inout Data) -> Response? {
        guard buffer.count >= 4 else { return nil }
        var reader = ByteReader(buffer)
        guard let length = reader.readUInt32(), length >= 1 else { return nil }
        guard buffer.count >= 4 + Int(length) else { return nil }
        guard let type = reader.readByte() else { return nil }

        // Everything after the type belongs to this packet and nothing else.
        var body = ByteReader(reader.remaining(limit: Int(length) - 1))
        defer { buffer.removeFirst(4 + Int(length)) }

        switch PacketType(rawValue: type) {
        case .version:
            return .version(body.readUInt32() ?? 0)

        case .handle:
            guard let id = body.readUInt32(), let handle = body.readBytes() else {
                return .other(type: type)
            }
            return .handle(id: id, handle: handle)

        case .status:
            guard let id = body.readUInt32(), let code = body.readUInt32() else {
                return .other(type: type)
            }
            // The message is advisory and some servers omit it.
            let message = body.readString() ?? ""
            return .status(id: id, code: code, message: message)

        case .name:
            guard let id = body.readUInt32(), let count = body.readUInt32() else {
                return .other(type: type)
            }
            var entries: [Entry] = []
            for _ in 0..<count {
                guard let name = body.readString() else { break }
                // The "longname" is the server's own `ls -l` rendering. It is
                // read to advance the cursor and then discarded: it is the
                // very thing this codec exists not to parse.
                _ = body.readString()
                guard let attrs = readAttributes(&body) else { break }
                entries.append(Entry(name: name, attributes: attrs))
            }
            return .names(id: id, entries: entries)

        case .attrs:
            guard let id = body.readUInt32(), let attrs = readAttributes(&body) else {
                return .other(type: type)
            }
            return .attributes(id: id, attributes: attrs)

        default:
            return .other(type: type)
        }
    }

    private static func readAttributes(_ reader: inout ByteReader) -> Attributes? {
        guard let flags = reader.readUInt32() else { return nil }
        var attrs = Attributes()
        if flags & 0x01 != 0 {
            attrs.size = reader.readUInt64().map { Int64(bitPattern: $0) }
        }
        if flags & 0x02 != 0 {
            _ = reader.readUInt32()  // uid
            _ = reader.readUInt32()  // gid
        }
        if flags & 0x04 != 0 {
            attrs.permissions = reader.readUInt32()
        }
        if flags & 0x08 != 0 {
            _ = reader.readUInt32()  // atime
            if let mtime = reader.readUInt32() {
                attrs.modified = Date(timeIntervalSince1970: TimeInterval(mtime))
            }
        }
        // Extended attributes are skipped rather than ignored: leaving them
        // in the stream would desynchronise every following entry.
        if flags & 0x8000_0000 != 0, let count = reader.readUInt32() {
            for _ in 0..<count {
                _ = reader.readBytes()
                _ = reader.readBytes()
            }
        }
        return attrs
    }
}

// MARK: - Byte plumbing

/// A cursor that never reads past its end. Every accessor returns nil
/// rather than trapping, because the bytes come from another machine and a
/// truncated or hostile packet must be a failed listing, not a crash.
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    mutating func readByte() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        defer { offset += 4 }
        var value: UInt32 = 0
        for i in 0..<4 {
            value = (value << 8) | UInt32(data[data.startIndex + offset + i])
        }
        return value
    }

    mutating func readUInt64() -> UInt64? {
        guard offset + 8 <= data.count else { return nil }
        defer { offset += 8 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return value
    }

    /// A length-prefixed byte string.
    mutating func readBytes() -> Data? {
        guard let length = readUInt32() else { return nil }
        guard offset + Int(length) <= data.count else { return nil }
        defer { offset += Int(length) }
        let start = data.startIndex + offset
        return data[start..<(start + Int(length))]
    }

    mutating func readString() -> String? {
        // Names are bytes, and a remote filesystem does not promise UTF-8.
        // A name that will not decode is shown as its replacement rather
        // than dropping the entry, so an odd file stays visible and stays
        // selectable.
        readBytes().map { String(decoding: $0, as: UTF8.self) }
    }

    func remaining(limit: Int) -> Data {
        let start = data.startIndex + offset
        let end = min(start + limit, data.endIndex)
        guard start <= end else { return Data() }
        return data[start..<end]
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendString(_ value: String) {
        let bytes = Data(value.utf8)
        appendUInt32(UInt32(bytes.count))
        append(bytes)
    }
}
