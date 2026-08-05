import SwiftUI

/// Lightweight task panel — hub-repo issues grouped by project label,
/// filterable by state (RFC-0003 C-UI). Clicking a task opens it on
/// GitHub; details/comments live on the platform by design.
struct TaskListView: View {
    @ObservedObject var taskMonitor: TaskMonitor
    @Binding var isPresented: Bool

    @State private var stateFilter: TaskStatus? = nil

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if taskMonitor.tasks.isEmpty {
                emptyState
            } else {
                taskGroups
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            Text("Tasks")
                .font(.headline)
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            Picker("State", selection: $stateFilter) {
                Text("All").tag(nil as TaskStatus?)
                Text("Todo").tag(TaskStatus.todo as TaskStatus?)
                Text("Doing").tag(TaskStatus.doing as TaskStatus?)
                Text("Done").tag(TaskStatus.done as TaskStatus?)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        .padding(10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(stateFilter == nil ? "No open tasks" : "Nothing \(stateFilter!.rawValue)")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Tasks are issues in your hub repo, grouped by p: labels.\nCreate one with `synapty task create`.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Grouped list

    private var filteredTasks: [TaskItem] {
        guard let filter = stateFilter else { return taskMonitor.tasks }
        return taskMonitor.tasks.filter { $0.status == filter }
    }

    private var groups: [(project: String, tasks: [TaskItem])] {
        let grouped = Dictionary(grouping: filteredTasks) { $0.projectLabel ?? "unassigned" }
        return grouped.keys.sorted().map { (project: $0, tasks: grouped[$0] ?? []) }
    }

    private var taskGroups: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groups, id: \.project) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.project)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                        ForEach(group.tasks) { task in
                            TaskRow(task: task)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let url = URL(string: task.url) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Row

struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(task.status.color)
                .frame(width: 7, height: 7)
            Text("#\(task.number)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            Text(task.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            if let assignee = task.assignee {
                Text(assignee)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Image(systemName: "arrow.up.right")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
