import SwiftUI

/// Bottom context bar (28pt) — shows info about the currently focused session/pane.
/// Agents live in the sidebar; this bar provides "what am I looking at right now?"
struct ContextStatusBar: View {
    @ObservedObject var paneManager: TerminalPaneManager
    @ObservedObject var agentMonitor: AgentMonitor
    @ObservedObject var hubManager: HubManager
    @ObservedObject var taskMonitor: TaskMonitor

    var body: some View {
        HStack(spacing: 0) {
            // Left: focused session context
            focusedSessionInfo
                .frame(maxWidth: .infinity, alignment: .leading)

            // Middle-right: per-project task badges (RFC-0003 C-UI)
            projectBadges

            // Right: bridge state + Hub summary
            bridgeStatusView
            hubSummary
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Focused session info

    @ViewBuilder
    private var focusedSessionInfo: some View {
        if let session = paneManager.activeSession {
            HStack(spacing: 6) {
                // Session type indicator
                Circle()
                    .fill(session.isLocal ? .green : .blue)
                    .frame(width: 7, height: 7)

                // Agent info if registered, otherwise session label
                if let agentID = session.agentID,
                   let agent = agentMonitor.agents.first(where: { $0.id == agentID }) {
                    Image(systemName: agent.tool.sfSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(agent.tool.accentColor)
                    Text(agent.tool.displayName)
                        .font(.system(size: 11, weight: .medium))
                    if agent.session != "-" {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(agent.session)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(session.label)
                        .font(.system(size: 11, weight: .medium))
                    if let agentID = session.agentID {
                        Text(agentID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        } else {
            Text("No active session")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Project task badges (RFC-0003 C-UI)

    private var projectBadges: some View {
        let counts = taskMonitor.projectCounts
        return HStack(spacing: 8) {
            ForEach(counts.keys.sorted(), id: \.self) { project in
                if let c = counts[project] {
                    HStack(spacing: 4) {
                        Text(project.replacingOccurrences(of: "p:", with: ""))
                            .font(.system(size: 10, weight: .semibold))
                        if c.doing > 0 {
                            Text("\(c.doing)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.blue)
                        }
                        if c.todo > 0 {
                            Text("\(c.todo)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        if c.done > 0 {
                            Text("\(c.done)✓")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    // MARK: - Bridge state (C-AUTH)

    @ViewBuilder
    private var bridgeStatusView: some View {
        switch taskMonitor.bridgeStatus {
        case .unknown, .configured:
            EmptyView()
        case .notConfigured:
            Button {
                // Opens the setup hint — login happens in a terminal.
                NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens?type=beta")!)
            } label: {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
            .help("GitHub bridge not configured — run `synapty github login` in a pane")
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(.red)
                .help(taskMonitor.lastError ?? "GitHub bridge error")
        }
    }

    // MARK: - Hub summary

    private var hubSummary: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(hubManager.status.isRunning ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            let count = agentMonitor.agents.count
            Text("Hub: \(count) agent\(count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Pulse Animation (used by sidebar AgentRow)

struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
