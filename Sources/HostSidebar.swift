import SwiftUI

/// Session-based sidebar. Shows active terminal sessions.
/// Gear button opens host config sheet. Plus button opens host picker.
struct HostSidebar: View {
    @ObservedObject var hostStore: HostStore
    @ObservedObject var paneManager: TerminalPaneManager
    @State private var showHostConfig = false
    @State private var showHostPicker = false

    /// Called when the user picks a remote host from the picker.
    var onHostConnect: ((HostEntry) -> Void)?
    /// Called when the user picks "Local" from the picker.
    var onNewLocalPane: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Header with gear and plus buttons
            HStack {
                Button {
                    showHostConfig = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Host Configuration")

                Spacer()

                Button {
                    showHostPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Session")
                .popover(isPresented: $showHostPicker, arrowEdge: .bottom) {
                    HostPickerPopover(
                        hostStore: hostStore,
                        onSelectLocal: {
                            showHostPicker = false
                            onNewLocalPane?()
                        },
                        onSelectHost: { host in
                            showHostPicker = false
                            onHostConnect?(host)
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Session list
            if paneManager.panes.isEmpty {
                VStack(spacing: 8) {
                    Text("No active sessions")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("Click + to open a session")
                        .foregroundColor(.secondary)
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { paneManager.activePaneID },
                    set: { id in
                        if let id { paneManager.activePaneID = id }
                    }
                )) {
                    ForEach(paneManager.panes) { pane in
                        SessionRow(pane: pane)
                            .tag(pane.id)
                            .contextMenu {
                                Button("Close Session") {
                                    paneManager.removePane(pane)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .sheet(isPresented: $showHostConfig) {
            HostConfigSheet(hostStore: hostStore, isPresented: $showHostConfig)
        }
    }
}

/// Row in the session list showing the pane label.
struct SessionRow: View {
    let pane: TerminalPaneManager.Pane

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(pane.command == nil ? .green : .blue)
                .frame(width: 8, height: 8)
            Text(pane.label)
                .font(.body)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// Popover showing available hosts to connect to.
struct HostPickerPopover: View {
    @ObservedObject var hostStore: HostStore
    var onSelectLocal: () -> Void
    var onSelectHost: (HostEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Session")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // Local is always first
                    Button {
                        onSelectLocal()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "terminal")
                                .frame(width: 16)
                            Text("Local")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !hostStore.hosts.isEmpty {
                        Divider()
                            .padding(.vertical, 4)

                        ForEach(hostStore.hosts) { host in
                            Button {
                                onSelectHost(host)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "server.rack")
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(host.label)
                                            .font(.body)
                                        Text("\(host.username)@\(host.address)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 220)
    }
}
