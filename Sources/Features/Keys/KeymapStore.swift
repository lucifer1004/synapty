import Foundation

/// WHERE THE HUMAN'S CHOICES LIVE ([[RFC-0016]] C-REBIND).
///
/// IN `shared/`, so they follow the person between machines rather than
/// belonging to the desk they are sitting at — the same side of
/// [[ConfigPaths]]'s line as the appearance they already carry with them.
/// The cost is stated in the clause and is not a defect to engineer away:
/// a rebind made because another application on THAT machine had taken a
/// chord arrives here where nothing had, and there is nothing to detect.
///
/// OVERRIDES ONLY, NEVER THE WHOLE TABLE. Storing the built table would
/// freeze every default the human never touched at the value it had on
/// the day they changed something else.
enum KeymapStore {

    static var url: URL { ConfigPaths.keymap }

    /// Injected by tests, which must never write the operator's real file.
    static var storageOverride: URL?

    private static var fileURL: URL {
        storageOverride.map { $0.appendingPathComponent(ConfigPaths.Entry.keymap.name) } ?? url
    }

    // MARK: - Reading and writing

    /// THE FILE SHAPE, chosen to be readable by the human who may edit it:
    ///
    ///     { "workbench.split-right": { "key": "d", "modifiers": 1 },
    ///       "terminal.copy":         null }
    ///
    /// A KEY PRESENT WITH `null` IS `none` — the command holds nothing,
    /// and the human said so. A key ABSENT is no override at all. JSON
    /// distinguishes the two natively, which is the whole reason the
    /// format can express what [[RFC-0016]] C-REBIND requires: recording a
    /// cleared command by omitting it would be indistinguishable from
    /// never having touched it, and every clearing would be undone by the
    /// next build.
    static func load() -> [String: Override] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Override].self, from: data)) ?? [:]
    }

    static func save(_ overrides: [String: Override]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(overrides).write(to: fileURL, options: .atomic)
    }

    // MARK: - Merging ([[RFC-0016]] C-CONFLICT)

    /// A MERGE MUST NOT PRODUCE A CONFLICT, and the generic merge cannot
    /// promise that on its own.
    ///
    /// [[RecordMerge]] is FIELD-WISE: it compares each key against the
    /// base and takes whichever side moved. Two machines that bind
    /// DIFFERENT commands to one chord touch different keys, so that merge
    /// reports no conflict and produces a file holding one chord against
    /// two commands — precisely the state C-CONFLICT forbids the workbench
    /// to write. Injectivity is a cross-field invariant and a field-wise
    /// merge is structurally blind to it.
    ///
    /// So a merged override set is normalised before it is stored: the
    /// same take rule, in the same stated order, with the loser left
    /// holding `none` on both sides exactly as a recording leaves it.
    /// Leaving it to the next build instead would satisfy the table and
    /// still put a conflict in the file.
    static func normalise(_ overrides: [String: Override]) -> (overrides: [String: Override],
                                                               displaced: [String]) {
        var holder: [Chord: String] = [:]
        var result = overrides
        var displaced: [String] = []
        for id in overrides.keys.sorted(by: byCodePoint) {
            guard case .chord(let chord) = overrides[id], chord.isBindable else { continue }
            if let loser = holder[chord] {
                // The loser is recorded as holding nothing, which is what a
                // recording would have written for it.
                result[loser] = Override.none
                displaced.append(loser)
            }
            holder[chord] = id
        }
        return (result, displaced)
    }

    /// The same normalisation over raw bytes, for the sync layer — which
    /// merges files rather than override sets and must not write a
    /// conflict into one ([[RFC-0016]] C-CONFLICT).
    static func normalised(_ data: Data) -> Data? {
        guard let overrides = try? JSONDecoder().decode([String: Override].self, from: data)
        else { return nil }
        let (result, displaced) = normalise(overrides)
        guard !displaced.isEmpty else { return data }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(result)
    }

    private static func byCodePoint(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }
}

extension Override: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .chord(try container.decode(Chord.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none: try container.encodeNil()
        case .chord(let chord): try container.encode(chord)
        }
    }
}
