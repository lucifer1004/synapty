import Foundation

/// ONE KEY AND ITS MODIFIERS ([[RFC-0016]] C-CHORD).
///
/// A value type with no reference to AppKit, so the rules that decide what
/// may be a chord can be tested without an event, a window or a responder.
struct Chord: Equatable, Hashable, Codable {

    /// THE KEY IS EITHER A CHARACTER KEY OR ONE OF A NAMED SET.
    ///
    /// The named set exists because a specification admitting only
    /// characters could not express the arrows or escape, which
    /// [[RFC-0016]] C-TABLE requires in the table.
    enum Key: Equatable, Hashable {
        /// Named by the character the key produces WITH NO MODIFIERS
        /// APPLIED — so a chord recorded with shift held is recognisable
        /// as itself.
        case character(Character)
        case named(NamedKey)
    }

    enum NamedKey: String, Equatable, Hashable, Codable, CaseIterable {
        case escape, tab, `return`, delete, forwardDelete
        case up, down, left, right
        case home, end, pageUp, pageDown
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    }

    struct Modifiers: OptionSet, Equatable, Hashable, Codable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        static let command = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let option  = Modifiers(rawValue: 1 << 2)
        static let shift   = Modifiers(rawValue: 1 << 3)

        /// The three that make a keystroke a chord rather than a character.
        static let qualifying: Modifiers = [.command, .control, .option]
    }

    let key: Key
    let modifiers: Modifiers

    // The store is a file a human may read and write ([[RFC-0016]]
    // C-REBIND), so a chord is written as text a person can recognise —
    // `"k"` or `"escape"` — rather than as an enum's synthesised shape.
    // `Character` has no Codable conformance of its own, which is why this
    // is written out.
    private enum CodingKeys: String, CodingKey { case key, modifiers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .key)
        if let named = NamedKey(rawValue: raw) {
            key = .named(named)
        } else if raw.count == 1 {
            key = .character(Character(raw))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .key, in: container,
                debugDescription: "not a character key or a named key: \(raw)")
        }
        modifiers = Modifiers(rawValue: try container.decode(Int.self, forKey: .modifiers))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch key {
        case .character(let c): try container.encode(String(c), forKey: .key)
        case .named(let n): try container.encode(n.rawValue, forKey: .key)
        }
        try container.encode(modifiers.rawValue, forKey: .modifiers)
    }

    init(_ key: Key, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// From what a keyboard event reports. The UNSHIFTED character is the
    /// one that names the chord; the shifted one is carried only so this
    /// initializer can be handed both without the caller choosing.
    init(fromCharacters _: String, unshifted: String, modifiers: Modifiers) {
        self.init(.character(Character(unshifted.lowercased())), modifiers)
    }

    // MARK: - What may be bound

    /// TWO REJECTIONS WEARING ONE WORD WOULD BE A MISTAKE ([[RFC-0016]]
    /// C-CHORD): refusing a listed chord says this chord may not be bound;
    /// rejecting a keystroke that is not a chord says what was pressed is
    /// not a chord at all, and the recorder goes on listening.
    enum Verdict: Equatable {
        case accepted
        case notAChord
        case refused
    }

    /// THE CLOSED LIST, published here and in the workbench's documentation.
    ///
    /// ⌘, IS DELIBERATELY ABSENT. Opening this workbench's own settings is
    /// an act of the workbench ([[RFC-0016]] C-TABLE) and therefore a
    /// command in the table like any other, so the chord convention gives
    /// it must be bindable to it. ⌘Tab is absent for a different reason:
    /// the window server consumes it, so it never arrives to be refused,
    /// and an obligation no implementation can discharge is worse than no
    /// obligation at all.
    static let refused: Set<Chord> = [
        Chord(.character("q"), [.command]),
        Chord(.character("h"), [.command]),
        Chord(.character("m"), [.command]),
    ]

    var verdict: Verdict {
        guard !modifiers.intersection(.qualifying).isEmpty else { return .notAChord }
        return Self.refused.contains(self) ? .refused : .accepted
    }

    var isBindable: Bool { verdict == .accepted }
}

extension Chord {
    /// How a chord is written for a human — the platform's glyphs, in the
    /// platform's order.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let c): text += String(c).uppercased()
        case .named(let named): text += named.display
        }
        return text
    }
}

extension Chord.NamedKey {
    var display: String {
        switch self {
        case .escape: return "esc"
        case .tab: return "⇥"
        case .return: return "↩"
        case .delete: return "⌫"
        case .forwardDelete: return "⌦"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }
}
