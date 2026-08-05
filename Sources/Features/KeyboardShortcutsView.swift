import SwiftUI

/// Keyboard shortcuts reference sheet.
struct KeyboardShortcutsView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            DSSheetHeader(title: "Keyboard Shortcuts", icon: "keyboard", isPresented: $isPresented)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    shortcutSection("Sessions & Tabs", shortcuts: [
                        ("New Session", "⌘N"),
                        ("New Tab", "⌘T"),
                        ("Close Split", "⌘W"),
                    ])

                    shortcutSection("Splitting", shortcuts: [
                        ("Split Right", "⌘D"),
                        ("Split Down", "⇧⌘D"),
                    ])

                    shortcutSection("Navigation", shortcuts: [
                        ("Next Split", "⌘]"),
                        ("Previous Split", "⌘["),
                        ("Next Tab", "⇧⌘]"),
                        ("Previous Tab", "⇧⌘["),
                        ("Session 1–9", "⌘1–⌘9"),
                    ])

                    shortcutSection("Editing", shortcuts: [
                        ("Copy", "⌘C"),
                        ("Paste", "⌘V"),
                        ("Rename (sidebar)", "Enter"),
                    ])

                    shortcutSection("Terminal", shortcuts: [
                        ("Find in Scrollback", "⌘F"),
                        ("Increase Font", "⌘+"),
                        ("Decrease Font", "⌘−"),
                        ("Reset Font", "⌘0"),
                    ])
                }
                .padding(DS.Space.xl)
            }
        }
        .frame(width: 400, height: 460)
        .background(DS.background)
    }

    private func shortcutSection(_ title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSSectionLabel(text: title)

            ForEach(shortcuts, id: \.0) { name, key in
                HStack {
                    Text(name)
                        .font(DS.Typography.body)
                    Spacer()
                    Text(key)
                        .font(DS.Typography.monoCaption)
                        .foregroundStyle(DS.textSecondary)
                        .padding(.horizontal, DS.Space.sm)
                        .padding(.vertical, 2)
                        .background(DS.hover, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
            }
        }
    }
}
