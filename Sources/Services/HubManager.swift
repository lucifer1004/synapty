import Foundation
import Observation

/// Owns this machine's hub ([[ADR-0008]]: every machine that hosts agents
/// runs one, and agents always connect to their own machine's over
/// loopback — there is no "current hub" to select).
///
/// The hub is a SUPERVISED CHILD PROCESS, not an in-process library, so a
/// fault in the message router cannot cost the human every pane and every
/// running process. Three guards replace the "lifetime by construction"
/// an in-process hub would have given for free:
///
///   1. --parent-pid: the hub watches this process and, when it dies,
///      starts a bounded grace window instead of lingering forever.
///   2. The grace window lets a RELAUNCHING workbench reclaim the same
///      hub (it reclaims by subscribing, which it does anyway); nobody
///      reclaims it, it exits. Orphans are bounded rather than possible.
///   3. hub_info handshake before adoption: never adopt a listener whose
///      build does not match, so version skew cannot be adopted in
///      silence.
@MainActor @Observable final class HubManager {

    enum HubStatus: Equatable {
        case stopped
        case starting
        /// Running and adopted. `owned` distinguishes a hub we spawned
        /// from one we adopted (a service hub, or a developer's).
        case running(port: Int, owned: Bool)
        /// A listener holds the port but is NOT ours to use — a foreign
        /// process, or a build mismatch we may not take over. Loud by
        /// design: silent degradation is the failure mode this replaces.
        case conflict(String)
        case failed(String)
        /// It was here and now it is not, and the workbench is bringing it
        /// back ([[WI-2026-09-02-029]]). Distinct from `failed`, which is
        /// "we tried and could not": the dot reads warning rather than
        /// danger, and the popover says when the next attempt is.
        case lost(String, attempt: Int)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .running(_, let owned): return owned ? "Running" : "Running (adopted)"
            case .conflict(let why): return "Conflict: \(why)"
            case .failed(let msg): return "Failed: \(msg)"
            case .lost(let why, _): return "Lost: \(why) — restarting"
            }
        }

        var isRecovering: Bool {
            if case .lost = self { return true }
            return false
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        /// REFUSED IS NOT ABSENT, and the two surfaces a human reads had
        /// no way to tell them apart — both said the hub was down, which
        /// is what a crash looks like and suggests waiting or restarting.
        /// A refused hub is RUNNING; what failed is our right to use it,
        /// and neither waiting nor restarting resolves that
        /// ([[WI-2026-09-04-001]]).
        var isRefused: Bool {
            if case .conflict = self { return true }
            return false
        }

        /// Why it was refused, in the words `decideAdoption` chose. Nil
        /// for every other state, so a caller cannot print a reason for a
        /// hub that simply is not there.
        var refusalReason: String? {
            if case .conflict(let why) = self { return why }
            return nil
        }
    }

    /// One hub log line with a stable sequence number (WI-2026-08-08-023).
    struct HubLogLine: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    private(set) var status: HubStatus = .stopped
    var logs: [HubLogLine] = []
    /// The port this machine's hub actually bound; nil while stopped.
    private(set) var boundPort: Int?

    private var process: Process?

    // MARK: - Loss and recovery ([[WI-2026-09-02-029]])

    /// One stretch of not having a hub, from the moment it was lost to the
    /// moment one answers again. Announced ONCE — a crash loop is one
    /// outage with several attempts, not several outages.
    struct Outage: Equatable {
        var attempts = 0

        /// A loss noticed while `current` stands is the same outage; one
        /// noticed with none standing begins a new one, and only that
        /// beginning is worth telling the human about.
        static func noticed(_ current: Outage?) -> (outage: Outage, announce: Bool) {
            if let current { return (current, false) }
            return (Outage(), true)
        }
    }

    enum Recovery: Equatable {
        case retry(afterSeconds: Double)
        case giveUp
    }

    /// Doubling from one second; the fifth failure ends it. About a
    /// minute of trying is long enough to ride out a hub that is being
    /// reinstalled and short enough that a human still sees the give-up
    /// in the same sitting.
    static let recoveryAttempts = 5
    nonisolated static func nextRecovery(afterAttempts attempts: Int) -> Recovery {
        guard attempts < recoveryAttempts else { return .giveUp }
        return .retry(afterSeconds: pow(2.0, Double(attempts)))
    }

    /// A port that stops answering has to fail twice, this far apart,
    /// before it is a loss: a probe that times out on the first second
    /// after wake is a slow hub, not a dead one — and spawning beside a
    /// live hub is the one thing [[ADR-0008]] forbids. The gap is also a
    /// developer's window to restart a hub they Ctrl-C'd themselves.
    static let lossGraceSeconds: Double = 5
    /// How often a port we may not touch is asked again whether that is
    /// still so.
    static let conflictReprobeSeconds: Double = 10

    /// A disappearance is confirmed by two silent probes, not one.
    nonisolated static func lossConfirmed(first: HubInfo?, second: HubInfo?) -> Bool {
        first == nil && second == nil
    }

    private var outage: Outage?
    private var recoveryTask: Task<Void, Never>?
    private var confirmingLoss = false
    /// Replaceable so the loss signals can be driven without a socket.
    var probe: @Sendable (Int) async -> HubInfo? = { await HubManager.probe(port: $0) }
    var lossGrace: Double = HubManager.lossGraceSeconds
    /// Pending log lines awaiting the next throttled publish.
    private var pendingLogs: [HubLogLine] = []
    private var logFlushTask: Task<Void, Never>?
    private var nextLogID = 0

    /// Build identity this workbench expects its hub to report: the build
    /// id of the `synapty` binary THIS APP SHIPS ([[WI-2026-08-14-005]]).
    ///
    /// ASKED OF THE BINARY, NOT COMPILED IN — Xcode copies a prebuilt
    /// helper into the bundle, so the two are built separately and no
    /// value known at Swift compile time can be the answer.
    ///
    /// Resolved once, lazily. A binary that cannot be asked yields
    /// "unknown", so the failure is a refusal to adopt, never a false
    /// match.
    static let expectedBuild: String = {
        guard let bin = SynaptyBinary.resolve() else { return "unknown" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "unknown" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let id = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return "unknown" }
        return id
    }()

    /// True when this process is an XCTest host ([[WI-2026-08-14-006]]).
    ///
    /// A TEST PROCESS MUST NOT MANAGE THE MACHINE'S HUB. It shares the
    /// port, the discovery file and the machine identity with whatever
    /// workbench the operator is running, so starting one here does not
    /// create a second hub — it takes over the real one.
    ///
    /// Read from XCTest's own environment rather than a build flag: the
    /// hazard belongs to the RUN, not the configuration, since the test
    /// host is a Debug build of the same app the operator may also run.
    nonisolated static var isTestHost: Bool { TestHost.isActive }

    // MARK: - Port policy

    /// SYNAPTY_HUB_PORT (strict — bind exactly or fail) is the single
    /// manual override; otherwise the default with the hub's own ladder.
    nonisolated static func preferredPort() -> Int {
        if let raw = ProcessInfo.processInfo.environment["SYNAPTY_HUB_PORT"],
           let p = Int(raw), p > 0
        {
            return p
        }
        return 9000
    }

    // MARK: - Adoption handshake (ADR-0008)

    struct HubInfo: Equatable {
        var build: String
        var pid: Int
        var workbenchSpawned: Bool
        var port: Int
        /// Live supervisor links — subscribers, so this is the count of
        /// workbenches actually USING this hub. NIL MEANS THE HUB DID NOT
        /// SAY, which a hub built before this field existed does not, and
        /// which is not the same as saying zero.
        var supervisors: Int?
        /// Relay links the hub ALREADY holds, as (peerID, loopbackPort).
        /// A workbench that just launched must adopt these rather than
        /// assume it starts unfederated: the hub deliberately outlives the
        /// workbench, so on relaunch it is routinely already peered while
        /// the workbench knows nothing about it — leaving it with no peer
        /// subscription and no port assignment, which silently disables
        /// both the merged view's rich data and any redial.
        var peers: [(peer: String, port: Int)] = []
        /// What each peer declared it PROVIDES ([[RFC-0010]]
        /// C-CAPABILITIES), keyed by peer id. What a peer does NOT provide
        /// is the part a human needs, and it is only derivable from this.
        var peerCapabilities: [String: Set<String>] = [:]

        static func == (a: HubInfo, b: HubInfo) -> Bool {
            a.build == b.build && a.pid == b.pid
                && a.workbenchSpawned == b.workbenchSpawned && a.port == b.port
                && a.supervisors == b.supervisors
                && a.peers.map(\.peer) == b.peers.map(\.peer)
                && a.peers.map(\.port) == b.peers.map(\.port)
                && a.peerCapabilities == b.peerCapabilities
        }
    }

    /// Capabilities per peer from a hub_info payload. A peer present with
    /// an EMPTY set is meaningful and distinct from a peer that is absent:
    /// the first provides nothing optional, the second is not linked.
    nonisolated static func parsePeerCapabilities(_ data: [String: Any]) -> [String: Set<String>] {
        guard let raw = data["peers"] as? [[String: Any]] else { return [:] }
        var out: [String: Set<String>] = [:]
        for entry in raw {
            guard let peer = entry["peer"] as? String, !peer.isEmpty else { continue }
            out[peer] = Set((entry["capabilities"] as? [String]) ?? [])
        }
        return out
    }

    /// Parse the `peers` array from a hub_info payload. Pure; unit-tested.
    nonisolated static func parsePeers(_ data: [String: Any]) -> [(peer: String, port: Int)] {
        guard let raw = data["peers"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let peer = entry["peer"] as? String, !peer.isEmpty,
                  let port = entry["port"] as? Int, port > 0
            else { return nil }
            return (peer: peer, port: port)
        }
    }

    /// What to do about a listener already holding the port. Pure so the
    /// policy is testable without sockets or processes.
    enum Adoption: Equatable {
        /// Build matches — use it as-is.
        case adopt
        /// Ours (workbench-spawned) but stale: terminate and respawn.
        case takeOver
        /// Someone else's, or a mismatch we must not touch. Surface it.
        case conflict(String)
    }

    nonisolated static func decideAdoption(info: HubInfo?, expectedBuild: String) -> Adoption {
        guard let info else {
            // A listener that will not answer hub_info is not a hub we
            // understand. Never assume; never adopt blind.
            return .conflict("port held by a process that is not a Synapty hub")
        }
        // "unknown" means a side could not work out its own build. Two
        // of those are two absences, not agreement.
        if info.build == expectedBuild, expectedBuild != "unknown" { return .adopt }
        if info.workbenchSpawned {
            // TAKEOVER IS FOR A HUB NOBODY IS USING. Its supervisor links
            // are subscribers, so a live one means another workbench is
            // routing through this hub right now — terminating it takes
            // that app's A2A out from under it, which is not ours to do
            // however wrong its build looks from here.
            //
            // A second instance must REUSE this machine's hub, never
            // replace or duplicate it: the machine mints ONE identity that
            // peers key their directory and spool on, publishes ONE
            // discovery entry that every bare CLI reads, and splitting
            // agents across two routers makes them invisible to each other
            // on the same machine ([[ADR-0008]], [[RFC-0010]]).
            // ABSENCE OF EVIDENCE IS NOT EVIDENCE OF ABSENCE. A hub that
            // predates this field reports nothing, and reading that as
            // "nobody is using it" would terminate a live workbench's hub
            // during exactly the upgrade window this guard exists for.
            guard let supervisors = info.supervisors else {
                return .conflict(
                    "a hub of build \(info.build) is here and cannot say whether it is in use")
            }
            guard supervisors == 0 else {
                return .conflict(
                    "another Synapty (build \(info.build)) is using this hub")
            }
            return .takeOver
        }
        return .conflict("hub build \(info.build) ≠ workbench build \(expectedBuild)")
    }

    // MARK: - Lifecycle

    /// Ensure this machine has a usable hub, and return its port.
    /// ASYNC, BECAUSE THE ANSWER IS NOT KNOWN UNTIL THE HUB SAYS
    /// ([[WI-2026-09-02-022]]): the hub picks its own port via the ladder,
    /// so the consumers have to wait for the confirmed one — and this used
    /// to make them wait by blocking the main actor: a half-second sleep on
    /// takeover and up to forty probes of a one-second socket read each,
    /// forty seconds of frozen window for a hub that accepted and never
    /// answered. The probes now run on a background thread and the main
    /// actor only publishes what came back.
    @discardableResult
    func start() async -> Int? {
        guard !Self.isTestHost else {
            // Not `.failed`: nothing went wrong, this process simply has
            // no business owning a hub.
            status = .stopped
            appendLog("test host — not managing this machine's hub")
            return nil
        }
        status = .starting
        let port = Self.preferredPort()
        // The build id is a subprocess the first time it is asked; asked
        // here, off the main actor, so the lazy static is never first
        // touched from it ([[WI-2026-09-02-034]]).
        let expected = await Task.detached(priority: .userInitiated) { Self.expectedBuild }.value

        // Something already listening? Ask who it is BEFORE trusting it.
        if let info = await probe(port) {
            switch Self.decideAdoption(info: info, expectedBuild: expected) {
            case .adopt:
                boundPort = info.port
                status = .running(port: info.port, owned: false)
                outage = nil
                appendLog("Adopted hub on \(info.port) (build \(info.build), pid \(info.pid))")
                return info.port
            case .takeOver:
                appendLog("Stale hub on \(port) (build \(info.build)) — taking over")
                kill(pid_t(info.pid), SIGTERM)
                // Give the old listener a moment to release the port; the
                // ladder covers us if it does not.
                try? await Task.sleep(nanoseconds: 500_000_000)
            case .conflict(let why):
                // LOUD: the human must know they are not getting A2A,
                // rather than discovering it through broken behaviour.
                status = .conflict(why)
                appendLog("Refusing to adopt: \(why)")
                // AND ASKED AGAIN. A conflict used to be decided once for
                // the life of the process; the hub that held the port
                // could be killed by hand and the workbench never noticed
                // the port was free ([[WI-2026-09-02-029]]).
                scheduleConflictReprobe()
                return nil
            }
        }
        let recovered = await spawn(preferredPort: port, strictPort: outage != nil)
        if recovered != nil { outage = nil }
        return recovered
    }

    // MARK: - Loss ([[WI-2026-09-02-029]])

    /// The hub is gone. Two signals arrive here — a spawned process
    /// exiting, and an adopted port confirmed silent — and this is the one
    /// place that says so and starts bringing it back.
    func hubLost(_ reason: String) {
        let (current, announce) = Outage.noticed(outage)
        outage = current
        boundPort = nil
        status = .lost(reason, attempt: current.attempts)
        appendLog("Hub lost: \(reason)")
        if announce {
            AppNotifications.shared?.post(
                .failed, "Hub stopped",
                detail: "\(reason). Restarting it; agents on this Mac cannot exchange messages until it is back.")
        }
        // A TEST PROCESS MUST NOT MANAGE THE MACHINE'S HUB, so it records
        // the loss and leaves the recovery to whoever owns the port.
        guard !Self.isTestHost else { return }
        scheduleRecovery()
    }

    /// The subscription to the hub dropped. Not yet a loss: the hub drops
    /// a subscriber it finds stalled ([[WI-2026-09-02-015]]) and stays up,
    /// so the port is asked — twice, a grace apart — before anyone is told.
    func subscriberDisconnected() {
        guard case .running(let port, _) = status, !confirmingLoss else { return }
        confirmingLoss = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { confirmingLoss = false }
            let first = await probe(port)
            if first != nil { return }
            try? await Task.sleep(nanoseconds: UInt64(lossGrace * 1_000_000_000))
            guard case .running = status else { return }
            let second = await probe(port)
            guard Self.lossConfirmed(first: first, second: second) else { return }
            hubLost("port \(port) went silent")
        }
    }

    /// Skip the wait and try again now. Also the way out of `failed`,
    /// which is what the popover's Start does.
    func restartNow() {
        recoveryTask?.cancel()
        recoveryTask = nil
        if outage == nil { outage = Outage() }
        Task { @MainActor in await recover() }
    }

    private func scheduleRecovery() {
        recoveryTask?.cancel()
        guard let current = outage else { return }
        switch Self.nextRecovery(afterAttempts: current.attempts) {
        case .giveUp:
            status = .failed("could not restart the hub after \(current.attempts) attempts")
            appendLog("Giving up after \(current.attempts) attempts; Start in the hub popover tries again")
            AppNotifications.shared?.post(
                .failed, "Hub could not be restarted",
                detail: "Click Hub in the status bar and choose Start to try again.")
            outage = nil
        case .retry(let seconds):
            recoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.recover()
            }
        }
    }

    private func recover() async {
        outage?.attempts += 1
        if await start() == nil, case .failed = status, outage != nil {
            scheduleRecovery()
        }
    }

    private func scheduleConflictReprobe() {
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.conflictReprobeSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, case .conflict = status else { return }
            _ = await start()
        }
    }

    /// One probe, off the main thread. `queryHubInfo` holds a socket read
    /// with a one-second deadline; that second belongs to a background
    /// thread, not to the window.
    nonisolated private static func probe(port: Int) async -> HubInfo? {
        await Task.detached(priority: .userInitiated) {
            Self.queryHubInfo(port: port) ?? Self.queryDiscoveredHub()
        }.value
    }

    /// `strictPort` for a RECOVERY spawn: the hub's ladder would step to
    /// the next port if this one is still held — and a port still held
    /// during a recovery means the hub we thought lost is alive, so the
    /// right outcome is a loud failure, never a second hub beside it.
    private func spawn(preferredPort port: Int, strictPort: Bool = false) async -> Int? {
        guard let binary = SynaptyBinary.resolve() else {
            status = .failed("synapty binary not found")
            appendLog("Error: synapty binary not found")
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "hub",
            "--port", "\(port)",
            // Supervision: our pid is the hub's lifeline.
            "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)",
        ] + (strictPort ? ["--strict-port"] : [])

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        // A CHUNK IS NOT A LINE. The pipe hands over whatever has arrived,
        // and a log line split across two reads used to appear as two
        // lines; the tail past the last newline is carried to the next
        // read. Only this handler touches the carry, and the handle
        // serialises its own callbacks.
        final class Carry: @unchecked Sendable { var tail = "" }
        let carry = Carry()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            var pieces = (carry.tail + str).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            carry.tail = pieces.removeLast()
            let lines = pieces
            Task { @MainActor in
                for line in lines where !line.isEmpty { self?.appendLog(line) }
            }
        }
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                if self.process === p {
                    self.process = nil
                    if self.status.isRunning {
                        self.hubLost("the hub exited with code \(p.terminationStatus)")
                    }
                }
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            status = .failed(error.localizedDescription)
            appendLog("Error: \(error.localizedDescription)")
            return nil
        }

        // The hub picks its own port via the ladder, so ASK where it
        // landed rather than assuming — the discovery file and the
        // handshake are the contract, not the flag we passed.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let info = await Self.probe(port: port) {
                boundPort = info.port
                status = .running(port: info.port, owned: true)
                appendLog("Hub listening on 127.0.0.1:\(info.port) (build \(info.build))")
                return info.port
            }
        }
        status = .failed("hub did not answer after start")
        appendLog("Hub did not answer hub_info after starting")
        return nil
    }

    /// App teardown. The hub's own parent-death watchdog is the guarantee;
    /// this is the graceful path.
    func shutdown() {
        recoveryTask?.cancel()
        recoveryTask = nil
        let owned: Bool
        if case .running(_, let o) = status { owned = o } else { owned = false }
        // STOPPED BEFORE TERMINATED: the exit that follows is ours, and
        // the termination handler must not read it as a loss to recover.
        // An adopted hub is left running — it was never ours to end — but
        // this side stops watching it all the same.
        status = .stopped
        boundPort = nil
        if owned { process?.terminate() }
    }

    /// Stand the manager in `running(adopted)` without a socket, for the
    /// loss-signal tests. Not a path the app takes.
    func adoptForTesting(port: Int) {
        boundPort = port
        status = .running(port: port, owned: false)
        outage = nil
    }

    // MARK: - hub_info query

    nonisolated static func queryHubInfo(port: Int) -> HubInfo? {
        guard let sock = HubEventClient.connectLoopback(port: port) else { return nil }
        defer { close(sock) }
        let envelope: [String: Any] = [
            "type": "hub_info", "id": "wb-info", "source": "workbench", "target": "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              HubEventClient.writeAll(sock, Array(data) + [0x0A]) else { return nil }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(sock, &buf, buf.count)
        guard n > 0 else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let d = payload["data"] as? [String: Any],
              let build = d["build"] as? String,
              let pid = d["pid"] as? Int,
              let boundPort = d["port"] as? Int
        else { return nil }
        return HubInfo(
            build: build, pid: pid,
            workbenchSpawned: (d["workbench_spawned"] as? Bool) ?? false,
            port: boundPort,
            supervisors: d["supervisors"] as? Int,
            peers: parsePeers(d),
            peerCapabilities: parsePeerCapabilities(d))
    }

    /// Fall back to the discovery file when the hub landed on a ladder
    /// rung we did not guess.
    nonisolated static func queryDiscoveredHub() -> HubInfo? {
        guard let port = discoveredPort() else { return nil }
        return queryHubInfo(port: port)
    }

    /// WHICH PORT THE DISCOVERY FILE NAMES, separated from asking that
    /// port anything so the read can be tested without a hub.
    ///
    /// THROUGH THE CLASSIFICATION ([[ConfigPaths]]), which is what honours
    /// SYNAPTY_CONFIG_ROOT. Built from $HOME by hand, this read the
    /// operator's real hub.json while the UI suite ran against a scratch
    /// root — so a test whose own hub landed on a rung its port list did
    /// not cover adopted the operator's live hub instead, and routed its
    /// A2A through it ([[WI-2026-08-30-004]]).
    nonisolated static func discoveredPort() -> Int? {
        guard let data = try? Data(contentsOf: ConfigPaths.discovery),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = obj["port"] as? Int
        else { return nil }
        return port
    }

    // MARK: - Log plumbing (throttled)

    private func appendLog(_ line: String) {
        // The hub logs "agent metadata updated" on every agents poll —
        // pure noise that churned logs → whole-UI re-render
        // (WI-2026-08-07-006). Skip it.
        if line.contains("agent metadata updated") { return }
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        pendingLogs.append(HubLogLine(id: nextLogID, text: "[\(timestamp)] \(line)"))
        nextLogID += 1
        if pendingLogs.count > 500 { pendingLogs.removeFirst(pendingLogs.count - 500) }
        guard logFlushTask == nil else { return }
        logFlushTask = Task { @MainActor in
            defer { self.logFlushTask = nil }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, !self.pendingLogs.isEmpty else { return }
            self.logs.append(contentsOf: self.pendingLogs)
            self.pendingLogs.removeAll()
            if self.logs.count > 500 { self.logs.removeFirst(self.logs.count - 500) }
        }
    }
}
