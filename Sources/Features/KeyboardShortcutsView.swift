import SwiftUI

/// Keyboard shortcuts reference sheet.
struct KeyboardShortcutsView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                }
                .padding()
            }
        }
        .frame(width: 380, height: 420)
    }

    private func shortcutSection(_ title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundColor(.secondary)

            ForEach(shortcuts, id: \.0) { name, key in
                HStack {
                    Text(name)
                        .font(.system(size: 13))
                    Spacer()
                    Text(key)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
