import SwiftUI

/// WHAT A PANE SAYS ABOUT OUTPUT IT CANNOT SHOW ([[RFC-0015]] C-FAILURE,
/// [[progress.Hole]]).
///
/// THE PANE IS WORKING AND IS STILL MISSING SOMETHING. A position the
/// holder could not honour leaves a repaint where a continuation should
/// have been; a catch-up the child outran leaves the scrollback with a gap
/// in it. Either way the screen looks complete and is not, and the only
/// way the human learns otherwise is scrolling up to find nothing there.
///
/// IT IS NOT A FAILURE, SO IT DISMISSES. [[LinkNoticeView]] refuses to,
/// because it reports a condition that is still true and a notice the
/// human can silence while the thing goes on being broken is a notice that
/// makes the pane lie quietly. This reports a fact about the past — the
/// gap does not grow, and nothing will fill it in — so it is theirs to
/// take or leave, exactly like [[RejoinNoticeView]].
///
/// OVER THE PANE AND NEVER INSIDE IT. C-FAILURE: the grid underneath holds
/// what the session did say, and our words do not go in it. The local
/// `attach` writes this same sentence into the terminal because with no
/// workbench there is no other surface; in a pane that is the mistake
/// [[WI-2026-08-29-004]] records.
struct HoleNoticeView: View {
    /// Verbatim from the far side. The workbench does not rewrite it: the
    /// sentence has one owner and it is [[progress.Hole]], so both clients
    /// say the same thing about the same event.
    let said: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "scissors")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.warning)
            Text(said)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Space.sm)
            DSIconButton(icon: "xmark", help: "Dismiss", size: 16, action: onDismiss)
        }
        .padding(.horizontal, DS.Space.md)
        .frame(height: PaneStrip.height)
        .background(DS.surfaceRaised)
        .overlay(alignment: .bottom) { DSHairline() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(said)
    }
}
