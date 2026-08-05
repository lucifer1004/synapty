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
}

struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var hostStore = HostStore()
    @StateObject private var agentMonitor = AgentMonitor()
    @StateObject private var paneManager = TerminalPaneManager()
    @StateObject private var tunnelManager = TunnelManager()
    @StateObject private var hubManager = HubManager()
    @StateObject private var taskMonitor = TaskMonitor()
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
                page: $page,
                onHostConnect: { host in
                    // Create placeholder immediately, update when tunnel is ready.
                    let sessionID = paneManager.addRemoteSessionPlaceholder(label: host.label, hostEntry: host)
                    tunnelManager.ensureTunnel(for: host) { [weak paneManager] result in
                        paneManager?.connectSession(id: sessionID, command: result.command, agentID: result.agentID)
                    }
                },
                onNewLocalPane: {
                    paneManager.addLocalSession()
                },
                onAgentTap: { [weak paneManager, weak agentMonitor] agent in
                    // Focus the session that owns this agent ID.
                    if let session = paneManager?.sessions.first(where: { $0.agentID == agent.id }) {
                        paneManager?.activeSessionID = session.id
                    }
                    agentMonitor?.clearAttention(agent.id)
                }
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            switch page {
            case .terminal:
                terminalPage
            case .hosts:
                HostConfigSheet(hostStore: hostStore, tunnelManager: tunnelManager)
            case .tasks:
                TaskListView(taskMonitor: taskMonitor)
            case .activity:
                ActivityLogView(taskMonitor: taskMonitor)
            case .hub:
                HubStatusSheet(hubManager: hubManager, agentMonitor: agentMonitor, taskMonitor: taskMonitor)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Page switcher — management surfaces are full pages.
                pageButton(.hosts, icon: "server.rack", label: "Hosts", help: "Host management")
                pageButton(.tasks, icon: "checklist", label: "Tasks", help: "Hub-repo task list")
                pageButton(.activity, icon: "tray.full", label: "Activity", help: "Tool-request activity log (⌘⇧M)")
                pageButton(.hub, icon: "dot.radiowaves.left.and.right", label: "Hub", help: "Hub status")
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

                if let session = paneManager.activeSession, session.panes.isEmpty {
                    // Remote placeholder while the tunnel is being
                    // established, or a failed connection: show a status
                    // view instead of a terminal (no ghostty surface —
                    // a nil-command surface would spawn a local shell,
                    // WI-2026-03-31-003).
                    SessionPlaceholderView(session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AllPanesSplitView(
                        paneManager: paneManager,
                        ghosttyApp: ghosttyApp
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Page buttons

    private func pageButton(_ target: AppPage, icon: String, label: String, help: String) -> some View {
        let isActive = page == target
        return Button {
            page = target
        } label: {
            Label(label, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isActive ? DS.accent : DS.textSecondary)
        }
        .help(help)
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(isActive ? DS.accentSoft : Color.clear)
        )
    }
}
