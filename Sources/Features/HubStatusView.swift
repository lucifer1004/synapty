import SwiftUI

/// Hub status page — shows running state, agents, logs with copiable text.
struct HubStatusSheet: View {
    @ObservedObject var hubManager: HubManager
    @ObservedObject var agentMonitor: AgentMonitor
    @ObservedObject var taskMonitor: TaskMonitor

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .frame(width: 18)
                Text("Hub Status")
                    .font(DS.Typography.titleLarge)
                Spacer()
                DSStatusDot(color: statusColor, size: 9)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)

            Divider()

            githubBridgeSection

            Divider()

            // Status + controls + agents
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                // Status row
                HStack {
                    HStack(spacing: DS.Space.sm) {
                        DSStatusDot(color: statusColor, size: 9)
                        Text(hubManager.status.label)
                            .font(DS.Typography.bodyStrong)
                    }
                    Spacer()
                    Text("Port \(hubManager.port)")
                        .font(DS.Typography.monoCaption)
                        .foregroundStyle(DS.textSecondary)
                }

                // Controls
                HStack(spacing: DS.Space.sm) {
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
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        DSSectionLabel(text: "Connected Agents", count: agentMonitor.agents.count)

                        ForEach(agentMonitor.agents) { agent in
                            HStack(spacing: DS.Space.sm) {
                                Image(systemName: agent.tool.sfSymbol)
                                    .font(.system(size: 11))
                                    .foregroundStyle(agent.tool.accentColor)
                                    .frame(width: 16)
                                Text(agent.tool.displayName)
                                    .font(DS.Typography.bodyStrong)
                                Text(agent.id)
                                    .font(DS.Typography.monoCaption)
                                    .foregroundStyle(DS.textSecondary)
                                Spacer()
                                if agent.session != "-" {
                                    Text(agent.session)
                                        .font(DS.Typography.detail)
                                        .foregroundStyle(DS.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, DS.Space.xs)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)

            Divider()

            // Logs — selectable and copiable
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack {
                    DSSectionLabel(text: "Logs", count: hubManager.logs.count)
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
                                    .font(DS.Typography.monoCaption)
                                    .foregroundStyle(DS.textPrimary)
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: hubManager.logs.count) { _, _ in
                        if let last = hubManager.logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(DS.background, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .stroke(DS.border, lineWidth: 1)
                )
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
    }

    // MARK: - GitHub bridge (RFC-0003 C-AUTH)

    @ViewBuilder
    private var githubBridgeSection: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.sm) {
                    Text("GitHub Bridge")
                        .font(DS.Typography.detailStrong)
                    Spacer()
                    switch taskMonitor.bridgeStatus {
                    case .configured:
                        HStack(spacing: 4) {
                            DSStatusDot(color: DS.success, size: 6)
                            Text("Connected")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.success)
                        }
                    case .notConfigured:
                        HStack(spacing: 4) {
                            DSStatusDot(color: DS.warning, size: 6)
                            Text("Not configured")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.warning)
                        }
                    case .error(let msg):
                        Text(msg)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.danger)
                            .lineLimit(1)
                    case .unknown:
                        Text("…")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                }
                if taskMonitor.bridgeStatus == .notConfigured {
                    Text("Run `synapty github login` in any terminal pane to configure the hub repo and token. The credential stays in your Keychain.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
        }
        .padding(DS.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(DS.accentSoft)
        )
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.lg)
    }

    private var statusColor: Color {
        switch hubManager.status {
        case .stopped: return DS.textTertiary
        case .starting: return DS.warning
        case .running: return DS.success
        case .failed: return DS.danger
        }
    }
}
