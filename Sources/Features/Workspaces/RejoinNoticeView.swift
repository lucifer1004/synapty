import SwiftUI

/// WHAT A REOPENED PANE TELLS THE HUMAN ABOUT ITSELF ([[RFC-0015]]
/// C-HONESTY, [[WI-2026-08-17-027]]).
///
/// A RESTARTED PANE LOOKS EXACTLY LIKE A REJOINED ONE. Same directory,
/// same prompt, same title — and the difference is the build that is no
/// longer running in it. The only moment this can be said is when the pane
/// comes back, and the only place it can be said is on the pane itself:
/// one banner for the window would make the human count panes.
///
/// OVER THE PANE, NOT INSIDE ITS GRID. The terminal underneath is a
/// live pty being painted by ghostty; writing into it would put our words
/// in the scrollback the session owns.
///
/// AND THE PANE GIVES UP THE SPACE rather than being covered. Floated on
/// top, this strip sat exactly on the shell's first row — the pane read as
/// BLANK in a screenshot, and the prompt was underneath it. A notice the
/// human did not ask for must not hide the thing it is reporting on, so
/// the terminal is inset by this height while it shows, which is what a
/// browser's infobar does and why it is shaped like one.
struct RejoinNoticeView: View {
    /// FIXED, because the layout above subtracts it from the pane. A
    /// strip that sized itself would leave the terminal a gap that is
    /// nearly right.
    static let height: CGFloat = DS.scaled(22)

    /// WHAT THE TERMINAL GETS while this is up: its own rect, less the
    /// strip. Here rather than in the view above it so it can be put a
    /// case to — the defect it fixes was invisible in every unit test and
    /// showed up as a pane that photographed BLANK.
    static func paneRect(_ rect: CGRect, showing: Bool) -> CGRect {
        guard showing else { return rect }
        return CGRect(x: rect.minX, y: rect.minY + height,
                      width: rect.width, height: max(0, rect.height - height))
    }

    let told: Rejoining
    /// WHAT THIS PANE WAS RUNNING, where the workbench recorded it
    /// ([[RFC-0006]] C-RESUME-PLAN). Its presence is the whole condition
    /// on the offer below: this view is drawn only where the work did NOT
    /// come back, so there is no reachable state in which the button
    /// types into a session that is still running its agent
    /// ([[RFC-0014]] C-LIVE-CHILD).
    var plan: ResumePlan?
    var onResume: (() -> Void)?
    let onDismiss: () -> Void

    /// "Resume claude session a1b2c3", or nothing to offer.
    ///
    /// NAMED, because the human is being asked to authorise a specific
    /// act. "Resume" alone would be a button that types an incantation
    /// they cannot see into a shell they did not choose.
    static func offerLabel(_ plan: ResumePlan?) -> String? {
        guard let plan, plan.incantation != nil else { return nil }
        guard let ref = plan.resumeRef else { return "Resume \(plan.tool)" }
        return "Resume \(plan.tool) session \(ref.suffix(6))"
    }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.warning)
            Text(told.sentence)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.sm)
            // THE ONE ACT, and only the human performs it.
            if let label = Self.offerLabel(plan), let onResume {
                Button(label, action: onResume)
                    .buttonStyle(.link)
                    .font(DS.Typography.caption)
                    .help("Types the recorded re-attach line into this pane. "
                          + "It re-attaches the harness; it does not start a turn.")
            }
            DSIconButton(icon: "xmark", help: "Dismiss", size: 16, action: onDismiss)
        }
        .padding(.horizontal, DS.Space.md)
        .frame(height: Self.height)
        .background(DS.surfaceRaised)
        .overlay(alignment: .bottom) { DSHairline() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(told.sentence)
    }
}
