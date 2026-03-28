import SwiftUI

/// Message log window — displays the Hub's global message log.
/// Opened via ⌘⇧M or toolbar button. Per [[RFC-0002:C-HUB-STATE]].
struct MessageLogView: View {
    @ObservedObject var agentMonitor: AgentMonitor

    var body: some View {
        VStack(spacing: 0) {
            if agentMonitor.messages.isEmpty {
                emptyState
            } else {
                messageTimeline
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "message")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No messages yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Messages between agents will appear here.\nAgents communicate via synapty send or MCP tools.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Message timeline

    private var messageTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(agentMonitor.messages) { msg in
                        MessageRow(message: msg)
                            .id(msg.id)
                    }
                }
                .padding()
            }
            .onChange(of: agentMonitor.messages.count) { _ in
                if let last = agentMonitor.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Message Row

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: sender + channel/DM + timestamp
            HStack(spacing: 6) {
                let tool = ToolType(from: message.from)
                Image(systemName: tool.sfSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tool.accentColor)

                Text(message.from)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tool.accentColor)

                if let channel = message.channel {
                    Text("→ #\(channel)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("(DM)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(formatTimestamp(message.timestamp))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Message text
            Text(message.text)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.04))
                )
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
