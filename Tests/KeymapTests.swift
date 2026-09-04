import XCTest
@testable import Synapty

/// [[RFC-0016]] C-CHORD: what may be a chord at all.
final class ChordTests: XCTestCase {

    func testAChordMustCarryCommandControlOrOption() {
        // "a binding without one of those three takes a character away from
        // whatever has focus, and in this application that is usually the
        // human typing into a shell."
        XCTAssertEqual(Chord(.character("k"), []).verdict, .notAChord)
        XCTAssertEqual(Chord(.character("k"), [.shift]).verdict, .notAChord,
                       "shift alone is not enough")
        XCTAssertEqual(Chord(.character("k"), [.command]).verdict, .accepted)
        XCTAssertEqual(Chord(.character("k"), [.control]).verdict, .accepted)
        XCTAssertEqual(Chord(.character("k"), [.option]).verdict, .accepted)
        XCTAssertEqual(Chord(.named(.escape), [.shift]).verdict, .notAChord,
                       "a named key is no more exempt than a letter")
    }

    /// THE MODIFIER TEST IS AN EQUALITY, NOT A CONTAINMENT — the rule the
    /// clause states because containment is the easier one to write.
    func testCommandKIsNotMatchedByCommandShiftK() {
        let plain = Chord(.character("k"), [.command])
        let shifted = Chord(.character("k"), [.command, .shift])
        XCTAssertNotEqual(plain, shifted)
    }

    /// A chord is named by the character the key produces UNSHIFTED, so a
    /// chord recorded with shift held is recognisable as itself.
    func testAChordIsNamedByTheUnshiftedCharacter() {
        XCTAssertEqual(Chord(fromCharacters: "K", unshifted: "k", modifiers: [.command, .shift]),
                       Chord(.character("k"), [.command, .shift]))
    }

    /// The closed list, and only it ([[RFC-0016]] C-CHORD). ⌘, is NOT on it:
    /// opening this workbench's own settings is an act of the workbench and
    /// therefore a command in the table like any other.
    func testTheRefusalListIsClosed() {
        XCTAssertEqual(Chord(.character("q"), [.command]).verdict, .refused)
        XCTAssertEqual(Chord(.character("h"), [.command]).verdict, .refused)
        XCTAssertEqual(Chord(.character("m"), [.command]).verdict, .refused)
        XCTAssertEqual(Chord(.character(","), [.command]).verdict, .accepted,
                       "settings is ours, so the chord convention gives it must be bindable")
        XCTAssertEqual(Chord(.character("q"), [.command, .shift]).verdict, .accepted,
                       "the list holds chords, not keys — equality again")
    }

    /// REFUSED and NOT-A-CHORD are different acts, and the clause says so:
    /// the first says this chord may not be bound, the second says what was
    /// pressed is not a chord at all.
    func testRefusalAndRejectionAreDifferentVerdicts() {
        XCTAssertNotEqual(Chord(.character("q"), [.command]).verdict,
                          Chord(.character("q"), []).verdict)
    }

    func testTheNamedNonCharacterKeysCanBeBound() {
        for key in Chord.NamedKey.allCases {
            XCTAssertEqual(Chord(.named(key), [.command]).verdict, .accepted,
                           "\(key) is in the named set and must be bindable")
        }
    }
}

/// [[RFC-0016]] C-CONFLICT: the table is built from the defaults, then each
/// override is applied as if it had just been recorded.
final class KeymapBuildTests: XCTestCase {

    // Identifiers chosen so that ascending code-point order is a, m, z —
    // several tests turn on the order being the stated one.
    private let cmdA = KeyCommand(id: "a.alpha", name: "Alpha",
                                  defaultChord: Chord(.character("1"), [.command]),
                                  domain: .workbench, nonKeyboardPath: .menu)
    private let cmdM = KeyCommand(id: "m.middle", name: "Middle",
                                  defaultChord: Chord(.character("2"), [.command]),
                                  domain: .workbench, nonKeyboardPath: .menu)
    private let cmdZ = KeyCommand(id: "z.omega", name: "Omega",
                                  defaultChord: nil,
                                  domain: .terminal, yieldsToTextEntry: true,
                                  nonKeyboardPath: .menu)

    private var table: [KeyCommand] { [cmdA, cmdM, cmdZ] }

    func testDefaultsAloneGiveEachCommandItsDefault() {
        let built = Keymap.build(commands: table, overrides: [:])
        XCTAssertEqual(built.chord(of: "a.alpha"), Chord(.character("1"), [.command]))
        XCTAssertEqual(built.chord(of: "m.middle"), Chord(.character("2"), [.command]))
        XCTAssertNil(built.chord(of: "z.omega"), "a default of `none` holds nothing")
    }

    /// RECORDING A CHORD THAT ANOTHER COMMAND HOLDS TAKES IT — and a load
    /// applies each override as if it had just been recorded.
    func testAnOverrideTakesTheChordFromWhoeverHoldsIt() {
        let built = Keymap.build(commands: table,
                                 overrides: ["z.omega": .chord(Chord(.character("1"), [.command]))])
        XCTAssertEqual(built.chord(of: "z.omega"), Chord(.character("1"), [.command]))
        XCTAssertNil(built.chord(of: "a.alpha"), "it lost the chord")
        XCTAssertEqual(built.displacedAtLoad, ["a.alpha"],
                       "and what it lost must be visible where bindings are shown")
    }

    /// `none` IS A VALUE AND NOT AN ABSENCE — the whole point of C-REBIND's
    /// store model. A cleared command stays cleared across a build.
    func testAnOverrideOfNoneClearsAndStaysCleared() {
        let built = Keymap.build(commands: table, overrides: ["a.alpha": Override.none])
        XCTAssertNil(built.chord(of: "a.alpha"))
        XCTAssertTrue(built.discarded.isEmpty,
                      "`none` is a value the store may hold, not a malformed override")
    }

    func testAnOverrideNamingAnUnknownCommandIsDiscarded() {
        let built = Keymap.build(commands: table,
                                 overrides: ["nope": .chord(Chord(.character("9"), [.command]))])
        XCTAssertEqual(built.discarded, [.init(commandID: "nope", reason: .unknownCommand)])
    }

    func testAnOverrideCarryingSomethingThatIsNotAChordIsDiscarded() {
        let built = Keymap.build(commands: table,
                                 overrides: ["a.alpha": .chord(Chord(.character("j"), []))])
        XCTAssertEqual(built.discarded, [.init(commandID: "a.alpha", reason: .notAChord)])
        XCTAssertEqual(built.chord(of: "a.alpha"), Chord(.character("1"), [.command]),
                       "and the default stands, because the override never applied")
    }

    /// REFUSAL APPLIES WHEREVER A CHORD ENTERS THE TABLE — including from
    /// storage, where there is no human to be given a reason.
    func testAnOverrideOnTheRefusalListIsDiscarded() {
        let built = Keymap.build(commands: table,
                                 overrides: ["a.alpha": .chord(Chord(.character("q"), [.command]))])
        XCTAssertEqual(built.discarded, [.init(commandID: "a.alpha", reason: .refused)])
    }

    /// A COLLIDING OVERRIDE IS NOT IN THE DISCARD LIST — it is applied, and
    /// displaces, exactly as a recording would. This is the rule round 3 of
    /// review replaced, and the one an implementer is most likely to get
    /// backwards.
    func testACollidingOverrideIsAppliedRatherThanDiscarded() {
        let onOne = Chord(.character("1"), [.command])
        let built = Keymap.build(commands: table,
                                 overrides: ["m.middle": .chord(onOne),
                                             "z.omega": .chord(onOne)])
        XCTAssertTrue(built.discarded.isEmpty, "neither is discarded")
        // Ascending code point: m.middle applies first and takes ⌘1 from
        // a.alpha; z.omega applies second and takes it from m.middle.
        XCTAssertEqual(built.chord(of: "z.omega"), onOne)
        XCTAssertNil(built.chord(of: "m.middle"))
        XCTAssertNil(built.chord(of: "a.alpha"))
        XCTAssertEqual(built.displacedAtLoad.sorted(), ["a.alpha", "m.middle"])
    }

    /// THE ORDER IS STATED SO THAT IT IS A CHOSEN ONE. Two hand-written
    /// overrides contending for one chord resolve the same way every time.
    func testTwoOverridesContendingForOneChordResolveDeterministically() {
        let onOne = Chord(.character("1"), [.command])
        let overrides: [String: Override] = ["m.middle": .chord(onOne), "z.omega": .chord(onOne)]
        let first = Keymap.build(commands: table, overrides: overrides)
        let second = Keymap.build(commands: table.reversed(), overrides: overrides)
        XCTAssertEqual(first.chord(of: "z.omega"), second.chord(of: "z.omega"))
        XCTAssertEqual(first.chord(of: "m.middle"), second.chord(of: "m.middle"))
    }

    /// IN THE ORDINARY CASE THE ORDER CHANGES NOTHING, because a
    /// displacement stores BOTH sides: the table the human left is
    /// reproduced whatever order its overrides are read in.
    func testADisplacementThenARebindRoundTripsThroughTheStore() {
        // The human gave ⌘1 to z.omega (displacing a.alpha, stored as
        // `none`), then later gave a.alpha ⌘3 of its own.
        let store: [String: Override] = [
            "z.omega": .chord(Chord(.character("1"), [.command])),
            "a.alpha": .chord(Chord(.character("3"), [.command])),
        ]
        let built = Keymap.build(commands: table, overrides: store)
        XCTAssertEqual(built.chord(of: "z.omega"), Chord(.character("1"), [.command]))
        XCTAssertEqual(built.chord(of: "a.alpha"), Chord(.character("3"), [.command]),
                       "the newer binding is not clobbered by replaying the old displacement")
        XCTAssertTrue(built.displacedAtLoad.isEmpty)
    }

    /// A DEFAULT THAT MOVED BETWEEN BUILDS onto a chord an override already
    /// holds. Nobody acted; there is no recording moment; the rule still has
    /// to produce one table.
    func testADefaultThatMovedOntoAHeldChordDisplacesCleanly() {
        // A new build ships a.alpha on ⌘2 — which m.middle's override holds.
        let moved = KeyCommand(id: "a.alpha", name: "Alpha",
                               defaultChord: Chord(.character("2"), [.command]),
                               domain: .workbench, nonKeyboardPath: .menu)
        let built = Keymap.build(commands: [moved, cmdM, cmdZ],
                                 overrides: ["m.middle": .chord(Chord(.character("2"), [.command]))])
        XCTAssertEqual(built.chord(of: "m.middle"), Chord(.character("2"), [.command]),
                       "the human's override outranks a default that moved under it")
        XCTAssertNil(built.chord(of: "a.alpha"))
        XCTAssertEqual(built.displacedAtLoad, ["a.alpha"], "and it is reported")
    }

    /// A DISPLACEMENT AT LOAD IS NOT STORED and lasts exactly as long as the
    /// override causing it. Remove that override and the displaced command is
    /// rebuilt with whatever it would have had all along.
    func testALoadDisplacementEvaporatesWhenItsCauseGoes() {
        let onOne = Chord(.character("1"), [.command])
        let displaced = Keymap.build(commands: table, overrides: ["z.omega": .chord(onOne)])
        XCTAssertNil(displaced.chord(of: "a.alpha"))

        let after = Keymap.build(commands: table, overrides: [:])
        XCTAssertEqual(after.chord(of: "a.alpha"), onOne,
                       "nothing was ever written to say it held nothing")
    }

    /// And it returns to its OWN OVERRIDE where it has one, not to its
    /// default — the imprecision the sixth review round caught.
    func testALoadDisplacedCommandReturnsToItsOverrideNotItsDefault() {
        let onOne = Chord(.character("1"), [.command])
        let ownChord = Chord(.character("7"), [.command])
        let displaced = Keymap.build(commands: table,
                                     overrides: ["z.omega": .chord(onOne), "a.alpha": .chord(ownChord)])
        XCTAssertEqual(displaced.chord(of: "a.alpha"), ownChord)

        let after = Keymap.build(commands: table, overrides: ["a.alpha": .chord(ownChord)])
        XCTAssertEqual(after.chord(of: "a.alpha"), ownChord)
    }

    /// The map from chords to commands is INJECTIVE AT EVERY MOMENT.
    func testTheBuiltTableIsAlwaysInjective() {
        let onOne = Chord(.character("1"), [.command])
        let built = Keymap.build(commands: table,
                                 overrides: ["m.middle": .chord(onOne), "z.omega": .chord(onOne)])
        let held = built.allChords
        XCTAssertEqual(Set(held).count, held.count, "no chord stands against two commands")
    }
}

/// [[RFC-0016]] C-DISPATCH: resolving a keystroke is a total function of the
/// focused surface and what the table says about the chord. These tests walk
/// the four ordered rows.
final class KeyDispatchTests: XCTestCase {

    private let workbenchChord = Chord(.character("d"), [.command])
    private let terminalChord = Chord(.character("k"), [.command, .shift])
    private let yieldingChord = Chord(.character("c"), [.command])
    private let unbound = Chord(.character("j"), [.command])

    private func makeTable() -> Keymap {
        Keymap.build(commands: [
            KeyCommand(id: "split", name: "Split Right", defaultChord: workbenchChord,
                       domain: .workbench, nonKeyboardPath: .menu),
            KeyCommand(id: "clear", name: "Clear Screen", defaultChord: terminalChord,
                       domain: .terminal, yieldsToTextEntry: false,
                       nonKeyboardPath: .menu),
            KeyCommand(id: "copy", name: "Copy", defaultChord: yieldingChord,
                       domain: .terminal, yieldsToTextEntry: true,
                       nonKeyboardPath: .menu),
        ], overrides: [:])
    }

    // MARK: Row 1 — a surface recording a chord

    func testTheRecorderTakesEverything() {
        let map = makeTable()
        for chord in [workbenchChord, terminalChord, unbound] {
            XCTAssertEqual(map.resolve(chord, in: .recorder), .recording,
                           "a human recording ⌘W must not thereby close a pane")
        }
    }

    // MARK: Row 2 — a text-entry surface belonging to a terminal leaf

    func testInALeafsOwnTextFieldAWorkbenchCommandStillRuns() {
        XCTAssertEqual(makeTable().resolve(workbenchChord, in: .textEntryOfTerminalLeaf(hasLiveTerminal: true)),
                       .runWorkbench("split"))
    }

    func testANonYieldingTerminalCommandRunsFromALeafsOwnTextField() {
        XCTAssertEqual(makeTable().resolve(terminalChord, in: .textEntryOfTerminalLeaf(hasLiveTerminal: true)),
                       .runTerminal("clear"))
    }

    func testAYieldingTerminalCommandLeavesTheChordToTheTextField() {
        XCTAssertEqual(makeTable().resolve(yieldingChord, in: .textEntryOfTerminalLeaf(hasLiveTerminal: true)),
                       .toResponderChain,
                       "copy copies from the field the human is typing in")
    }

    /// Row 2 was NOT tightened to a live terminal when row 3 was, which the
    /// fourth review round caught: a dialling leaf's rename field would
    /// otherwise run an action against a terminal that does not exist.
    func testALeafWithNoLiveTerminalHasNoTerminalToActOn() {
        XCTAssertEqual(makeTable().resolve(terminalChord, in: .textEntryOfTerminalLeaf(hasLiveTerminal: false)),
                       .toResponderChain)
    }

    func testAnUnboundChordInATextFieldGoesToTheResponderChain() {
        XCTAssertEqual(makeTable().resolve(unbound, in: .textEntryOfTerminalLeaf(hasLiveTerminal: true)),
                       .toResponderChain)
    }

    // MARK: Row 3 — a live terminal

    func testInALiveTerminalAWorkbenchCommandRunsAndTheTerminalIsNotOffered() {
        XCTAssertEqual(makeTable().resolve(workbenchChord, in: .liveTerminal), .runWorkbench("split"))
    }

    func testInALiveTerminalATerminalCommandRunsAsAnAction() {
        XCTAssertEqual(makeTable().resolve(terminalChord, in: .liveTerminal), .runTerminal("clear"))
    }

    /// "OFFERED TO THE TERMINAL" IS AN OBLIGATION, NOT A DEFAULT — and this
    /// is the only cell in the whole function that reaches the shell.
    func testOnlyALiveTerminalReceivesAnUnclaimedChordAsInput() {
        let map = makeTable()
        XCTAssertEqual(map.resolve(unbound, in: .liveTerminal), .toTerminalAsInput)
        XCTAssertEqual(map.resolve(unbound, in: .other), .toResponderChain)
        XCTAssertEqual(map.resolve(unbound, in: .textEntryOfTerminalLeaf(hasLiveTerminal: true)),
                       .toResponderChain)
        XCTAssertEqual(map.resolve(unbound, in: .recorder), .recording)
    }

    // MARK: Row 4 — anything else with focus

    func testElsewhereAWorkbenchCommandRunsAndATerminalCommandDoesNot() {
        let map = makeTable()
        XCTAssertEqual(map.resolve(workbenchChord, in: .other), .runWorkbench("split"),
                       "closing a pane means the same act whether the cursor is in a terminal or the sidebar")
        XCTAssertEqual(map.resolve(terminalChord, in: .other), .toResponderChain,
                       "there is no terminal in front of the human to clear")
    }

    /// A chord the human moved is answered at its new place and nowhere at
    /// its old one — the property the whole facility exists to provide.
    func testARebindMovesTheCommandAndLeavesNothingBehind() {
        let moved = Chord(.character("d"), [.command, .option])
        let map = Keymap.build(commands: [
            KeyCommand(id: "split", name: "Split Right", defaultChord: workbenchChord,
                       domain: .workbench, nonKeyboardPath: .menu),
        ], overrides: ["split": .chord(moved)])
        XCTAssertEqual(map.resolve(moved, in: .liveTerminal), .runWorkbench("split"))
        XCTAssertEqual(map.resolve(workbenchChord, in: .liveTerminal), .toTerminalAsInput,
                       "the old chord is not a command any more — it is a keystroke")
    }
}

/// [[RFC-0016]] C-REBIND: what is stored, and [[RFC-0016]] C-CONFLICT's
/// rule that a merge must not produce a conflict.
final class KeymapStoreTests: XCTestCase {

    override func setUpWithError() throws {
        // Never the operator's real keys.json.
        KeymapStore.storageOverride = try TestTempStorage.makeDir()
    }

    override func tearDownWithError() throws {
        KeymapStore.storageOverride = nil
    }

    private let chordD = Chord(.character("d"), [.command])

    func testAnOverrideRoundTripsThroughTheFile() throws {
        try KeymapStore.save(["workbench.split": .chord(chordD)])
        XCTAssertEqual(KeymapStore.load(), ["workbench.split": .chord(chordD)])
    }

    /// `none` IS A VALUE AND NOT AN ABSENCE — and the file has to be able
    /// to say so, or every clearing is undone by the next launch.
    func testAClearedCommandIsStoredAsAValueAndComesBackAsOne() throws {
        try KeymapStore.save(["terminal.copy": Override.none])
        XCTAssertEqual(KeymapStore.load(), ["terminal.copy": Override.none])
        XCTAssertNotEqual(KeymapStore.load(), [:],
                          "a cleared command is not the same as an untouched one")
    }

    /// The file is one a human may open, so `none` is written as JSON null
    /// against a key that is present.
    func testTheFileSaysNullForACommandHoldingNothing() throws {
        try KeymapStore.save(["terminal.copy": Override.none])
        let text = try String(contentsOf: KeymapStore.storageOverride!
            .appendingPathComponent("keys.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"terminal.copy\" : null"), text)
    }

    func testAnUntouchedCommandHasNoKeyAtAll() throws {
        try KeymapStore.save(["a": .chord(chordD)])
        XCTAssertNil(KeymapStore.load()["b"])
    }

    /// THE CASE THE GENERIC MERGE CANNOT SEE. Two machines bind DIFFERENT
    /// commands to one chord; `RecordMerge` is field-wise, so it reports no
    /// conflict and hands back a set holding one chord against two
    /// commands. Injectivity is a cross-field invariant, and normalising is
    /// what keeps the workbench from writing the conflict C-CONFLICT
    /// forbids it to write.
    func testAMergeThatWouldHoldOneChordTwiceIsNormalisedBeforeItIsStored() {
        let merged: [String: Override] = [
            "a.first": .chord(chordD),   // this machine
            "z.second": .chord(chordD),  // the other one
        ]
        let (normalised, displaced) = KeymapStore.normalise(merged)
        XCTAssertEqual(normalised["z.second"], .chord(chordD), "the later identifier takes it")
        XCTAssertEqual(normalised["a.first"], Override.none,
                       "and the loser is WRITTEN as holding nothing, not left to the next build")
        XCTAssertEqual(displaced, ["a.first"])
    }

    func testNormalisingLeavesAWellFormedSetAlone() {
        let fine: [String: Override] = [
            "a.first": .chord(chordD),
            "z.second": .chord(Chord(.character("e"), [.command])),
            "m.cleared": Override.none,
        ]
        let (normalised, displaced) = KeymapStore.normalise(fine)
        XCTAssertEqual(normalised, fine)
        XCTAssertTrue(displaced.isEmpty)
    }

    /// Normalisation is not a second validator: a malformed override is
    /// [[Keymap]]'s to discard at build time, and normalising must not
    /// silently drop it here as well.
    func testNormalisingDoesNotDiscardAMalformedOverride() {
        let bad: [String: Override] = ["a.first": .chord(Chord(.character("d"), []))]
        let (normalised, _) = KeymapStore.normalise(bad)
        XCTAssertEqual(normalised, bad)
    }

    /// End to end: what the human left is what comes back.
    func testTheTableTheHumanLeftIsTheTableThatComesBack() throws {
        let commands = [
            KeyCommand(id: "a.alpha", name: "Alpha", defaultChord: chordD,
                       domain: .workbench, nonKeyboardPath: .menu),
            KeyCommand(id: "z.omega", name: "Omega", defaultChord: nil,
                       domain: .workbench, nonKeyboardPath: .menu),
        ]
        // The human gives ⌘D to omega, displacing alpha — both sides stored.
        try KeymapStore.save(["z.omega": .chord(chordD), "a.alpha": Override.none])
        let built = Keymap.build(commands: commands, overrides: KeymapStore.load())
        XCTAssertEqual(built.chord(of: "z.omega"), chordD)
        XCTAssertNil(built.chord(of: "a.alpha"))
        XCTAssertTrue(built.displacedAtLoad.isEmpty,
                      "nothing was displaced at load — the store already said so")
    }
}

/// [[RFC-0016]] C-CONFLICT and C-CHORD state two constraints on the SHIPPED
/// table that are checkable by inspecting it alone — "a defect nobody has to
/// press a key to find". This is that inspection.
final class KeyCommandTableTests: XCTestCase {

    private var table: [KeyCommand] { KeyCommandTable.commands }

    /// THE SHIPPED DEFAULTS ARE THE FIRST CASE OF INJECTIVITY.
    func testNoTwoCommandsShipOnTheSameChord() {
        var holder: [Chord: String] = [:]
        for command in table {
            guard let chord = command.defaultChord else { continue }
            if let other = holder[chord] {
                XCTFail("\(command.id) and \(other) both ship on the same chord")
            }
            holder[chord] = command.id
        }
    }

    func testNoShippedDefaultIsOnTheRefusalList() {
        for command in table {
            guard let chord = command.defaultChord else { continue }
            XCTAssertNotEqual(chord.verdict, .refused,
                              "\(command.id) ships on a chord the workbench refuses to bind")
        }
    }

    /// A default that is not a chord at all would be discarded at every
    /// load, leaving a command that silently ships unbound.
    func testEveryShippedDefaultIsBindable() {
        for command in table {
            guard let chord = command.defaultChord else { continue }
            XCTAssertTrue(chord.isBindable, "\(command.id) ships on \(chord)")
        }
    }

    /// THE IDENTIFIERS ARE THE STORE'S VOCABULARY: a duplicate would make
    /// one command's override silently drive another.
    func testIdentifiersAreUnique() {
        XCTAssertEqual(Set(table.map(\.id)).count, table.count)
    }

    /// C-UNBOUND requires a non-keyboard path for every command whether or
    /// not it holds a chord. The type has no empty value, so this checks
    /// the thing a type cannot: that nobody wrote an empty string into it.
    func testEveryCommandNamesAReachablePlace() {
        for command in table {
            XCTAssertFalse(
                command.nonKeyboardPathDescription
                    .trimmingCharacters(in: .whitespaces).isEmpty,
                "\(command.id) has a non-keyboard path in name only")
        }
    }

    /// A COMMAND THAT SAYS IT IS IN THE MENU BAR IS IN THE MENU BAR.
    /// `.menu` carries no menu name — [[MenuLayout]] answers that — so a
    /// row claiming it while nothing in the bar invokes it would print a
    /// path consisting of its own label and no route to it.
    func testEveryCommandClaimingTheMenuBarIsInIt() {
        for command in table where command.nonKeyboardPath == .menu {
            XCTAssertNotNil(MenuLayout.chain(of: command.id),
                            "\(command.id) says it is in the menu bar and no menu builds it")
        }
    }

    /// AND THE OTHER DIRECTION: a menu cannot invoke a command that is not
    /// a row, because the item takes its label and its chord from the row
    /// — an id with no row would render as a blank item that does nothing.
    func testEveryCommandTheMenuBarInvokesIsARowOfTheTable() {
        let ids = Set(table.map(\.id))
        for placed in MenuLayout.placedCommandIDs {
            XCTAssertTrue(ids.contains(placed),
                          "the menu bar invokes \(placed), which is not in the table")
        }
    }

    /// The path is BUILT from the menu the item is in, so it cannot name
    /// another one. Split Right is the case that was wrong: it is a File
    /// item and the table said View.
    func testAMenuPathNamesTheMenuTheItemIsBuiltInto() {
        let split = table.first { $0.id == "pane.split-right" }
        XCTAssertEqual(split?.nonKeyboardPathDescription, "File ▸ Split Right")
        let workspace2 = table.first { $0.id == "workspace.select-2" }
        XCTAssertEqual(workspace2?.nonKeyboardPathDescription,
                       "Go to ▸ Workspace ▸ Workspace 2")
    }

    /// EVERY CHORD THIS WORKBENCH ANSWERED TO BEFORE THE TABLE EXISTED IS
    /// STILL ANSWERED. With ghostty's binding set emptied ([[RFC-0016]]
    /// C-TERMINAL), a terminal command nobody transcribed is simply gone —
    /// so the inventory is pinned here rather than trusted to review.
    func testTheTableCarriesEveryChordTheThreeOldSitesHeld() {
        let built = Keymap.build(commands: table, overrides: [:])
        let expected: [(Chord, String)] = [
            (Chord(.character("n"), [.command]), "workspace.new"),
            (Chord(.character("t"), [.command]), "pane.new"),
            (Chord(.character("w"), [.command]), "workspace.close-pane"),
            (Chord(.character("d"), [.command]), "pane.split-right"),
            (Chord(.character("d"), [.command, .shift]), "pane.split-down"),
            (Chord(.character("]"), [.command]), "slot.focus-next"),
            (Chord(.character("["), [.command]), "slot.focus-previous"),
            (Chord(.character("]"), [.command, .shift]), "pane.next"),
            (Chord(.character("["), [.command, .shift]), "pane.previous"),
            (Chord(.character("k"), [.command]), "palette.quick-connect"),
            (Chord(.character("/"), [.command, .shift]), "help.shortcuts"),
            (Chord(.character("s"), [.command, .control]), "sidebar.toggle"),
            (Chord(.character("p"), [.command, .option]), "settings.toggle-panel"),
            (Chord(.character("."), [.command, .shift]), "files.show-hidden"),
            (Chord(.character("c"), [.command]), "terminal.copy"),
            (Chord(.character("v"), [.command]), "terminal.paste"),
            (Chord(.character("f"), [.command]), "terminal.find"),
            (Chord(.character("="), [.command]), "terminal.font-increase"),
            (Chord(.character("-"), [.command]), "terminal.font-decrease"),
            (Chord(.character("0"), [.command]), "terminal.font-reset"),
            (Chord(.character("k"), [.command, .shift]), "terminal.clear"),
            (Chord(.character("1"), [.command]), "workspace.select-1"),
            (Chord(.character("9"), [.command]), "workspace.select-9"),
            (Chord(.character("1"), [.command, .option]), "pane.select-1"),
            (Chord(.character("9"), [.command, .control]), "slot.select-9"),
            (Chord(.character("1"), [.command, .shift]), "page.terminal"),
        ]
        for (chord, id) in expected {
            XCTAssertEqual(built.command(for: chord), id, "\(id) lost its chord")
        }
    }

    /// ⌘\ was a second chord for Split Right. A command holds AT MOST ONE,
    /// so it is gone rather than quietly carried over as a duplicate row.
    func testTheSplitAliasIsNotSmuggledInAsASecondRow() {
        let built = Keymap.build(commands: table, overrides: [:])
        XCTAssertNil(built.command(for: Chord(.character("\\"), [.command])))
        XCTAssertEqual(table.filter { $0.id.hasPrefix("pane.split") }.count, 2)
    }

    /// The families that lived only in an event monitor are now in the
    /// table WITH a way to reach them — which is the same act, because
    /// `NonKeyboardPath` has no empty value.
    func testTheFamiliesThatHadNoMenuItemNowHaveOne() {
        for family in ["pane.select-", "slot.select-"] {
            let rows = table.filter { $0.id.hasPrefix(family) }
            XCTAssertEqual(rows.count, 9, "\(family) is nine commands, not one")
            for row in rows {
                guard row.nonKeyboardPath == .menu else {
                    return XCTFail("\(row.id) still has no menu item")
                }
            }
        }
    }

    /// Only the terminal's own commands may claim the terminal domain, and
    /// only they consult the yields column.
    func testOnlyTerminalCommandsYieldToTextEntry() {
        for command in table where command.domain == .workbench {
            XCTAssertFalse(command.yieldsToTextEntry,
                           "\(command.id) is a workbench command; the column is meaningless for it")
        }
        let yielding = table.filter(\.yieldsToTextEntry).map(\.id).sorted()
        XCTAssertEqual(yielding, ["terminal.copy", "terminal.paste"],
                       "copy and paste give way to a text field; clearing and font size do not")
    }
}

/// [[RFC-0016]] C-DISPATCH: ONE KEYSTROKE RUNS A COMMAND AT MOST ONCE.
///
/// The obligation the implementation found and six review rounds did not.
/// A local monitor returning nil does NOT stop a SwiftUI menu's key
/// equivalent, so one press reached the command twice — through two
/// mechanisms both reading this table and both naming the same command,
/// which violated nothing about WHICH command a chord reaches.
@MainActor
final class KeystrokeEchoTests: XCTestCase {

    private let dispatcher = KeyDispatcher.shared

    override func tearDown() {
        dispatcher.forgetAnsweredKeystrokeForTesting()
        super.tearDown()
    }

    func testAMenuInvokedByTheMouseIsNeverAnEcho() {
        dispatcher.rememberAnsweredForTesting(timestamp: 100, keyCode: 40)
        XCTAssertFalse(dispatcher.isEcho(of: nil),
                       "a click carries no keystroke and is always the human asking")
    }

    func testTheSameKeystrokeArrivingTwiceIsAnEcho() {
        dispatcher.rememberAnsweredForTesting(timestamp: 100, keyCode: 40)
        XCTAssertTrue(dispatcher.isEcho(of: .init(timestamp: 100, keyCode: 40)))
    }

    /// The same key pressed AGAIN is a new act, not an echo — the case
    /// that matters for a toggle the human presses repeatedly, and the one
    /// a cruder "ignore anything within N milliseconds" rule would break.
    func testTheSameKeyPressedAgainIsNotAnEcho() {
        dispatcher.rememberAnsweredForTesting(timestamp: 100, keyCode: 40)
        XCTAssertFalse(dispatcher.isEcho(of: .init(timestamp: 100.3, keyCode: 40)))
    }

    func testADifferentKeyInTheSameInstantIsNotAnEcho() {
        dispatcher.rememberAnsweredForTesting(timestamp: 100, keyCode: 40)
        XCTAssertFalse(dispatcher.isEcho(of: .init(timestamp: 100, keyCode: 41)))
    }

    func testNothingIsAnEchoBeforeAnyKeystrokeHasBeenAnswered() {
        dispatcher.forgetAnsweredKeystrokeForTesting()
        XCTAssertFalse(dispatcher.isEcho(of: .init(timestamp: 100, keyCode: 40)))
    }
}

/// [[RFC-0016]] C-REBIND and C-CONFLICT, as the human's acts: recording,
/// clearing, and getting a default back.
final class KeymapEditorTests: XCTestCase {

    private let onD = Chord(.character("d"), [.command])
    private let onE = Chord(.character("e"), [.command])

    private var commands: [KeyCommand] {
        [KeyCommand(id: "a.alpha", name: "Alpha", defaultChord: onD,
                    domain: .workbench, nonKeyboardPath: .menu),
         KeyCommand(id: "z.omega", name: "Omega", defaultChord: onE,
                    domain: .workbench, nonKeyboardPath: .menu)]
    }

    private func build(_ overrides: [String: Override]) -> Keymap {
        Keymap.build(commands: commands, overrides: overrides)
    }

    // MARK: Recording

    func testRecordingAFreeChordJustTakesIt() {
        var overrides: [String: Override] = [:]
        let free = Chord(.character("j"), [.command])
        let outcome = KeymapEditor.record(free, for: "a.alpha",
                                          in: &overrides, effective: build([:]))
        XCTAssertEqual(outcome, .recorded(displaced: nil))
        XCTAssertEqual(overrides, ["a.alpha": .chord(free)])
    }

    /// TAKES IT, and writes BOTH sides — the loser's `none` is stored in
    /// the same act, or the store cannot reproduce what the human saw.
    func testRecordingAHeldChordTakesItAndWritesBothSides() {
        var overrides: [String: Override] = [:]
        let outcome = KeymapEditor.record(onD, for: "z.omega",
                                          in: &overrides, effective: build([:]))
        XCTAssertEqual(outcome, .recorded(displaced: "a.alpha"),
                       "the command that lost the chord must be named at that moment")
        XCTAssertEqual(overrides["z.omega"], .chord(onD))
        XCTAssertEqual(overrides["a.alpha"], Override.none)
    }

    func testRecordingACommandsOwnChordDisplacesNothing() {
        var overrides: [String: Override] = [:]
        let outcome = KeymapEditor.record(onD, for: "a.alpha",
                                          in: &overrides, effective: build([:]))
        XCTAssertEqual(outcome, .recorded(displaced: nil))
    }

    func testARefusedChordIsRefusedAndNothingIsWritten() {
        var overrides: [String: Override] = [:]
        let outcome = KeymapEditor.record(Chord(.character("q"), [.command]),
                                          for: "a.alpha", in: &overrides, effective: build([:]))
        XCTAssertEqual(outcome, .refused)
        XCTAssertTrue(overrides.isEmpty)
    }

    func testAKeystrokeThatIsNotAChordIsRejectedAndNothingIsWritten() {
        var overrides: [String: Override] = [:]
        let outcome = KeymapEditor.record(Chord(.character("j"), [.shift]),
                                          for: "a.alpha", in: &overrides, effective: build([:]))
        XCTAssertEqual(outcome, .notAChord)
        XCTAssertTrue(overrides.isEmpty)
    }

    // MARK: Clearing

    func testClearingIsStoredAsAValue() {
        var overrides: [String: Override] = [:]
        XCTAssertEqual(KeymapEditor.clear("a.alpha", in: &overrides), .cleared)
        XCTAssertEqual(overrides["a.alpha"], Override.none,
                       "not an absence: the next build must know the human said so")
    }

    // MARK: Recovery

    func testRecoveringADefaultRemovesTheOverrideRatherThanStoringTheDefault() {
        var overrides: [String: Override] = ["a.alpha": .chord(Chord(.character("j"), [.command]))]
        let outcome = KeymapEditor.recoverDefault(of: "a.alpha", in: &overrides,
                                                  commands: commands, effective: build(overrides))
        XCTAssertEqual(outcome, .recovered)
        XCTAssertNil(overrides["a.alpha"],
                     "storing the default as an override would freeze it at today's value")
    }

    /// RECOVERY MUST NOT DISPLACE. The human is asking to undo their own
    /// change, not to make a new one at a third command's expense.
    func testRecoveringADefaultAnotherCommandHoldsIsUnavailableAndNamesTheHolder() {
        // Omega was given Alpha's default chord; Alpha was cleared by that.
        var overrides: [String: Override] = ["z.omega": .chord(onD), "a.alpha": Override.none]
        let outcome = KeymapEditor.recoverDefault(of: "a.alpha", in: &overrides,
                                                  commands: commands, effective: build(overrides))
        XCTAssertEqual(outcome, .defaultHeldBy("z.omega"))
        XCTAssertEqual(overrides["z.omega"], .chord(onD), "the holder is untouched")
        XCTAssertEqual(overrides["a.alpha"], Override.none, "and nothing was quietly done")
    }

    /// Whole-table recovery is the one act that undoes a displacement,
    /// because it removes both sides of it.
    func testWholeTableRecoveryRestoresBothSidesOfADisplacement() {
        var overrides: [String: Override] = ["z.omega": .chord(onD), "a.alpha": Override.none]
        KeymapEditor.recoverAllDefaults(in: &overrides)
        let rebuilt = build(overrides)
        XCTAssertEqual(rebuilt.chord(of: "a.alpha"), onD)
        XCTAssertEqual(rebuilt.chord(of: "z.omega"), onE)
    }

    /// End to end through the store: record, reload, and the table is the
    /// one the human left.
    func testARecordingSurvivesARebuild() {
        var overrides: [String: Override] = [:]
        _ = KeymapEditor.record(onD, for: "z.omega", in: &overrides, effective: build([:]))
        let rebuilt = build(overrides)
        XCTAssertEqual(rebuilt.chord(of: "z.omega"), onD)
        XCTAssertNil(rebuilt.chord(of: "a.alpha"))
        XCTAssertTrue(rebuilt.displacedAtLoad.isEmpty,
                      "the store already says so — nothing is displaced at load")
    }
}

/// While a surface is RECORDING, no keystroke dispatches anything — by any
/// mechanism the platform offers it to ([[RFC-0016]] C-DISPATCH row 1).
@MainActor
final class RecordingSuppressesDispatchTests: XCTestCase {

    private let dispatcher = KeyDispatcher.shared

    override func tearDown() {
        dispatcher.endRecording()
        dispatcher.forgetAnsweredKeystrokeForTesting()
        super.tearDown()
    }

    func testAKeystrokeReachingTheMenuWhileRecordingIsDropped() {
        dispatcher.beginRecording { _ in }
        XCTAssertTrue(dispatcher.isSuppressed(.init(timestamp: 1, keyCode: 2)),
                      "recording ⌘D must not split the pane")
    }

    /// A CLICK IS NOT A KEYSTROKE. The human reaching for the menu with the
    /// mouse means it, even mid-recording.
    func testAMouseInvocationIsNotDroppedWhileRecording() {
        dispatcher.beginRecording { _ in }
        XCTAssertFalse(dispatcher.isSuppressed(nil))
    }

    func testOutsideRecordingOnlyTheEchoIsDropped() {
        dispatcher.endRecording()
        dispatcher.rememberAnsweredForTesting(timestamp: 1, keyCode: 2)
        XCTAssertTrue(dispatcher.isSuppressed(.init(timestamp: 1, keyCode: 2)))
        XCTAssertFalse(dispatcher.isSuppressed(.init(timestamp: 9, keyCode: 2)))
    }
}

/// [[RFC-0016]] C-TABLE: an INDEXED FAMILY is one act over an index, and is
/// rebound as a whole by its modifier.
final class IndexedFamilyTests: XCTestCase {

    private var commands: [KeyCommand] {
        var rows: [KeyCommand] = [
            KeyCommand(id: "other", name: "Other", defaultChord: Chord(.character("3"), [.command, .option]),
                       domain: .workbench, nonKeyboardPath: .menu),
        ]
        for n in 1...9 {
            rows.append(KeyCommand(id: "pane.select-\(n)", name: "Pane \(n)",
                                   defaultChord: Chord(.character(Character("\(n)")), [.command]),
                                   domain: .workbench,
                                   nonKeyboardPath: .menu,
                                   family: "pane.select-"))
        }
        return rows
    }

    private func build(_ o: [String: Override]) -> Keymap {
        Keymap.build(commands: commands, overrides: o)
    }

    /// ONLY THE MODIFIER IS TAKEN. The digit the human happened to press is
    /// theirs, not the family's — pressing ⌥⌘7 moves all nine.
    func testRebindingAFamilyMovesEveryMemberOntoTheNewModifier() {
        var overrides: [String: Override] = [:]
        let outcome = KeymapEditor.recordFamily([.command, .option], family: "pane.select-",
                                                in: &overrides, commands: commands,
                                                effective: build([:]))
        guard case .recorded = outcome else { return XCTFail("expected a recording, got \(outcome)") }
        let rebuilt = build(overrides)
        for n in 1...9 {
            XCTAssertEqual(rebuilt.chord(of: "pane.select-\(n)"),
                           Chord(.character(Character("\(n)")), [.command, .option]),
                           "member \(n) did not move with its family")
        }
    }

    /// A family displaces like any other recording — and names one loser
    /// rather than nine.
    func testAFamilyTakesChordsFromWhoeverHeldThem() {
        var overrides: [String: Override] = [:]
        let outcome = KeymapEditor.recordFamily([.command, .option], family: "pane.select-",
                                                in: &overrides, commands: commands,
                                                effective: build([:]))
        XCTAssertEqual(outcome, .recorded(displaced: "other"))
        XCTAssertEqual(overrides["other"], Override.none)
    }

    /// MEMBERS DO NOT DISPLACE EACH OTHER. Moving the family from ⌘N to
    /// ⌥⌘N passes through states where a member's new chord is another
    /// member's old one; treating that as a displacement would clear a
    /// member the same act is about to bind.
    func testMovingAFamilyOntoItsOwnRangeDoesNotClearItsMembers() {
        var overrides: [String: Override] = [:]
        _ = KeymapEditor.recordFamily([.command, .control], family: "pane.select-",
                                      in: &overrides, commands: commands, effective: build([:]))
        var second: [String: Override] = overrides
        _ = KeymapEditor.recordFamily([.command], family: "pane.select-",
                                      in: &second, commands: commands, effective: build(overrides))
        let rebuilt = build(second)
        for n in 1...9 {
            XCTAssertEqual(rebuilt.chord(of: "pane.select-\(n)"),
                           Chord(.character(Character("\(n)")), [.command]))
        }
    }

    func testAFamilyOnARefusedModifierIsRefused() {
        var overrides: [String: Override] = [:]
        // ⌘Q is refused; a family on plain ⌘ over digits is not, so the
        // refusal has to be judged on the modifier's own chord.
        let outcome = KeymapEditor.recordFamily([], family: "pane.select-",
                                                in: &overrides, commands: commands,
                                                effective: build([:]))
        XCTAssertEqual(outcome, .notAChord, "a family needs a qualifying modifier too")
        XCTAssertTrue(overrides.isEmpty)
    }

    /// Recovered as a unit: nine overrides removed, not one.
    func testRecoveringAFamilyRemovesEveryMembersOverride() {
        var overrides: [String: Override] = [:]
        _ = KeymapEditor.recordFamily([.command, .option], family: "pane.select-",
                                      in: &overrides, commands: commands, effective: build([:]))
        _ = KeymapEditor.recoverFamily("pane.select-", in: &overrides, commands: commands)
        for n in 1...9 {
            XCTAssertNil(overrides["pane.select-\(n)"])
        }
    }

    /// Every member of every shipped family carries the same modifier —
    /// the property the panel's range display depends on.
    func testEveryShippedFamilyIsUniformInItsModifier() {
        let built = Keymap.build(commands: KeyCommandTable.commands, overrides: [:])
        let families = Set(KeyCommandTable.commands.compactMap(\.family))
        XCTAssertEqual(families.count, 3)
        for family in families {
            let mods = KeyCommandTable.commands
                .filter { $0.family == family }
                .compactMap { built.chord(of: $0.id)?.modifiers }
            XCTAssertEqual(Set(mods).count, 1, "\(family) ships with mixed modifiers")
        }
    }
}

/// [[RFC-0016]] C-DISCOVERY: what a surface displays is read from the
/// table, and every command is listed — including those holding nothing.
@MainActor
final class ShortcutReferenceTests: XCTestCase {

    /// EVERY COMMAND APPEARS EXACTLY ONCE across the groups, with a family
    /// standing for its nine. A command that fell through the grouping
    /// predicates would be invisible in both surfaces at once, since they
    /// now read the same list.
    func testEveryCommandIsListedOnceAcrossTheGroups() {
        var seen: [String] = []
        for group in KeyCommandTable.groups {
            for entry in group.entries {
                switch entry {
                case .command(let c): seen.append(c.id)
                case .family(let f): seen.append(contentsOf: f.members.map(\.id))
                }
            }
        }
        let all = KeyCommandTable.commands.map(\.id)
        XCTAssertEqual(Set(seen).count, seen.count, "a command is listed twice")
        XCTAssertEqual(Set(seen), Set(all),
                       "missing: \(Set(all).subtracting(seen).sorted())")
    }

    /// The three families are entries, not twenty-seven rows.
    func testTheFamiliesAppearAsThreeEntries() {
        let families = KeyCommandTable.groups.flatMap(\.entries).compactMap { entry -> String? in
            if case .family(let f) = entry { return f.id }
            return nil
        }
        XCTAssertEqual(families.count, 3)
    }

    /// A range is a claim about nine bindings at once, so it is withheld
    /// the moment they stop sharing a modifier.
    func testAFamilyRangeIsWithheldOnceItsMembersDisagree() {
        let family = KeyCommandTable.families.first { $0.id == "pane.select-" }!
        let clean = Keymap.build(commands: KeyCommandTable.commands, overrides: [:])
        XCTAssertNotNil(family.rangeDisplay(clean))

        let broken = Keymap.build(commands: KeyCommandTable.commands,
                                  overrides: ["pane.select-5": .chord(Chord(.character("j"), [.command]))])
        XCTAssertNil(family.rangeDisplay(broken),
                     "one member moved — printing ⌥⌘1–9 would be a lie about the other eight")
    }
}

/// The keymap follows the human between machines ([[RFC-0016]] C-REBIND),
/// and a merge must not leave a conflict in the file ([[RFC-0016]]
/// C-CONFLICT).
final class KeymapSyncTests: XCTestCase {

    /// IN `shared/`, which is what decides that it travels — the same side
    /// of the line as the appearance settings.
    func testTheKeymapIsClassifiedAsSharedAndSoIsSynced() {
        let entry = ConfigPaths.allEntries.first { $0.name == "keys.json" }
        XCTAssertEqual(entry?.kind, .shared, "the keymap must be on the side that travels")
        XCTAssertEqual(ConfigPaths.keymap.deletingLastPathComponent().lastPathComponent, "shared")
    }

    /// THE CASE THE FIELD-WISE MERGE CANNOT SEE, over the bytes the sync
    /// layer actually hands around: two machines binding DIFFERENT
    /// commands to one chord touch different keys, so the merge reports no
    /// conflict and produces a file holding one chord twice.
    func testMergedBytesHoldingOneChordTwiceAreNormalisedBeforeTheyAreWritten() throws {
        let merged = """
        {"a.first":{"key":"d","modifiers":1},"z.second":{"key":"d","modifiers":1}}
        """.data(using: .utf8)!
        let fixed = try XCTUnwrap(KeymapStore.normalised(merged))
        let decoded = try JSONDecoder().decode([String: Override].self, from: fixed)
        XCTAssertEqual(decoded["z.second"], .chord(Chord(.character("d"), [.command])))
        XCTAssertEqual(decoded["a.first"], Override.none,
                       "the loser is written as holding nothing, not left for the next build")
    }

    /// A well-formed file is handed back untouched — normalising must not
    /// rewrite a store it has nothing to fix, or every launch would offer
    /// the sync layer a change that is not one.
    func testAWellFormedStoreIsReturnedUnchanged() throws {
        let clean = """
        {"a.first":{"key":"d","modifiers":1},"z.second":null}
        """.data(using: .utf8)!
        XCTAssertEqual(KeymapStore.normalised(clean), clean)
    }

    func testBytesThatAreNotAKeymapAreLeftAlone() {
        XCTAssertNil(KeymapStore.normalised(Data("not json".utf8)))
    }
}

/// [[RFC-0015]] C-CONTENT: a pane is not necessarily a terminal, and a tab
/// says which kind it is — except for the kind that is the default.
final class PaneKindMarkTests: XCTestCase {

    /// THE TERMINAL IS UNMARKED, and that is the finding
    /// [[WI-2026-08-09-013]] left behind: every tab wearing the same glyph
    /// was noise. A mark that appears on three tabs in twenty is one the
    /// eye can use; a mark on all twenty is not.
    func testATerminalTabCarriesNoKindGlyph() {
        XCTAssertNil(SplitNode.PaneContent.terminal(command: nil).tabIcon)
        XCTAssertNil(SplitNode.PaneContent.terminal(command: "bash").tabIcon)
    }

    func testEveryOtherKindIsMarked() {
        XCTAssertEqual(SplitNode.PaneContent.files(directory: nil).tabIcon, "folder")
        XCTAssertEqual(SplitNode.PaneContent.browser(address: nil).tabIcon, "globe")
    }

    /// The glyphs distinguish — two kinds sharing one would mark without
    /// telling apart.
    func testTheMarksAreDistinct() {
        let marks = [SplitNode.PaneContent.files(directory: nil), .services, .browser(address: nil)].compactMap(\.tabIcon)
        XCTAssertEqual(Set(marks).count, marks.count)
    }

    /// A name for the places a glyph cannot go — a tooltip, an
    /// accessibility label.
    func testEveryKindCanSayWhatItIs() {
        for kind: SplitNode.PaneContent in [.terminal(command: nil), .files(directory: nil), .services, .browser(address: nil)] {
            XCTAssertFalse(kind.kindName.isEmpty)
        }
    }
}

/// WHAT A CONTROL PRINTS COMES FROM THE TABLE ([[RFC-0016]] C-DISCOVERY).
@MainActor
final class CommandHintTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestTempStorage.makeDir()
        KeymapStore.storageOverride = tempDir
    }

    override func tearDownWithError() throws {
        KeymapStore.storageOverride = nil
    }

    /// A REBIND MOVES WHAT THE TOOLTIP SAYS. Ten controls typed their
    /// chord in beside the label, so the moment a human moved a command
    /// out of the way of another application — which the Keys pane's own
    /// copy tells them to do — the tooltip went on advertising the chord
    /// they had just abandoned ([[WI-2026-08-28-007]]).
    func testARebindMovesWhatAControlAdvertises() throws {
        let dispatcher = KeyDispatcher.shared
        defer { try? KeymapStore.save([:]); dispatcher.reload() }

        try KeymapStore.save(["files.show-hidden": .chord(Chord(.character("h"), [.command, .control]))])
        dispatcher.reload()

        XCTAssertEqual(CommandHint.reach("files.show-hidden", dispatcher: dispatcher), "⌃⌘H")
        XCTAssertEqual(CommandHint.help("Show hidden files", for: "files.show-hidden",
                                        dispatcher: dispatcher),
                       "Show hidden files (⌃⌘H)")
    }

    /// AND A CLEARED COMMAND NAMES THE WAY THAT STILL WORKS rather than
    /// printing an empty bracket or dropping the sentence ([[RFC-0016]]
    /// C-UNBOUND).
    func testAClearedCommandAdvertisesItsNonKeyboardPath() throws {
        let dispatcher = KeyDispatcher.shared
        defer { try? KeymapStore.save([:]); dispatcher.reload() }

        try KeymapStore.save(["files.show-hidden": .none])
        dispatcher.reload()

        XCTAssertEqual(CommandHint.reach("files.show-hidden", dispatcher: dispatcher),
                       "View ▸ Show Hidden Files")
    }
}

/// TWO RULES THE TABLE OWNS, BECAUSE MORE THAN ONE SURFACE ASKS THEM
/// ([[WI-2026-08-30-002]]).
///
/// Both were written out by hand at each asking site — the shortcuts
/// reference and the pane bindings are edited on each had a private copy
/// of "differs from default". They agreed, which is the only state a
/// duplicated rule is ever found in until it does not.
final class KeymapNamedRulesTests: XCTestCase {

    private let bound = KeyCommand(id: "a.alpha", name: "Alpha",
                                   defaultChord: Chord(.character("1"), [.command]),
                                   domain: .workbench, nonKeyboardPath: .menu)
    private let unbound = KeyCommand(id: "z.omega", name: "Omega",
                                     defaultChord: nil,
                                     domain: .workbench, nonKeyboardPath: .menu)

    private func built(_ overrides: [String: Override] = [:]) -> Keymap {
        Keymap.build(commands: [bound, unbound], overrides: overrides)
    }

    func testACommandOnItsDefaultDoesNotDiffer() {
        XCTAssertFalse(built().differsFromDefault(bound))
    }

    func testRebindingMakesACommandDiffer() {
        let map = built(["a.alpha": .chord(Chord(.character("j"), [.command, .control]))])
        XCTAssertTrue(map.differsFromDefault(bound))
    }

    /// CLEARING IS NOT REBINDING, and both rules have to say so: a command
    /// holding nothing differs from a default that held something.
    func testAClearedCommandHoldsNothingAndDiffers() {
        XCTAssertFalse(built().holdsNothing("a.alpha"))
        let map = built(["a.alpha": Override.none])
        XCTAssertTrue(map.holdsNothing("a.alpha"))
        XCTAssertTrue(map.differsFromDefault(bound))
    }

    /// A command that SHIPS holding nothing holds nothing and does not
    /// differ. The two rules are not each other, and a surface that used
    /// one for the other would offer "Reset to Default" on a row already
    /// on its default.
    func testACommandThatShipsUnboundDoesNotDiffer() {
        let map = built()
        XCTAssertTrue(map.holdsNothing("z.omega"))
        XCTAssertFalse(map.differsFromDefault(unbound))
    }
}

/// WHAT THE LOAD DROPPED OR TOOK AWAY IS SAYABLE
/// ([[RFC-0016]] C-CONFLICT, [[WI-2026-08-30-008]]).
///
/// "WHAT WAS DISCARDED OR DISPLACED AT LOAD MUST BE VISIBLE where bindings
/// are shown." Both facts were computed and read by nothing, so a store
/// with a line this build cannot apply was silently ignored and a command
/// left holding nothing by a collision in the file was silently left that
/// way.
final class KeymapLoadNoticeTests: XCTestCase {

    private let alpha = KeyCommand(id: "a.alpha", name: "Alpha",
                                   defaultChord: Chord(.character("1"), [.command]),
                                   domain: .workbench, nonKeyboardPath: .menu)
    private let omega = KeyCommand(id: "z.omega", name: "Omega",
                                   defaultChord: nil,
                                   domain: .workbench, nonKeyboardPath: .menu)

    private func built(_ overrides: [String: Override]) -> Keymap {
        Keymap.build(commands: [alpha, omega], overrides: overrides)
    }

    func testAnUneventfulLoadSaysNothing() {
        XCTAssertNil(built([:]).loadNotice)
    }

    /// A store whose overrides collide leaves a command holding nothing,
    /// and the human is told which command by name.
    func testACommandLeftHoldingNothingIsNamed() {
        let map = built(["z.omega": .chord(Chord(.character("1"), [.command]))])
        let notice = try? XCTUnwrap(map.loadNotice)
        XCTAssertNotNil(notice)
        XCTAssertTrue(map.loadNotice?.contains("Alpha") == true,
                      "the command that lost its chord was not named: \(map.loadNotice ?? "nil")")
    }

    /// A line this build cannot apply is reported rather than dropped in
    /// silence — "silently dropping the human's choice and silently
    /// keeping a broken one are equally bad".
    func testAnIgnoredLineIsReported() {
        let map = built(["nobody.here": .chord(Chord(.character("9"), [.command]))])
        XCTAssertTrue(map.loadNotice?.contains("nobody.here") == true,
                      "an override naming no command was dropped in silence")
    }

    /// AND NOT A LOG OF THE WAY THERE. A command displaced by one override
    /// and given another chord by a later one holds a chord at the end;
    /// telling the human it lost something it still has is a false alarm.
    func testACommandThatEndsUpHoldingAChordIsNotReportedAsLosingOne() {
        // TWO COMMANDS SHIPPED ON ONE CHORD, which the defaults pass
        // resolves by displacing the loser — so a displacement IS logged.
        let twin = KeyCommand(id: "b.beta", name: "Beta",
                              defaultChord: Chord(.character("1"), [.command]),
                              domain: .workbench, nonKeyboardPath: .menu)
        let collided = Keymap.build(commands: [alpha, twin], overrides: [:])
        XCTAssertNotNil(collided.loadNotice, "a shipped collision was not reported at all")

        // And with the loser given a chord of its own, it holds one at the
        // end — so it has lost nothing to tell the human about.
        let rescued = Keymap.build(
            commands: [alpha, twin],
            overrides: ["a.alpha": .chord(Chord(.character("2"), [.command]))])
        XCTAssertNotNil(rescued.chord(of: "a.alpha"))
        XCTAssertNotNil(rescued.chord(of: "b.beta"))
        XCTAssertNil(rescued.loadNotice,
                     "a command that still holds a chord was reported as having lost one")
    }
}

/// EVERY ROW OF THE TABLE IS A COMMAND THE DISPATCHER ANSWERS
/// ([[WI-2026-08-30-009]]).
///
/// A row with no arm is a menu item and a chord that do nothing, and
/// nothing said so: the dispatch ends in a chain of prefix tests and then
/// falls off the end. Adding a command to the table is one edit and giving
/// it an arm is another, in a different file.
@MainActor
final class DispatchCoverageTests: XCTestCase {

    func testEveryRowOfTheTableIsPerformable() {
        let dispatcher = KeyDispatcher.shared
        for command in KeyCommandTable.commands {
            XCTAssertTrue(dispatcher.performed(command.id),
                          "\(command.id) is in the table and nothing performs it")
        }
    }

    /// AND AN ID NOTHING DEFINES IS NOT QUIETLY ACCEPTED, or the assertion
    /// above would pass for a dispatcher that answered everything.
    func testAnIdTheTableDoesNotHaveIsNotPerformed() {
        XCTAssertFalse(KeyDispatcher.shared.performed("nothing.at-all"))
    }
}

/// EVERY MENU THE LAYOUT DECLARES IS A MENU THE BAR BUILDS
/// ([[RFC-0016]] C-DISCOVERY, [[WI-2026-08-30-008]]).
///
/// The list was written out twice — `MenuLayout.all` and again in
/// `SynaptyCommands.body` — so a section added to one and not the other
/// appears in the path the Keys pane prints and in no menu a human can
/// open. `all` is derived from the tuple now and the tuple's arity is
/// part of its type, so `body` cannot silently ignore a new section. This
/// holds the half the compiler does not: that the sections are the ones
/// the layout names, in the order it names them.
final class MenuBarTests: XCTestCase {

    func testTheDerivedListIsTheSectionsThemselves() {
        let s = MenuLayout.sections
        XCTAssertEqual(MenuLayout.all.map(\.title),
                       [s.file, s.help, s.goTo, s.terminal, s.view].map(\.title))
    }

    /// A section with no entries would be a title leading nowhere.
    func testNoMenuIsEmpty() {
        for section in MenuLayout.all {
            XCTAssertFalse(section.entries.isEmpty, "\(section.title) has no items")
        }
    }

    /// EVERY COMMAND A MENU PLACES IS A COMMAND THE TABLE HAS. A menu item
    /// naming an id nothing defines is a row that does nothing and shows a
    /// blank chord.
    func testEveryPlacedCommandIsInTheTable() {
        let known = Set(KeyCommandTable.commands.map(\.id))
        for id in MenuLayout.placedCommandIDs {
            XCTAssertTrue(known.contains(id), "\(id) is in a menu and not in the table")
        }
    }
}
