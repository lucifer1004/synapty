import Foundation

/// Merge two versions of one record without discarding either side.
///
/// [[WI-2026-08-13-005]] forbids the easy answer: "a concurrent edit to
/// the same host is merged or surfaced, never silently resolved by
/// discarding one side". Last-writer-wins is one line, and it loses an
/// edit the human made and watched succeed.
///
/// THREE-WAY, BECAUSE TWO-WAY CANNOT ANSWER THE QUESTION. CloudKit hands
/// back the server record and the client record on conflict, and nothing
/// else. From those two alone you can see THAT two versions differ; you
/// cannot see WHO CHANGED WHAT, which is the only thing that makes a
/// merge safe rather than a guess. So the last synced version is kept
/// locally as the base — machine-scoped bookkeeping that must itself
/// never sync, which SyncDomain already enforces.
///
/// Without a base the merge degrades HONESTLY: every differing field is a
/// conflict, rather than a silent pick that looks like a merge.
enum RecordMerge {

    struct Result: Equatable {
        /// The record to write. Conflicted fields keep OUR value — a
        /// local edit stays visible on the machine that made it while the
        /// human decides, rather than being replaced under their cursor.
        let merged: [String: JSONValue]
        /// Fields where both sides moved away from the base, or where
        /// there was no base to judge by. Non-empty means the human is
        /// told; it does NOT mean the merge failed.
        let conflicts: [String]
        /// What the other side had for each conflicted field, so the
        /// choice can be offered rather than merely announced.
        let theirs: [String: JSONValue]

        var isClean: Bool { conflicts.isEmpty }
    }

    /// Merge `ours` and `theirs` relative to `base` (the last version both
    /// machines agreed on, or nil when this machine has never synced this
    /// record).
    static func threeWay(
        base: [String: JSONValue]?,
        ours: [String: JSONValue],
        theirs: [String: JSONValue]
    ) -> Result {
        var merged: [String: JSONValue] = [:]
        var conflicts: [String] = []
        var conflictingTheirs: [String: JSONValue] = [:]

        for key in Set(ours.keys).union(theirs.keys).sorted() {
            let o = ours[key]
            let t = theirs[key]

            // Agreement needs no arbitration, including agreement that a
            // field is absent.
            if o == t {
                if let v = o { merged[key] = v }
                continue
            }

            guard let b = base?[key] ?? (base == nil ? nil : JSONValue.null) else {
                // No base at all: this machine has never synced this
                // record, so nothing here can distinguish "I changed it"
                // from "they changed it". Every difference is a conflict.
                // Degrading to last-writer-wins here is exactly the
                // silent loss this type exists to prevent.
                if let v = o { merged[key] = v } else if let v = t { merged[key] = v }
                conflicts.append(key)
                if let v = t { conflictingTheirs[key] = v }
                continue
            }

            let ourValue = o ?? .null
            let theirValue = t ?? .null

            if ourValue == b {
                // Only they moved. Take theirs — including a deletion.
                if let v = t { merged[key] = v }
            } else if theirValue == b {
                // Only we moved.
                if let v = o { merged[key] = v }
            } else {
                // Both moved, and to different places. KEEP OURS and say
                // so: the human on this machine made this edit and is
                // looking at it, and replacing it under their cursor is
                // the more surprising of the two wrong answers.
                if let v = o { merged[key] = v }
                conflicts.append(key)
                if let v = t { conflictingTheirs[key] = v }
            }
        }

        return Result(merged: merged, conflicts: conflicts, theirs: conflictingTheirs)
    }
}

/// A JSON value that is Equatable, so a merge can compare fields without
/// reaching for NSObject bridging or re-encoding on every comparison.
enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init?(any: Any) {
        switch any {
        case let v as String: self = .string(v)
        case let v as Bool where type(of: any) == type(of: true): self = .bool(v)
        case let v as NSNumber:
            // NSNumber bridges both; booleans must not become 1 and 0 or
            // a merge would treat `true` and `1` as the same edit.
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue) }
            else { self = .number(v.doubleValue) }
        case is NSNull: self = .null
        case let v as [Any]: self = .array(v.compactMap(JSONValue.init(any:)))
        case let v as [String: Any]:
            var o: [String: JSONValue] = [:]
            for (k, x) in v { if let j = JSONValue(any: x) { o[k] = j } }
            self = .object(o)
        default: return nil
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v == v.rounded() ? Int(v) : v
        case .bool(let v): return v
        case .null: return NSNull()
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        }
    }

    static func object(fromJSON data: Data) -> [String: JSONValue]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: JSONValue] = [:]
        for (k, v) in raw { if let j = JSONValue(any: v) { out[k] = j } }
        return out
    }

    static func data(from object: [String: JSONValue]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object.mapValues(\.anyValue), options: [.sortedKeys])
    }
}
