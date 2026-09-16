import Foundation

/// WHICH MACHINE THE COMMAND'S EFFECT LANDS ON ([[RFC-0016]] C-TABLE).
enum KeyDomain: Equatable {
    /// An act of the workbench: it runs against the active workspace and
    /// its focused pane, whatever holds first responder.
    case workbench
    /// An act of the terminal, dispatched as an engine action against the
    /// terminal the focus is in or belongs to — and nowhere else.
    case terminal
}

/// WHERE THE COMMAND IS REACHED WITHOUT A CHORD.
///
/// Not optional, and that is the point: [[RFC-0016]] C-UNBOUND requires
/// every command in the table to have one, so a command cannot be
/// constructed without saying where. Clearing a chord then removes a
/// shortcut and never a capability.
enum NonKeyboardPath: Equatable {
    /// In the menu bar. WHICH menu is [[MenuLayout]]'s answer and not a
    /// string written beside the row: a string written here is a claim
    /// about a structure it cannot see, and it had gone stale — two
    /// commands built into File advertised themselves as View's, and the
    /// three indexed families named a submenu level that is not in the
    /// path they printed.
    case menu
    /// A control in the workbench's own chrome, named here because
    /// nothing else knows it.
    case control(String)
}

/// A ROW OF THE TABLE ([[RFC-0016]] C-TABLE).
struct KeyCommand: Equatable, Identifiable {
    /// TEXT, stable, and what a stored override names — never a position
    /// in a list, and unchanged when `name` changes.
    let id: String
    let name: String
    /// `nil` is `none`: the same holds-nothing state a human reaches by
    /// clearing, spelled the same way throughout.
    let defaultChord: Chord?
    let domain: KeyDomain
    /// Consulted in exactly ONE place — row 2 of the dispatch function,
    /// where a text-entry surface BELONGING TO A TERMINAL LEAF has focus.
    /// Meaningless for a `workbench` command.
    let yieldsToTextEntry: Bool
    let nonKeyboardPath: NonKeyboardPath
    /// The INDEXED FAMILY this belongs to, if any ([[RFC-0016]] C-TABLE).
    /// A member is an ordinary command in every respect the dispatcher and
    /// the injectivity rules care about; what the family changes is what
    /// the HUMAN may edit — the modifier, for all nine at once.
    let family: String?

    init(id: String, name: String, defaultChord: Chord?, domain: KeyDomain,
         yieldsToTextEntry: Bool = false, nonKeyboardPath: NonKeyboardPath,
         family: String? = nil) {
        self.family = family
        self.id = id
        self.name = name
        self.defaultChord = defaultChord
        self.domain = domain
        self.yieldsToTextEntry = yieldsToTextEntry
        self.nonKeyboardPath = nonKeyboardPath
    }

    /// WHAT THE HUMAN IS TOLD TO WALK ([[RFC-0016]] C-UNBOUND), built
    /// from the menu the item is actually in and the label it actually
    /// carries — the item's label IS this row's `name`.
    var nonKeyboardPathDescription: String {
        switch nonKeyboardPath {
        case .control(let place):
            return place
        case .menu:
            return ((MenuLayout.chain(of: id) ?? []) + [name]).joined(separator: " ▸ ")
        }
    }
}

/// WHAT THE HUMAN CHANGED ([[RFC-0016]] C-REBIND).
///
/// `none` IS A VALUE AND NOT AN ABSENCE. Recording a cleared command by
/// storing no override at all is indistinguishable from never having
/// touched it, and the table is rebuilt from the defaults every time — so
/// every clearing would be undone by the next launch, handing back the
/// chord the human removed BECAUSE another application had taken it.
enum Override: Equatable {
    case chord(Chord)
    case none
}

/// THE EFFECTIVE TABLE, which is ALWAYS `build(defaults, overrides)`
/// ([[RFC-0016]] C-CONFLICT).
///
/// There is one construction and no incremental one. Mutating a live table
/// in place is a reasonable thing to build and gives a DIFFERENT answer:
/// removing an override that was displacing another command would leave
/// that command holding nothing for the rest of the session and hand its
/// binding back only after a relaunch.
struct Keymap {

    struct Discarded: Equatable {
        enum Reason: Equatable {
            case unknownCommand
            case notAChord
            case refused
        }
        let commandID: String
        let reason: Reason
    }

    private(set) var commands: [String: KeyCommand] = [:]
    /// command id → the chord it holds. A command holding nothing is absent
    /// from this map, which is what keeps the map injective: a command
    /// holding nothing is not in it and cannot collide with anything.
    private(set) var bindings: [String: Chord] = [:]
    /// The inverse, maintained together with `bindings` so resolution is a
    /// lookup rather than a scan.
    private(set) var holders: [Chord: String] = [:]

    /// WHAT WAS DISCARDED OR DISPLACED AT LOAD MUST BE VISIBLE where
    /// bindings are shown — so the build reports both rather than
    /// swallowing them.
    private(set) var discarded: [Discarded] = []
    private(set) var displacedAtLoad: [String] = []

    // MARK: - Building

    /// THE TABLE IS BUILT FROM THE DEFAULTS, THEN EACH OVERRIDE IS APPLIED
    /// AS IF IT HAD JUST BEEN RECORDED, in ascending order of command
    /// identifier compared by Unicode code point.
    ///
    /// The order is stated so that it is a CHOSEN one, and the rule is the
    /// recording rule so that there are not two resolutions to keep in
    /// step. In the ordinary case the order changes nothing, because a
    /// recorded displacement stores both sides — it decides only what
    /// happens when something moved underneath the human: a default that
    /// changed between builds, or a line written into the store by hand.
    static func build(commands: [KeyCommand], overrides: [String: Override]) -> Keymap {
        var map = Keymap()
        for command in commands {
            map.commands[command.id] = command
        }
        // Defaults first, in the same stated order — two commands shipped
        // on one chord is a well-formedness defect ([[RFC-0016]]
        // C-CONFLICT), and resolving it the same way as everything else
        // keeps the table injective even when the table is malformed.
        for command in commands.sorted(by: Self.byCodePoint) {
            guard let chord = command.defaultChord else { continue }
            map.take(chord, for: command.id, atLoad: true)
        }
        for id in overrides.keys.sorted(by: { Self.byCodePoint($0, $1) }) {
            map.apply(overrides[id]!, to: id)
        }
        // WHAT THE FINISHED TABLE LOST, not a log of what happened on the
        // way to it. A command displaced by one override and given another
        // chord by a later one holds a chord at the end, and reporting it
        // as displaced would tell the human they had lost something they
        // still have ([[RFC-0016]] C-CONFLICT).
        map.displacedAtLoad = map.displacedAtLoad.filter { map.bindings[$0] == nil }
        return map
    }

    /// WHAT THE LOAD DROPPED OR TOOK AWAY, in one sentence, or nil when it
    /// dropped and took nothing.
    ///
    /// [[RFC-0016]] C-CONFLICT: "WHAT WAS DISCARDED OR DISPLACED AT LOAD
    /// MUST BE VISIBLE where bindings are shown. Silently dropping the
    /// human's choice and silently keeping a broken one are equally bad."
    /// Both facts were computed here and read by nothing
    /// ([[WI-2026-08-30-008]]).
    ///
    /// THE WORDING LIVES HERE, once, so the two surfaces that list
    /// bindings cannot describe the same load differently. The switch is
    /// exhaustive: a fourth reason cannot be added without a sentence.
    var loadNotice: String? {
        var parts: [String] = []
        if !displacedAtLoad.isEmpty {
            let names = displacedAtLoad.map { commands[$0]?.name ?? $0 }.sorted()
            parts.append("\(names.joined(separator: ", ")) held nothing after this file was read — "
                + "something else in it took the chord.")
        }
        for drop in discarded.sorted(by: { Self.byCodePoint($0.commandID, $1.commandID) }) {
            let name = commands[drop.commandID]?.name ?? drop.commandID
            switch drop.reason {
            case .unknownCommand:
                parts.append("\(name) is not a command this build has, so its line was ignored.")
            case .notAChord:
                parts.append("\(name)'s line is not a chord, so it was ignored.")
            case .refused:
                parts.append("\(name)'s chord is one this workbench will not take, so it was ignored.")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// AS IF IT HAD JUST BEEN RECORDED imports the RESOLUTION rule and
    /// nothing else — not the write that a recording performs, and not the
    /// naming of the displaced command, which at load has no moment to
    /// happen in and no one to happen to.
    private mutating func apply(_ override: Override, to id: String) {
        guard commands[id] != nil else {
            discarded.append(.init(commandID: id, reason: .unknownCommand))
            return
        }
        switch override {
        case .none:
            release(id)
        case .chord(let chord):
            switch chord.verdict {
            case .notAChord:
                discarded.append(.init(commandID: id, reason: .notAChord))
            case .refused:
                discarded.append(.init(commandID: id, reason: .refused))
            case .accepted:
                take(chord, for: id, atLoad: true)
            }
        }
    }

    /// RECORDING A CHORD THAT ANOTHER COMMAND HOLDS TAKES IT.
    private mutating func take(_ chord: Chord, for id: String, atLoad: Bool) {
        if let loser = holders[chord], loser != id {
            bindings.removeValue(forKey: loser)
            if atLoad { displacedAtLoad.append(loser) }
        }
        if let previous = bindings[id] { holders.removeValue(forKey: previous) }
        bindings[id] = chord
        holders[chord] = id
    }

    private mutating func release(_ id: String) {
        if let chord = bindings.removeValue(forKey: id) { holders.removeValue(forKey: chord) }
    }

    /// Ascending by Unicode code point — not by Swift's default String
    /// ordering, which compares by canonical equivalence and would make the
    /// stated order depend on normalisation.
    private static func byCodePoint(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    private static func byCodePoint(_ a: KeyCommand, _ b: KeyCommand) -> Bool {
        byCodePoint(a.id, b.id)
    }

    // MARK: - Reading

    func chord(of id: String) -> Chord? { bindings[id] }

    /// WHETHER A COMMAND HOLDS NOTHING ([[RFC-0016]] C-UNBOUND).
    ///
    /// Named because the clause names it, and because a surface that has
    /// to say so — a row offering a non-keyboard path instead of a chord,
    /// a Clear button with nothing to clear — must not each decide it.
    func holdsNothing(_ id: String) -> Bool { bindings[id] == nil }

    /// WHETHER A COMMAND HAS BEEN MOVED OFF WHAT SHIPPED
    /// ([[RFC-0016]] C-DISCOVERY: a surface listing the table marks those
    /// that differ from their default).
    ///
    /// ONE OWNER. Two surfaces list the table — the shortcuts reference
    /// and the pane bindings are edited on — and each carried its own
    /// private copy of this comparison. They agreed, which is the only
    /// state a duplicated rule is ever found in until it does not: the day
    /// "differs" learns about a cleared binding, one surface would say
    /// "changed" and the other would not, about the same row.
    func differsFromDefault(_ command: KeyCommand) -> Bool {
        chord(of: command.id) != command.defaultChord
    }
    func command(for chord: Chord) -> String? { holders[chord] }
    var allChords: [Chord] { Array(bindings.values) }
}

// MARK: - Dispatch ([[RFC-0016]] C-DISPATCH)

/// THE FOCUSED SURFACE, classified by THE FIRST ROW THAT MATCHES.
///
/// Ordering rather than disjointness, because the categories genuinely
/// overlap — a terminal's tab-rename field is both a text field and
/// workbench chrome, and a leaf mid-dial is a terminal leaf with no
/// terminal in it. Saying which row wins is what makes the function total.
enum FocusedSurface: Equatable {
    /// Row 1.
    case recorder
    /// Row 2 — its find field, its tab's rename field. Carries whether the
    /// leaf actually has a terminal: a leaf that is dialling or has failed
    /// draws workbench chrome with nothing behind it to act on.
    case textEntryOfTerminalLeaf(hasLiveTerminal: Bool)
    /// Row 3 — a terminal leaf whose connection is up and whose terminal
    /// exists.
    case liveTerminal
    /// Row 4 — the catch-all: another kind of leaf, a leaf that is
    /// dialling or has failed, an empty workspace, a page over the layout,
    /// the workbench's own chrome. A new kind of surface lands here unless
    /// a row is added above it, which is the safe direction.
    case other
}

enum KeyOutcome: Equatable {
    case recording
    case runWorkbench(String)
    case runTerminal(String)
    case toTerminalAsInput
    case toResponderChain
}

extension Keymap {
    /// The twelve cells, as a function.
    func resolve(_ chord: Chord, in surface: FocusedSurface) -> KeyOutcome {
        // Row 1 first: while a surface is recording, NO command is
        // dispatched, because a human recording ⌘W must not thereby close
        // a pane.
        if case .recorder = surface { return .recording }

        guard let id = command(for: chord), let command = commands[id] else {
            // THE ONLY CELL THAT REACHES THE SHELL. "Offered to the
            // terminal" is an obligation and not a default: a terminal
            // surface answers YES to every command-modified key equivalent
            // it is given, so a chord the table does not claim reaches the
            // human's shell because the workbench passed it there.
            if case .liveTerminal = surface { return .toTerminalAsInput }
            return .toResponderChain
        }

        switch command.domain {
        case .workbench:
            return .runWorkbench(id)
        case .terminal:
            switch surface {
            case .textEntryOfTerminalLeaf(let hasLiveTerminal):
                guard hasLiveTerminal, !command.yieldsToTextEntry else { return .toResponderChain }
                return .runTerminal(id)
            case .liveTerminal:
                return .runTerminal(id)
            case .other, .recorder:
                return .toResponderChain
            }
        }
    }

}
