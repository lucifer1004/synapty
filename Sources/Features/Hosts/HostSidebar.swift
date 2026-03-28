import SwiftUI

/// Session-based sidebar. Shows active terminal sessions, online agents, and host management.
struct HostSidebar: View {
    @ObservedObject var hostStore: HostStore
    @ObservedObject var paneManager: TerminalPaneManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var agentMonitor: AgentMonitor
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
                        tunnelManager: tunnelManager,
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

            List(selection: Binding(
                get: { paneManager.activeSessionID },
                set: { id in
                    if let id { paneManager.activeSessionID = id }
                }
            )) {
                // SESSIONS section
                Section {
                    if paneManager.sessions.isEmpty {
                        Text("No active sessions")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(paneManager.sessions) { session in
                            SessionRow(session: session)
                                .tag(session.id)
                                .contextMenu {
                                    Button("Close Session") {
                                        paneManager.removeSession(session)
                                    }
                                }
                        }
                    }
                } header: {
                    Text("Sessions")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundColor(.secondary)
                }

                // AGENTS section per [[RFC-0002:C-AGENT-IDENTITY]]
                Section {
                    if agentMonitor.agents.isEmpty {
                        Text("No agents")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(agentMonitor.agents) { agent in
                            AgentRow(agent: agent)
                        }
                    }
                } header: {
                    Text("Agents")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.sidebar)
        }
        .sheet(isPresented: $showHostConfig) {
            HostConfigSheet(hostStore: hostStore, tunnelManager: tunnelManager, isPresented: $showHostConfig)
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: TerminalPaneManager.Session

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.isLocal ? .green : .blue)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.label)
                    .font(.body)
                    .lineLimit(1)
                if session.panes.count > 1 {
                    Text("\(session.panes.count) panes")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Agent Row

struct AgentRow: View {
    let agent: AgentInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: agent.tool.sfSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(agent.tool.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.tool.displayName)
                    .font(.body)
                    .lineLimit(1)
                if agent.session != "-" {
                    Text(agent.session)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(agent.id)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .help("\(agent.id)\n\(agent.project)")
    }
}

// MARK: - Host Picker Popover

struct HostPickerPopover: View {
    @ObservedObject var hostStore: HostStore
    @ObservedObject var tunnelManager: TunnelManager
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
                                    Circle()
                                        .fill(Color(tunnelManager.status(for: host).color))
                                        .frame(width: 8, height: 8)
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
