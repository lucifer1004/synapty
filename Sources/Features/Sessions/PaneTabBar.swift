import SwiftUI

struct PaneTabBar: View {
    @ObservedObject var paneManager: TerminalPaneManager
    let session: TerminalPaneManager.Session

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(session.panes) { pane in
                        PaneTab(
                            pane: pane,
                            isActive: session.activePaneID == pane.id,
                            onSelect: { paneManager.activatePane(pane) },
                            onClose: { paneManager.removePane(pane) },
                            onRename: { newName in paneManager.renamePane(pane.id, to: newName) }
                        )
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
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack(spacing: 4) {
            if isEditing {
                TextField("Name", text: $editText, onCommit: {
                    if !editText.isEmpty { onRename(editText) }
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(minWidth: 60)
            } else {
                Text(pane.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        editText = pane.label
                        isEditing = true
                    }
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
