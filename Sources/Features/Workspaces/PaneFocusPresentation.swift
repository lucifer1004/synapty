import Foundation

/// How a pane says it has the keyboard, and how the others say they do
/// not.
///
/// THE FOCUSED PANE WEARS NOTHING. A 2pt accent ring around it was the
/// previous answer, and it was the wrong kind of answer: it decorated the
/// one surface the human is reading, half of it fell outside the window at
/// the edges, and it shared its exact shape with the attention ring so the
/// two differed by hue alone. Terminals settled this long ago (ghostty's
/// own frontend, iTerm2, kitty): the panes NOT in focus step back, under a
/// wash of their own background, and the one in focus is simply the one
/// left alone. The tab strip then carries the positive signal — the
/// focused slot's active tab wears the accent — so the eye has one place
/// to confirm what the wash implies ([[WI-2026-09-02-003]]).
enum PaneFocusPresentation {

    /// THE WASH IS THE PANE'S OWN BACKGROUND, so it leaves the background
    /// where it is and takes this fraction out of the text's contrast —
    /// the pane does not change color, its writing steps back. That is
    /// why it cannot be very light: at 0.12 (measured) nothing visibly
    /// happened. Ghostty's own default is 0.3; this stays under it because
    /// the other panes on an agent workbench are being watched, not
    /// parked.
    static let dimOpacity: Double = 0.25

    /// Whether a visible pane sits under the wash. Never with one slot
    /// (there is nothing to tell apart), never the focused pane, and
    /// never a pane asking for attention — a pane that wants the human is
    /// the one thing that must not recede.
    static func dims(paneID: UUID, focusedPaneID: UUID?, slotCount: Int,
                     awaitingAttention: Bool) -> Bool {
        guard slotCount > 1, !awaitingAttention else { return false }
        return paneID != focusedPaneID
    }

    /// The active tab of the focused slot, and no other tab — in one slot
    /// as much as in four, since "the tab with the keyboard" is a fact
    /// that does not appear when the window splits.
    static func tabWearsAccent(isActive: Bool, inFocusedSlot: Bool) -> Bool {
        isActive && inFocusedSlot
    }
}
