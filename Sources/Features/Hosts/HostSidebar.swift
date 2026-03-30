import SwiftUI

/// Session-based sidebar. Shows active terminal sessions with nested agent info and host management.
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
    /// Called when the user taps the agent sub-row to focus its pane.
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
                Section {
                    if paneManager.sessions.isEmpty {
                        Text("No active sessions")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(paneManager.sessions) { session in
                            let agent = agentMonitor.agents.first(where: { $0.id == session.agentID })
                            let attention = agent.map { agentMonitor.needsAttention.contains($0.id) } ?? false
                            SessionRow(
                                session: session,
                                paneManager: paneManager,
                                editingSessionID: $editingSessionID,
                                agent: agent,
                                agentNeedsAttention: attention
                            )
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
            }
            .listStyle(.sidebar)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard editingSessionID == nil,
                      let id = paneManager.activeSessionID else { return .ignored }
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
    /// Agent registered on this session, if any.
    let agent: AgentInfo?
    let agentNeedsAttention: Bool

    @State private var editText = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var now = Date()

    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var isEditing: Bool { editingSessionID == session.id }

    private func commitRename() {
        if !editText.isEmpty {
            paneManager.renameSession(session.id, to: editText)
        }
        editingSessionID = nil
    }

    // MARK: - Derived display values

    private var hostAddress: String? {
        guard let host = session.hostEntry else { return nil }
        return "\(host.username)@\(host.address)"
    }

    private var tabCount: Int { session.panes.count }

    private var splitCount: Int {
        session.panes.reduce(0) { $0 + $1.splitRoot.leaves.count }
    }

    /// Human-readable duration string from session creation. Sessions don't carry a
    /// `createdAt` timestamp in V1 data model, so we derive from `agentID` presence
    /// as a proxy and fall back to the `now` ticker for display only.
    /// NOTE: When `Session` gains a `createdAt: Date` field this should use that directly.
    private func durationString(from date: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(date))
        if elapsed < 60 { return "< 1m" }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    /// Tab + split count summary, e.g. "2 tabs · 3 splits", "1 tab", "2 tabs"
    private var countSummary: String? {
        let tabs = tabCount
        let splits = session.panes.reduce(0) { $0 + max(0, $1.splitRoot.leaves.count - 1) }
        var parts: [String] = []
        if tabs > 1 { parts.append("\(tabs) tabs") }
        if splits > 0 { parts.append("\(splits) split\(splits == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Status dot — vertically centered with label
            statusDot
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                // Primary row: label + duration
                HStack(spacing: 0) {
                    labelView
                    Spacer(minLength: 6)
                    if case .connecting = session.state {
                        EmptyView()
                    } else if case .failed = session.state {
                        EmptyView()
                    } else {
                        Text(durationString(from: session.createdAt))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Host address — remote sessions only
                if let addr = hostAddress {
                    Text(addr)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Count summary — only when there is something notable
                if let summary = countSummary {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                // Error message
                if case .failed(let msg) = session.state {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }

                // Agent sub-row — only when an agent is registered
                if let agent {
                    AgentSubRow(agent: agent, needsAttention: agentNeedsAttention)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(session.state == .connecting ? 0.6 : 1.0)
        .onReceive(timer) { date in now = date }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusDot: some View {
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
    }

    @ViewBuilder
    private var labelView: some View {
        if isEditing {
            TextField("Name", text: $editText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($isTextFieldFocused)
                .onAppear {
                    editText = session.label
                    DispatchQueue.main.async { isTextFieldFocused = true }
                }
                .onSubmit { commitRename() }
                .onExitCommand { editingSessionID = nil }
                .onChange(of: isTextFieldFocused) { _, focused in
                    if !focused { commitRename() }
                }
        } else {
            HStack(spacing: 4) {
                Text(session.label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if case .connecting = session.state {
                    Text("connecting")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Agent Sub-Row

/// Nested agent display within a session row.
/// A 2pt vertical rule in the tool's accent color (amber when attention) visually
/// anchors the agent to its parent session.
struct AgentSubRow: View {
    let agent: AgentInfo
    let needsAttention: Bool

    private var ruleColor: Color {
        needsAttention ? .orange : agent.tool.accentColor
    }

    private var iconColor: Color {
        needsAttention ? .orange : agent.tool.accentColor
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Accent rule
            Rectangle()
                .fill(ruleColor)
                .frame(width: 2)
                .cornerRadius(1)

            HStack(alignment: .center, spacing: 5) {
                Image(systemName: agent.tool.sfSymbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 14, alignment: .center)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(agent.tool.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 4)

                        if needsAttention {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 5, height: 5)
                                .modifier(PulseAnimation())
                        }
                    }

                    if agent.session != "-" {
                        Text(agent.session)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if agent.project != "-" {
                        Text(agent.project)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.vertical, 3)
        }
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
