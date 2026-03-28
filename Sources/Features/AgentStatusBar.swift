import SwiftUI

// MARK: - Agent Status Rail (28pt, always visible)

struct AgentStatusBar: View {
    @ObservedObject var agentMonitor: AgentMonitor
    var onAgentTap: ((AgentInfo) -> Void)?

    var body: some View {
        HStack(spacing: 1) {
            if agentMonitor.agents.isEmpty {
                Text("No agents")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(agentMonitor.agents) { agent in
                            AgentChip(
                                agent: agent,
                                needsAttention: agentMonitor.needsAttention.contains(agent.id)
                            )
                            .onTapGesture { onAgentTap?(agent) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Spacer()
        }
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Agent Chip

struct AgentChip: View {
    let agent: AgentInfo
    let needsAttention: Bool
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

            if needsAttention {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                    .modifier(PulseAnimation())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            needsAttention ? Color.orange.opacity(0.6) : Color.primary.opacity(0.12),
                            lineWidth: needsAttention ? 1.5 : 0.5
                        )
                )
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help("\(agent.tool.displayName) — \(agent.id)\n\(agent.project)")
    }
}

// MARK: - Pulse Animation

struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
