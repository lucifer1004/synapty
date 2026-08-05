import SwiftUI

/// Minimal find-in-scrollback bar (WI-2026-03-31-006).
///
/// Ghostty's core performs the search; the embedder supplies the bar UI.
/// Each keystroke issues a `search:<needle>` binding action; closing issues
/// `end_search` and hides the bar.
struct FindBarView: View {
    @Binding var text: String
    let onTextChange: (String) -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.accent)
            TextField("Find in scrollback", text: $text)
                .textFieldStyle(.plain)
                .font(DS.Typography.mono)
                .focused($focused)
                .onChange(of: text) { _, newValue in
                    onTextChange(newValue)
                }
                .onSubmit {
                    onTextChange(text)
                }
            Divider()
                .frame(height: 14)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(DS.hover, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close search (Esc)")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .frame(width: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .stroke(DS.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .onExitCommand {
            onClose()
        }
        .onAppear {
            focused = true
        }
    }
}
