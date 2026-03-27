import SwiftUI

struct AgentStatusBar: View {
    @ObservedObject var agentMonitor: AgentMonitor

    var body: some View {
        HStack(spacing: 8) {
            if agentMonitor.agents.isEmpty {
                Text("No agents connected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(agentMonitor.agents, id: \.self) { agent in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text(agent)
                            .font(.caption)
                    }
                }
            }

            Spacer()

            if agentMonitor.messageCount > 0 {
                Text("\(agentMonitor.messageCount) msgs")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
