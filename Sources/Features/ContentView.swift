import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var hostStore = HostStore()
    @StateObject private var agentMonitor = AgentMonitor()
    @StateObject private var paneManager = TerminalPaneManager()
    @StateObject private var tunnelManager = TunnelManager()

    var body: some View {
        NavigationSplitView {
            HostSidebar(
                hostStore: hostStore,
                paneManager: paneManager,
                tunnelManager: tunnelManager,
                onHostConnect: { host in
                    tunnelManager.ensureTunnel(for: host) { [weak paneManager] cmd in
                        paneManager?.addRemoteSession(label: host.label, hostEntry: host, command: cmd)
                    }
                },
                onNewLocalPane: {
                    paneManager.addLocalSession()
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
                AgentStatusBar(agentMonitor: agentMonitor)
            }
        }
        .onAppear {
            agentMonitor.startMonitoring()
            tunnelManager.startHeartbeat()
            TunnelManager.shared = tunnelManager
        }
        .onDisappear {
            agentMonitor.stopMonitoring()
            tunnelManager.stopHeartbeat()
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyRequestSplit)) { notif in
            if let direction = notif.userInfo?["direction"] as? SplitNode.SplitDirection {
                paneManager.splitFocusedLeaf(direction: direction)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyRequestCloseSplit)) { _ in
            paneManager.closeFocusedLeaf()
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyRequestFocusNextSplit)) { _ in
            paneManager.focusNextLeaf()
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyRequestFocusPreviousSplit)) { _ in
            paneManager.focusPreviousLeaf()
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyLeafFocused)) { notif in
            if let leafID = notif.userInfo?["leafID"] as? UUID {
                paneManager.focusLeaf(leafID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyLeafClosed)) { notif in
            if let leafID = notif.userInfo?["leafID"] as? UUID {
                paneManager.closeLeaf(leafID)
            }
        }
    }
}
