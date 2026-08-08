import SwiftUI

/// Hub page — shows running state, agents, logs with copiable text.
/// Hierarchy (WI-2026-08-08-054): the hub's own state is the first visual
/// weight; the GitHub bridge is a standard section below it.
struct HubPageView: View {
    var hubManager: HubManager
    var agentMonitor: AgentMonitor
    var taskMonitor: TaskMonitor

    /// Shared GitHub bridge state (WI-2026-08-08-056) — one model +
    /// refresh/disconnect path for the Hub page and the Settings page.
    @State private var bridge = GithubBridgeController()
    @State private var showConnectSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .frame(width: 18)
                Text("Hub")
                    .font(DS.Typography.titleLarge)
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)

            Divider()

            // Hub state + controls + agents — the page's subject.
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
                    if hubManager.isRestarting {
                        // The restart wait window: Start/Restart must not
                        // be offered — a second launch would orphan the
                        // real hub (WI-2026-08-08-031).
                        Text("Restarting…")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textSecondary)
                    } else if case .running(let owned) = hubManager.status {
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

            // GitHub bridge — a standard section BELOW the hub state
            // (WI-2026-08-08-054): secondary integration, not page hero.
            githubBridgeSection
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.lg)

            Divider()

            // Logs — selectable and copiable
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack {
                    DSSectionLabel(text: "Logs", count: hubManager.logs.count)
                    Spacer()
                    Button("Copy All") {
                        let text = hubManager.logs.map(\.text).joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(hubManager.logs) { line in
                                Text(line.text)
                                    .font(DS.Typography.monoCaption)
                                    .foregroundStyle(DS.textPrimary)
                                    .textSelection(.enabled)
                                    .id(line.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Key on the last line's sequence id — at the 500-line
                    // cap the count never changes and count-based scrolling
                    // silently dies (WI-2026-08-08-023).
                    .onChange(of: hubManager.logs.last?.id) { _, _ in
                        if let last = hubManager.logs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
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
        .sheet(isPresented: $showConnectSheet) {
            GithubConnectSheet(
                isPresented: $showConnectSheet,
                onConnected: {
                    taskMonitor.refreshTasks()
                    bridge.refresh()
                }
            )
        }
        .onAppear {
            bridge.refresh()
        }
    }

    // MARK: - GitHub bridge (RFC-0003 C-AUTH)

    @ViewBuilder
    private var githubBridgeSection: some View {
        DSSectionBlock(title: "GitHub Bridge") {
            VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
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
                Spacer()
            }

            // Bound repo details (WI-2026-08-08-044) — visible for both
            // configured and error states so users know WHAT is bound.
            if let binding = bridge.binding {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.textTertiary)
                    Text(binding.owner.isEmpty ? "…" : "\(binding.owner)/\(binding.repo)")
                        .font(DS.Typography.monoCaption)
                        .foregroundStyle(DS.textSecondary)
                    if let username = binding.username, !username.isEmpty {
                        Text("· \(username)")
                            .font(DS.Typography.monoCaption)
                            .foregroundStyle(DS.textTertiary)
                    }
                }
            }

            if taskMonitor.bridgeStatus == .notConfigured && (bridge.binding?.owner.isEmpty ?? true) {
                Text("Connect a hub repo to start the task center. The credential stays in your Keychain.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }

            // Action entry (WI-2026-08-08-043/044): every state has a
            // path forward — Connect, Change, or Disconnect.
            HStack(spacing: DS.Space.sm) {
                Button {
                    showConnectSheet = true
                } label: {
                    Label(taskMonitor.bridgeStatus == .configured ? "Change" : "Connect", systemImage: "link.badge.plus")
                }
                .controlSize(.small)
                if bridge.binding?.owner.isEmpty == false {
                    Button {
                        bridge.disconnect()
                        taskMonitor.refreshTasks()
                    } label: {
                        Label(bridge.isDisconnecting ? "Disconnecting…" : "Disconnect", systemImage: "link.slash")
                    }
                    .controlSize(.small)
                    .disabled(bridge.isDisconnecting)
                }
            }
            }
        }
        .padding(DS.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(DS.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .stroke(DS.border, lineWidth: 1)
        )
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
