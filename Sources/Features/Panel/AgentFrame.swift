import SwiftUI

/// The container every piece of AGENT-PRESENTED content sits in, and the
/// only one it may sit in.
///
/// WHY THIS EXISTS, stated plainly because the reason is a threat and not a
/// preference. Agents act on material they read — a README, an issue body,
/// a page — and that material can instruct them. Today the worst outcome of
/// a poisoned agent is a wrong command, which a human sees in a pane. Once
/// an agent can put content on the screen, the worst outcome becomes a
/// convincing credential prompt drawn inside the window the human trusts
/// most. Nothing else in this application defends against that: the content
/// is arbitrary by design.
///
/// SO THE DEFENCE IS THAT IT NEVER LOOKS LIKE OURS. Agent content is inset
/// from the panel edge, framed, and carries a bar naming the agent that
/// asked for it. Whatever it renders inside, it cannot occupy the full
/// surface and cannot present itself as the application speaking, because
/// the frame around it is drawn by the application and the content cannot
/// reach outside it.
///
/// [[ADR-0010]] rule (d), [[RFC-0013]] C-REQUEST-NOT-SEIZE.
struct DSAgentFrame<Content: View>: View {

    /// The agent that asked for this. There is no anonymous presented
    /// content: a caller with nothing to attribute has nothing to show.
    let agent: String
    /// What the agent called it. Its own words, so it is rendered as a
    /// quotation rather than as a heading of ours.
    var title: String?
    var onDismiss: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            attributionBar
            DSHairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(DS.surface)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(DS.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        // INSET FROM THE PANEL EDGE. A full-bleed surface reads as the
        // application's own; a framed one reads as something the
        // application is holding.
        .padding(DS.Space.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Content from \(agent)")
    }

    /// ALWAYS PRESENT, never conditional on hover or focus. This bar is the
    /// thing that says "an agent put this here", so a state in which it is
    /// absent is a state in which agent content is indistinguishable from
    /// ours.
    private var attributionBar: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "cpu")
                .font(DS.Icon.mark)
                .foregroundStyle(DS.textTertiary)
            Text(agent)
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let title, !title.isEmpty {
                Text("·")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
                // The agent's own words, quoted. Rendering them as a plain
                // heading would let a title like "Synapty · Sign in" read as
                // this application's, which is the whole thing the frame is
                // here to prevent.
                Text("“\(title)”")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DS.Space.xs)
            if let onDismiss {
                DSIconButton(icon: "xmark", help: "Dismiss", size: 18) { onDismiss() }
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .background(DS.hover)
    }
}
