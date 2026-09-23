import Foundation

/// The last version this machine and the server agreed on, per record.
///
/// It exists for one reason: [[WI-2026-08-13-005]] forbids resolving a
/// concurrent edit by discarding a side, and RecordMerge cannot do better
/// than a guess without a common ancestor. CloudKit does not supply one —
/// it hands back the server record and the client record and nothing else
/// — so the ancestor has to be remembered locally.
///
/// MACHINE-SCOPED, and not as a filing convenience. This is bookkeeping
/// about what THIS Mac last saw; replicating it would tell another machine
/// it had agreed to something it never saw, which is worse than having no
/// base at all — a wrong ancestor produces a confident merge instead of an
/// honest conflict. SyncDomain already refuses to send anything under
/// `machine/`, and a test pins that this directory is on that side.
enum SyncBaseStore {

    static var root: URL { ConfigPaths.machine.appendingPathComponent("sync-base") }

    private static func url(for path: String) -> URL {
        root.appendingPathComponent(SyncRecord.recordName(for: path))
    }

    /// The agreed-upon version, or nil when this machine has never synced
    /// this record. Nil is a real answer and RecordMerge treats it as one.
    static func base(for path: String) -> [String: JSONValue]? {
        guard let data = try? Data(contentsOf: url(for: path)) else { return nil }
        return JSONValue.object(fromJSON: data)
    }

    /// Record agreement. Called after a send is accepted and after a fetch
    /// is applied — the two moments the two sides are known to match.
    static func setBase(for path: String, contents: Data) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try contents.write(to: url(for: path), options: .atomic)
        } catch {
            // Not fatal, and not silent. Losing a base costs precision on
            // the NEXT conflict — it degrades to "every difference is a
            // conflict", which is the honest fallback rather than a wrong
            // merge. Worth saying so nobody debugs the symptom later.
            AppLog.sync.error(
                "could not record sync base for \(path, privacy: .public): \(error.localizedDescription, privacy: .public) — the next conflict on this record will be reported field-by-field instead of merged")
        }
    }

    static func forget(_ path: String) {
        try? FileManager.default.removeItem(at: url(for: path))
    }
}
