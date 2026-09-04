import SwiftUI

/// Task board — hub-repo issues grouped by project label (RFC-0003 C-UI).
/// Clicking a task opens it on GitHub; details and comments live on the
/// platform by design. What happened to those tasks is [[ActivityPage]]'s.
struct TaskListView: View {
    var taskMonitor: TaskMonitor

    @State private var stateFilter: TaskStatus? = nil
    @State private var isRefreshing = false
    @State private var showConnectSheet = false


    var body: some View {
        VStack(spacing: 0) {
            header
            if taskMonitor.tasks.isEmpty {
                emptyState
            } else {
                taskGroups
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        .sheet(isPresented: $showConnectSheet) {
            GithubConnectSheet(
                isPresented: $showConnectSheet,
                onConnected: {
                    taskMonitor.refreshTasks()
                }
            )
        }
        // THE ACTIVITY POLLING GATE LEFT WITH THE STREAM. It followed
        // the stream from ContentView to here (WI-2026-08-09-007) and has
        // now followed it to [[ActivityPage]]; a page that no longer shows
        // the stream has no business starting or stopping its polling.
    }

    // MARK: - Header (board filter bar)

    private var headerMeta: String? {
        taskMonitor.tasks.isEmpty ? nil : "\(taskMonitor.tasks.count) total"
    }

    /// Unified page grammar (user feedback, WI-2026-08-09-008 round):
    /// DSPageHeader trailing = ACTIONS only; the control row under the
    /// header carries the filters — same as Hosts and Settings.
    private var header: some View {
        VStack(spacing: 0) {
            DSPageHeader("Tasks", meta: headerMeta) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                } else {
                    DSIconButton(icon: "arrow.clockwise", help: "Refresh tasks") {
                        isRefreshing = true
                        Task { @MainActor in
                            taskMonitor.refreshTasks()
                            // Give the observation update a moment to land.
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            isRefreshing = false
                        }
                    }
                }
            }

            DSHairline()

            // THE TAB SWITCH IS GONE with the Activity tab it switched to
            // ([[ActivityPage]]), and the board's own filter leads the row
            // now that nothing precedes it.
            HStack(spacing: DS.Space.md) {
                do {
                    DSSegmented(selection: $stateFilter, options: [
                        (TaskStatus?.none, "All"),
                        (.todo, "Todo"),
                        (.doing, "Doing"),
                        (.done, "Done"),
                    ])
                }
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.md)
        }
    }

    // MARK: - Empty state

    /// Empty-state guide branches on the bridge state — connect first,
    /// create second (WI-2026-08-08-055).
    @ViewBuilder
    private var emptyState: some View {
        if stateFilter != nil {
            // Filtered view is empty — not a bridge problem.
            DSEmptyState(
                icon: "line.3.horizontal.decrease.circle",
                title: "Nothing \(stateFilter!.rawValue)",
                message: "No tasks match the current filter."
            )
        } else {
            switch taskMonitor.bridgeStatus {
            case .notConfigured:
                DSEmptyState(
                    icon: "link.badge.plus",
                    title: "Connect GitHub to get started",
                    message: "Tasks are issues in your hub repo. Connect a repo first — the credential stays in your Keychain."
                ) {
                    Button {
                        showConnectSheet = true
                    } label: {
                        Label("Connect GitHub", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .error(let msg):
                DSEmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Tasks unavailable",
                    message: msg
                ) {
                    Button {
                        // Settings → GitHub owns bridge config
                        // (WI-2026-08-09-007): Connect/Change/Disconnect.
                        NotificationCenter.default.post(
                            name: .synaptyShowPage,
                            object: nil,
                            userInfo: ["page": AppPage.settings.rawValue]
                        )
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                }
            case .configured, .unknown:
                DSEmptyState(
                    icon: "checkmark.circle",
                    title: "No open tasks",
                    message: "Tasks are issues in your hub repo, grouped by p: labels. Create one with `synapty task create`."
                )
            }
        }
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
                    // Inset-grouped card per project — the System Settings
                    // block idiom (WI-2026-08-08-090).
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        DSSectionLabel(text: group.project.replacingOccurrences(of: "p:", with: ""), count: group.tasks.count, preserveCase: true)
                        DSCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.tasks.enumerated()), id: \.element.id) { index, task in
                                    TaskRow(task: task)
                                    if index < group.tasks.count - 1 {
                                        DSHairline().padding(.leading, DS.Space.xl)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)
            // Readable content column, Settings-style (WI-2026-08-09-005).
            .frame(maxWidth: DS.scaled(760), alignment: .leading)
            // Bounded from the page's own left edge rather than centred in
            // what is left over — the same page-title-and-content-disagree
            // defect the Settings column had.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Row

struct TaskRow: View {
    let task: TaskItem

    @State private var isHovered = false

    /// The number as a STRING, so the surrounding literal cannot resolve
    /// to the LocalizedStringKey initialiser. `accessibilityLabel`'s
    /// StringProtocol overload is `@_disfavoredOverload` in the SDK, so a
    /// literal there picks LocalizedStringKey exactly as `Text` does.
    static func numberText(_ number: Int) -> String { String(number) }

    /// What the row shows: "#1234".
    static func numberLabel(_ number: Int) -> String { "#" + numberText(number) }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            DSStatusDot(color: task.status.color, size: 7)
            // AN ISSUE NUMBER IS AN IDENTIFIER, NOT A QUANTITY — the same
            // rule `portText` states in ServicesView, and the same
            // initialiser. Interpolating the Int picks LocalizedStringKey,
            // which group-separates for the locale, so issue 1234 renders
            // as "#1,234" — a number GitHub has never heard of.
            Text(TaskRow.numberLabel(task.number))
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
                .font(DS.Icon.control)
                .foregroundStyle(DS.textTertiary)
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .background(isHovered ? DS.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        // Named for the outcome, not the gesture: a keyboard user should
        // not have to know that clicking a row was the only way to ask.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open on GitHub") {
            if let url = URL(string: task.url) { NSWorkspace.shared.open(url) }
        }
        .onTapGesture {
            if let url = URL(string: task.url) {
                NSWorkspace.shared.open(url)
            }
        }
        // Row is a link to GitHub (WI-2026-08-09-020).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Task \(TaskRow.numberText(task.number)): \(task.title), \(task.status.rawValue)\(task.assignee.map { ", assigned to \($0)" } ?? "")")
        .accessibilityAddTraits([.isButton, .isLink])
    }
}
