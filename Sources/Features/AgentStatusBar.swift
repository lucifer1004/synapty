import SwiftUI

// MARK: - Agent Status Rail (28pt, always visible)

struct AgentStatusBar: View {
    @ObservedObject var agentMonitor: AgentMonitor
    @ObservedObject var hubManager: HubManager

    var body: some View {
        HStack(spacing: 1) {
            // Hub status pill
            HubStatusPill(hubManager: hubManager)

            Divider().frame(height: 16)

            // Agent chips (horizontal scroll)
            if agentMonitor.agents.isEmpty {
                Text("No agents")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(agentMonitor.agents) { agent in
                            AgentChip(agent: agent)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Spacer()

            if agentMonitor.messageCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 9))
                    Text("\(agentMonitor.messageCount)")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.secondary)
                .padding(.trailing, 8)
            }
        }
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Hub Status Pill

struct HubStatusPill: View {
    @ObservedObject var hubManager: HubManager

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text("Hub")
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch hubManager.status {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Agent Chip

struct AgentChip: View {
    let agent: AgentInfo
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: agent.tool.sfSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(agent.tool.accentColor)

            VStack(alignment: .leading, spacing: 0) {
                Text(agent.tool.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                if agent.session != "-" {
                    Text(agent.session)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help("\(agent.tool.displayName) — \(agent.id)\n\(agent.project)")
    }
}
