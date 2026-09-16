import Foundation

/// WHAT BROADCAST FORWARDS, written down ([[WI-2026-09-02-010]]).
///
/// A key sent to the wrong machine cannot be taken back, so the rule is
/// a closed list rather than "whatever the focused pane received":
/// - KEYS, with their modifiers, presses, repeats and releases — the
///   armed panes see the same event the focused one did, so control
///   sequences and ghostty's own key encoding agree across them.
/// - IME-COMMITTED TEXT, once: the composition is the focused pane's
///   business, only its result is a keystroke.
/// - NOT PASTE. A paste is the one input whose size the human cannot see
///   at the moment of the act; a script pasted into eight machines is the
///   exact failure this refuses. It stays where ⌘V was pressed.
enum BroadcastRule {

    enum Input: Equatable {
        /// A key event that is not part of an IME composition.
        case key
        /// A key event that commits an IME composition (text arrives).
        case imeCommit
        /// A key event while a composition is still open.
        case imeComposing
        case paste
    }

    static func forwards(_ input: Input) -> Bool {
        switch input {
        case .key, .imeCommit: return true
        case .imeComposing, .paste: return false
        }
    }
}
