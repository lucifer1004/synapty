import SwiftUI

/// Session-based sidebar. Shows active terminal sessions, online agents, and host management.
struct HostSidebar: View {
    @ObservedObject var hostStore: HostStore
    @ObservedObject var paneManager: TerminalPaneManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var agentMonitor: AgentMonitor
    @State private var showHostConfig = false
    @State private var showHostPicker = false
    /// ID of the session currently being renamed inline.
    @State private var editingSessionID: UUID?

    /// Called when the user picks a remote host from the picker.
    var onHostConnect: ((HostEntry) -> Void)?
    /// Called when the user picks "Local" from the picker.
    var onNewLocalPane: (() -> Void)?
    /// Called when the user clicks an agent row to focus its pane.
    var onAgentTap: ((AgentInfo) -> Void)?

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
                            SessionRow(session: session, paneManager: paneManager, editingSessionID: $editingSessionID)
                                .tag(session.id)
                                .contextMenu {
                                    Button("Rename") {
                                        editingSessionID = session.id
                                    }
                                    Divider()
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
                            AgentRow(
                                agent: agent,
                                needsAttention: agentMonitor.needsAttention.contains(agent.id)
                            )
                            .onTapGesture { onAgentTap?(agent) }
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
            .onKeyPress(.return) {
                // Enter on selected session → inline rename (Finder pattern)
                guard let id = paneManager.activeSessionID else { return .ignored }
                editingSessionID = id
                return .handled
            }
        }
        .sheet(isPresented: $showHostConfig) {
            HostConfigSheet(hostStore: hostStore, tunnelManager: tunnelManager, isPresented: $showHostConfig)
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: TerminalPaneManager.Session
    @ObservedObject var paneManager: TerminalPaneManager
    @Binding var editingSessionID: UUID?
    @State private var editText = ""

    private var isEditing: Bool { editingSessionID == session.id }

    var body: some View {
        HStack(spacing: 6) {
            // Status dot
            switch session.state {
            case .connecting:
                Circle()
                    .fill(.yellow)
                    .frame(width: 8, height: 8)
                    .modifier(PulseAnimation())
            case .connected:
                Circle()
                    .fill(session.isLocal ? .green : .blue)
                    .frame(width: 8, height: 8)
            case .failed:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 1) {
                if isEditing {
                    TextField("Name", text: $editText, onCommit: {
                        if !editText.isEmpty {
                            paneManager.renameSession(session.id, to: editText)
                        }
                        editingSessionID = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onAppear { editText = session.label }
                    .onExitCommand { editingSessionID = nil }
                } else {
                    HStack(spacing: 4) {
                        Text(session.label)
                            .font(.body)
                            .lineLimit(1)
                        if case .connecting = session.state {
                            Text("...")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if session.panes.count > 1 {
                    Text("\(session.panes.count) panes")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if case .failed(let msg) = session.state {
                    Text(msg)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(session.state == .connecting ? 0.6 : 1.0)
    }
}

// MARK: - Agent Row

struct AgentRow: View {
    let agent: AgentInfo
    let needsAttention: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: agent.tool.sfSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(needsAttention ? .orange : agent.tool.accentColor)
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
            Spacer()
            if needsAttention {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                    .modifier(PulseAnimation())
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
