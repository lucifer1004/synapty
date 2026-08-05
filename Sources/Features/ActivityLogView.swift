import SwiftUI

/// Activity log window — the hub's tool-request stream (RFC-0003 C-UI).
/// Replaces the chat-message log of the dialogue model.
struct ActivityLogView: View {
    @ObservedObject var taskMonitor: TaskMonitor
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            DSSheetHeader(title: "Activity", icon: "tray.full", isPresented: $isPresented)
            Divider()
            if taskMonitor.activities.isEmpty {
                emptyState
            } else {
                activityTimeline
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(DS.background)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(DS.textTertiary)
            Text("No activity yet")
                .font(DS.Typography.titleLarge)
                .foregroundStyle(DS.textSecondary)
            Text("Task tool requests (list / claim / update / comment / create)\nwill appear here as agents work the hub repo.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
    }

    // MARK: - Activity timeline

    private var activityTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(taskMonitor.activities) { item in
                        ActivityRow(item: item)
                            .id(item.id)
                    }
                }
                .padding(DS.Space.lg)
            }
            .onChange(of: taskMonitor.activities.count) { _ in
                if let last = taskMonitor.activities.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Row

struct ActivityRow: View {
    let item: ActivityItem

    private var timeText: String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.ts))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private var icon: String {
        switch item.tool {
        case "task.create": return "plus.circle"
        case "task.claim": return "hand.raised"
        case "task.update": return "arrow.triangle.2.circlepath"
        case "task.comment": return "bubble.left"
        default: return "list.bullet"
        }
    }

    private var iconColor: Color {
        switch item.tool {
        case "task.create": return DS.success
        case "task.claim": return DS.info
        case "task.update": return DS.warning
        case "task.comment": return DS.accent
        default: return DS.textSecondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 18)
            Text(timeText)
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.textTertiary)
            Text(item.detail)
                .font(DS.Typography.body)
                .lineLimit(1)
            Spacer()
            Text(item.agent)
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 1)
                .background(DS.hover, in: Capsule())
        }
        .padding(.vertical, DS.Space.xs)
    }
}
