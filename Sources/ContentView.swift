import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var hostStore = HostStore()
    @StateObject private var agentMonitor = AgentMonitor()
    @StateObject private var paneManager = TerminalPaneManager()
    @StateObject private var deployManager = DeployManager()

    var body: some View {
        NavigationSplitView {
            HostSidebar(
                hostStore: hostStore,
                paneManager: paneManager,
                onHostConnect: { host in
                    let cmd = deployManager.fullDeployCommand(for: host)
                    paneManager.addRemotePane(label: host.label, command: cmd)
                },
                onNewLocalPane: {
                    paneManager.addLocalPane()
                }
            )
        } detail: {
            VStack(spacing: 0) {
                if let ghosttyApp = appDelegate.ghosttyApp {
                    // All terminal panes kept alive in a ZStack; only the active one is visible.
                    // This preserves ghostty_surface_t state across session switches.
                    ZStack {
                        ForEach(paneManager.panes) { pane in
                            TerminalView(ghosttyApp: ghosttyApp, command: pane.command)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(paneManager.activePaneID == pane.id ? 1 : 0)
                                .allowsHitTesting(paneManager.activePaneID == pane.id)
                        }
                    }
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
        }
        .onDisappear {
            agentMonitor.stopMonitoring()
        }
    }
}
