import Foundation

@MainActor final class AgentMonitor: ObservableObject {
    @Published var agents: [String] = []
    @Published var messageCount: Int = 0

    private var timer: Timer?

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

    private func refresh() {
        // V1: run `synapty agents` and parse stdout for registered agent IDs
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["synapty", "agents"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress errors silently

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let lines = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            DispatchQueue.main.async {
                self.agents = lines
            }
        } catch {
            // synapty CLI not available yet — stay silent
        }
    }
}
