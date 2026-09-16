import SwiftUI

/// WHAT THE ONE DOT ON A WORKSPACE ROW SAYS.
///
/// IT USED TO SAY WHICH MACHINE, and that was a question the row had
/// already decided not to answer. [[WI-2026-08-17-026]] took the ADDRESS
/// off this row because a workspace may hold panes on three machines and a
/// container has no single one to name — [[RFC-0015]] C-LEAF-BINDING puts
/// that question on the leaf. The colour was computed the same way, from
/// `hosts(ofWorkspace:).first`, and survived the removal: the same
/// forbidden question, answered through a different channel, by picking
/// one machine out of however many.
///
/// AND IT WAS THE WRONG THING TO SPEND THE CHANNEL ON. The machine's name
/// is written on the row already; the hue repeated it. Meanwhile the one
/// fact the dot uniquely could carry — something in here needs you — was
/// drowned, because `DS.danger` and `DS.warning` are the only saturated
/// colours with a meaning and they were competing with three hundred and
/// sixty arbitrary hues. A red dot among a rainbow is just another colour.
///
/// THE MACHINE'S COLOUR IS NOT GONE, it is where it works: a pane tab has
/// no room for a name and is on exactly one machine ([[PaneTabBar]]), and
/// a host avatar IS a host ([[HostBlockView]]). This row was HostTint's
/// only consumer that coloured something which is not a single machine.
///
/// ONE DOT, ONE MEANING. The row used to draw up to three: this one, a
/// pulsing one after the label for a pane awaiting input, and another
/// after the agent icon for the agent's own. Three unlabelled dots is not
/// three channels, it is one channel used badly.
///
/// [[WI-2026-09-07-003]]
enum WorkspaceStatus: Equatable {
    /// Put away. Not a state of the work — a state of the row.
    case archived
    /// Something in here is waiting on the human.
    case attention
    /// A connection in here broke ([[RFC-0015]] C-FAILURE).
    case failed
    /// Running, and nothing wants anything.
    case quiet

    /// ATTENTION OUTRANKS FAILURE, WHICH IS NOT THE OBVIOUS ORDER.
    ///
    /// Broken is worse than waiting, so failure looks like it should win.
    /// It must not, because the two facts do not have the same number of
    /// channels: a failure ALSO puts its reason on the right of the row in
    /// red, and attention has nothing else once the second dot is gone. If
    /// failure took the dot, a workspace that had broken AND was waiting
    /// would show the break twice and the wait not at all.
    ///
    /// So the scarce channel goes to the fact with no other, and both
    /// remain readable: a human scanning for what is broken reads the red
    /// text, and one scanning for what wants them reads the dots.
    /// [[RFC-0015]] C-FAILURE is still met — it requires the break to be
    /// visible without opening the workspace, not to be visible twice.
    ///
    /// THAT ARGUMENT RESTS ENTIRELY ON THE SECOND CHANNEL EXISTING, and it
    /// stopped existing for a whole class of failure the same day it was
    /// written. [[WI-2026-09-07-004]] widened what marks a row to include a
    /// pane's own link, and the reason text came from
    /// `firstFailure` — connections only — so a workspace whose only
    /// trouble was a dropped link wore the mark with no reason and, where
    /// something also wanted the human, wore the ATTENTION mark and was
    /// indistinguishable from a workspace with nothing wrong.
    ///
    /// [[WorkspaceManager.failureReason]] is the second channel now, and
    /// it answers for both kinds. The precedence below is unchanged
    /// because the precedence was never the defect; the premise under it
    /// was, and a premise that has to hold is one to state where it can be
    /// checked ([[WI-2026-09-07-007]]).
    init(archived: Bool, attention: Bool, failed: Bool) {
        if archived { self = .archived }
        else if attention { self = .attention }
        else if failed { self = .failed }
        else { self = .quiet }
    }

    var color: Color {
        switch self {
        case .archived, .quiet: return DS.textTertiary
        case .attention: return DS.warning
        case .failed: return DS.danger
        }
    }

    /// A QUIET ROW KEEPS ITS PLACE IN THE COLUMN WITHOUT ASKING FOR THE
    /// EYE. The dot is smaller when it has nothing to say, so a column of
    /// running workspaces reads as a rail and the one that is alerting is
    /// the one that is seen. It is drawn in a fixed-width slot, so this
    /// changes weight and not alignment.
    ///
    /// IN DESIGN POINTS, SCALED BY THE CALLER. This dot scales with the UI
    /// size where the other `DSStatusDot`s in the app do not, and the
    /// reason is the slot: the archive glyph beside it is `DS.Icon.control`,
    /// which is scaled, so the slot has to be — and a fixed dot inside a
    /// growing slot shrinks to a speck at 150%.
    var dotSize: CGFloat { self == .quiet ? 5 : 8 }

    /// Only a state that WANTS something pulses. A failure has already
    /// happened and is not going to change while the human looks at it;
    /// motion is how "act on me" is said.
    var pulses: Bool { self == .attention }

    /// The state in words, because the dot is colour-only
    /// ([[WI-2026-08-09-020]]).
    ///
    /// NIL ONLY WHERE THE ROW'S OWN LABEL ALREADY SAYS IT, and that is a
    /// shorter list than it looks. The row is an
    /// `accessibilityElement(children: .ignore)`, so a label on the glyph
    /// itself is DISCARDED — the archive icon carried
    /// `accessibilityLabel("Archived")` and nothing has ever read it out.
    /// A failure is different: the row's own description appends the
    /// reason, so saying "failed" here would say it twice.
    var spoken: String? {
        switch self {
        case .attention: return "needs attention"
        case .archived: return "archived"
        case .failed, .quiet: return nil
        }
    }
}
