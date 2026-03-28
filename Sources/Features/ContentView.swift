import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var hostStore = HostStore()
    @StateObject private var agentMonitor = AgentMonitor()
    @StateObject private var paneManager = TerminalPaneManager()
    @StateObject private var tunnelManager = TunnelManager()
    @StateObject private var hubManager = HubManager()
    @State private var showHubSheet = false

    var body: some View {
        NavigationSplitView {
            HostSidebar(
                hostStore: hostStore,
                paneManager: paneManager,
                tunnelManager: tunnelManager,
                agentMonitor: agentMonitor,
                onHostConnect: { host in
                    tunnelManager.ensureTunnel(for: host) { [weak paneManager] result in
                        paneManager?.addRemoteSession(label: host.label, hostEntry: host, command: result.command, agentID: result.agentID)
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
                ContextStatusBar(paneManager: paneManager, agentMonitor: agentMonitor, hubManager: hubManager)
            }
        }
        .toolbar {
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
            HubStatusSheet(hubManager: hubManager, agentMonitor: agentMonitor, isPresented: $showHubSheet)
        }
        .onAppear {
            hubManager.ensureRunning()
            agentMonitor.startMonitoring()
            tunnelManager.startHeartbeat()
            TunnelManager.shared = tunnelManager
            TerminalCoordinatorRef.instance = paneManager
            if paneManager.sessions.isEmpty {
                paneManager.addLocalSession()
            }
        }
        .onDisappear {
            agentMonitor.stopMonitoring()
            tunnelManager.stopHeartbeat()
            hubManager.shutdown()
        }
    }
}
