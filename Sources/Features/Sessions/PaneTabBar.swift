import SwiftUI

struct PaneTabBar: View {
    @ObservedObject var paneManager: TerminalPaneManager
    let session: TerminalPaneManager.Session
    @State private var editingPaneID: UUID?

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(session.panes) { pane in
                        PaneTab(
                            pane: pane,
                            isActive: session.activePaneID == pane.id,
                            editingPaneID: $editingPaneID,
                            onSelect: { paneManager.activatePane(pane) },
                            onClose: { paneManager.removePane(pane) },
                            onRename: { newName in paneManager.renamePane(pane.id, to: newName) }
                        )
                        .contextMenu {
                            Button("Rename") {
                                editingPaneID = pane.id
                            }
                            Divider()
                            Button("Close Tab") {
                                paneManager.removePane(pane)
                            }
                        }
                    }
                }
            }

            // New pane
            Button {
                paneManager.addPaneToActiveSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(DS.hover, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
            .buttonStyle(.plain)
            .help("New pane in this session")
            .padding(.trailing, DS.Space.sm)
        }
        .padding(.leading, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .frame(height: DS.Layout.tabBarHeight)
        .background(DS.surface)
        .overlay(alignment: .bottom) { Divider() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard editingPaneID == nil,
                  let activePaneID = session.activePaneID else { return .ignored }
            editingPaneID = activePaneID
            return .handled
        }
    }
}

struct PaneTab: View {
    let pane: TerminalPaneManager.Pane
    let isActive: Bool
    @Binding var editingPaneID: UUID?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var editText = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var isHovered = false

    private var isEditing: Bool { editingPaneID == pane.id }

    private func commitRename() {
        if !editText.isEmpty { onRename(editText) }
        editingPaneID = nil
    }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            // Terminal glyph for tab identity
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(isActive ? DS.accent : DS.textTertiary)

            if isEditing {
                TextField("Name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.body)
                    .frame(minWidth: 50)
                    .focused($isTextFieldFocused)
                    .onAppear {
                        editText = pane.label
                        DispatchQueue.main.async {
                            isTextFieldFocused = true
                        }
                    }
                    .onSubmit { commitRename() }
                    .onExitCommand { editingPaneID = nil }
                    .onChange(of: isTextFieldFocused) { _, focused in
                        if !focused {
                            Task { @MainActor in commitRename() }
                        }
                    }
            } else {
                Text(pane.label)
                    .font(DS.Typography.bodyStrong)
                    .lineLimit(1)
            }

            if isHovered || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.textTertiary)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(isActive ? DS.accentSoft : (isHovered ? DS.hover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(isActive ? DS.accent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in isHovered = hovering }
    }
}
