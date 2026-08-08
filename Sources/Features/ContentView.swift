import SwiftUI

/// Top-level application pages. Terminal is the default workspace; the
/// management surfaces (hosts/tasks/activity/hub) are full pages, not
/// modal popovers, so they can use the whole window.
enum AppPage: String, CaseIterable, Hashable {
    case terminal
    case hosts
    case tasks
    case activity
    case hub
    case settings

    /// Menu label — Go-to menu (WI-2026-08-08-053).
    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .hosts: return "Hosts"
        case .tasks: return "Tasks"
        case .activity: return "Activity"
        case .hub: return "Hub"
        case .settings: return "Settings"
        }
    }
}

struct ContentView: View {
    @State private var hostStore = HostStore()
    @State private var agentMonitor = AgentMonitor()
    @State private var paneManager = TerminalPaneManager()
    @State private var tunnelManager = TunnelManager()
    @State private var hubManager = HubManager()
    @State private var taskMonitor = TaskMonitor()
    @State private var settings = SynaptySettings.shared
    @State private var page: AppPage = .terminal
    @State private var showShortcuts = false
    @State private var showFindBar = false
    @State private var findText = ""
    /// Right settings panel visibility — global, persisted (WI-2026-08-07-002).
    @AppStorage("synapty.settingsPanelVisible") private var showSettingsPanel = false
    /// Left sidebar width — drag-resizable, persisted (WI-2026-08-08-080).
    @AppStorage("synapty.sidebarWidth") private var sidebarWidth: Double = 230
    /// Right settings panel width — drag-resizable (WI-2026-08-08-080).
    @State private var settingsPanelWidth: Double = 300
    /// Drag start anchors.
    @State private var sidebarDragStart: Double?
    @State private var panelDragStart: Double?
    /// Bumped on .synaptyUiScaleChanged so every page recomputes with the
    /// new DS.uiFontScale (WI-2026-08-08-070).
    @State private var uiScaleTick = 0
    /// Observed copy of GhosttyApp.shared — shared is a plain static var
    /// SwiftUI cannot track, so the readiness notification materializes it
    /// into @State (WI-2026-08-08-079).
    @State private var ghosttyAppState: GhosttyApp?

    var body: some View {
        // Reading the tick makes this body depend on UI-scale changes; the
        // whole tree recomputes with the new global font scale.
        let _ = uiScaleTick
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
                    handleHostConnect(host)
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
            .frame(width: sidebarWidth)
            DSDragDivider(
                onDrag: { delta in
                    let start = sidebarDragStart ?? sidebarWidth
                    sidebarDragStart = start
                    sidebarWidth = min(max(start + delta, 180), 320)
                },
                onEnded: { sidebarDragStart = nil }
            )
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
                        // Handle on the panel's LEFT edge (WI-2026-08-08-081).
                        DSDragDivider(
                            onDrag: { delta in
                                let start = panelDragStart ?? settingsPanelWidth
                                panelDragStart = start
                                settingsPanelWidth = min(max(start - delta, 260), 420)
                            },
                            onEnded: { panelDragStart = nil }
                        )
                        TerminalSettingsPanel(settings: settings) {
                            showSettingsPanel = false
                        }
                        .frame(width: settingsPanelWidth)
                    }
                }
            }
            .overlay {
                // Management pages are lightweight; render only when active.
                if page != .terminal {
                    switch page {
                    case .hosts:
                        HostsPageView(
                            hostStore: hostStore,
                            tunnelManager: tunnelManager,
                            onOpenTerminal: { host in
                                // One-click terminal from the Hosts list
                                // (WI-2026-08-08-064).
                                handleHostConnect(host)
                            }
                        )
                    case .tasks:
                        TaskListView(taskMonitor: taskMonitor)
                    case .activity:
                        ActivityLogView(taskMonitor: taskMonitor)
                    case .hub:
                        HubPageView(hubManager: hubManager, agentMonitor: agentMonitor, taskMonitor: taskMonitor)
                    case .settings:
                        SettingsPage(settings: settings, taskMonitor: taskMonitor)
                    case .terminal:
                        EmptyView()
                    }
                }

                // Other pages: settings panel floats over the content's right edge.
                if showSettingsPanel && page != .terminal {
                    HStack(spacing: 0) {
                        DSDragDivider(
                            onDrag: { delta in
                                let start = panelDragStart ?? settingsPanelWidth
                                panelDragStart = start
                                settingsPanelWidth = min(max(start - delta, 260), 420)
                            },
                            onEnded: { panelDragStart = nil }
                        )
                        TerminalSettingsPanel(settings: settings) {
                            showSettingsPanel = false
                        }
                        .frame(width: settingsPanelWidth)
                    }
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .background(Color.clear)
                    .shadow(color: .black.opacity(0.15), radius: 8, x: -2, y: 0)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Settings-panel toggle — available on EVERY page
                // (WI-2026-08-08-052). When the panel is visible it shifts
                // left of the panel instead of covering its close button.
                // Hidden while the panel is open — the panel header has its
                // own close button (WI-2026-08-08-081).
                if !showSettingsPanel {
                    Button {
                        showSettingsPanel.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.textSecondary)
                            .frame(width: 26, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.md)
                                    .fill(DS.hover)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Terminal settings panel (⌘⌥P)")
                    .accessibilityLabel("Terminal settings panel")
                    .padding(DS.Space.sm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.background)
        }
        .toolbar {
            // Navigation moved into the sidebar (layered groups); the
            // toolbar stays empty to avoid duplicated page switching.
        }
        .modifier(NotificationHandlers(
            page: $page,
            showShortcuts: $showShortcuts,
            showFindBar: $showFindBar,
            findText: $findText,
            showSettingsPanel: $showSettingsPanel,
            uiScaleTick: $uiScaleTick,
            ghosttyAppState: $ghosttyAppState,
            paneManager: paneManager,
            taskMonitor: taskMonitor
        ))
        .onAppear {
            TunnelManager.shared = tunnelManager
            tunnelManager.hostStore = hostStore
            // Apply configured ports before the hub starts / tunnels connect.
            hubManager.port = settings.hubPort
            tunnelManager.hubPort = settings.hubPort
            tunnelManager.tunnelPort = settings.tunnelPort
            TerminalCoordinatorRef.instance = paneManager
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
        // Window lifecycle + page-switch effects in one modifier — keeps
        // the main body expression small enough for the type-checker
        // (WI-2026-08-08-043 round).
        .modifier(WindowLifecycle(
            page: $page,
            taskMonitor: taskMonitor,
            ghosttyAppProvider: { GhosttyApp.shared },
            onStart: {
                hubManager.ensureRunning()
                agentMonitor.startMonitoring()
                taskMonitor.start()
                tunnelManager.startHeartbeat()
                if paneManager.sessions.isEmpty {
                    paneManager.addLocalSession()
                }
            },
            onStop: {
                agentMonitor.stopMonitoring()
                taskMonitor.stop()
                tunnelManager.stopHeartbeat()
                hubManager.shutdown()
                settings.flushPersistence()
            }
        ))
    }

    // MARK: - Terminal page

    private var terminalPage: some View {
        VStack(spacing: 0) {
            if let ghosttyApp = ghosttyAppState {
                if let session = paneManager.activeSession {
                    // Always visible for the active session — even while a
                    // connecting placeholder has no panes yet, so the
                    // terminal chrome does not jump (WI-2026-08-08-056).
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
                        ghosttyApp: ghosttyApp,
                        isTerminalPageVisible: page == .terminal
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
                // The settings-panel toggle lives at ContentView level now
                // (WI-2026-08-08-052) — available on every page.
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

    /// Shared single-host connect path (session picker, Hosts list):
    /// create the placeholder immediately, wire the tunnel when ready
    /// (WI-2026-08-08-064).
    private func handleHostConnect(_ host: HostEntry) {
        page = .terminal
        let sessionID = paneManager.addRemoteSessionPlaceholder(label: host.label, hostEntry: host)
        tunnelManager.ensureTunnel(for: host) { [weak paneManager] result in
            paneManager?.connectSession(id: sessionID, command: result.command, agentID: result.agentID)
        }
    }
}


// MARK: - Window lifecycle + page-switch effects

/// Holds the window min-size enforcement, teardown, and page-switch side
/// effects (surface pausing + activity-poll gating) — extracted from the
/// main body to keep its expression type-checkable (WI-2026-08-08-043).
private struct WindowLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Binding var page: AppPage
    let taskMonitor: TaskMonitor
    let ghosttyAppProvider: () -> GhosttyApp?
    let onStart: () -> Void
    let onStop: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                // The SwiftUI WindowGroup window often does not exist yet
                // at applicationDidFinishLaunching — enforce the min size
                // on the real window here (WI-2026-08-08-033).
                if let window = NSApp.keyWindow {
                    window.minSize = NSSize(width: 760, height: 480)
                }
                // Initial activity-poll state (WI-2026-08-08-041).
                taskMonitor.setActivityPollingEnabled(page == .activity)
            }
            // Service start/stop is scenePhase-driven (WI-2026-08-08-050):
            // onDisappear timing is unreliable (window close, tree removal).
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    onStart()
                case .background, .inactive:
                    onStop()
                @unknown default:
                    break
                }
            }
            // Page switch: pause hidden terminal surfaces (WI-2026-08-07-006)
            // and the Activity-page poll (WI-2026-08-08-041).
            .onChange(of: page) { _, newPage in
                ghosttyAppProvider()?.setSurfacesPaused(newPage != .terminal)
                taskMonitor.setActivityPollingEnabled(newPage == .activity)
            }
    }
}


// MARK: - Notification handlers (extracted for type-checker headroom)

/// All NotificationCenter observers in one modifier — keeps the main body
/// expression small enough for the type-checker (WI-2026-08-08-043,
/// WI-2026-08-08-079).
private struct NotificationHandlers: ViewModifier {
    @Binding var page: AppPage
    @Binding var showShortcuts: Bool
    @Binding var showFindBar: Bool
    @Binding var findText: String
    @Binding var showSettingsPanel: Bool
    @Binding var uiScaleTick: Int
    @Binding var ghosttyAppState: GhosttyApp?
    let paneManager: TerminalPaneManager
    let taskMonitor: TaskMonitor

    func body(content: Content) -> some View {
        content
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
                guard let surface = GhosttyApp.shared?.activeSurface else { return }
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
                showFindBar = true
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .synaptyShowShortcuts)
                    .merge(with: NotificationCenter.default.publisher(for: .synaptyShowHubPage))
            ) { note in
                switch note.name {
                case .synaptyShowShortcuts: showShortcuts = true
                case .synaptyShowHubPage: page = .hub
                default: break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .synaptyToggleSettingsPanel)) { _ in
                showSettingsPanel.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .synaptyShowPage)) { note in
                // Go-to menu / clickable status-bar badges (WI-2026-08-08-053).
                guard let raw = note.userInfo?["page"] as? String,
                      let target = AppPage(rawValue: raw) else { return }
                page = target
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .synaptyUiScaleChanged)
                    .merge(with: NotificationCenter.default.publisher(for: .synaptyGhosttyReady))
            ) { note in
                switch note.name {
                case .synaptyUiScaleChanged: uiScaleTick += 1
                default: ghosttyAppState = GhosttyApp.shared
                }
            }
    }
}
