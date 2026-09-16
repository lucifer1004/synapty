import SwiftUI

/// The transient half of [[AppNotifications]], drawn where the human
/// already looks for what is happening to them.
///
/// BOTTOM RIGHT, RISING FROM THE STATUS BAR. The badge for things that are
/// waiting has always lived there, so "what is going on with me" already
/// has one place; putting outcomes anywhere else would make the eye check
/// two. It rises rather than drops because it is anchored to that bar
/// rather than floating over the window.
struct NotificationStack: View {
    let notifications: AppNotifications

    var body: some View {
        VStack(alignment: .trailing, spacing: DS.Space.xs) {
            ForEach(notifications.visible) { item in
                row(item)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: DS.scaled(360), alignment: .trailing)
        .padding(.trailing, DS.Space.lg)
        .padding(.bottom, DS.Space.sm)
        .animation(.easeOut(duration: 0.18), value: notifications.visible)
    }

    private func row(_ item: AppNotifications.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Image(systemName: item.tone.icon)
                .font(DS.Icon.control)
                .foregroundStyle(item.tone == .failed ? DS.danger : DS.success)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(DS.Typography.detail)
                    .lineLimit(1)
                if let detail = item.detail {
                    // The thing it happened TO. "Delivered" alone does not
                    // answer "delivered what", and this is the only chance
                    // to say so before the row goes.
                    Text(detail)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // DISMISSABLE, because a row that only leaves on its own is a
            // row that sits over the terminal for as long as it likes.
            DSIconButton(icon: "xmark", help: "Dismiss", size: 18) {
                notifications.dismiss(item.id)
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        // NO WIDTH HERE. A maxWidth on the row made the background fill it
        // whatever the text was, so "Delivered · probe.txt" sat in a card
        // with a hand's width of empty to its right. The cap belongs to
        // the CONTAINER, which proposes it downward: a short row then hugs
        // its own content and only a long one truncates.
        .background(DSChromeBackground())
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .stroke(DS.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
    }
}
