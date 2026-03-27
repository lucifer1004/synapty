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
                    // Pane tab bar (only shown when there is more than one pane)
                    if paneManager.panes.count > 1 {
                        PaneTabBar(paneManager: paneManager)
                    }

                    // Active terminal pane
                    if let active = paneManager.activePane {
                        TerminalView(ghosttyApp: ghosttyApp, command: active.command)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // Re-create the surface when the active pane changes
                            .id(active.id)
                    } else {
                        Color.black
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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

// MARK: - Pane Tab Bar

struct PaneTabBar: View {
    @ObservedObject var paneManager: TerminalPaneManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(paneManager.panes) { pane in
                    PaneTab(
                        pane: pane,
                        isActive: paneManager.activePaneID == pane.id,
                        onSelect: { paneManager.activate(pane) },
                        onClose: { paneManager.removePane(pane) }
                    )
                }
            }
        }
        .frame(height: 30)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct PaneTab: View {
    let pane: TerminalPaneManager.Pane
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(pane.label)
                .font(.system(size: 12))
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? Color(NSColor.selectedContentBackgroundColor).opacity(0.2) : Color.clear)
        .overlay(
            Rectangle()
                .frame(height: 2)
                .foregroundColor(isActive ? .accentColor : .clear),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}
