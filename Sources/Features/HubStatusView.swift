import SwiftUI

/// Hub status sheet — shows running state, agents, logs with copiable text.
struct HubStatusSheet: View {
    @ObservedObject var hubManager: HubManager
    @ObservedObject var agentMonitor: AgentMonitor
    @ObservedObject var taskMonitor: TaskMonitor
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text("Hub Status")
                        .font(.headline)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            githubBridgeSection

            Divider()

            // Status + controls + agents
            VStack(alignment: .leading, spacing: 10) {
                // Status row
                HStack {
                    Text(hubManager.status.label)
                        .font(.body)
                    Spacer()
                    Text("Port \(hubManager.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Controls
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
                    Spacer()
                }

                // Connected agents
                if !agentMonitor.agents.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connected Agents (\(agentMonitor.agents.count))")
                            .font(.system(size: 10, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundColor(.secondary)

                        ForEach(agentMonitor.agents) { agent in
                            HStack(spacing: 6) {
                                Image(systemName: agent.tool.sfSymbol)
                                    .font(.system(size: 11))
                                    .foregroundStyle(agent.tool.accentColor)
                                    .frame(width: 14)
                                Text(agent.tool.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                Text(agent.id)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Spacer()
                                if agent.session != "-" {
                                    Text(agent.session)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Logs — selectable and copiable
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Logs")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Copy All") {
                        let text = hubManager.logs.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(hubManager.logs.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: hubManager.logs.count) { _ in
                        if let last = hubManager.logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - GitHub bridge (RFC-0003 C-AUTH)

    @ViewBuilder
    private var githubBridgeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                Text("GitHub Bridge")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                switch taskMonitor.bridgeStatus {
                case .configured:
                    Text("Connected")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                case .notConfigured:
                    Text("Not configured")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                case .error(let msg):
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(1)
                case .unknown:
                    Text("…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            if taskMonitor.bridgeStatus == .notConfigured {
                Text("Run `synapty github login` in any terminal pane to configure the hub repo and token. The credential stays in your Keychain.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
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
