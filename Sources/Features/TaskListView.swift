import SwiftUI

/// Task management page — hub-repo issues grouped by project label,
/// filterable by state (RFC-0003 C-UI). Clicking a task opens it on
/// GitHub; details/comments live on the platform by design.
struct TaskListView: View {
    @ObservedObject var taskMonitor: TaskMonitor

    @State private var stateFilter: TaskStatus? = nil
    @State private var isRefreshing = false

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        .onAppear {
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .frame(width: 18)
                Text("Tasks")
                    .font(DS.Typography.titleLarge)
                Spacer()
                if !taskMonitor.tasks.isEmpty {
                    Text("\(taskMonitor.tasks.count) total")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                // Manual refresh — the task list is low-frequency by design.
                Button {
                    isRefreshing = true
                    Task { @MainActor in
                        taskMonitor.refreshTasks()
                        // Give the @Published update a moment to land.
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(DS.hover, in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .help("Refresh tasks")
                .disabled(isRefreshing)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.lg)
            .padding(.bottom, DS.Space.md)

            // State filter chips
            HStack(spacing: DS.Space.xs) {
                filterChip(title: "All", status: nil)
                filterChip(title: "Todo", status: .todo)
                filterChip(title: "Doing", status: .doing)
                filterChip(title: "Done", status: .done)
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.bottom, DS.Space.lg)
        }
    }

    private func filterChip(title: String, status: TaskStatus?) -> some View {
        let isSelected = stateFilter == status
        return Button {
            stateFilter = status
        } label: {
            Text(title)
                .font(DS.Typography.detailStrong)
                .foregroundStyle(isSelected ? DS.accent : DS.textSecondary)
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.xs)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.pill)
                        .fill(isSelected ? DS.accentSoft : DS.hover)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.pill)
                        .stroke(isSelected ? DS.accent.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(DS.textTertiary)
            Text(stateFilter == nil ? "No open tasks" : "Nothing \(stateFilter!.rawValue)")
                .font(DS.Typography.titleLarge)
                .foregroundStyle(DS.textSecondary)
            Text("Tasks are issues in your hub repo, grouped by p: labels.\nCreate one with `synapty task create`.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
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
            LazyVStack(alignment: .leading, spacing: DS.Space.xl) {
                ForEach(groups, id: \.project) { group in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        DSSectionLabel(text: group.project.replacingOccurrences(of: "p:", with: ""), count: group.tasks.count)
                            .padding(.horizontal, DS.Space.xl)
                        ForEach(group.tasks) { task in
                            TaskRow(task: task)
                                .padding(.horizontal, DS.Space.lg)
                                .padding(.vertical, DS.Space.sm)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.Radius.md)
                                        .fill(DS.hover)
                                )
                                .padding(.horizontal, DS.Space.xl)
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
            .padding(.vertical, DS.Space.lg)
        }
    }
}

// MARK: - Row

struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            DSStatusDot(color: task.status.color, size: 7)
            Text("#\(task.number)")
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.textSecondary)
            Text(task.title)
                .font(DS.Typography.body)
                .lineLimit(1)
            Spacer()
            if let assignee = task.assignee {
                Text(assignee)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            Image(systemName: "arrow.up.right")
                .font(.system(size: 9))
                .foregroundStyle(DS.textTertiary)
        }
    }
}
