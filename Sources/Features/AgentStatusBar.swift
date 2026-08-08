import SwiftUI

/// Bottom context bar — shows info about the currently focused session/pane.
/// Agents live in the sidebar; this bar provides "what am I looking at right now?"
struct ContextStatusBar: View {
    @ObservedObject var paneManager: TerminalPaneManager
    @ObservedObject var agentMonitor: AgentMonitor
    @ObservedObject var hubManager: HubManager
    @ObservedObject var taskMonitor: TaskMonitor

    var body: some View {
        HStack(spacing: DS.Space.md) {
            // Left: focused session context
            focusedSessionInfo
                .frame(maxWidth: .infinity, alignment: .leading)

            // Middle-right: per-project task badges (RFC-0003 C-UI)
            projectBadges

            // Right: bridge state + Hub summary
            bridgeStatusView
            hubSummary
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: DS.Layout.statusBarHeight)
        .background(DS.surface)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Focused session info

    @ViewBuilder
    private var focusedSessionInfo: some View {
        if let session = paneManager.activeSession {
            HStack(spacing: DS.Space.sm) {
                // Session type indicator
                DSStatusDot(
                    color: session.isLocal ? DS.success : DS.info,
                    size: 7
                )

                // Agent info if registered, otherwise session label
                if let agentID = session.agentID,
                   let agent = agentMonitor.agents.first(where: { $0.id == agentID }) {
                    Image(systemName: agent.tool.sfSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(agent.tool.accentColor)
                    Text(agent.tool.displayName)
                        .font(DS.Typography.detailStrong)
                    if agent.session != "-" {
                        Text("·")
                            .foregroundStyle(DS.textTertiary)
                        Text(agent.session)
                            .font(DS.Typography.detail)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(session.label)
                        .font(DS.Typography.detailStrong)
                    if let agentID = session.agentID {
                        Text(agentID)
                            .font(DS.Typography.monoCaption)
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }
        } else {
            Text("No active session")
                .font(DS.Typography.detail)
                .foregroundStyle(DS.textSecondary)
        }
    }

    // MARK: - Project task badges (RFC-0003 C-UI)

    private var projectBadges: some View {
        let counts = taskMonitor.projectCounts
        return HStack(spacing: DS.Space.sm) {
            ForEach(counts.keys.sorted(), id: \.self) { project in
                if let c = counts[project] {
                    HStack(spacing: DS.Space.xs) {
                        Text(project.replacingOccurrences(of: "p:", with: ""))
                            .font(DS.Typography.captionStrong)
                        if c.doing > 0 {
                            Text("\(c.doing)")
                                .font(DS.Typography.captionStrong)
                                .foregroundStyle(DS.info)
                        }
                        if c.todo > 0 {
                            Text("\(c.todo)")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.textSecondary)
                        }
                        if c.done > 0 {
                            Text("\(c.done)✓")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.textSecondary)
                        }
                    }
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.pill)
                            .fill(DS.hover)
                    )
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
                    .foregroundColor(DS.warning)
            }
            .buttonStyle(.plain)
            .help("GitHub bridge not configured — run `synapty github login` in a pane")
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(DS.danger)
                .help(taskMonitor.lastError ?? "GitHub bridge error")
        }
    }

    // MARK: - Hub summary

    private var hubSummary: some View {
        HStack(spacing: DS.Space.xs) {
            DSStatusDot(
                color: hubManager.status.isRunning ? DS.success : DS.danger,
                size: 6
            )
            let count = agentMonitor.agents.count
            Text("Hub: \(count) agent\(count == 1 ? "" : "s")")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
    }
}

// MARK: - Pulse Animation (used by sidebar AgentRow)

struct PulseAnimation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            // Under Reduce Motion the pulse is disabled entirely — the dot
            // must stay FULLY visible, not stuck at the dimmed pulse value
            // (the nil animation applies the onAppear change instantly;
            // WI-2026-08-08-024).
            .opacity(reduceMotion ? 1.0 : (isPulsing ? 0.4 : 1.0))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
