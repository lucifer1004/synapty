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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Find", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                .onChange(of: text) { _, newValue in
                    onTextChange(newValue)
                }
                .onSubmit {
                    onTextChange(text)
                }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close search (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .shadow(radius: 6)
        .onExitCommand {
            onClose()
        }
        .onAppear {
            focused = true
        }
    }
}
