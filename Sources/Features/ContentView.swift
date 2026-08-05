import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var hostStore = HostStore()
    @StateObject private var agentMonitor = AgentMonitor()
    @StateObject private var paneManager = TerminalPaneManager()
    @StateObject private var tunnelManager = TunnelManager()
    @StateObject private var hubManager = HubManager()
    @StateObject private var taskMonitor = TaskMonitor()
    @State private var showHubSheet = false
    @State private var showShortcuts = false
    @State private var showActivityLog = false
    @State private var showTaskList = false

    var body: some View {
        NavigationSplitView {
            HostSidebar(
                hostStore: hostStore,
                paneManager: paneManager,
                tunnelManager: tunnelManager,
                agentMonitor: agentMonitor,
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
        } detail: {
            VStack(spacing: 0) {
                if let ghosttyApp = appDelegate.ghosttyApp {
                    if let session = paneManager.activeSession, session.panes.count > 0 {
                        PaneTabBar(paneManager: paneManager, session: session)
                    }

                    AllPanesSplitView(
                        paneManager: paneManager,
                        ghosttyApp: ghosttyApp
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Initializing terminal...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                        .foregroundColor(.white)
                }
                ContextStatusBar(
                    paneManager: paneManager,
                    agentMonitor: agentMonitor,
                    hubManager: hubManager,
                    taskMonitor: taskMonitor
                )
            }
        }
        .sheet(isPresented: $showActivityLog) {
            ActivityLogView(taskMonitor: taskMonitor)
        }
        .sheet(isPresented: $showTaskList) {
            TaskListView(taskMonitor: taskMonitor)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showTaskList = true
                } label: {
                    Label("Tasks", systemImage: "checklist")
                }
                .help("Hub-repo task list")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showActivityLog = true
                } label: {
                    Label("Activity", systemImage: "tray.full")
                }
                .help("Tool-request activity log (⌘⇧M)")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showHubSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(hubManager.status.isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text("Hub")
                            .font(.caption)
                    }
                }
                .help("Hub Status")
            }
        }
        .sheet(isPresented: $showHubSheet) {
            HubStatusSheet(hubManager: hubManager, agentMonitor: agentMonitor, taskMonitor: taskMonitor, isPresented: $showHubSheet)
        }
        .sheet(isPresented: $showShortcuts) {
            KeyboardShortcutsView(isPresented: $showShortcuts)
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyNewSession)) { _ in
            paneManager.addLocalSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyShowShortcuts)) { _ in
            showShortcuts = true
        }
        .onAppear {
            TunnelManager.shared = tunnelManager
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
}
