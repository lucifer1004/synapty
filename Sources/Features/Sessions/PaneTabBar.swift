import SwiftUI

struct PaneTabBar: View {
    @ObservedObject var paneManager: TerminalPaneManager
    let session: TerminalPaneManager.Session
    @State private var showRenameAlert = false
    @State private var renamePaneID: UUID?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(session.panes) { pane in
                        PaneTab(
                            pane: pane,
                            isActive: session.activePaneID == pane.id,
                            onSelect: { paneManager.activatePane(pane) },
                            onClose: { paneManager.removePane(pane) }
                        )
                        .contextMenu {
                            Button("Rename...") {
                                renamePaneID = pane.id
                                renameText = pane.label
                                showRenameAlert = true
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
        .alert("Rename Tab", isPresented: $showRenameAlert) {
            TextField("Tab name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = renamePaneID, !renameText.isEmpty {
                    paneManager.renamePane(id, to: renameText)
                }
            }
        }
    }
}

struct PaneTab: View {
    let pane: TerminalPaneManager.Pane
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(pane.label)
                .font(.system(size: 12))
                .lineLimit(1)

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
