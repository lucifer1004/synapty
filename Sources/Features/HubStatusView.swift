import SwiftUI

/// Hub status popover — non-blocking, attached to toolbar button.
/// Replaces the previous 500x400 modal sheet.
struct HubStatusPopover: View {
    @ObservedObject var hubManager: HubManager
    @ObservedObject var agentMonitor: AgentMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Hub Status")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Status + controls
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(hubManager.status.label)
                        .font(.body)
                    Spacer()
                    Text("Port \(hubManager.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    if case .running(let owned) = hubManager.status {
                        if owned {
                            Button("Stop") { hubManager.stopHub() }
                                .controlSize(.small)
                            Button("Restart") { hubManager.restartHub() }
                                .controlSize(.small)
                        }
                    } else if !hubManager.status.isRunning {
                        Button("Start") { hubManager.launchHub() }
                            .controlSize(.small)
                    }
                }

                // Agent count
                let count = agentMonitor.agents.count
                Text("\(count) agent\(count == 1 ? "" : "s") connected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Compact recent log (last 8 lines)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent Log")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(recentLogs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
    }

    private var statusColor: Color {
        switch hubManager.status {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }

    private var recentLogs: [String] {
        Array(hubManager.logs.suffix(8))
    }
}
