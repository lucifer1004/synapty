import AppKit

/// THE ONE PLACE A KEYSTROKE IS ANSWERED ([[RFC-0016]] C-TABLE, C-DISPATCH).
///
/// A LOCAL EVENT MONITOR AND NOT A MENU, because a monitor runs BEFORE the
/// window dispatches — and `GhosttyNSView.performKeyEquivalent` returns
/// true for every command-modified key equivalent it is offered, so a menu
/// shortcut never sees a keystroke while a terminal has focus. Claiming
/// the event here and passing through exactly what the table does not name
/// is the only arrangement in which the table is the sole authority.
///
/// The menu items keep their key equivalents for DISPLAY ([[RFC-0016]]
/// C-DISCOVERY) — they are read from this table too, and they never fire,
/// because the monitor has already consumed the event.
@MainActor @Observable final class KeyDispatcher {

    // Observable so a menu item redraws when a rebind moves its chord
    // ([[RFC-0016]] C-DISCOVERY): the display is read from the table, and
    // a table that changed while the menu was built would otherwise print
    // the old chord until the next launch.

    static let shared = KeyDispatcher()

    private(set) var keymap: Keymap
    private var monitor: Any?

    /// WHILE A SURFACE IS RECORDING, NOTHING IS DISPATCHED — row 1 of the
    /// function. Held here rather than discovered from the responder chain
    /// because it is a mode the panel enters deliberately, and a human
    /// recording ⌘W must not thereby close a pane.
    ///
    /// AND THE KEYSTROKE IS CONSUMED HERE, not passed down for a view to
    /// read. Row 1 says the keystroke IS the recording; letting it travel
    /// on so a recorder view could see it also let the MENU's key
    /// equivalent match it, so recording ⌘D split the pane — the same
    /// mechanism as the ⌘K echo, met from the other side. The recorder
    /// hands in a sink instead and this is the only reader.
    private var recordingSink: ((Chord) -> Void)?

    var isRecording: Bool { recordingSink != nil }

    func beginRecording(_ sink: @escaping (Chord) -> Void) { recordingSink = sink }
    func endRecording() { recordingSink = nil }

    /// A SURFACE THAT HAS TAKEN THE WINDOW REGISTERS ITS WAY OUT.
    ///
    /// Escape is not a binding — it is a surface's own exit, as it is for
    /// the recorder ([[RFC-0016]] C-REBIND) — and waiting for focus to
    /// arrive before honouring it is a race the human loses at speed. The
    /// palette's field takes first responder ASYNCHRONOUSLY after it
    /// appears; an Escape pressed before that lands on whatever still
    /// holds the responder, which is the terminal, so the palette stays
    /// open and the shell gets an escape character. Registering the exit
    /// makes it answered from the moment the surface exists.
    private var escapeExit: (() -> Void)?

    func claimEscape(_ exit: @escaping () -> Void) { escapeExit = exit }
    func releaseEscape() { escapeExit = nil }

    /// A TEXT FIELD THAT BELONGS TO A TERMINAL LEAF — row 2 of
    /// [[RFC-0016]] C-DISPATCH, and the only way that row is decidable.
    ///
    /// The row is defined over a surface BELONGING to a leaf, and no
    /// inspection of the responder chain yields that: an `NSTextField` in
    /// a SwiftUI hierarchy does not know which pane drew it. So the field
    /// says so itself, and names the leaf — which is also the terminal a
    /// `terminal` command dispatched from there acts on.
    private var textEntryLeaf: UUID?

    func claimTextEntry(leaf: UUID) { textEntryLeaf = leaf }
    func releaseTextEntry(leaf: UUID) {
        if textEntryLeaf == leaf { textEntryLeaf = nil }
    }

    private init() {
        keymap = Keymap.build(commands: KeyCommandTable.commands,
                              overrides: KeymapStore.load())
    }

    /// THE EFFECTIVE TABLE IS ALWAYS `build(defaults, overrides)`, REBUILT
    /// AFTER EVERY CHANGE TO THE STORE ([[RFC-0016]] C-CONFLICT) — never
    /// mutated in place, so removing an override that was displacing
    /// another command hands that command its binding back on THIS run
    /// rather than at the next launch.
    func reload() {
        keymap = Keymap.build(commands: KeyCommandTable.commands,
                              overrides: KeymapStore.load())
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    // MARK: - The function, applied to a real event

    /// Returns nil when the event is consumed here, or the event itself
    /// when it must go on to the responder chain — which for a live
    /// terminal means the shell.
    func handle(_ event: NSEvent) -> NSEvent? {
        // BEFORE THE TABLE, because Escape is nobody's binding: a
        // surface with an exit has claimed it, and while one has, no
        // command and no terminal may see it.
        if let escapeExit, event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           recordingSink == nil {
            escapeExit()
            return nil
        }
        guard let chord = Chord(event) else {
            // A keystroke this table cannot even name is still the
            // recording's while one is listening — passing it on would let
            // it type into whatever is behind the panel.
            return isRecording ? nil : event
        }
        switch keymap.resolve(chord, in: focusedSurface()) {
        case .recording:
            // ANSWERED, EVEN THOUGH NO COMMAND RAN. Consuming the event is
            // not enough on this platform: a menu's key equivalent fires
            // whatever the monitor returns, so a keystroke that is not
            // marked as answered arrives at the menu and runs the command
            // the human was trying to REBIND — recording ⌘D split the pane.
            // Row 1 is an answer like any other, and this is what says so.
            answered = Keystroke(event)
            recordingSink?(chord)
            return nil
        case .runWorkbench(let id), .runTerminal(let id):
            answered = Keystroke(event)
            performed(id)
            return nil
        case .toTerminalAsInput:
            return event
        case .toResponderChain:
            // A CHORD THIS TABLE NAMES, YIELDED TO WHAT HAS FOCUS — and
            // therefore one a menu item is still holding.
            //
            // [[RFC-0016]] C-TABLE: "copying FROM A TERMINAL is a command
            // in this table, and copying from a text field is the
            // platform's ... Which one a keystroke means is settled by
            // C-DISPATCH and not by precedence between two owners of one
            // chord." It WAS settled by precedence, and the wrong one won:
            // the platform offers an ENABLED key equivalent before the
            // responder chain sees the key, so Terminal ▸ Copy answered ⌘C
            // in every workbench text field — copying the terminal's empty
            // selection — and Terminal ▸ Paste typed the clipboard into
            // the human's shell instead of the field they were looking at.
            //
            // DISABLING THE ITEM DOES NOT FIX IT: SwiftUI's `disabled`
            // is whatever the last render decided, and focus moving into a
            // text field re-renders nothing. Measured — the item stayed
            // enabled and kept the chord.
            //
            // The item keeps its equivalent because C-DISCOVERY requires
            // it to SHOW the table's chord. What changes is that the act
            // happens here, and the keystroke is marked answered so the
            // menu's action does not then run the terminal's verb too.
            //
            // THE MARK IS NOT DECORATION, THOUGH NO TEST HERE CAN SEE IT.
            // Returning nil does not stop the equivalent (measured, above),
            // so without the mark Terminal ▸ Paste still fires AFTER the
            // field has been served — and types the clipboard into the
            // human's shell, which is the uglier half of what was
            // reported. A UI test cannot read that: the terminal is a
            // Metal surface with no accessible text.
            if let id = keymap.command(for: chord), let verb = Self.platformVerbs[id] {
                answered = Keystroke(event)
                NSApp.sendAction(verb, to: nil, from: nil)
                return nil
            }
            return event
        }
    }

    /// THE PLATFORM'S OWN VERB THAT EACH OF THESE MIRRORS
    /// ([[RFC-0016]] C-TABLE's OUT list).
    ///
    /// Only commands whose chord the platform also spends on a text field
    /// belong here. A terminal command the platform has no verb for —
    /// clearing the screen, changing the font size — yields to a text
    /// field by doing nothing, which is already right.
    private static let platformVerbs: [String: Selector] = [
        "terminal.copy": #selector(NSText.copy(_:)),
        "terminal.paste": #selector(NSText.paste(_:)),
    ]

    /// WHICH ROW THE FOCUSED SURFACE IS IN, by the first that matches.
    ///
    /// ROW 2 REQUIRES A TEXT FIELD THAT BELONGS TO A TERMINAL LEAF, and
    /// the find bar is one: it claims its leaf while it holds focus and
    /// releases it when it loses it, so a chord pressed mid-search
    /// resolves against the pane behind the bar rather than against the
    /// window. It carries whether that leaf still HAS a terminal, because
    /// a leaf that is dialling or has failed draws the same chrome with
    /// nothing behind it to act on.
    ///
    /// A text field belonging to no leaf is row 4 ([[RFC-0016]]
    /// C-DISPATCH), which is where the rest of the workbench's own chrome
    /// lands and where a new kind of surface lands until a row is added
    /// above it.
    private func focusedSurface() -> FocusedSurface {
        if isRecording { return .recorder }
        if let leaf = textEntryLeaf {
            return .textEntryOfTerminalLeaf(
                hasLiveTerminal: GhosttyApp.shared?.surface(forLeaf: leaf) != nil)
        }
        guard let responder = NSApp.keyWindow?.firstResponder as? GhosttyNSView,
              responder.surface != nil,
              responder.isVisiblePane, responder.isTerminalPageVisible
        else { return .other }
        return .liveTerminal
    }

    // MARK: - One keystroke, one command ([[RFC-0016]] C-DISPATCH)

    /// A KEYSTROKE THIS MONITOR HAS ALREADY ANSWERED.
    ///
    /// RETURNING nil FROM A LOCAL MONITOR DOES NOT STOP A SwiftUI MENU'S
    /// KEY EQUIVALENT — measured, not assumed: the monitor resolved ⌘K,
    /// ran the command and consumed the event, and fourteen milliseconds
    /// later the menu item fired and ran it again. On a toggle that is
    /// open-then-shut in one press, which reads as the palette failing to
    /// notice it was already open, with the full-window scrim flashing.
    ///
    /// The menu keeps its equivalent because it is what the human READS
    /// ([[RFC-0016]] C-DISCOVERY), so the second arrival is dropped here
    /// instead. Both mechanisms name the same command from the same
    /// table, so nothing about WHICH command a chord reaches was ever
    /// wrong — what had to be added is that a keystroke runs it AT MOST
    /// ONCE.
    struct Keystroke: Equatable {
        let timestamp: TimeInterval
        let keyCode: UInt16

        init(_ event: NSEvent) {
            timestamp = event.timestamp
            keyCode = event.keyCode
        }

        init(timestamp: TimeInterval, keyCode: UInt16) {
            self.timestamp = timestamp
            self.keyCode = keyCode
        }
    }

    private(set) var answered: Keystroke?

    /// Whether an invocation arriving now is the tail of a keystroke
    /// already answered. Pure, so the rule can be tested without an event
    /// loop; nil is a menu invoked by the mouse, which is never a
    /// duplicate.
    func isEcho(of keystroke: Keystroke?) -> Bool {
        guard let keystroke, let answered else { return false }
        return keystroke == answered
    }

    /// The menu's way in. Separate from `perform` so the drop is decided
    /// where the ambiguity is rather than inside every command.
    func performFromMenu(_ id: String) {
        let current = NSApp.currentEvent.flatMap { $0.type == .keyDown ? Keystroke($0) : nil }
        guard !isSuppressed(current) else { return }
        performed(id)
    }

    /// WHETHER A MENU INVOCATION ARRIVING NOW MUST BE DROPPED.
    ///
    /// Two reasons, and both are about a keystroke rather than about the
    /// command: it is the tail of one already answered ([[RFC-0016]]
    /// C-DISPATCH — one keystroke runs a command at most once), or a
    /// surface is RECORDING, in which case no keystroke dispatches
    /// anything at all (row 1). A menu click carries no keystroke and is
    /// never dropped for either reason.
    func isSuppressed(_ keystroke: Keystroke?) -> Bool {
        guard keystroke != nil else { return false }
        return isRecording || isEcho(of: keystroke)
    }

    // SEAMS FOR THE TESTS, which have no event loop to press a key in —
    // and named as such, because a comment saying "seam" is a claim only
    // this file can see, while the suffix is one a checker can.
    func rememberAnsweredForTesting(timestamp: TimeInterval, keyCode: UInt16) {
        answered = Keystroke(timestamp: timestamp, keyCode: keyCode)
    }

    func forgetAnsweredKeystrokeForTesting() { answered = nil }

    // MARK: - What a command does

    /// WHETHER THIS COMMAND HAS SOMETHING TO ACT ON ([[RFC-0016]]
    /// C-DISPATCH). Unavailability MUST be visible wherever the command is
    /// shown; a chord that does nothing and says nothing is
    /// indistinguishable from a binding that is broken.
    func isAvailable(_ id: String) -> Bool {
        guard let coordinator = TerminalCoordinatorRef.instance else { return true }
        if id.hasPrefix("layout.") { return coordinator.slotCount > 1 }
        if id == "workspace.close-pane" || id == "workspace.archive-pane" || id.hasPrefix("pane.split")
            || id.hasPrefix("slot.focus-") || id.hasPrefix("pane.select-")
            || id == "pane.next" || id == "pane.previous" {
            return coordinator.hasFocusedPane
        }
        if Self.engineActions[id] != nil { return coordinator.hasFocusedPane }
        return true
    }

    /// WHICH COMMANDS ACT ON THE LAYOUT, and therefore must have it in
    /// view before they act.
    private static func actsOnLayout(_ id: String) -> Bool {
        id.hasPrefix("pane.") || id.hasPrefix("slot.") || id.hasPrefix("layout.")
            || id == "workspace.close-pane" || id == "workspace.archive-pane" || id.hasPrefix("workspace.select-")
    }

    /// The registry. Kept beside the table rather than in it, so the table
    /// stays data that can be read and tested without an application.
    /// WHETHER ANYTHING ANSWERED THIS COMMAND.
    ///
    /// A ROW WITH NO ARM IS A MENU ITEM AND A CHORD THAT DO NOTHING, and
    /// nothing said so: the switch below ends in a chain of prefix tests
    /// and then simply falls off, so a command added to the table and not
    /// to this file was silently inert. The answer is returned rather than
    /// asserted here — `perform` is called from a keystroke and a menu,
    /// neither of which is a place to fail — and
    /// `testEveryRowOfTheTableIsPerformable` is what reads it
    /// ([[WI-2026-08-30-009]]).
    @discardableResult
    func performed(_ id: String) -> Bool {
        let coordinator = TerminalCoordinatorRef.instance
        // IT MUST NOT ACT ON A LAYOUT THE HUMAN CANNOT SEE ([[RFC-0016]]
        // C-DISPATCH). While a page is drawn over the layout, the layout
        // goes back in its place FIRST — an arrangement that changed
        // behind a page the human was reading is a change they meet later
        // with no way to account for it.
        if Self.actsOnLayout(id) { showPage(.terminal) }
        switch id {
        // Workspaces and panes
        case "workspace.new": post(.synaptyNewSession)
        case "workspace.close-pane": coordinator?.requestCloseSplit()
        case "workspace.archive-pane": coordinator?.requestArchivePane()
        case "pane.new": coordinator?.requestNewPane()
        case "pane.split-right": coordinator?.requestSplit(direction: .horizontal)
        case "pane.split-down": coordinator?.requestSplit(direction: .vertical)
        case "slot.focus-next": coordinator?.requestFocusNextSlot()
        case "layout.zoom": coordinator?.requestToggleZoom()
        case "layout.grow-left": coordinator?.requestResizeFocused(.left)
        case "layout.grow-right": coordinator?.requestResizeFocused(.right)
        case "layout.grow-up": coordinator?.requestResizeFocused(.up)
        case "layout.grow-down": coordinator?.requestResizeFocused(.down)
        case "layout.equalize": coordinator?.requestEqualizePositions()
        case "layout.broadcast": coordinator?.requestToggleBroadcast()
        case "slot.focus-previous": coordinator?.requestFocusPreviousSlot()
        case "pane.next": coordinator?.requestNextPane()
        case "pane.previous": coordinator?.requestPreviousPane()

        // The workbench's own surfaces
        case "palette.quick-connect": post(.synaptyQuickConnect)
        case "sidebar.toggle": post(.synaptyToggleSidebar)
        case "settings.toggle-panel": post(.synaptyToggleSettingsPanel)
        case "settings.open": showPage(.settings)
        case "help.shortcuts": post(.synaptyShowShortcuts)
        case "files.show-hidden": post(.synaptyToggleHiddenFiles)
        // FIND IS THE WORKBENCH'S BAR OVER A TERMINAL, not an engine
        // action: ghostty searches, but the field belongs to the leaf
        // ([[WI-2026-08-20-001]]). Asking the engine to `start_search`
        // and letting it ask us back for a bar was the arrangement that
        // ended in a flag nobody read.
        case "terminal.find": post(.synaptyFind)

        default:
            if let n = numberedSuffix(of: id, after: "workspace.select-") {
                coordinator?.requestSwitchWorkspace(index: n)
            } else if let n = numberedSuffix(of: id, after: "pane.select-") {
                coordinator?.requestSelectPane(index: n)
            } else if let n = numberedSuffix(of: id, after: "slot.select-") {
                coordinator?.requestFocusSlot(index: n)
            } else if id.hasPrefix("page."),
                      let page = AppPage(rawValue: String(id.dropFirst("page.".count))) {
                showPage(page)
            } else if id.hasPrefix("layout."),
                      let preset = SplitNode.LayoutPreset(rawValue: String(id.dropFirst("layout.".count))) {
                coordinator?.applyLayout(preset)
            } else if let action = Self.engineActions[id] {
                // A `terminal` command is dispatched as an ACTION against
                // the focused terminal rather than by letting a keystroke
                // through to an engine binding — the engine holds none
                // ([[RFC-0016]] C-TERMINAL).
                runEngineAction(action)
            } else {
                return false
            }
        }
        return true
    }

    /// The terminal's own commands, as the engine names them.
    private static let engineActions: [String: String] = [
        "terminal.copy": "copy_to_clipboard",
        "terminal.paste": "paste_from_clipboard",

        "terminal.find-next": "navigate_search:next",
        "terminal.find-previous": "navigate_search:previous",
        "terminal.clear": "clear_screen",
        // The font actions take a required f32 parameter; without one
        // ghostty's Action.parse fails and the binding silently does
        // nothing (WI-2026-03-31-005).
        "terminal.font-increase": "increase_font_size:1",
        "terminal.font-decrease": "decrease_font_size:1",
        "terminal.font-reset": "reset_font_size",
    ]

    /// AGAINST THE FOCUSED TERMINAL FOR A KEYSTROKE, AND THE LAST ONE FOR
    /// A CLICK. Row 3 guarantees a live terminal holds the responder when
    /// a chord gets here, so the first responder is the right target. A
    /// MENU CLICK is the other half — the non-keyboard path [[RFC-0016]]
    /// C-UNBOUND requires — and it arrives with the menu holding focus and
    /// no terminal responder at all; the terminal the human last worked in
    /// is what they mean, and it is what the old notification path used.
    private func runEngineAction(_ action: String) {
        // THE LEAF THE FOCUS BELONGS TO COMES FIRST. In row 2 the focus is
        // in a field, not in a terminal, and the terminal the command
        // means is the one that field belongs to — not whichever surface
        // was last active.
        let owned = textEntryLeaf.flatMap { GhosttyApp.shared?.surface(forLeaf: $0) }
        let focused = (NSApp.keyWindow?.firstResponder as? GhosttyNSView)?.surface
        guard let surface = owned ?? focused ?? GhosttyApp.shared?.activeSurface else { return }
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    private func numberedSuffix(of id: String, after prefix: String) -> Int? {
        guard id.hasPrefix(prefix) else { return nil }
        return Int(id.dropFirst(prefix.count))
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func showPage(_ page: AppPage) {
        NotificationCenter.default.post(name: .synaptyShowPage, object: nil,
                                        userInfo: ["page": page.rawValue])
    }
}

// MARK: - Reading a chord off an event

extension Chord {
    /// THE UNSHIFTED CHARACTER NAMES THE CHORD ([[RFC-0016]] C-CHORD), so
    /// this asks for the characters produced with NO modifiers applied
    /// rather than for `charactersIgnoringModifiers`, which still applies
    /// shift on several keys and would make a shifted binding
    /// unrecognisable to itself.
    init?(_ event: NSEvent) {
        var mods: Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }

        if let named = Self.namedKeys[event.keyCode] {
            self.init(.named(named), mods)
            return
        }
        let unshifted = event.characters(byApplyingModifiers: [])
            ?? event.charactersIgnoringModifiers
        guard let text = unshifted?.lowercased(), text.count == 1 else { return nil }
        self.init(.character(Character(text)), mods)
    }

    /// The keys that produce no character. Virtual key codes rather than
    /// characters, because that is the only thing they have.
    private static let namedKeys: [UInt16: NamedKey] = [
        53: .escape, 48: .tab, 36: .return, 51: .delete, 117: .forwardDelete,
        126: .up, 125: .down, 123: .left, 124: .right,
        115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
        122: .f1, 120: .f2, 99: .f3, 118: .f4, 96: .f5, 97: .f6,
        98: .f7, 100: .f8, 101: .f9, 109: .f10, 103: .f11, 111: .f12,
    ]
}
