import Foundation
import AppKit

/// Manages the synapty-hub subprocess lifecycle.
/// Auto-detects existing Hub at launch, starts one if needed,
/// captures logs, and monitors health.
@MainActor final class HubManager: ObservableObject {

    enum HubStatus: Equatable {
        case stopped
        case starting
        case running(owned: Bool) // owned = we started it
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting..."
            case .running(let owned): return owned ? "Running" : "Running (external)"
            case .failed(let msg): return "Failed: \(msg)"
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published var status: HubStatus = .stopped
    @Published var logs: [String] = []
    @Published var port: Int = 9000

    private var process: Process?
    private var healthTimer: Timer?

    // MARK: - Hub binary path

    private func hubBinaryPath() -> String? {
        // Bundled in .app
        if let bundled = Bundle.main.path(forResource: "synapty-hub", ofType: nil) {
            return bundled
        }
        // Dev fallback
        let devPath = "zig-out/bin/synapty-hub"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
    }

    // MARK: - Port check

    /// Check if the Hub port is already in use (another Hub is running).
    func isPortInUse() -> Bool {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - Auto-launch

    /// Check for existing Hub and launch if needed. Called from ContentView.onAppear.
    func ensureRunning() {
        if isPortInUse() {
            status = .running(owned: false)
            appendLog("Hub detected on port \(port) (external)")
            startHealthCheck()
            return
        }
        launchHub()
    }

    // MARK: - Launch

    func launchHub() {
        guard let binary = hubBinaryPath() else {
            status = .failed("synapty-hub binary not found")
            appendLog("Error: synapty-hub binary not found")
            return
        }

        status = .starting
        appendLog("Starting Hub on port \(port)...")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        // Hub currently uses hardcoded port 9000. Future: pass --port flag.

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Read output asynchronously for log capture
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let lines = str.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            DispatchQueue.main.async {
                for line in lines where !line.isEmpty {
                    self?.appendLog(line)
                }
            }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.status.isRunning {
                    self.status = .failed("Hub exited (code \(proc.terminationStatus))")
                    self.appendLog("Hub exited with code \(proc.terminationStatus)")
                }
                self.process = nil
            }
        }

        do {
            try proc.run()
            process = proc
            // Give it a moment to bind the port
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if self.isPortInUse() {
                    self.status = .running(owned: true)
                    self.appendLog("Hub started on port \(self.port)")
                    self.startHealthCheck()
                } else {
                    self.status = .failed("Hub did not bind port \(self.port)")
                    self.appendLog("Error: Hub did not bind port")
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Stop / Restart

    func stopHub() {
        process?.terminate()
        process = nil
        healthTimer?.invalidate()
        healthTimer = nil
        status = .stopped
        appendLog("Hub stopped")
    }

    func restartHub() {
        stopHub()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.launchHub()
        }
    }

    // MARK: - Health check

    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.isPortInUse() {
                if case .running(owned: true) = self.status {
                    self.appendLog("Hub health check failed, restarting...")
                    self.restartHub()
                } else {
                    self.status = .stopped
                    self.appendLog("External Hub no longer available")
                }
            }
        }
    }

    // MARK: - Logging

    private func appendLog(_ line: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(line)")
        // Keep last 500 lines
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    // MARK: - Cleanup

    func shutdown() {
        healthTimer?.invalidate()
        if case .running(owned: true) = status {
            process?.terminate()
        }
    }
}
