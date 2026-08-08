import SwiftUI

/// Session-based sidebar with layered navigation.
/// Top: grouped navigation (workspace / infrastructure / collaboration /
/// system). Bottom: active sessions (always visible so you can jump back
/// to the terminal from any page).
struct HostSidebar: View {
    @ObservedObject var hostStore: HostStore
    @ObservedObject var paneManager: TerminalPaneManager
    @ObservedObject var tunnelManager: TunnelManager
    @ObservedObject var agentMonitor: AgentMonitor
    /// Currently displayed application page (navigation selection).
    @Binding var page: AppPage
    @State private var showHostPicker = false
    /// ID of the session currently being renamed inline.
    @State private var editingSessionID: UUID?
    /// ONE shared ticker for all session rows (WI-2026-08-08-039) — the
    /// per-row Timer.publish churned a timer per row per parent render.
    @State private var sessionNow = Date()

    /// Called when the user picks a remote host from the picker.
    var onHostConnect: ((HostEntry) -> Void)?
    /// Called when the user picks "Local" from the picker.
    var onNewLocalPane: (() -> Void)?
    /// Called when the user taps the agent sub-row to focus its pane.
    var onAgentTap: ((AgentInfo) -> Void)?
    /// Called when the user selects a session in the list (switch to terminal page).
    var onSessionSelect: (() -> Void)?

    /// Navigation items, in display order. Icon-only rail (Termius style):
    /// no section headers, no text labels — compact and scroll-free.
    private static let navItems: [(page: AppPage, icon: String, label: String)] = [
        (.terminal, "terminal", "Terminal"),
        (.hosts, "server.rack", "Hosts"),
        (.tasks, "checklist", "Tasks"),
        (.activity, "tray.full", "Activity"),
        (.hub, "dot.radiowaves.left.and.right", "Hub"),
        (.settings, "gearshape", "Settings"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Icon navigation rail — single row, tooltips only.
            HStack(spacing: DS.Space.xs) {
                ForEach(Self.navItems, id: \.page) { item in
                    navButton(item)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)

            Divider()

            // Sessions — always visible; tapping one returns to Terminal.
            sessionsSection
        }
        .background(DS.sidebar)
    }

    private func navButton(_ item: (page: AppPage, icon: String, label: String)) -> some View {
        NavRailButton(item: item, isActive: page == item.page) {
            page = item.page
        }
    }

    /// The sessions list with the "+" new-session action.
    private var sessionsSection: some View {
        VStack(spacing: 0) {
            HStack {
                DSSectionLabel(text: "Sessions", count: paneManager.sessions.isEmpty ? nil : paneManager.sessions.count)
                Spacer()
                Button {
                    showHostPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(DS.accent, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(.plain)
                .help("New Session")
                .accessibilityLabel("New Session")
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
            .padding(.top, DS.Space.md)
            .padding(.bottom, DS.Space.sm)

            List(selection: Binding(
                get: { paneManager.activeSessionID },
                set: { id in
                    guard let id else { return }
                    Task { @MainActor in
                        paneManager.activeSessionID = id
                        // Selecting a session from the sidebar always returns
                        // to the terminal workspace.
                        onSessionSelect?()
                    }
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
                        // Agent lookup once per body — O(agents) total, not
                        // O(agents) per row (WI-2026-08-08-040).
                        let agentsByID = Dictionary(
                            uniqueKeysWithValues: agentMonitor.agents.map { ($0.id, $0) }
                        )
                        ForEach(paneManager.sessions) { session in
                            let agent = session.agentID.flatMap { agentsByID[$0] }
                            let attention = agent.map { agentMonitor.needsAttention.contains($0.id) } ?? false
                            SessionRow(
                                session: session,
                                paneManager: paneManager,
                                hostStore: hostStore,
                                editingSessionID: $editingSessionID,
                                agent: agent,
                                agentNeedsAttention: attention,
                                now: sessionNow,
                                onTap: {
                                    // Explicit tap handler: List selection's
                                    // set: does NOT fire when the clicked
                                    // session is already active, so returning
                                    // to the terminal from another page would
                                    // silently fail. Always select + switch.
                                    paneManager.activeSessionID = session.id
                                    onSessionSelect?()
                                }
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
            // ONE shared ticker for every session row's live duration
            // (WI-2026-08-08-039): one Timer-style loop, not one Timer per
            // row per render.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    sessionNow = Date()
                }
            }
        }
    }
}

// MARK: - Navigation rail button

/// Navigation rail icon button — soft fill + bottom indicator bar on the
/// active icon, hover feedback, tooltip (WI-2026-08-07-003).
private struct NavRailButton: View {
    let item: (page: AppPage, icon: String, label: String)
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            // Horizontal rail convention: soft fill + bottom indicator bar
            // under the active icon.
            VStack(spacing: 2) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? DS.accent : DS.textSecondary)
                    .frame(width: 26, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md)
                            .fill(isActive ? DS.accentSoft : (isHovered ? DS.hover : Color.clear))
                    )
                    .contentShape(Rectangle())
                Rectangle()
                    .fill(isActive ? DS.accent : Color.clear)
                    .frame(width: 18, height: 2)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .help(item.label)
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: TerminalPaneManager.Session
    @ObservedObject var paneManager: TerminalPaneManager
    @ObservedObject var hostStore: HostStore
    @Binding var editingSessionID: UUID?
    /// Agent registered on this session, if any.
    let agent: AgentInfo?
    let agentNeedsAttention: Bool
    /// Shared sidebar ticker value (WI-2026-08-08-039) — one ticker for
    /// all rows instead of a per-row Timer.publish that churned on every
    /// parent render.
    let now: Date
    /// Fired on row tap (selects session + returns to terminal page).
    var onTap: (() -> Void)? = nil

    @State private var editText = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var isHovered = false

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

    /// True when the host record changed AFTER this session was created —
    /// the session still uses the stale copy (Session.hostEntry is a value
    /// copy; WI-2026-08-08-045).
    private var configDrifted: Bool {
        guard let sessionHost = session.hostEntry,
              let current = hostStore.hosts.first(where: { $0.id == sessionHost.id })
        else { return false }
        return current.address != sessionHost.address
            || current.port != sessionHost.port
            || current.username != sessionHost.username
            || current.sshKeyPath != sessionHost.sshKeyPath
    }

    private var tabCount: Int { session.panes.count }

    private var splitCount: Int {
        session.panes.reduce(0) { $0 + $1.splitRoot.leaves.count }
    }

    /// Human-readable duration string from session creation. Session DOES
    /// carry createdAt (TerminalPaneManager.Session) — the `now` ticker is
    /// only for live elapsed-time updates (WI-2026-08-08-025).
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
                    if configDrifted {
                        Image(systemName: "arrow.triangle.2.circlepath.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.warning)
                            .help("Host config changed after this session started — reconnect to apply")
                    }
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
        .onTapGesture {
            // Always fires, even when the row is already the selected
            // session (List selection set: would not). Ensures returning
            // to the terminal page works from any page.
            onTap?()
        }
        .opacity(session.state == .connecting ? 0.7 : 1.0)
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
                                        // Effective credentials: host → identity → group chain.
                                        Text("\(tunnelManager.effectiveUsername(for: host))@\(host.address)")
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
