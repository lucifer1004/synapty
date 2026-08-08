import Foundation
import SwiftUI
import os

// MARK: - Data Models (RFC-0003 task-center model)

/// A task = a GitHub issue in the hub repo (C-ISSUE-STATES).
struct TaskItem: Identifiable, Decodable, Equatable {
    let number: Int
    let title: String
    let state: String
    let url: String
    let labels: [String]
    let assignee: String?

    var id: Int { number }

    var projectLabel: String? {
        labels.first { $0.hasPrefix("p:") }
    }

    var statusLabel: String? {
        labels.first { $0.hasPrefix("s:") }
    }

    var status: TaskStatus {
        switch statusLabel {
        case "s:doing": return .doing
        case "s:done": return .done
        default: return .todo
        }
    }
}

enum TaskStatus: String {
    case todo = "todo"
    case doing = "doing"
    case done = "done"

    var color: Color {
        switch self {
        case .todo: return .secondary
        case .doing: return .blue
        case .done: return .green
        }
    }
}

/// One hub tool-request activity entry (C-HUB-ROLE).
struct ActivityItem: Identifiable, Decodable, Equatable {
    let ts: Int64
    let agent: String
    let tool: String
    let detail: String

    var id: Int64 { ts }
}

/// Per-project task counts.
struct ProjectCounts {
    var todo = 0
    var doing = 0
    var done = 0

    var total: Int { todo + doing + done }
}

/// Bridge connection state (C-AUTH: login device holds the credential).
enum BridgeStatus: Equatable {
    case unknown
    case configured
    case notConfigured
    case error(String)
}

// MARK: - TaskMonitor

/// Polls the hub for the task list and the tool-request activity stream,
/// driving the status-bar badges and the activity log view.
@MainActor final class TaskMonitor: ObservableObject {
    @Published var tasks: [TaskItem] = []
    @Published var activities: [ActivityItem] = []
    @Published var bridgeStatus: BridgeStatus = .unknown
    @Published var lastError: String?

    private var activityTimer: Timer?
    private var tasksTimer: Timer?
    /// Activity stream is real-time-ish; the task list changes rarely.
    private let activityInterval: TimeInterval = 5.0
    private let tasksInterval: TimeInterval = 60.0

    /// Aggregate per-project counts from the current task list.
    var projectCounts: [String: ProjectCounts] {
        var counts: [String: ProjectCounts] = [:]
        for task in tasks {
            guard let project = task.projectLabel else { continue }
            switch task.status {
            case .todo: counts[project, default: ProjectCounts()].todo += 1
            case .doing: counts[project, default: ProjectCounts()].doing += 1
            case .done: counts[project, default: ProjectCounts()].done += 1
            }
        }
        return counts
    }

    func start() {
        guard activityTimer == nil else { return }
        // Activity stream: frequent (5s). Task list: very low frequency
        // (60s) — manual refresh is the primary path (Tasks page button).
        activityTimer = Timer.scheduledTimer(withTimeInterval: activityInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchActivity()
            }
        }
        tasksTimer = Timer.scheduledTimer(withTimeInterval: tasksInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchTasks()
            }
        }
        // Initial fetch of both.
        poll()
    }

    func stop() {
        activityTimer?.invalidate()
        activityTimer = nil
        tasksTimer?.invalidate()
        tasksTimer = nil
    }

    /// Manual refresh of the task list (Tasks page refresh button).
    func refreshTasks() {
        fetchTasks()
    }

    func poll() {
        fetchTasks()
        fetchActivity()
    }

    // MARK: - Binary path (matches AgentMonitor/HubManager pattern)

    /// Run `synapty <args...>` asynchronously — the subprocess (incl. the
    /// GitHub API round-trip) runs on a background queue so the main thread
    /// is never blocked (WI-2026-08-07-006: polling was freezing the UI
    /// every few seconds). `completion` is called on the main actor.
    private func runCLI(
        _ arguments: [String],
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let binary = SynaptyBinary.resolve() else {
            Task { @MainActor in completion(nil) }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            // Drains both pipes concurrently and enforces a timeout — a
            // full pipe used to wedge the child (and with it all future
            // polls) forever (WI-2026-08-08-005).
            let output = SubprocessRunner.run(
                executable: binary,
                arguments: arguments,
                timeout: 60
            )
            if let error = output.error {
                AppLog.taskMonitor.error("launch failed: \(error, privacy: .public)")
            } else if output.timedOut {
                AppLog.taskMonitor.error("`synapty \(arguments.joined(separator: " "), privacy: .public)` timed out after 60s")
            } else if !output.stderr.isEmpty {
                AppLog.taskMonitor.error("stderr: \(output.stderr, privacy: .public)")
            }
            let result = output.error == nil && !output.timedOut ? output.stdout : nil
            Task { @MainActor in completion(result) }
        }
    }

    /// In-flight guards — skip a poll when the previous one is still
    /// running (slow GitHub calls must not pile up).
    private var tasksInFlight = false
    private var activityInFlight = false

    /// Extract the tool_response envelope payload dict from CLI stdout.
    func parseEnvelopePayload(_ output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any]
        else { return nil }
        return payload
    }

    /// Drop self-generated polling noise (cli-tmp- agents' own
    /// activity.list/task.list calls) from the activity stream. Pure —
    /// unit-tested (WI-2026-08-08-021).
    nonisolated static func filterActivityNoise(_ items: [ActivityItem]) -> [ActivityItem] {
        items.filter { item in
            guard item.agent.hasPrefix("cli-tmp-") else { return true }
            return !(item.tool == "activity.list" || item.tool == "task.list")
        }
    }

    // MARK: - Fetch tasks

    private func fetchTasks() {
        guard !tasksInFlight else { return }
        tasksInFlight = true
        runCLI(["task", "list"]) { [weak self] output in
            defer { self?.tasksInFlight = false }
            guard let self, let output else { return }
            guard let payload = self.parseEnvelopePayload(output) else { return }

            if let ok = payload["ok"] as? Bool, !ok {
                let msg = payload["error"] as? String ?? "github error"
                if msg.contains("not configured") || msg.contains("token") {
                    if self.bridgeStatus != .notConfigured { self.bridgeStatus = .notConfigured }
                } else if self.bridgeStatus != .error(msg) {
                    self.bridgeStatus = .error(msg)
                }
                if self.lastError != msg { self.lastError = msg }
                return
            }
            if self.bridgeStatus != .configured { self.bridgeStatus = .configured }
            if self.lastError != nil { self.lastError = nil }

            guard let data = payload["data"] as? [[String: Any]] else { return }
            var items: [TaskItem] = []
            for dict in data {
                guard let item = try? JSONDecoder().decode(
                    TaskItem.self,
                    from: JSONSerialization.data(withJSONObject: dict)
                ) else { continue }
                items.append(item)
            }
            // Publish only on change — otherwise every poll re-renders the
            // Tasks page + status badges and triggers a full layout pass.
            if items != self.tasks {
                self.tasks = items
            }
        }
    }

    // MARK: - Fetch activity

    private func fetchActivity() {
        guard !activityInFlight else { return }
        activityInFlight = true
        runCLI(["activity"]) { [weak self] output in
            defer { self?.activityInFlight = false }
            guard let self, let output else { return }
            guard let payload = self.parseEnvelopePayload(output),
                  let ok = payload["ok"] as? Bool, ok,
                  let data = payload["data"] as? [[String: Any]]
            else { return }

            var items: [ActivityItem] = []
            for dict in data {
                guard let item = try? JSONDecoder().decode(
                    ActivityItem.self,
                    from: JSONSerialization.data(withJSONObject: dict)
                ) else { continue }
                items.append(item)
            }
            // Filter self-generated polling noise: the hub records every
            // activity.list/task.list call as an activity event, so the
            // stream never stabilizes and the change-detection below would
            // always fire (re-render + layout every poll). WI-2026-08-07-006.
            let real = Self.filterActivityNoise(items)
            // Publish only on change (see fetchTasks).
            let suffix = Array(real.suffix(100))
            if suffix != self.activities {
                self.activities = suffix
            }
        }
    }
}
