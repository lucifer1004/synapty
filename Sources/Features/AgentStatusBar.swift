import SwiftUI

/// Bottom context bar (28pt) — shows info about the currently focused session/pane.
/// Agents live in the sidebar; this bar provides "what am I looking at right now?"
struct ContextStatusBar: View {
    @ObservedObject var paneManager: TerminalPaneManager
    @ObservedObject var agentMonitor: AgentMonitor
    @ObservedObject var hubManager: HubManager

    var body: some View {
        HStack(spacing: 0) {
            // Left: focused session context
            focusedSessionInfo
                .frame(maxWidth: .infinity, alignment: .leading)

            // Right: Hub summary
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
