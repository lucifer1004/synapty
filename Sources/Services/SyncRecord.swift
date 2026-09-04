import CloudKit
import Foundation

/// How a file in the sync domain becomes a CloudKit record and back.
///
/// Separated from the engine because this half is pure and therefore
/// testable, while the engine half needs an account, a network and a
/// second Mac. The bugs that hide here — a name that does not round-trip,
/// a path that collides — produce records that upload fine and land in the
/// wrong file, which is the kind of failure that looks like data loss.
enum SyncRecord {

    static let zoneName = "SynaptyConfig"
    static let recordType = "ConfigFile"
    /// The relative path (`hosts/ABC-123.json`). Carried as a FIELD rather
    /// than inferred from the record name, because the name is sanitized
    /// and sanitization is not always reversible.
    static let pathKey = "path"
    static let dataKey = "data"

    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName) }

    /// CKRecord names accept ASCII letters, digits, `-`, `_` and `.` — not
    /// `/`, which every relative path in the domain contains. Percent-
    /// encoding the separator keeps the name stable, unique and readable,
    /// and the true path travels in its own field regardless.
    static func recordName(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "_")
    }

    static func recordID(for path: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(for: path), zoneID: zoneID)
    }

    /// Build the record for a file. Returns nil when the file cannot be
    /// read, rather than uploading an empty record over a good one —
    /// a failed read is not an empty file.
    static func makeRecord(path: String, contents: Data) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(for: path))
        record[pathKey] = path as CKRecordValue
        record[dataKey] = contents as CKRecordValue
        return record
    }

    /// The (path, contents) a fetched record carries, or nil if it carries
    /// neither — a record missing its path is not routable and guessing
    /// from the sanitized name is how a file lands somewhere else.
    static func decode(_ record: CKRecord) -> (path: String, contents: Data)? {
        guard let path = record[pathKey] as? String, !path.isEmpty,
              let data = record[dataKey] as? Data
        else { return nil }
        // A path that escapes the domain must be refused even when it
        // arrives signed and encrypted from our own account: another
        // machine running an older or modified build is still another
        // machine.
        guard isSafeRelativePath(path) else { return nil }
        return (path, data)
    }

    /// Relative, no traversal, no absolute anchor. `../../machine/identity.json`
    /// is the attack this rejects, and it costs one function to close.
    static func isSafeRelativePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.isEmpty { return false }
        for p in parts {
            if p.isEmpty || p == ".." || p == "." { return false }
        }
        return true
    }
}
