import SwiftUI

/// Top-level application pages. Terminal is the default workspace; the
/// management surfaces (hosts/tasks/activity/hub) are full pages, not
/// modal popovers, so they can use the whole window.
enum AppPage: Hashable {
    case terminal
    case hosts
    case tasks
    case activity
    case hub
    case settings
}

struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var hostStore = HostStore()
    @StateObject private var agentMonitor = AgentMonitor()
    @StateObject private var paneManager = TerminalPaneManager()
    @StateObject private var tunnelManager = TunnelManager()
    @StateObject private var hubManager = HubManager()
    @StateObject private var taskMonitor = TaskMonitor()
    @StateObject private var settings = SynaptySettings()
    @State private var page: AppPage = .terminal
    @State private var showShortcuts = false
    @State private var showFindBar = false
    @State private var findText = ""

    var body: some View {
        NavigationSplitView {
            HostSidebar(
                hostStore: hostStore,
                paneManager: paneManager,
                tunnelManager: tunnelManager,
                agentMonitor: agentMonitor,
                onHostConnect: { host in
                    // Create placeholder immediately, update when tunnel is ready.
                    page = .terminal
                    let sessionID = paneManager.addRemoteSessionPlaceholder(label: host.label, hostEntry: host)
                    tunnelManager.ensureTunnel(for: host) { [weak paneManager] result in
                        paneManager?.connectSession(id: sessionID, command: result.command, agentID: result.agentID)
                    }
                },
                onNewLocalPane: {
                    page = .terminal
                    paneManager.addLocalSession()
                },
                onAgentTap: { [weak paneManager, weak agentMonitor] agent in
                    // Focus the session that owns this agent ID.
                    if let session = paneManager?.sessions.first(where: { $0.agentID == agent.id }) {
                        paneManager?.activeSessionID = session.id
                    }
                    agentMonitor?.clearAttention(agent.id)
                },
                onSessionSelect: {
                    page = .terminal
                }
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            ZStack {
                // Terminal workspace stays in the view tree at all times.
                // Destroying it on page switch would deinit the ghostty
                // surfaces, killing the PTY child processes and removing
                // sessions via close_surface_cb — "session cleared when
                // switching back". Hidden via opacity instead.
                terminalPage
                    .opacity(page == .terminal ? 1 : 0)
                    .allowsHitTesting(page == .terminal)
                    .accessibilityHidden(page != .terminal)

                // Management pages are lightweight; render only when active.
                if page != .terminal {
                    switch page {
                    case .hosts:
                        HostConfigSheet(hostStore: hostStore, tunnelManager: tunnelManager)
                    case .tasks:
                        TaskListView(taskMonitor: taskMonitor)
                    case .activity:
                        ActivityLogView(taskMonitor: taskMonitor)
                    case .hub:
                        HubStatusSheet(hubManager: hubManager, agentMonitor: agentMonitor, taskMonitor: taskMonitor)
                    case .settings:
                        SettingsPage(settings: settings)
                    case .terminal:
                        EmptyView()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Page switcher — icon-only, management surfaces are full pages.
                // No Terminal button: selecting a session in the sidebar always
                // returns to the terminal workspace.
                pageButton(.hosts, icon: "server.rack", help: "Host management")
                pageButton(.tasks, icon: "checklist", help: "Hub-repo task list")
                pageButton(.activity, icon: "tray.full", help: "Tool-request activity log")
                pageButton(.hub, icon: "dot.radiowaves.left.and.right", help: "Hub status")
                Spacer()
                pageButton(.settings, icon: "gearshape", help: "Settings")
            }
        }
        .sheet(isPresented: $showShortcuts) {
            KeyboardShortcutsView(isPresented: $showShortcuts)
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyNewSession)) { _ in
            page = .terminal
            paneManager.addLocalSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyTunnelFailed)) { note in
            guard let hostID = note.userInfo?["hostID"] as? UUID,
                  let message = note.userInfo?["message"] as? String else { return }
            paneManager.markSessionFailed(hostID: hostID, message: message)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .synaptyFontIncrease).merge(
                with: NotificationCenter.default.publisher(for: .synaptyFontDecrease),
                NotificationCenter.default.publisher(for: .synaptyFontReset)
            )
        ) { note in
            guard let surface = appDelegate.ghosttyApp?.activeSurface else { return }
            let action: String
            switch note.name {
            case .synaptyFontIncrease: action = "increase_font_size:1"
            case .synaptyFontDecrease: action = "decrease_font_size:1"
            default: action = "reset_font_size"
            }
            action.withCString { ptr in
                ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyFind)) { _ in
            // Cmd+F (or the View ▸ Find menu): show the find bar overlay.
            // Ghostty's core search is driven via the "search:<needle>"
            // binding action from the bar (WI-2026-03-31-006).
            showFindBar = true
        }
        .overlay(alignment: .top) {
            if showFindBar && page == .terminal {
                FindBarView(
                    text: $findText,
                    onTextChange: { needle in
                        guard let surface = appDelegate.ghosttyApp?.activeSurface else { return }
                        let action = "search:\(needle)"
                        action.withCString { ptr in
                            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                        }
                    },
                    onClose: {
                        guard let surface = appDelegate.ghosttyApp?.activeSurface else { return }
                        _ = "end_search".withCString { ptr in
                            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                        }
                        showFindBar = false
                        findText = ""
                    }
                )
                .padding(.top, 8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyShowShortcuts)) { _ in
            showShortcuts = true
        }
        .onAppear {
            TunnelManager.shared = tunnelManager
            tunnelManager.hostStore = hostStore
            TerminalCoordinatorRef.instance = paneManager
            Task { @MainActor in
                hubManager.ensureRunning()
                agentMonitor.startMonitoring()
                tunnelManager.startHeartbeat()
                if paneManager.sessions.isEmpty {
                    paneManager.addLocalSession()
                }
            }
        }
        .onDisappear {
            agentMonitor.stopMonitoring()
            tunnelManager.stopHeartbeat()
            hubManager.shutdown()
        }
    }

    // MARK: - Terminal page

    private var terminalPage: some View {
        VStack(spacing: 0) {
            if let ghosttyApp = appDelegate.ghosttyApp {
                if let session = paneManager.activeSession, session.panes.count > 0 {
                    PaneTabBar(paneManager: paneManager, session: session)
                }

                // Both the terminal surfaces and the placeholder stay in the
                // view tree; switching between them uses opacity, never
                // removal. Removing AllPanesSplitView (e.g. when the active
                // session is a connecting placeholder) would deinit every
                // ghostty surface — killing PTY children and clearing
                // sessions (recurring bug).
                ZStack {
                    AllPanesSplitView(
                        paneManager: paneManager,
                        ghosttyApp: ghosttyApp
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showPlaceholder ? 0 : 1)
                    .allowsHitTesting(!showPlaceholder)

                    if showPlaceholder {
                        SessionPlaceholderView(session: placeholderSession)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                VStack(spacing: DS.Space.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DS.accent)
                    Text("Initializing terminal…")
                        .font(DS.Typography.detail)
                        .foregroundStyle(DS.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.background)
            }
            ContextStatusBar(
                paneManager: paneManager,
                agentMonitor: agentMonitor,
                hubManager: hubManager,
                taskMonitor: taskMonitor
            )
        }
    }

    /// True when the active session is a connecting placeholder (no panes).
    private var showPlaceholder: Bool {
        guard let session = paneManager.activeSession else { return false }
        return session.panes.isEmpty
    }

    /// The placeholder session (active session when it has no panes).
    private var placeholderSession: TerminalPaneManager.Session {
        paneManager.activeSession ?? TerminalPaneManager.Session(
            label: "Local",
            hostEntry: nil,
            state: .connecting
        )
    }

    // MARK: - Page buttons

    private func pageButton(_ target: AppPage, icon: String, help: String) -> some View {
        let isActive = page == target
        return Button {
            page = target
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? DS.accent : DS.textSecondary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .fill(isActive ? DS.accentSoft : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .help(help)
        .buttonStyle(.plain)
    }
}
