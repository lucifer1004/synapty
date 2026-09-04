import SwiftUI

/// WHAT A SURFACE DISPLAYS IS READ FROM THE TABLE ([[RFC-0016]]
/// C-DISCOVERY) — never typed in beside it, because a chord written by
/// hand is a claim about behaviour that nothing keeps true and stays on
/// screen looking authoritative for as long as it takes someone to notice.
extension Keymap {
    /// nil where the command holds nothing, which SwiftUI renders as a
    /// menu item with no chord beside it — the honest picture of a command
    /// the human has cleared ([[RFC-0016]] C-UNBOUND).
    func shortcut(of id: String) -> KeyboardShortcut? {
        guard let chord = chord(of: id) else { return nil }
        return KeyboardShortcut(chord.keyEquivalent, modifiers: chord.eventModifiers)
    }
}

extension Chord {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let c): return KeyEquivalent(c)
        case .named(let named):
            switch named {
            case .escape: return .escape
            case .tab: return .tab
            case .return: return .return
            case .delete: return .delete
            case .forwardDelete: return .deleteForward
            case .up: return .upArrow
            case .down: return .downArrow
            case .left: return .leftArrow
            case .right: return .rightArrow
            case .home: return .home
            case .end: return .end
            case .pageUp: return .pageUp
            case .pageDown: return .pageDown
            // SwiftUI has no KeyEquivalent for the function keys. They are
            // bindable and they dispatch — the monitor reads the event
            // directly — so what is missing is only the menu's printed
            // glyph, and printing a WRONG one would be worse.
            case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
                return KeyEquivalent(" ")
            }
        }
    }

    var eventModifiers: EventModifiers {
        var mods: EventModifiers = []
        if modifiers.contains(.command) { mods.insert(.command) }
        if modifiers.contains(.control) { mods.insert(.control) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        return mods
    }
}

/// HOW A CONTROL SAYS WHAT IT DOES AND HOW ELSE TO DO IT.
///
/// A tooltip or an empty state that INVOKES a table command must take the
/// chord from the table ([[RFC-0016]] C-DISCOVERY) — and where the human
/// has cleared that command it must name the non-keyboard path instead
/// rather than print an empty bracket or drop the sentence ([[RFC-0016]]
/// C-UNBOUND). Six controls typed their chord in by hand and went stale
/// the moment anyone rebound one ([[WI-2026-08-28-007]]).
@MainActor
enum CommandHint {

    /// "Close panel (⌘⌥P)", or "Close panel (View ▸ Appearance Panel)"
    /// where the command holds nothing.
    static func help(_ label: String, for id: String,
                     dispatcher: KeyDispatcher? = nil) -> String {
        "\(label) (\(reach(id, dispatcher: dispatcher)))"
    }

    /// "⇧⌘." or, where nothing is bound, the path that still works.
    /// `nil` IS THE ORDINARY CASE and is resolved inside, not in a
    /// default argument: a default is evaluated where the CALL is, and a
    /// main-actor singleton cannot be reached from there.
    static func reach(_ id: String, dispatcher: KeyDispatcher? = nil) -> String {
        let dispatcher = dispatcher ?? .shared
        if let chord = dispatcher.keymap.chord(of: id) { return chord.display }
        return KeyCommandTable.command(id)?.nonKeyboardPathDescription ?? id
    }
}

extension KeyCommandTable {
    private static let byID: [String: KeyCommand] =
        Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })

    static func command(_ id: String) -> KeyCommand? { byID[id] }
    static func name(of id: String) -> String { byID[id]?.name ?? id }
}

/// One menu item, whose label, chord and action all come from the table.
///
/// THE CHORD HERE IS DISPLAY AND NOT AUTHORITY. [[KeyDispatcher]]'s monitor
/// consumes the event before the menu is offered it, so this equivalent
/// never fires; it is what the human READS to learn the binding.
struct KeyCommandMenuItem: View {
    let id: String
    var dispatcher = KeyDispatcher.shared

    var body: some View {
        Button(KeyCommandTable.name(of: id)) {
            // THROUGH THE MENU'S OWN DOOR, because this action fires both
            // when the human clicks it and when the platform matches the
            // key equivalent below — and the second is a keystroke the
            // monitor has already answered ([[RFC-0016]] C-DISPATCH: one
            // keystroke runs a command at most once).
            dispatcher.performFromMenu(id)
        }
        .keyboardShortcut(dispatcher.keymap.shortcut(of: id))
        // SHOWN UNAVAILABLE RATHER THAN SILENT ([[RFC-0016]] C-DISPATCH):
        // closing a pane in a workspace that has none, arranging one
        // position. A menu item that greys out says so before the human
        // presses anything.
        .disabled(!dispatcher.isAvailable(id))
    }
}
