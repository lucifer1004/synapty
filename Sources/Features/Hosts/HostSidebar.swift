import SwiftUI

/// Session-based sidebar. Shows active terminal sessions with nested agent info and host management.
struct HostSidebar: View {
    @ObservedObject var hostStore: HostStore
    @ObservedObject var paneManager: TerminalPaneManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var agentMonitor: AgentMonitor
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
            // Header — single action: new session. Page navigation lives
            // in the window toolbar (no duplicated controls).
            HStack(spacing: DS.Space.sm) {
                Spacer(minLength: DS.Space.sm)

                // New session
                Button {
                    showHostPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(DS.accent, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(.plain)
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
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.lg)

            Divider()

            List(selection: Binding(
                get: { paneManager.activeSessionID },
                set: { id in
                    guard let id else { return }
                    Task { @MainActor in paneManager.activeSessionID = id }
                }
            )) {
                Section {
                    if paneManager.sessions.isEmpty {
                        VStack(spacing: DS.Space.sm) {
                            Image(systemName: "terminal")
                                .font(.system(size: 20))
                                .foregroundStyle(DS.textTertiary)
                            Text("No active sessions")
                                .font(DS.Typography.detail)
                                .foregroundStyle(DS.textSecondary)
                            Text("Press + to start a local or remote session")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.xxl)
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
                    DSSectionLabel(text: "Sessions", count: paneManager.sessions.isEmpty ? nil : paneManager.sessions.count)
                        .padding(.top, DS.Space.md)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard editingSessionID == nil,
                      let id = paneManager.activeSessionID else { return .ignored }
                editingSessionID = id
                return .handled
            }
        }
        .background(DS.sidebar)
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
    @State private var isHovered = false

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

    private var statusColor: Color {
        switch session.state {
        case .connecting: return DS.warning
        case .connected: return session.isLocal ? DS.success : DS.info
        case .failed: return DS.danger
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            // Status dot
            DSStatusDot(
                color: statusColor,
                size: 8,
                pulsing: session.state == .connecting
            )
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                // Primary row: label + duration
                HStack(spacing: DS.Space.xs) {
                    labelView
                    if case .connecting = session.state {
                        Text("connecting")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                    Spacer(minLength: DS.Space.xs)
                    if case .connected = session.state {
                        Text(durationString(from: session.createdAt))
                            .font(DS.Typography.monoCaption)
                            .foregroundStyle(DS.textTertiary)
                    }
                }

                // Host address — remote sessions only
                if let addr = hostAddress {
                    Text(addr)
                        .font(DS.Typography.monoCaption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }

                // Count summary — only when there is something notable
                if let summary = countSummary {
                    Text(summary)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                }

                // Error message
                if case .failed(let msg) = session.state {
                    Text(msg)
                        .font(DS.Typography.caption)
                        .foregroundColor(DS.danger)
                        .lineLimit(2)
                }

                // Agent sub-row — only when an agent is registered
                if let agent {
                    AgentSubRow(agent: agent, needsAttention: agentNeedsAttention)
                        .padding(.top, DS.Space.xs)
                }
            }
        }
        .padding(.vertical, DS.Space.sm)
        .padding(.horizontal, DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(isHovered ? DS.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .opacity(session.state == .connecting ? 0.7 : 1.0)
        .onReceive(timer) { date in now = date }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var labelView: some View {
        if isEditing {
            TextField("Name", text: $editText)
                .textFieldStyle(.plain)
                .font(DS.Typography.title)
                .focused($isTextFieldFocused)
                .onAppear {
                    editText = session.label
                    DispatchQueue.main.async { isTextFieldFocused = true }
                }
                .onSubmit { commitRename() }
                .onExitCommand { editingSessionID = nil }
                .onChange(of: isTextFieldFocused) { _, focused in
                    if !focused {
                        Task { @MainActor in commitRename() }
                    }
                }
        } else {
            Text(session.label)
                .font(DS.Typography.title)
                .lineLimit(1)
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
        needsAttention ? DS.warning : agent.tool.accentColor
    }

    private var iconColor: Color {
        needsAttention ? DS.warning : agent.tool.accentColor
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Accent rule
            RoundedRectangle(cornerRadius: 1)
                .fill(ruleColor)
                .frame(width: 2.5)

            HStack(alignment: .center, spacing: DS.Space.sm) {
                Image(systemName: agent.tool.sfSymbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 14, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.Space.xs) {
                        Text(agent.tool.displayName)
                            .font(DS.Typography.detailStrong)
                            .foregroundStyle(DS.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: DS.Space.xs)

                        if needsAttention {
                            DSStatusDot(color: DS.warning, size: 5, pulsing: true)
                        }
                    }

                    if agent.session != "-" {
                        Text(agent.session)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    } else if agent.project != "-" {
                        Text(agent.project)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
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
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.accent)
                Text("New Session")
                    .font(DS.Typography.titleLarge)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.lg)
            .padding(.bottom, DS.Space.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    // Local option — accent treatment
                    Button {
                        onSelectLocal()
                    } label: {
                        HStack(spacing: DS.Space.md) {
                            Image(systemName: "terminal")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DS.accent)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Local")
                                    .font(DS.Typography.bodyStrong)
                                Text("Terminal on this machine")
                                    .font(DS.Typography.caption)
                                    .foregroundStyle(DS.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.sm)
                        .background(DS.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !hostStore.hosts.isEmpty {
                        Divider()
                            .padding(.vertical, DS.Space.sm)

                        ForEach(hostStore.hosts) { host in
                            Button {
                                onSelectHost(host)
                            } label: {
                                HStack(spacing: DS.Space.md) {
                                    DSStatusDot(color: Color(tunnelManager.status(for: host).color), size: 8)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(host.label)
                                            .font(DS.Typography.bodyStrong)
                                        Text("\(host.username)@\(host.address)")
                                            .font(DS.Typography.monoCaption)
                                            .foregroundStyle(DS.textSecondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, DS.Space.lg)
                                .padding(.vertical, DS.Space.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, DS.Space.md)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 250)
    }
}
