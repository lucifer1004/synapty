import SwiftUI

/// Activity log window — the hub's tool-request stream (RFC-0003 C-UI).
/// Replaces the chat-message log of the dialogue model.
struct ActivityLogView: View {
    @ObservedObject var taskMonitor: TaskMonitor
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if taskMonitor.activities.isEmpty {
                emptyState
            } else {
                activityTimeline
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No activity yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Task tool requests (list / claim / update / comment / create)\nwill appear here as agents work the hub repo.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Activity timeline

    private var activityTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(taskMonitor.activities) { item in
                        ActivityRow(item: item)
                            .id(item.id)
                    }
                }
                .padding()
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(timeText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            Text(item.detail)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Text(item.agent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}
