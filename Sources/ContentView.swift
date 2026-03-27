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
                    // Pane tab bar for the active session
                    if let session = paneManager.activeSession, session.panes.count > 0 {
                        PaneTabBar(paneManager: paneManager, session: session)
                    }

                    // Render ALL panes' leaves in a single ZStack so surfaces
                    // survive tab switches. Only the active pane's leaves are visible.
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
            // Split keyboard shortcuts
            .keyboardShortcut(for: .splitRight, action: {
                paneManager.splitFocusedLeaf(direction: .horizontal)
            })
            .keyboardShortcut(for: .splitDown, action: {
                paneManager.splitFocusedLeaf(direction: .vertical)
            })
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

// MARK: - Split Keyboard Shortcuts

enum SplitShortcut {
    case splitRight, splitDown
}

extension View {
    func keyboardShortcut(for shortcut: SplitShortcut, action: @escaping () -> Void) -> some View {
        // SwiftUI doesn't have a clean way to add arbitrary keyboard shortcuts
        // to non-Button views. We use overlay buttons instead.
        self
    }
}

// MARK: - Pane Tab Bar

struct PaneTabBar: View {
    @ObservedObject var paneManager: TerminalPaneManager
    let session: TerminalPaneManager.Session

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(session.panes) { pane in
                        PaneTab(
                            pane: pane,
                            isActive: session.activePaneID == pane.id,
                            onSelect: { paneManager.activatePane(pane) },
                            onClose: { paneManager.removePane(pane) }
                        )
                    }
                }
            }

            Button {
                paneManager.addPaneToActiveSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .help("New pane in this session")
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
