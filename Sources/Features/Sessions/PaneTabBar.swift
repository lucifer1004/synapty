import SwiftUI

struct PaneTabBar: View {
    @ObservedObject var paneManager: TerminalPaneManager
    let session: TerminalPaneManager.Session
    @State private var editingPaneID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
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

            Button {
                paneManager.addPaneToActiveSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .help("New pane in this session")
        }
        .frame(height: 30)
        .background(Color(NSColor.windowBackgroundColor))
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

    private var isEditing: Bool { editingPaneID == pane.id }

    var body: some View {
        HStack(spacing: 4) {
            if isEditing {
                TextField("Name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(minWidth: 50)
                    .focused($isTextFieldFocused)
                    .onAppear {
                        editText = pane.label
                        DispatchQueue.main.async {
                            isTextFieldFocused = true
                        }
                    }
                    .onSubmit {
                        if !editText.isEmpty { onRename(editText) }
                        editingPaneID = nil
                    }
                    .onExitCommand { editingPaneID = nil }
            } else {
                Text(pane.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? Color(NSColor.selectedContentBackgroundColor).opacity(0.2) : Color.clear)
        .overlay(
            Rectangle()
                .frame(height: 2)
                .foregroundColor(isActive ? .accentColor : .clear),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}
