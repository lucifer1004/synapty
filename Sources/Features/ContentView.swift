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
    /// Right settings panel visibility — global, persisted (WI-2026-08-07-002).
    @AppStorage("synapty.settingsPanelVisible") private var showSettingsPanel = false

    var body: some View {
        // Plain HStack instead of NavigationSplitView: the split view adds
        // ~10+ levels of internal hosting/NSView nesting, making every
        // layout pass (page switches, display cycles) expensive — the
        // "whole UI feels heavy" symptom (WI-2026-08-07-006).
        HStack(spacing: 0) {
            HostSidebar(
                hostStore: hostStore,
                paneManager: paneManager,
                tunnelManager: tunnelManager,
                agentMonitor: agentMonitor,
                page: $page,
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
            .frame(width: 230)
            Divider()
            ZStack {
                // Terminal page dock + right settings panel on the terminal
                // page (panel shrinks the terminal).
                HStack(spacing: 0) {
                    terminalPage
                        .opacity(page == .terminal ? 1 : 0)
                        .allowsHitTesting(page == .terminal)
                        .accessibilityHidden(page != .terminal)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showSettingsPanel && page == .terminal {
                        TerminalSettingsPanel(settings: settings) {
                            showSettingsPanel = false
                        }
                    }
                }
            }
            .overlay {
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

                // Other pages: settings panel floats over the content's right edge.
                if showSettingsPanel && page != .terminal {
                    TerminalSettingsPanel(settings: settings) {
                        showSettingsPanel = false
                    }
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .background(Color.clear)
                    .shadow(color: .black.opacity(0.15), radius: 8, x: -2, y: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.background)
        }
        .toolbar {
            // Navigation moved into the sidebar (layered groups); the
            // toolbar stays empty to avoid duplicated page switching.
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
            _ = action.withCString { ptr in
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
                        _ = action.withCString { ptr in
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
        .onReceive(NotificationCenter.default.publisher(for: .synaptyToggleSettingsPanel)) { _ in
            showSettingsPanel.toggle()
        }
        .onAppear {
            TunnelManager.shared = tunnelManager
            tunnelManager.hostStore = hostStore
            // Apply configured ports before the hub starts / tunnels connect.
            hubManager.port = settings.hubPort
            tunnelManager.hubPort = settings.hubPort
            tunnelManager.tunnelPort = settings.tunnelPort
            TerminalCoordinatorRef.instance = paneManager
            Task { @MainActor in
                hubManager.ensureRunning()
                agentMonitor.startMonitoring()
                taskMonitor.start()
                tunnelManager.startHeartbeat()
                if paneManager.sessions.isEmpty {
                    paneManager.addLocalSession()
                }
            }
        }
        // Port changes from Settings → Network apply on the next Hub start
        // (Hub page Restart) / next tunnel connection.
        .onChange(of: settings.hubPort) { _, newPort in
            hubManager.port = newPort
            tunnelManager.hubPort = newPort
        }
        .onChange(of: settings.tunnelPort) { _, newPort in
            tunnelManager.tunnelPort = newPort
        }
        .onDisappear {
            agentMonitor.stopMonitoring()
            taskMonitor.stop()
            tunnelManager.stopHeartbeat()
            hubManager.shutdown()
        }
        // Pause vsync rendering of hidden terminal surfaces while on other
        // pages — keeps the window compositor light (WI-2026-08-07-006).
        .onChange(of: page) { _, newPage in
            appDelegate.ghosttyApp?.setSurfacesPaused(newPage != .terminal)
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
                        SessionPlaceholderView(
                            session: placeholderSession,
                            onRetry: retryFailedSession
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Right settings panel toggle (WI-2026-08-07-002).
                    Button {
                        showSettingsPanel.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(showSettingsPanel ? DS.accent : DS.textSecondary)
                            .frame(width: 26, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.md)
                                    .fill(showSettingsPanel ? DS.accentSoft : DS.hover)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Terminal settings panel (⌘⌥P)")
                    .padding(DS.Space.sm)
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

    /// Re-run the tunnel setup for the failed placeholder session
    /// (WI-2026-08-07-004).
    private func retryFailedSession() {
        guard let session = paneManager.activeSession,
              let host = session.hostEntry else { return }
        let sessionID = session.id
        paneManager.markSessionConnecting(id: sessionID)
        tunnelManager.ensureTunnel(for: host) { [weak paneManager] result in
            paneManager?.connectSession(id: sessionID, command: result.command, agentID: result.agentID)
        }
    }
}
