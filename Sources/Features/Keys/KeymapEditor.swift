import Foundation

/// THE HUMAN'S ACTS ON THE TABLE ([[RFC-0016]] C-REBIND, C-CONFLICT) —
/// recording a chord, clearing one, and getting a default back.
///
/// PURE, AND SEPARATE FROM THE PANEL. Every rule here is one a review round
/// argued about, so each is a function over values that a test can put a
/// case to; what the panel adds is pixels and a place to press a key.
enum KeymapEditor {

    /// What an act did, in the terms the human must be shown.
    enum Outcome: Equatable {
        /// Recorded. `displaced` names the command that lost the chord —
        /// which MUST be named at that moment ([[RFC-0016]] C-CONFLICT).
        case recorded(displaced: String?)
        case cleared
        /// The default came back.
        case recovered
        /// On the closed list ([[RFC-0016]] C-CHORD).
        case refused
        /// Not a chord at all — the recorder says which rule failed and
        /// goes on listening.
        case notAChord
        /// Recovery only: the default chord is held by another command's
        /// override, so removing an override this command does not have
        /// would quietly do nothing. Names the holder, which is the one
        /// fact that lets the human act.
        case defaultHeldBy(String)
    }

    /// RECORDING A CHORD THAT ANOTHER COMMAND HOLDS TAKES IT, and the
    /// loser's new state is written as its own override — a displacement
    /// stores BOTH sides, or the store cannot reproduce the table the
    /// human was looking at.
    static func record(_ chord: Chord, for id: String,
                       in overrides: inout [String: Override],
                       effective: Keymap) -> Outcome {
        switch chord.verdict {
        case .notAChord: return .notAChord
        case .refused: return .refused
        case .accepted: break
        }
        var displaced: String?
        if let holder = effective.command(for: chord), holder != id {
            overrides[holder] = Override.none
            displaced = holder
        }
        overrides[id] = .chord(chord)
        return .recorded(displaced: displaced)
    }

    /// Clearing is an act of its own, and it is STORED — `none` is a value
    /// and not an absence.
    static func clear(_ id: String, in overrides: inout [String: Override]) -> Outcome {
        overrides[id] = Override.none
        return .cleared
    }

    /// RECOVERING A DEFAULT REMOVES THE OVERRIDE rather than storing the
    /// default as one, so a default the workbench corrects later still
    /// reaches this human.
    ///
    /// AND IS UNAVAILABLE WHERE THE DEFAULT IS NOT FREE: recovery MUST NOT
    /// displace, because the human is asking to undo their own change, not
    /// to make a new one at a third command's expense.
    static func recoverDefault(of id: String,
                               in overrides: inout [String: Override],
                               commands: [KeyCommand],
                               effective: Keymap) -> Outcome {
        guard let command = commands.first(where: { $0.id == id }) else { return .recovered }
        if let wanted = command.defaultChord,
           let holder = effective.command(for: wanted), holder != id {
            return .defaultHeldBy(holder)
        }
        overrides.removeValue(forKey: id)
        return .recovered
    }

    /// REBINDING AN INDEXED FAMILY ([[RFC-0016]] C-TABLE): one act over
    /// nine commands. Only the MODIFIER is taken from the chord the human
    /// pressed — the digit they happened to hit is theirs, not the
    /// family's — and each member is then recorded on that modifier over
    /// its own index, displacing whatever held it exactly as a single
    /// recording would.
    static func recordFamily(_ modifiers: Chord.Modifiers, family: String,
                             in overrides: inout [String: Override],
                             commands: [KeyCommand],
                             effective: Keymap) -> Outcome {
        let members = commands.filter { $0.family == family }
        guard !members.isEmpty else { return .notAChord }
        // Judged ONCE, on the modifier: the nine chords differ only in a
        // digit, so a verdict on one is a verdict on all.
        switch Chord(.character("1"), modifiers).verdict {
        case .notAChord: return .notAChord
        case .refused: return .refused
        case .accepted: break
        }
        var displaced: String?
        for member in members {
            guard let index = member.id.split(separator: "-").last,
                  let digit = index.first else { continue }
            let chord = Chord(.character(digit), modifiers)
            if let holder = effective.command(for: chord),
               holder != member.id, commands.first(where: { $0.id == holder })?.family != family {
                overrides[holder] = Override.none
                displaced = displaced ?? holder
            }
            overrides[member.id] = .chord(chord)
        }
        return .recorded(displaced: displaced)
    }

    /// And recovered as a unit — nine overrides removed, not one.
    static func recoverFamily(_ family: String, in overrides: inout [String: Override],
                              commands: [KeyCommand]) -> Outcome {
        for member in commands where member.family == family {
            overrides.removeValue(forKey: member.id)
        }
        return .recovered
    }

    /// Whole-table recovery, which is the one act that also undoes a
    /// displacement: every override goes, so both sides of it do.
    static func recoverAllDefaults(in overrides: inout [String: Override]) {
        overrides.removeAll()
    }
}
