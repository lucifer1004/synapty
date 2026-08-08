import Foundation
import AppKit
import os

private extension Logger {
    static let tunnelManager = Logger(subsystem: "com.synapty.app", category: "TunnelManager")
}

/// Manages SSH ControlMaster tunnels to remote hosts.
/// Provides auto-setup on first connect, heartbeat monitoring, and auto-reconnect.
@MainActor final class TunnelManager: ObservableObject {

    /// Singleton for access from TerminalPaneManager (addPaneToActiveSession).
    static weak var shared: TunnelManager?

    /// Host store for resolving inherited credentials (groups/identities).
    weak var hostStore: HostStore?

    enum TunnelStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed(String)

        /// The reconnect action makes sense for every state except a live
        /// connection and an in-flight connect (WI-2026-08-08-025).
        var canReconnect: Bool {
            switch self {
            case .connected, .connecting: return false
            case .disconnected, .reconnecting, .failed: return true
            }
        }

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

    /// Local hub TCP port (where the in-app hub listens). Default 9000.
    @Published var hubPort: Int = 9000

    /// Remote listen port of the reverse tunnel; forwards to localhost:HUB_PORT.
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
    nonisolated func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Script paths

    private func scriptPath(_ name: String) -> String {
        if let bundled = Bundle.main.path(forResource: name, ofType: "sh", inDirectory: "scripts") {
            return bundled
        }
        return "scripts/\(name).sh"
    }

    // MARK: - Credential resolution (Termius-style inheritance)

    /// Effective username for a host (host field → identity → group chain).
    func effectiveUsername(for host: HostEntry) -> String {
        hostStore?.effectiveUsername(for: host) ?? host.username
    }

    /// Effective SSH key path for a host, or nil.
    func effectiveKeyPath(for host: HostEntry) -> String? {
        hostStore?.effectiveKeyPath(for: host) ?? host.sshKeyPath
    }

    /// Effective port for a host.
    func effectivePort(for host: HostEntry) -> Int {
        hostStore?.effectivePort(for: host) ?? host.port
    }

    /// Effective jump host (ProxyJump) for a host, or nil.
    func effectiveProxyJump(for host: HostEntry) -> String? {
        hostStore?.effectiveProxyJump(for: host)
    }

    /// Effective port-forwarding rules for a host.
    func effectiveForwardings(for host: HostEntry) -> [PortForward] {
        hostStore?.effectiveForwardings(for: host) ?? host.forwardings
    }

    // MARK: - Socket path

    func socketPath(for host: HostEntry) -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".synapty/sockets").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/\(effectiveUsername(for: host))@\(host.address):\(effectivePort(for: host))"
    }

    // MARK: - Tunnel status

    func status(for host: HostEntry) -> TunnelStatus {
        tunnelStates[host.id] ?? .disconnected
    }

    // MARK: - Check tunnel health

    func checkTunnel(for host: HostEntry) -> Bool {
        Self.sshControl(
            socket: socketPath(for: host),
            userAtHost: "\(effectiveUsername(for: host))@\(host.address)",
            ctl: "check"
        )
    }

    // MARK: - Ensure tunnel (auto-setup on first connect)

    /// Ensures a tunnel is active for the host AND the remote synapty binary
    /// is up to date. Always runs setup-host.sh — it reuses an existing
    /// ControlMaster (fast) and uploads a stale remote binary (WI-2026-03-31-003,
    /// sa_family_t deploy fix), so a live master no longer skips binary
    /// freshness checks.
    func ensureTunnel(for host: HostEntry, completion: @escaping ((command: String, agentID: String)) -> Void) {
        trackedHosts[host.id] = host

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
    /// Argument layout is FIXED so the shell scripts can shift reliably:
    /// <agent-id> <host> <port> <user> <tunnel-port> <hub-port> <key|''> <jump|''> [forwards...]
    func connectCommand(for host: HostEntry) -> (command: String, agentID: String) {
        let script = scriptPath("connect")
        let agentID = "\(host.label)-\(UUID().uuidString.prefix(4).lowercased())"
        let username = effectiveUsername(for: host)
        let port = effectivePort(for: host)
        // Always pass key and jump (empty string when absent) so positional
        // parsing in the script is unambiguous.
        let key = effectiveKeyPath(for: host) ?? ""
        let jump = effectiveProxyJump(for: host) ?? ""
        var parts = ["bash", shellEscape(script), shellEscape(agentID),
                     shellEscape(host.address), "\(port)",
                     shellEscape(username), "\(tunnelPort)", "\(hubPort)",
                     shellEscape(key), shellEscape(jump)]
        // Optional port-forwarding rules ("local 8080 localhost 80" each).
        for fwd in effectiveForwardings(for: host) {
            parts.append(fwd.kind.rawValue)
            parts.append("\(fwd.listenPort)")
            parts.append(shellEscape(fwd.targetHost))
            parts.append("\(fwd.targetPort)")
        }
        return (parts.joined(separator: " "), agentID)
    }

    /// Returns (command, agentID) for local sessions.
    func localCommand() -> (command: String, agentID: String) {
        let agentID = "local-\(UUID().uuidString.prefix(4).lowercased())"
        let synaptyBin: String
        // Contents/MacOS/ — Resources/ copies are killed by ASP (signature
        // not sealed); MacOS/ is the standard nested-helper location.
        let macosBin = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/synapty-cli").path
        if FileManager.default.fileExists(atPath: macosBin) {
            synaptyBin = macosBin
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            synaptyBin = "\(cwd)/zig-out/bin/synapty"
        }
        let cmd = "\(shellEscape(synaptyBin)) run --id \(shellEscape(agentID)) --hub 127.0.0.1:\(hubPort) -- ${SHELL:-/bin/zsh} -l"
        return (cmd, agentID)
    }

    // MARK: - Setup (background process)

    private func runSetup(for host: HostEntry) {
        let script = scriptPath("setup-host")
        // Process.arguments are passed as argv (no shell interpolation), so no escaping needed here.
        // The script itself uses $1, $2 etc. which are safe in bash.
        // Fixed layout: <host> <port> <user> <tunnel-port> <hub-port> <key|''> <jump|''> [forwards...]
        var args = [script, host.address, "\(effectivePort(for: host))", effectiveUsername(for: host), "\(tunnelPort)", "\(hubPort)"]
        args.append(effectiveKeyPath(for: host) ?? "")
        args.append(effectiveProxyJump(for: host) ?? "")
        // Optional port-forwarding rules ("local 8080 localhost 80" each).
        for fwd in effectiveForwardings(for: host) {
            args.append(fwd.kind.rawValue)
            args.append("\(fwd.listenPort)")
            args.append(fwd.targetHost)
            args.append("\(fwd.targetPort)")
        }

        // Runs on a background queue: both pipes are drained concurrently
        // and a hard timeout bounds a stuck ssh — previously the setup
        // output pipe was never drained while running, so a >64KB burst
        // blocked the child and the session hung in .connecting forever
        // (WI-2026-08-08-005).
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = SubprocessRunner.run(
                executable: "/bin/bash",
                arguments: args,
                timeout: 60
            )
            DispatchQueue.main.async {
                guard let self else { return }
                if output.error == nil && !output.timedOut {
                    self.tunnelStates[host.id] = .connected
                    // Fire all pending callbacks
                    let callbacks = self.pendingCallbacks.removeValue(forKey: host.id) ?? []
                    for cb in callbacks {
                        cb(self.connectCommand(for: host))
                    }
                } else {
                    if let error = output.error {
                        Logger.tunnelManager.error("setup launch failed: \(error, privacy: .public)")
                    } else if output.timedOut {
                        Logger.tunnelManager.error("setup for \(host.address, privacy: .public) timed out after 60s")
                    }
                    let lastLine = output.stderr.split(separator: "\n").last.map(String.init)
                        ?? output.stdout.split(separator: "\n").last.map(String.init)
                        ?? (output.error ?? "Setup failed")
                    self.tunnelStates[host.id] = .failed(lastLine)
                    self.pendingCallbacks.removeValue(forKey: host.id)
                    // Tell the UI so the connecting placeholder shows the error
                    // instead of spinning forever (WI-2026-03-31-003).
                    NotificationCenter.default.post(
                        name: .synaptyTunnelFailed,
                        object: nil,
                        userInfo: ["hostID": host.id, "message": lastLine]
                    )
                }
            }
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
        // The blocking ssh -O exit runs off the main thread with the
        // socket/user resolved first: on an unreachable remote it can
        // otherwise block for the full connect timeout and freeze the UI
        // (WI-2026-08-08-010). Launch errors are handled inside sshControl
        // (no waitUntilExit on a never-run process).
        let socket = socketPath(for: host)
        let userAtHost = "\(effectiveUsername(for: host))@\(host.address)"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = Self.sshControl(socket: socket, userAtHost: userAtHost, ctl: "exit")
            DispatchQueue.main.async {
                guard let self else { return }
                self.tunnelStates[host.id] = .disconnected
                self.trackedHosts.removeValue(forKey: host.id)
            }
        }
    }

    // MARK: - Heartbeat

    func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            // Timer callbacks are Sendable; hop to the main actor for the
            // @MainActor runHeartbeat (WI-2026-08-08-009).
            Task { @MainActor [weak self] in
                self?.runHeartbeat()
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func runHeartbeat() {
        let hostsToCheck = trackedHosts.filter { tunnelStates[$0.key] == .connected }

        for (hostID, host) in hostsToCheck {
            // Resolve everything the check needs on the main actor; the
            // blocking ssh spawn then runs off-main (WI-2026-08-08-009).
            let socket = socketPath(for: host)
            let userAtHost = "\(effectiveUsername(for: host))@\(host.address)"
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let alive = Self.sshControl(socket: socket, userAtHost: userAtHost, ctl: "check")
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !alive && self.tunnelStates[hostID] == .connected {
                        self.reconnectTunnel(for: host)
                    }
                }
            }
        }
    }

    /// Spawn `ssh -S <socket> -O <ctl> <user@host>` against a ControlMaster
    /// socket. Pure process spawn with no shared-state access, so it can run
    /// off the main actor without isolation warnings.
    nonisolated private static func sshControl(socket: String, userAtHost: String, ctl: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-S", socket, "-O", ctl, userAtHost]
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
}
