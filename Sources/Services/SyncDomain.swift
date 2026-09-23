import Foundation

/// What a sync layer is allowed to replicate, and nothing else.
///
/// The classification already exists (ConfigPaths: `shared` is the human's
/// intent, `machine` is this Mac and nothing else). This type is the
/// ENFORCEMENT of it — the single place a sync engine asks "may I send
/// this", so that no future sync code has to remember the rule.
///
/// The stake is named in [[RFC-0010]] C-COLLISION: identity.json is one of
/// exactly two ways two machines end up holding one peer id, and the
/// symptom is that every message between them is misrouted, with a manual
/// re-mint as the only remedy. A directory sync that reached
/// `machine/` would be that scenario automated and running continuously.
enum SyncDomain {

    /// The one directory a sync layer may replicate wholesale.
    static var root: URL { ConfigPaths.shared }

    /// Is this path inside the domain?
    ///
    /// SYMLINKS ARE RESOLVED FIRST, and that is the whole reason this is a
    /// function rather than a prefix comparison at each call site. A
    /// symlink sitting in `shared/` and pointing at `machine/identity.json`
    /// passes any string-prefix check and then hands the sync engine the
    /// exact file this split exists to keep off the wire. Nothing creates
    /// such a link today; the point is that nothing has to, for this to
    /// be the hole someone finds later.
    static func contains(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        // Compare PATH COMPONENTS, not strings: "…/shared-backup" has
        // "…/shared" as a string prefix and is not inside it.
        let r = resolved.pathComponents
        let b = base.pathComponents
        guard r.count >= b.count else { return false }
        return Array(r.prefix(b.count)) == b
    }

    /// Every file the sync layer may send, with anything that escapes the
    /// domain excluded rather than trusted.
    static func files() -> [URL] {
        let fm = FileManager.default
        guard
            let walker = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        var out: [URL] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            // Re-checked per file rather than assumed from the walk root:
            // the enumerator will happily descend through a symlinked
            // directory and hand back paths outside it.
            guard contains(url) else {
                AppLog.sync.error(
                    "refusing to sync \(url.lastPathComponent, privacy: .public): it resolves outside the shared directory")
                continue
            }
            // RESOLVED and standardized, so a caller comparing against a
            // path it built itself gets a match. macOS's temp dir is a
            // symlink (/var -> /private/var), so an enumerator URL and a
            // hand-built one for the SAME file compare unequal — which is
            // exactly the kind of mismatch that turns a sync into "it
            // uploaded nothing and said nothing".
            guard isSendableRecord(url) else { continue }
            out.append(url.resolvingSymlinksInPath().standardizedFileURL)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// A RECORD WITH NO FIELDS IS NOT A RECORD, and sending one can only
    /// create or overwrite nothing on the far side.
    ///
    /// Found on the operator's own machine: 64 host records containing
    /// `{}`, written by a test suite that was still using the real config
    /// root, and every one tracked in sync-base — so all 64 had been
    /// offered to CloudKit and would arrive on a second Mac as 64 empty
    /// files. The store steps over them (`try?` inside a `compactMap`),
    /// which is why nobody saw it; this layer enumerated anything shaped
    /// like a file.
    ///
    /// THE RULE IS ABOUT RECORDS, NOT FILES. `config.toml` is not JSON
    /// and must keep syncing, so a `.json` suffix is what marks a file as
    /// claiming to be one — phrased as "must parse", this would have
    /// quietly stopped replicating the GitHub configuration.
    static func isSendableRecord(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isSendableRecord(data, named: url.lastPathComponent)
    }

    /// The same judgement on bytes that have not been written yet, so what
    /// ARRIVES is held to the rule that governs what is sent. An outbound
    /// guard alone leaves the hole open at the end that matters.
    static func isSendableRecord(_ data: Data, named name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        guard url.pathExtension == "json" else { return true }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            // A half-written record is not one either, and a sync that
            // caught a file mid-write would replicate the truncation.
            AppLog.sync.error(
                "refusing to sync \(name, privacy: .public): it is not readable JSON")
            return false
        }
        guard let fields = object as? [String: Any] else { return true }
        if fields.isEmpty {
            AppLog.sync.error(
                "refusing to sync \(name, privacy: .public): a record with no fields")
            return false
        }
        return true
    }

    /// The record id a synced file is keyed by — stable across machines,
    /// which is what makes a set-union merge possible at all.
    static func recordID(for url: URL) -> String? {
        guard contains(url) else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let rel = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.dropFirst(base.count)
        return rel.isEmpty ? nil : rel.joined(separator: "/")
    }
}
