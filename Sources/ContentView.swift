import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var hostStore = HostStore()
    @StateObject private var agentMonitor = AgentMonitor()

    var body: some View {
        NavigationSplitView {
            HostSidebar(hostStore: hostStore)
        } detail: {
            VStack(spacing: 0) {
                if let ghosttyApp = appDelegate.ghosttyApp {
                    TerminalView(ghosttyApp: ghosttyApp)
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
