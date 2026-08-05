import Foundation
import SwiftUI

// MARK: - Data Models per [[RFC-0002:C-AGENT-IDENTITY]]

enum ToolType: String, CaseIterable {
    case claude, codex, gemini, human, unknown

    init(from string: String) {
        self = ToolType(rawValue: string.lowercased()) ?? .unknown
    }

    var sfSymbol: String {
        switch self {
        case .claude: return "cpu"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "sparkles"
        case .human: return "person.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var accentColor: Color {
        switch self {
        case .claude: return Color(red: 0.8, green: 0.5, blue: 0.3)
        case .codex: return Color(red: 0.2, green: 0.6, blue: 0.9)
        case .gemini: return Color(red: 0.3, green: 0.7, blue: 0.5)
        case .human: return .secondary
        case .unknown: return .secondary
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .human: return "Human"
        case .unknown: return "Agent"
        }
    }
}

struct AgentInfo: Identifiable, Equatable {
    let id: String
    let tool: ToolType
    let project: String
    let session: String

    var hasMetadata: Bool {
        tool != .unknown || project != "-" || session != "-"
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID = UUID()
    let from: String
    let channel: String?
    let text: String
    let timestamp: Date

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - AgentMonitor

@MainActor final class AgentMonitor: ObservableObject {
    @Published var agents: [AgentInfo] = []
    @Published var messages: [ChatMessage] = []
    @Published var messageCount: Int = 0
    /// Agent IDs that need human attention (e.g., bell rang).
    @Published var needsAttention: Set<String> = []

    private var timer: Timer?
    /// Stable agent map keyed by ID — prevents ordering jumps on re-poll.
    private var knownAgents: [String: AgentInfo] = [:]

    func startMonitoring() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Stable merge + filter

    /// Merge incoming agents into stable ordered list.
    /// Only agents with metadata (tool != unknown) are shown.
    private func mergeAgents(_ incoming: [AgentInfo]) {
        var newMap: [String: AgentInfo] = [:]
        for agent in incoming where agent.hasMetadata {
            newMap[agent.id] = agent
        }
        // Sort alphabetically by ID for stable ordering.
        let sorted = Array(newMap.values).sorted { $0.id < $1.id }
        // Only publish if changed — avoids unnecessary SwiftUI re-renders.
        if sorted != agents {
            knownAgents = newMap
            agents = sorted
        }
        // Prune attention for agents that disappeared.
        needsAttention = needsAttention.filter { newMap[$0] != nil }
    }

    // MARK: - Attention

    func markNeedsAttention(_ agentID: String) {
        needsAttention.insert(agentID)
    }

    func clearAttention(_ agentID: String) {
        needsAttention.remove(agentID)
    }

    // MARK: - Binary path resolution (matches HubManager pattern)

    private func synaptyBinaryPath() -> String? {
        // Contents/MacOS/ — Resources/ copies are killed by ASP (signature
        // not sealed); MacOS/ is the standard nested-helper location.
        let macosBin = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/synapty-cli").path
        if FileManager.default.fileExists(atPath: macosBin) {
            return macosBin
        }
        let devPath = "zig-out/bin/synapty"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
    }

    // MARK: - Refresh

    private func refresh() {
        guard let binary = synaptyBinaryPath() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["agents"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let parsed = parseAgentsOutput(output)
            DispatchQueue.main.async {
                self.mergeAgents(parsed)
            }
        } catch {
            // Binary not available yet — stay silent
        }
    }

    // MARK: - Output parsing

    /// Parse the output of `synapty agents`.
    /// IPC path returns JSON: {"success":true,"data":"<hub-response-json>"}
    /// The Hub response contains: {"ok":true,"agents":[{"id":"...","tool":"...","project":"...","session":"..."},...]}
    /// Fallback (direct TCP) returns raw Hub JSON envelope.
    private func parseAgentsOutput(_ output: String) -> [AgentInfo] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Try JSON parsing first (IPC path)
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseAgentsJSON(json)
        }

        // Fallback: try each line as JSON (raw Hub envelope from TCP fallback)
        for line in trimmed.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            if let data = l.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return parseAgentsJSON(json)
            }
        }

        return []
    }

    /// Extract agent list from various JSON response shapes.
    private func parseAgentsJSON(_ json: [String: Any]) -> [AgentInfo] {
        // Shape 1: IPC response {"success":true,"data":"<json-string>"}
        if let dataStr = json["data"] as? String,
           let innerData = dataStr.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] {
            return extractAgents(from: inner)
        }

        // Shape 2: Direct Hub response {"ok":true,"agents":[...]}
        if let _ = json["ok"] {
            return extractAgents(from: json)
        }

        // Shape 3: Hub envelope {"type":"response","payload":{"ok":true,"agents":[...]}}
        if let payload = json["payload"] as? [String: Any] {
            return extractAgents(from: payload)
        }

        return []
    }

    /// Extract [AgentInfo] from a dict containing "agents" array.
    private func extractAgents(from dict: [String: Any]) -> [AgentInfo] {
        guard let agentArray = dict["agents"] as? [[String: Any]] else { return [] }
        return agentArray.compactMap { obj -> AgentInfo? in
            guard let id = obj["id"] as? String else { return nil }
            let tool = ToolType(from: (obj["tool"] as? String) ?? "-")
            let project = (obj["project"] as? String) ?? "-"
            let session = (obj["session"] as? String) ?? "-"
            return AgentInfo(id: id, tool: tool, project: project, session: session)
        }
    }
}
