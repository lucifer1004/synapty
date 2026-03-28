import Foundation
import AppKit

/// Manages SSH ControlMaster tunnels to remote hosts.
/// Provides auto-setup on first connect, heartbeat monitoring, and auto-reconnect.
@MainActor final class TunnelManager: ObservableObject {

    /// Singleton for access from TerminalPaneManager (addPaneToActiveSession).
    static weak var shared: TunnelManager?

    enum TunnelStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed(String)

        var color: NSColor {
            switch self {
            case .disconnected: return .systemGray
            case .connecting, .reconnecting: return .systemYellow
            case .connected: return .systemGreen
            case .failed: return .systemRed
            }
        }

        var label: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting: return "Setting up..."
            case .connected: return "Connected"
            case .reconnecting: return "Reconnecting..."
            case .failed(let msg): return "Failed: \(msg)"
            }
        }
    }

    /// Global tunnel port (Hub + reverse tunnel). Default 9000.
    @Published var tunnelPort: Int = 9000

    /// Per-host tunnel status.
    @Published var tunnelStates: [UUID: TunnelStatus] = [:]

    /// Hosts we're tracking for heartbeat.
    private var trackedHosts: [UUID: HostEntry] = [:]

    /// Heartbeat timer.
    private var heartbeatTimer: Timer?

    /// Pending connection callbacks (queued while setup is running).
    private var pendingCallbacks: [UUID: [((command: String, agentID: String)) -> Void]] = [:]

    // MARK: - Shell escaping

    /// Single-quote a string for safe shell interpolation.
    /// Handles embedded single quotes by ending the quote, adding an escaped quote, and reopening.
    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Script paths

    private func scriptPath(_ name: String) -> String {
        if let bundled = Bundle.main.path(forResource: name, ofType: "sh", inDirectory: "scripts") {
            return bundled
        }
        return "scripts/\(name).sh"
    }

    // MARK: - Socket path

    func socketPath(for host: HostEntry) -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".synapty/sockets").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/\(host.username)@\(host.address):\(host.port)"
    }

    // MARK: - Tunnel status

    func status(for host: HostEntry) -> TunnelStatus {
        tunnelStates[host.id] ?? .disconnected
    }

    // MARK: - Check tunnel health

    func checkTunnel(for host: HostEntry) -> Bool {
        let socket = socketPath(for: host)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-S", socket, "-O", "check", "\(host.username)@\(host.address)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Ensure tunnel (auto-setup on first connect)

    /// Ensures a tunnel is active for the host. If already connected, calls completion
    /// immediately with the connect command. Otherwise runs setup first.
    func ensureTunnel(for host: HostEntry, completion: @escaping ((command: String, agentID: String)) -> Void) {
        trackedHosts[host.id] = host

        if checkTunnel(for: host) {
            tunnelStates[host.id] = .connected
            completion(connectCommand(for: host))
            return
        }

        // Queue the callback and run setup
        pendingCallbacks[host.id, default: []].append(completion)

        // Only start setup if not already in progress
        let currentStatus = tunnelStates[host.id]
        if currentStatus == .connecting || currentStatus == .reconnecting {
            return // setup already running, callback queued
        }

        tunnelStates[host.id] = .connecting
        runSetup(for: host)
    }

    // MARK: - Connect command

    /// Returns (command, agentID) so callers can store the agent ID on the session.
    func connectCommand(for host: HostEntry) -> (command: String, agentID: String) {
        let script = scriptPath("connect")
        let agentID = "\(host.label)-\(UUID().uuidString.prefix(4).lowercased())"
        var parts = ["bash", shellEscape(script), shellEscape(agentID),
                     shellEscape(host.address), "\(host.port)",
                     shellEscape(host.username), "\(tunnelPort)"]
        if let key = host.sshKeyPath, !key.isEmpty {
            parts.append(shellEscape(key))
        }
        return (parts.joined(separator: " "), agentID)
    }

    /// Returns (command, agentID) for local sessions.
    func localCommand() -> (command: String, agentID: String) {
        let agentID = "local-\(UUID().uuidString.prefix(4).lowercased())"
        let synaptyBin: String
        if let bundled = Bundle.main.path(forResource: "synapty", ofType: nil) {
            synaptyBin = bundled
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            synaptyBin = "\(cwd)/zig-out/bin/synapty"
        }
        let cmd = "\(shellEscape(synaptyBin)) run --id \(shellEscape(agentID)) --hub 127.0.0.1:\(tunnelPort) -- ${SHELL:-/bin/zsh} -l"
        return (cmd, agentID)
    }

    // MARK: - Setup (background process)

    private func runSetup(for host: HostEntry) {
        let script = scriptPath("setup-host")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Process.arguments are passed as argv (no shell interpolation), so no escaping needed here.
        // The script itself uses $1, $2 etc. which are safe in bash.
        var args = [script, host.address, "\(host.port)", host.username, "\(tunnelPort)"]
        if let key = host.sshKeyPath, !key.isEmpty {
            args.append(key)
        }
        process.arguments = args

        // Capture output for error reporting
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                if proc.terminationStatus == 0 {
                    self.tunnelStates[host.id] = .connected
                    // Fire all pending callbacks
                    let callbacks = self.pendingCallbacks.removeValue(forKey: host.id) ?? []
                    for cb in callbacks {
                        cb(self.connectCommand(for: host))
                    }
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                    let lastLine = output.split(separator: "\n").last.map(String.init) ?? "Setup failed"
                    self.tunnelStates[host.id] = .failed(lastLine)
                    self.pendingCallbacks.removeValue(forKey: host.id)
                }
            }
        }

        do {
            try process.run()
        } catch {
            tunnelStates[host.id] = .failed(error.localizedDescription)
            pendingCallbacks.removeValue(forKey: host.id)
        }
    }

    // MARK: - Reconnect

    func reconnectTunnel(for host: HostEntry) {
        trackedHosts[host.id] = host
        tunnelStates[host.id] = .reconnecting
        runSetup(for: host)
    }

    // MARK: - Disconnect

    func disconnectTunnel(for host: HostEntry) {
        let socket = socketPath(for: host)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-S", socket, "-O", "exit", "\(host.username)@\(host.address)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        tunnelStates[host.id] = .disconnected
        trackedHosts.removeValue(forKey: host.id)
    }

    // MARK: - Heartbeat

    func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.runHeartbeat()
        }
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func runHeartbeat() {
        let hostsToCheck = trackedHosts.filter { tunnelStates[$0.key] == .connected }

        for (hostID, host) in hostsToCheck {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let alive = self.checkTunnel(for: host)
                DispatchQueue.main.async {
                    if !alive && self.tunnelStates[hostID] == .connected {
                        self.reconnectTunnel(for: host)
                    }
                }
            }
        }
    }
}
