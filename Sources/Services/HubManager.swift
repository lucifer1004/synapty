import Foundation
import Observation
import AppKit

/// Manages the Hub subprocess lifecycle (the unified `synapty hub`
/// subcommand per [[ADR-0004]]). Auto-detects an existing Hub at launch,
/// starts one if needed, captures logs, and monitors health.
@MainActor @Observable final class HubManager {

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

    /// One hub log line with a stable sequence number (WI-2026-08-08-023).
    struct HubLogLine: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    var status: HubStatus = .stopped
    var logs: [HubLogLine] = []
    var port: Int = 9000
    /// True while restartHub waits for the old process to exit — the UI
    /// must not offer Start/Restart in this window (a second launch would
    /// orphan the real hub from `process`; WI-2026-08-08-031).
    private(set) var isRestarting = false
    /// Bumped per restart; a superseded relaunch closure bails
    /// (WI-2026-08-08-031).
    private var restartGeneration = 0

    private var process: Process?
    private var healthTimer: Timer?
    /// Pending log lines awaiting the next throttled publish.
    private var pendingLogs: [HubLogLine] = []
    private var logFlushTask: Task<Void, Never>?
    /// Monotonic line sequence — rows keyed by array offset shift identity
    /// when the 500-line cap trims (WI-2026-08-08-023).
    private var nextLogID = 0

    // MARK: - Hub binary path

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
        guard let binary = SynaptyBinary.resolve() else {
            status = .failed("synapty binary not found")
            appendLog("Error: synapty binary not found")
            return
        }

        status = .starting
        appendLog("Starting Hub on port \(port)...")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        // Hub runs as the `hub` subcommand of the unified binary ([[ADR-0004]]).
        // WI-2026-08-06-001: pass the configured port (Settings → Network).
        proc.arguments = ["hub", "--port", "\(port)"]

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
                // Identity check: only clear the reference when the exiting
                // process IS the current one — a stale handler from a
                // restarted hub must not nil out the NEW process (which
                // would orphan a running hub the UI can no longer stop;
                // WI-2026-08-08-006).
                if self.process === proc {
                    self.process = nil
                }
            }
        }

        do {
            try proc.run()
            process = proc
            // Health check timer will detect when port binds and update status
            startHealthCheck()
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
        isRestarting = false
        restartGeneration += 1 // supersede any pending relaunch
        appendLog("Hub stopped")
    }

    func restartHub() {
        // Re-entrancy guard: a second click during the wait must not
        // launch another hub (WI-2026-08-08-031).
        guard !isRestarting else { return }
        guard let old = process else {
            launchHub()
            return
        }
        isRestarting = true
        restartGeneration += 1
        let generation = restartGeneration
        healthTimer?.invalidate()
        healthTimer = nil
        status = .stopped
        appendLog("Hub stopping for restart...")

        // Terminate the old process and relaunch only after it has FULLY
        // exited, so the port is actually free when the new hub binds it.
        // A SIGTERM that is ignored for 2s is force-killed so the restart
        // can never hang (WI-2026-08-08-006).
        process = nil
        old.terminate()
        old.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                if proc.terminationStatus != 0 {
                    self.appendLog("Hub (old instance) exited with code \(proc.terminationStatus)")
                }
                // A newer restart superseded this one — only the current
                // generation relaunches (WI-2026-08-08-031).
                guard self.restartGeneration == generation else { return }
                self.isRestarting = false
                self.launchHub()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak old, weak self] in
            guard let old, old.isRunning else { return }
            // The old hub ignored SIGTERM — force-kill so the relaunch
            // (already pending on its terminationHandler) can proceed.
            kill(old.processIdentifier, SIGKILL)
            self?.appendLog("Hub did not stop on SIGTERM — force-killed")
        }
    }

    // MARK: - Health check

    private func startHealthCheck() {
        healthTimer?.invalidate()
        // Use 1s interval during startup for fast detection, 10s once running.
        // Timer callbacks are Sendable; hop to the main actor for the
        // @MainActor health logic (WI-2026-08-08-009).
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let portUp = self.isPortInUse()

                if portUp {
                    if case .starting = self.status {
                        self.status = .running(owned: true)
                        self.appendLog("Hub started on port \(self.port)")
                        // Slow down to steady-state interval
                        self.startSteadyHealthCheck()
                    }
                } else {
                    if case .running(owned: true) = self.status {
                        self.appendLog("Hub health check failed, restarting...")
                        self.restartHub()
                    } else if case .running(owned: false) = self.status {
                        self.status = .stopped
                        self.appendLog("External Hub no longer available")
                    }
                }
            }
        }
    }

    private func startSteadyHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
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
    }

    // MARK: - Logging

    private func appendLog(_ line: String) {
        // The hub logs "agent metadata updated" on every agents poll —
        // pure noise that churned logs → whole-UI re-render
        // (WI-2026-08-07-006). Skip it.
        if line.contains("agent metadata updated") {
            return
        }
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        pendingLogs.append(HubLogLine(id: nextLogID, text: "[\(timestamp)] \(line)"))
        nextLogID += 1
        if pendingLogs.count > 500 {
            pendingLogs.removeFirst(pendingLogs.count - 500)
        }
        // Throttle publishes to at most one per second so bursts of hub
        // output don't re-render the whole UI on every line.
        guard logFlushTask == nil else { return }
        logFlushTask = Task { @MainActor in
            defer { self.logFlushTask = nil }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard !self.pendingLogs.isEmpty else { return }
            self.logs.append(contentsOf: self.pendingLogs)
            self.pendingLogs.removeAll()
            if self.logs.count > 500 {
                self.logs.removeFirst(self.logs.count - 500)
            }
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
