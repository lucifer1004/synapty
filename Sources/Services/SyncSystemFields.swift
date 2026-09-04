import CloudKit
import Foundation

/// The server's own metadata for a record — most importantly its change
/// tag — kept so a second save is an UPDATE rather than an INSERT.
///
/// A CKRecord built fresh from `CKRecord(recordType:recordID:)` carries no
/// change tag, and CloudKit reads that as "insert this". The first upload
/// therefore succeeds and every one after it fails with "record to insert
/// already exists" — so a machine can seed the container once and then
/// never push another change, while reporting itself as syncing. Which is
/// exactly what it did.
///
/// MACHINE-SCOPED, like the merge base and the engine's state: it records
/// what THIS Mac last heard from the server. Replicating it would hand
/// another machine change tags it never received.
enum SyncSystemFields {

    static var root: URL { ConfigPaths.machine.appendingPathComponent("sync-meta") }

    private static func url(for path: String) -> URL {
        root.appendingPathComponent(SyncRecord.recordName(for: path))
    }

    /// Rebuild the record the server knows about, or nil when this machine
    /// has never seen one — in which case an insert is correct.
    static func record(for path: String) -> CKRecord? {
        guard let data = try? Data(contentsOf: url(for: path)) else { return nil }
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }

    /// Remember what the server said. Called after a save is accepted and
    /// after a fetch — the two moments this machine has a current tag.
    static func remember(_ record: CKRecord, path: String) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            // System fields ONLY: the values travel in the record we build
            // from the file, and storing them here would be a second copy
            // that can disagree with the first.
            record.encodeSystemFields(with: coder)
            try coder.encodedData.write(to: url(for: path), options: .atomic)
        } catch {
            AppLog.sync.error(
                "could not remember the server tag for \(path, privacy: .public): \(error.localizedDescription, privacy: .public) — the next save of this record will be refused as a duplicate insert")
        }
    }

    static func forget(_ path: String) {
        try? FileManager.default.removeItem(at: url(for: path))
    }
}
