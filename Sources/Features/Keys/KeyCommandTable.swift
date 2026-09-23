import Foundation

/// THE TABLE ITSELF ([[RFC-0016]] C-TABLE) — every chord this workbench
/// answers to, in one place.
///
/// DATA AND NOT BEHAVIOUR. A row says what a command IS: its identifier,
/// its name, the chord it ships with, whose act it is, and where it can be
/// reached without a keyboard. What it DOES is bound at the call site, so
/// the table can be read and tested without an application around it.
///
/// THE IDENTIFIERS ARE THE STORE'S VOCABULARY and outlive every name shown
/// to a human, so they are chosen once and changed never — renaming one
/// silently discards that command's override at the next load
/// ([[RFC-0016]] C-CONFLICT).
enum KeyCommandTable {

    /// The shipped table. Order is irrelevant to behaviour — [[Keymap]]
    /// sorts by identifier — and is chosen here for reading.
    static let commands: [KeyCommand] = workspace + panes + numbered + workbench + terminal

    // MARK: - Indexed families ([[RFC-0016]] C-TABLE)

    /// A FAMILY AS THE HUMAN SEES IT: one name, one modifier, nine chords.
    ///
    /// Defined HERE and not in whichever surface happens to draw it. The
    /// name "Workspace 1–9" is a fact about the table, and a second copy
    /// in a second view is the shape of defect this whole work item is
    /// about — two places that agree until one of them is edited.
    struct Family: Identifiable {
        let id: String
        let name: String
        let members: [KeyCommand]

        /// The nine chords as one range, where they still share a
        /// modifier. Nil once they do not — a range is a claim about nine
        /// bindings at once, and [[RFC-0016]] C-DISCOVERY does not permit
        /// printing one that has stopped being true.
        func rangeDisplay(_ keymap: Keymap) -> String? {
            let chords = members.compactMap { keymap.chord(of: $0.id) }
            guard chords.count == members.count,
                  let first = chords.first, let last = chords.last,
                  chords.allSatisfy({ $0.modifiers == first.modifiers })
            else { return nil }
            return "\(first.display)–\(last.display.suffix(1))"
        }
    }

    static let families: [Family] = [
        .init(id: "workspace.select-", name: "Workspace 1–9",
              members: commands.filter { $0.family == "workspace.select-" }),
        .init(id: "pane.select-", name: "Pane 1–9",
              members: commands.filter { $0.family == "pane.select-" }),
        .init(id: "slot.select-", name: "Slot 1–9",
              members: commands.filter { $0.family == "slot.select-" }),
    ]

    static func family(of command: KeyCommand) -> Family? {
        command.family.flatMap { id in families.first { $0.id == id } }
    }

    // MARK: - Workspaces and panes

    private static let workspace: [KeyCommand] = [
        .init(id: "workspace.new", name: "New Workspace",
              defaultChord: Chord(.character("n"), [.command]),
              domain: .workbench, nonKeyboardPath: .menu),
        .init(id: "workspace.close-pane", name: "Close Pane",
              defaultChord: Chord(.character("w"), [.command]),
              domain: .workbench, nonKeyboardPath: .menu),
        // THE OTHER ACT, one modifier away from the first ([[ADR-0019]]):
        // ⌘W ends the pane's session, ⌥⌘W puts it away still running.
        .init(id: "workspace.archive-pane", name: "Archive Pane",
              defaultChord: Chord(.character("w"), [.command, .option]),
              domain: .workbench, nonKeyboardPath: .menu),
    ]

    private static let panes: [KeyCommand] = [
        .init(id: "pane.new", name: "New Pane",
              defaultChord: Chord(.character("t"), [.command]),
              domain: .workbench, nonKeyboardPath: .menu),
        // ⌘\ USED TO BE A SECOND CHORD FOR THIS COMMAND and is gone.
        // C-TABLE permits a command AT MOST ONE, so an alias is either a
        // command of its own — which "split right, again" is not — or it
        // is a chord the table cannot express. It was undocumented and
        // absent from every menu, so nothing announced it and nothing
        // loses it; a human who wants it back can bind it.
        .init(id: "pane.split-right", name: "Split Right",
              defaultChord: Chord(.character("d"), [.command]),
              domain: .workbench, nonKeyboardPath: .menu),
        .init(id: "pane.split-down", name: "Split Down",
              defaultChord: Chord(.character("d"), [.command, .shift]),
              domain: .workbench, nonKeyboardPath: .menu),
        .init(id: "slot.focus-next", name: "Next Slot",
              defaultChord: Chord(.character("]"), [.command]),
              domain: .workbench, nonKeyboardPath: .menu),
        .init(id: "slot.focus-previous", name: "Previous Slot",
              defaultChord: Chord(.character("["), [.command]),
              domain: .workbench, nonKeyboardPath: .menu),
        .init(id: "pane.next", name: "Next Pane",
              defaultChord: Chord(.character("]"), [.command, .shift]),
              domain: .workbench, nonKeyboardPath: .menu),
        .init(id: "pane.previous", name: "Previous Pane",
              defaultChord: Chord(.character("["), [.command, .shift]),
              domain: .workbench, nonKeyboardPath: .menu),
    ]

    // MARK: - The numbered families

    /// THREE FAMILIES OF NINE AND ONE OF SIX, generated rather than typed
    /// out, because a command HOLDS AT MOST ONE CHORD ([[RFC-0016]]
    /// C-TABLE): "go to workspace N" is nine commands and not one command
    /// with a number in it, and each needs its own identifier so the human
    /// can rebind exactly one of them.
    ///
    /// TWO OF THESE FAMILIES HAD NO MENU ITEM AT ALL — they lived only in
    /// an event monitor, which is what made them invisible and, under
    /// C-UNBOUND, unrepresentable: `NonKeyboardPath` has no empty value,
    /// so admitting them to the table is the same act as giving them one.
    private static let numbered: [KeyCommand] = {
        var rows: [KeyCommand] = []
        for n in 1...9 {
            let digit = Character("\(n)")
            rows.append(.init(id: "workspace.select-\(n)", name: "Workspace \(n)",
                              defaultChord: Chord(.character(digit), [.command]),
                              domain: .workbench,
                              nonKeyboardPath: .menu,
                              family: "workspace.select-"))
            rows.append(.init(id: "pane.select-\(n)", name: "Pane \(n)",
                              defaultChord: Chord(.character(digit), [.command, .option]),
                              domain: .workbench,
                              nonKeyboardPath: .menu,
                              family: "pane.select-"))
            rows.append(.init(id: "slot.select-\(n)", name: "Slot \(n)",
                              defaultChord: Chord(.character(digit), [.command, .control]),
                              domain: .workbench,
                              nonKeyboardPath: .menu,
                              family: "slot.select-"))
        }
        for (index, page) in AppPage.allCases.enumerated() {
            let digit = Character("\(index + 1)")
            rows.append(.init(id: "page.\(page.rawValue)", name: page.title,
                              defaultChord: Chord(.character(digit), [.command, .shift]),
                              domain: .workbench,
                              nonKeyboardPath: .menu))
        }
        return rows
    }()

    // MARK: - The rest of the workbench

    private static let workbench: [KeyCommand] = [
        .init(id: "palette.quick-connect", name: "Quick Connect",
              defaultChord: Chord(.character("k"), [.command]),
              domain: .workbench, nonKeyboardPath: .menu),
        .init(id: "sidebar.toggle", name: "Toggle Sidebar",
              defaultChord: Chord(.character("s"), [.command, .control]),
              domain: .workbench, nonKeyboardPath: .menu),
        .init(id: "settings.toggle-panel", name: "Appearance Panel",
              defaultChord: Chord(.character("p"), [.command, .option]),
              domain: .workbench, nonKeyboardPath: .control("Titlebar ▸ Appearance")),
        // ⌘, IS DELIBERATELY LEFT UNBOUND, having briefly been given to a
        // `settings.open` row here. That row was a SECOND command for an
        // act `page.settings` already performs, and two commands for one
        // act is a worse defect than an unclaimed chord: whichever the
        // human rebinds, the other still answers. ⌘, remains off the
        // refusal list ([[RFC-0016]] C-CHORD) because settings is the
        // workbench's own act — so a human who wants that convention can
        // bind it to `page.settings`, which is what the facility is for.
        .init(id: "help.shortcuts", name: "Keyboard Shortcuts",
              defaultChord: Chord(.character("/"), [.command, .shift]),
              domain: .workbench, nonKeyboardPath: .menu),
        .init(id: "files.show-hidden", name: "Show Hidden Files",
              defaultChord: Chord(.character("."), [.command, .shift]),
              domain: .workbench, nonKeyboardPath: .menu),
        // A COMMAND MAY SHIP HOLDING NOTHING. The layout presets have
        // always been menu-only, and the table admits them by the act they
        // are rather than by whether a chord happens to point at one —
        // which is also what lets the human bind one ([[RFC-0016]]
        // C-TABLE, C-UNBOUND).
    ] + SplitNode.LayoutPreset.allCases.map { preset in
        KeyCommand(id: "layout.\(preset.rawValue)", name: "Arrange: \(preset.label)",
                   defaultChord: nil, domain: .workbench,
                   nonKeyboardPath: .menu)
    } + [
        // ONE POSITION, THE WHOLE AREA, AND BACK ([[WI-2026-09-02-006]]).
        // ⌘⇧↩ is ghostty's own chord for it; under `layout.` so it is
        // offered only when there is more than one position, like the
        // arrangements above.
        KeyCommand(id: "layout.zoom", name: "Zoom Pane",
                   defaultChord: Chord(.named(.return), [.command, .shift]),
                   domain: .workbench, nonKeyboardPath: .menu),
        // PUSH AN EDGE OUT, AND EVEN SHARES ([[WI-2026-09-02-008]]).
        // ⌘⌃ + arrow: the arrow names the edge; ⌃ beside ⌘ keeps clear
        // of ⌘⌥ (tab jumps) and of the terminal's own ⌥-arrow words.
        // ⌘⌃= is ghostty's equalize_splits.
        KeyCommand(id: "layout.grow-left", name: "Resize Pane Left",
                   defaultChord: Chord(.named(.left), [.command, .control]),
                   domain: .workbench, nonKeyboardPath: .menu),
        KeyCommand(id: "layout.grow-right", name: "Resize Pane Right",
                   defaultChord: Chord(.named(.right), [.command, .control]),
                   domain: .workbench, nonKeyboardPath: .menu),
        KeyCommand(id: "layout.grow-up", name: "Resize Pane Up",
                   defaultChord: Chord(.named(.up), [.command, .control]),
                   domain: .workbench, nonKeyboardPath: .menu),
        KeyCommand(id: "layout.grow-down", name: "Resize Pane Down",
                   defaultChord: Chord(.named(.down), [.command, .control]),
                   domain: .workbench, nonKeyboardPath: .menu),
        KeyCommand(id: "layout.equalize", name: "Equalize Panes",
                   defaultChord: Chord(.character("="), [.command, .control]),
                   domain: .workbench, nonKeyboardPath: .menu),
        // TYPE INTO EVERY VISIBLE PANE, OR STOP ([[WI-2026-09-02-010]]).
        KeyCommand(id: "layout.broadcast", name: "Broadcast Input to Visible Panes",
                   defaultChord: Chord(.character("b"), [.command, .control]),
                   domain: .workbench, nonKeyboardPath: .menu),
    ]

    // MARK: - The terminal's own

    /// YIELDS TO TEXT ENTRY is the column that decides row 2 of the
    /// dispatch function and nothing else: copy and paste give way to a
    /// text field belonging to the leaf, so ⌘C copies the find query the
    /// human is typing rather than the screen behind it. Clearing and the
    /// font size do not — they act on the pane whether or not its own
    /// chrome has focus.
    /// A MENU OF THEIR OWN, AND NOT THE PLATFORM'S EDIT MENU. On macOS the
    /// thing that makes ⌘C reach a text field's `copy:` IS the Edit menu
    /// item's key equivalent, so putting THIS copy there and letting it
    /// carry the table's chord would kill text-field copy the moment a
    /// human rebound it — which [[RFC-0016]] C-TABLE's OUT list forbids.
    /// A separate item invokes the terminal's own act and leaves the
    /// platform's verb exactly where it was.
    private static let terminal: [KeyCommand] = [
        .init(id: "terminal.copy", name: "Copy",
              defaultChord: Chord(.character("c"), [.command]),
              domain: .terminal, yieldsToTextEntry: true,
              nonKeyboardPath: .menu),
        .init(id: "terminal.paste", name: "Paste",
              defaultChord: Chord(.character("v"), [.command]),
              domain: .terminal, yieldsToTextEntry: true,
              nonKeyboardPath: .menu),
        .init(id: "terminal.find", name: "Find in Scrollback",
              defaultChord: Chord(.character("f"), [.command]),
              domain: .terminal, yieldsToTextEntry: false,
              nonKeyboardPath: .menu),
        // GHOSTTY'S ⌘K, MOVED. The palette took the plain chord, and with
        // the engine's binding set emptied ([[RFC-0016]] C-TERMINAL) a
        // terminal command the table does not carry is simply gone — so
        // this row is what keeps clearing the screen reachable at all.
        // NEXT AND PREVIOUS MATCH. In the table rather than only on the
        // bar's own buttons: a find bar whose only way forward is the
        // mouse is the shape a human notices as wrong before they can say
        // why. They YIELD to text entry — the human is typing in the find
        // field when they press them, which is row 2's whole case — but
        // unlike copy and paste the field has no verb of its own for
        // them, so the yield is decided by [[RFC-0016]] C-DISPATCH's
        // table rather than assumed here.
        .init(id: "terminal.find-next", name: "Find Next",
              defaultChord: Chord(.character("g"), [.command]),
              domain: .terminal, yieldsToTextEntry: false,
              nonKeyboardPath: .control("Find bar ▸ ⌄")),
        .init(id: "terminal.find-previous", name: "Find Previous",
              defaultChord: Chord(.character("g"), [.command, .shift]),
              domain: .terminal, yieldsToTextEntry: false,
              nonKeyboardPath: .control("Find bar ▸ ⌃")),
        .init(id: "terminal.clear", name: "Clear Screen",
              defaultChord: Chord(.character("k"), [.command, .shift]),
              domain: .terminal, yieldsToTextEntry: false,
              nonKeyboardPath: .menu),
        .init(id: "terminal.font-increase", name: "Increase Font Size",
              defaultChord: Chord(.character("="), [.command]),
              domain: .terminal, yieldsToTextEntry: false,
              nonKeyboardPath: .menu),
        .init(id: "terminal.font-decrease", name: "Decrease Font Size",
              defaultChord: Chord(.character("-"), [.command]),
              domain: .terminal, yieldsToTextEntry: false,
              nonKeyboardPath: .menu),
        .init(id: "terminal.font-reset", name: "Reset Font Size",
              defaultChord: Chord(.character("0"), [.command]),
              domain: .terminal, yieldsToTextEntry: false,
              nonKeyboardPath: .menu),
    ]
}
