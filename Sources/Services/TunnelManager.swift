import Foundation
import Observation
import AppKit
import os

/// Manages SSH ControlMaster tunnels to remote hosts.
/// Provides auto-setup on first connect, heartbeat monitoring, and auto-reconnect.
@MainActor @Observable final class TunnelManager {

    /// Singleton for access from WorkspaceManager (addPaneToActiveWorkspace).
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
        /// connection and an in-flight connect (WI-2026-08-08-025,
        /// WI-2026-08-08-031): .reconnecting means a setup is already
        /// running — offering Reconnect would allow double setups.
        var canReconnect: Bool {
            switch self {
            case .connected, .connecting, .reconnecting: return false
            case .disconnected, .failed: return true
            }
        }

        /// A tunnel in a state that implies an active/live connection —
        /// used for cascade warnings when hosts are deleted
        /// (WI-2026-08-08-045).
        var isActive: Bool {
            switch self {
            case .connected, .connecting, .reconnecting: return true
            case .disconnected, .failed: return false
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
    /// A HUB REACHED IS A HUB TOLD WHAT THE HUMAN SET
    /// ([[RFC-0012]] C-LEVEL-CONTROL, [[HubLogLevel.applyCurrent]]).
    var hubPort: Int = 9000 {
        didSet { HubLogLevel.applyCurrent(port: hubPort) }
    }

    /// Remote listen port of the reverse tunnel; forwards to localhost:HUB_PORT.
    var tunnelPort: Int = 9000

    /// Per-host tunnel status.
    var tunnelStates: [UUID: TunnelStatus] = [:]

    /// Hosts we're tracking for heartbeat.
    private var trackedHosts: [UUID: HostEntry] = [:]

    private var heartbeatTimer: Timer?

    /// Pending connection callbacks (queued while setup is running), each
    /// with the connect command CAPTURED AT REQUEST TIME — recomputing it
    /// at completion could drift from the tunnel actually established if
    /// ports/hosts changed mid-setup (WI-2026-08-08-031).
    private var pendingCallbacks: [UUID: [(command: String, agentID: String, onReady: ((command: String, agentID: String)) -> Void)]] = [:]

    // MARK: - Shell escaping

    /// Single-quote a string for safe shell interpolation.
    /// Handles embedded single quotes by ending the quote, adding an escaped quote, and reopening.
    /// Contents/Helpers/synapty — see SynaptyBinary.bundledPath for why it
    /// must not live in MacOS/ (APFS case collision with "Synapty"); the
    /// dev checkout's zig-out otherwise.
    nonisolated static func localSynaptyBin() -> String {
        let macosBin = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/synapty").path
        if FileManager.default.fileExists(atPath: macosBin) { return macosBin }
        return "\(FileManager.default.currentDirectoryPath)/zig-out/bin/synapty"
    }

    /// TELL THE HOLDER WHAT THE HUMAN CALLS THIS SESSION ([[RFC-0014]]
    /// C-SESSION-NAME), so `synapty sessions` and the attach banner say
    /// the same name the tab does. Fire-and-forget: a holder that keeps no
    /// names, or one out of reach, changes nothing here.
    func nameSession(agentID: String, on host: HostEntry?, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let host {
            runOnHost(host, command: ".synapty/bin/synapty name --id \(Shell.quote(agentID)) --name \(Shell.quote(trimmed))") { _ in }
            return
        }
        let bin = Self.localSynaptyBin()
        DispatchQueue.global(qos: .utility).async {
            _ = SubprocessRunner.run(executable: bin,
                                     arguments: ["name", "--id", agentID, "--name", trimmed],
                                     timeout: 5)
        }
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

    /// Detect the remote OS after a successful connect and fill the host's
    /// osHint when it is still unset (WI-2026-08-09-002). Failures stay
    /// silent — this is a cosmetic affordance, never a connection gate.
    /// THE IDENTITY AND THE ROUTE, resolved through the inheritance that
    /// decides what the REAL connection presents ([[WI-2026-08-28-006]]).
    ///
    /// NOT THE PORT: the connection pool keys on it and passes it itself,
    /// so this is the part every caller shares.
    ///
    /// `effectiveKeyPath` here rather than the store's, because this one
    /// falls back to the key enrolment authorized when the record names a
    /// path this Mac does not have ([[ADR-0009]]) — and a probe that
    /// presents a different credential than the connection is a probe
    /// answering a different question.
    func identityArgs(for host: HostEntry) -> [String] {
        var args: [String] = []
        if let identity = effectiveKeyPath(for: host), !identity.isEmpty {
            args += ["-i", identity]
        }
        if let jump = effectiveProxyJump(for: host), !jump.isEmpty {
            args += ["-J", jump]
        }
        return args
    }

    /// EVERYTHING A ONE-OFF ssh TO THIS HOST NEEDS, destination and remote
    /// command included.
    ///
    /// One function because there were four, and they had drifted: the
    /// connection added `-J` for a jump host and Test Connection, the OS
    /// probe and enrolment's `runOnHost` did not — so on any host behind a
    /// bastion all three went straight at a machine that only answers
    /// through one, and reported a failure the human's own connection does
    /// not have.
    ///
    /// BatchMode so a host that would prompt fails instead of hanging on a
    /// password nobody can see.
    func oneOffArgs(for host: HostEntry, connectTimeout: Int,
                    remote: String) -> [String] {
        SSHPolicy.opening(connectTimeout: connectTimeout)
            + ["-p", "\(effectivePort(for: host))"]
            + identityArgs(for: host)
            + ["\(effectiveUsername(for: host))@\(host.address)", remote]
    }

    private func probeOS(for host: HostEntry) {
        guard let store = hostStore,
              let current = store.hosts.first(where: { $0.id == host.id }),
              current.osHint == nil || current.osHint?.isEmpty == true
        else { return }
        let args = oneOffArgs(for: host, connectTimeout: 5, remote: OSProbe.command)
        let hostID = host.id
        DispatchQueue.global(qos: .utility).async {
            let output = SubprocessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: args,
                timeout: 10
            )
            guard output.error == nil, !output.timedOut,
                  let hint = OSProbe.parse(output.stdout) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.hostStore?.setDetectedOS(hint, for: hostID)
            }
        }
    }

    /// What running a command on a host came to. A plain enum rather than
    /// `Result`: the failure is a sentence for a human, not an Error.
    enum HostCommandOutcome {
        case ok(String)
        case failed(String)
    }

    /// Run ONE command on a host and hand back what it said.
    ///
    /// Used by enrolment ([[ADR-0009]]), which is a human's explicit act:
    /// this never runs as a consequence of adding a host, connecting to
    /// one, or turning sync on. BatchMode so a host that would prompt
    /// fails instead of hanging on a password nobody can see.
    func runOnHost(
        _ host: HostEntry, command: String,
        completion: @escaping @MainActor (HostCommandOutcome) -> Void
    ) {
        // A SUCCESS SENTINEL rather than an exit code: SubprocessRunner
        // does not surface one, and ssh writes warnings to stderr that say
        // nothing about whether the remote command worked. The marker only
        // appears if the command actually reached the end.
        let marker = "__synapty_ok__"
        let args = oneOffArgs(for: host, connectTimeout: 10,
                              remote: "\(command) && echo \(marker)")
        DispatchQueue.global(qos: .userInitiated).async {
            let out = SubprocessRunner.run(
                executable: "/usr/bin/ssh", arguments: args, timeout: 20)
            Task { @MainActor in
                if out.timedOut {
                    return completion(.failed("the host did not answer within 20 seconds"))
                }
                if let e = out.error { return completion(.failed(e)) }
                guard out.stdout.contains(marker) else {
                    let said = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    return completion(.failed(said.isEmpty ? "the host refused the command" : said))
                }
                completion(.ok(out.stdout.replacingOccurrences(of: marker, with: "")))
            }
        }
    }

    /// Effective SSH key path for a host, or nil.
    /// The key this machine will actually PRESENT.
    ///
    /// Host records SYNC and `sshKeyPath` is a machine-local PATH, so a
    /// record that works on the Mac it was written on can name a file the
    /// next Mac does not have. Falling back to this machine's dedicated
    /// key is what makes enrolment mean anything ([[ADR-0009]]): without
    /// it, enrolment authorizes a key nothing ever offers.
    ///
    /// Only when the configured path is absent or missing HERE, so a Mac
    /// that has the human's key keeps using it and no working setup
    /// changes which credential it presents.
    func effectiveKeyPath(for host: HostEntry) -> String? {
        let configured = hostStore?.effectiveKeyPath(for: host) ?? host.sshKeyPath

        // NO KEY NAMED IS NOT A MISSING KEY ([[WI-2026-08-15-008]]).
        //
        // A record with no `sshKeyPath` is the ordinary setup for anyone
        // on ssh-agent or ~/.ssh/config, and the right answer is to pass
        // NOTHING and let ssh use what it already knows. Supplying this
        // machine's dedicated key there offers an identity no host has
        // authorised and turns a working connection into "Permission
        // denied" — measured against a live host, where the same command
        // succeeds without `-i` and fails with it.
        guard let configured else { return nil }

        if FileManager.default.fileExists(atPath: configured) { return configured }

        // A key that IS named and is not on this machine: the record came
        // from another Mac, naming a path that exists there. This is the
        // case [[ADR-0009]] enrolment answers, and the only one where
        // substituting our own key is right.
        if let peerID = MachineKey.localPeerID() {
            let own = MachineKey.privateKeyURL(peerID: peerID).path
            if FileManager.default.fileExists(atPath: own) { return own }
        }
        // Neither on disk: hand back what was configured, so the failure
        // names the file the human expected rather than nothing.
        return configured
    }

    func effectivePort(for host: HostEntry) -> Int {
        hostStore?.effectivePort(for: host) ?? host.port
    }

    func effectiveProxyJump(for host: HostEntry) -> String? {
        hostStore?.effectiveProxyJump(for: host)
    }

    func effectiveForwardings(for host: HostEntry) -> [PortForward] {
        hostStore?.effectiveForwardings(for: host) ?? host.forwardings
    }

    // MARK: - Connections

    /// A host's SSH connections, as many as its load has called for
    /// ([[RFC-0013]] C-BROKER). There is no lane and no fixed count: which
    /// connection a channel lands on follows what the others are carrying,
    /// and a refused channel opens one more.
    let pool = MasterPool()

    /// The name a pane's slot is recorded under, and the file its own
    /// transport re-reads on every attempt. ONE RECORD, NOT TWO: this used
    /// to be a dictionary here beside a file on disk, and they disagreed
    /// on the most ordinary case there is — the first pane on a host,
    /// where the pool had nothing to offer and the launch script wrote the
    /// derived path into the file while this side counted nothing.
    ///
    /// THE MACHINE IS IN THE NAME because the agent id is not unique
    /// across machines and never promised to be ([[RFC-0009]]
    /// C-IDENTITY-SCOPE qualifies it for exactly that reason). Keying this
    /// by the agent id alone worked only because remote panes happened to
    /// carry a host label in their id — an accident, not a design, and one
    /// that would have broken the moment those ids took the shape
    /// [[RFC-0008]] C-IDENTITY reserves for them.
    ///
    /// THE MACHINE IS ITS ID, NOT ITS LABEL. The label is the human's to
    /// change while the pane is open, and a slot claimed under the old
    /// name was never released under the new one ([[WI-2026-09-02-024]]).
    static func paneTenant(hostID: UUID?, agentID: String) -> String {
        "pane.\(hostID?.uuidString ?? "local").\(agentID)"
    }

    /// A pane closed. Called from the leaf lifecycle, which is the only
    /// place that knows a session is finished with rather than merely
    /// moved — releasing on a move would hand back a slot still in use.
    func paneClosed(hostID: UUID?, agentID: String) {
        let tenant = Self.paneTenant(hostID: hostID, agentID: agentID)
        pool.release(tenant: tenant)
        try? FileManager.default.removeItem(
            at: MasterPool.tenantDirectory.appendingPathComponent(tenant + ".pid"))
    }

    /// Where a pane's transport reads which connection to use, and writes
    /// its own pid. connect.sh writes the same two files.
    /// Move an open pane onto a different connection ([[RFC-0013]]
    /// C-BROKER).
    ///
    /// NOTHING IS RESTARTED AND NOTHING IS LOST. The pane's process is the
    /// attach client, which already respawns its transport when the
    /// transport dies — in the same process and the same pty, so the local
    /// scrollback stays where it is. The transport resolves its socket from
    /// a file each time it starts, so writing a different one there and
    /// ending the transport is the whole of a migration; the holder on the
    /// far side then resumes the client from where it stopped reading.
    ///
    /// THE ORDER IS NOT INCIDENTAL. The file is written before the
    /// transport is ended, because the respawn reads it immediately and a
    /// migration that lost that race would reconnect to the connection it
    /// was leaving.
    @discardableResult
    func migratePane(hostID: UUID?, agentID: String, to socket: String) -> Bool {
        let tenant = Self.paneTenant(hostID: hostID, agentID: agentID)
        return migratePane(tenant: tenant, from: pool.recordedCarrier(of: tenant), to: socket)
    }

    @discardableResult
    func migratePane(tenant: String, from old: String?, to socket: String) -> Bool {
        let pidFile = MasterPool.tenantDirectory.appendingPathComponent(tenant + ".pid")
        guard let pidText = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              // AND IT IS STILL RUNNING. The pid comes off disk now and so
              // outlives the process that wrote it; signalling a recycled
              // one would end somebody else's program. Signal 0 asks
              // without sending.
              kill(pid, 0) == 0 || errno == EPERM
        else { return false }

        // NOTHING MOVES UNTIL THE PANE IS KNOWN TO BE THERE. ONE WRITE:
        // the record the pool counts and the file the transport re-reads
        // are the same file, so moving a pane is changing its mind once
        // rather than keeping two copies in step.
        if let old { pool.noteSlotFreed(on: old) }
        pool.claim(tenant: tenant, on: socket)
        kill(pid, SIGTERM)
        AppLog.tunnelManager.info(
            "pane \(tenant, privacy: .public) moved to \((socket as NSString).lastPathComponent, privacy: .public)")
        return true
    }

    /// Panes that were already open when the load arrived.
    ///
    /// Placement keeps anything NEW off a loaded connection, which is the
    /// cheap half; this is the residue, and it is the case the human
    /// actually reports — a terminal that was fine until a port forward
    /// started moving data underneath it.
    private func migrateStalledPanes(for host: HostEntry) {
        let key = poolKey(for: host)
        for (tenant, socket) in pool.panes(on: key) {
            guard let better = pool.betterThan(socket, for: key) else { continue }
            // THROUGH THE ONE IMPLEMENTATION. This had a copy of
            // `migratePane`'s body, which drifted from it immediately: the
            // copy claimed the new socket and cleared the old one's
            // refusal BEFORE checking that a transport was running. A
            // record left behind by a pane that is gone would then clear
            // `full` on a connection genuinely at its session bound —
            // undoing the one thing that flag exists to hold — and be
            // redistributed rather than aged out, with a "moved" line in
            // the log for a pane nobody can see.
            migratePane(tenant: tenant, from: socket, to: better)
        }
    }


    /// The human's own forwarding rules go up with the first connection,
    /// added by the launch script rather than through the pool — so
    /// without this the pool believes that connection is carrying nothing
    /// while it is in fact carrying every forward the host is configured
    /// with, and would put the next pane straight on top of them.
    ///
    /// Their LOAD is seen either way, by the round trip the heartbeat
    /// measures. This is about the tie-break between two equally quiet
    /// connections, not about the stall.
    private func hostForwardTenant(_ host: HostEntry, _ index: Int) -> String {
        "hostfwd.\(host.id.uuidString).\(index)"
    }

    private func recordConfiguredForwards(for host: HostEntry) {
        let rules = effectiveForwardings(for: host)
        let socket = pool.primary(for: poolKey(for: host))
        // ONE RECORD PER RULE, NAMED, so a reconnect claiming them again
        // is claiming the same names and changes nothing.
        for i in rules.indices {
            pool.claim(tenant: hostForwardTenant(host, i), on: socket)
        }
        // AND THE RECORDS FOR RULES THAT ARE NO LONGER THERE GO. A human
        // who deletes a forwarding rule and reconnects used to leave its
        // record behind counting against the connection forever — and
        // deleting the LAST rule left every one of them, because this
        // returned early on an empty list and never reached the claim
        // loop that would have been its only chance to notice.
        var extra = rules.count
        while pool.recordedCarrier(of: hostForwardTenant(host, extra)) != nil {
            pool.release(tenant: hostForwardTenant(host, extra))
            extra += 1
        }
    }

    init() {
        installPoolCredentials()
    }

    func poolKey(for host: HostEntry) -> MasterPool.HostKey {
        MasterPool.HostKey(
            userAtHost: "\(effectiveUsername(for: host))@\(host.address)",
            port: effectivePort(for: host))
    }

    /// Credentials for a connection the pool opens itself. The pool knows
    /// nothing about inheritance, which is this object's job.
    private func installPoolCredentials() {
        pool.sshArgs = { [weak self] key in
            guard let self,
                  let host = self.trackedHosts.values.first(where: {
                      "\(self.effectiveUsername(for: $0))@\($0.address)" == key.userAtHost
                          && self.effectivePort(for: $0) == key.port
                  })
            else { return [] }
            return self.identityArgs(for: host)
        }
    }

    /// Everything a file listing or a short remote command needs to reach
    /// this host, resolved here because credential inheritance is this
    /// object's job and the work itself runs off the main actor
    /// ([[WI-2026-08-15-009]]).
    ///
    /// A SHORT COMMAND RIDES WHATEVER IS ALREADY UP. When the host holds
    /// nothing the first connection's name is handed back anyway: ssh with
    /// `ControlMaster=no` and a socket that is not there simply connects on
    /// its own, which is what a listing on an unconnected host did before
    /// any of this existed.
    func connection(for host: HostEntry) -> RemoteConnection {
        let key = poolKey(for: host)
        return RemoteConnection(
            userAtHost: key.userAtHost,
            port: key.port,
            controlPath: pool.existing(key) ?? pool.primary(for: key),
            identity: effectiveKeyPath(for: host))
    }

    // MARK: - Tunnel status

    func status(for host: HostEntry) -> TunnelStatus {
        tunnelStates[host.id] ?? .disconnected
    }

    // MARK: - Ensure tunnel (auto-setup on first connect)

    /// Ensures a tunnel is active for the host AND the remote synapty binary
    /// is up to date. Always runs setup-host.sh — it reuses an existing
    /// ControlMaster (fast) and uploads a stale remote binary (WI-2026-03-31-003,
    /// sa_family_t deploy fix), so a live master no longer skips binary
    /// freshness checks.
    /// Returns the agent id this dial will use, so the caller can watch
    /// the account it has just begun ([[WI-2026-08-17-016]]).
    @discardableResult
    func ensureTunnel(
        for host: HostEntry,
        agentID: String? = nil,
        completion: @escaping ((command: String, agentID: String)) -> Void
    ) -> String {
        trackedHosts[host.id] = host

        // Queue the callback with the command captured NOW
        // (WI-2026-08-08-031).
        let command = connectCommand(for: host, agentID: agentID)
        pendingCallbacks[host.id, default: []].append((command.command, command.agentID, completion))

        // THE ACCOUNT BEGINS WHERE THE DIAL BEGINS ([[WI-2026-08-17-016]]).
        // The slow half of a connection happens here, before there is a
        // pane at all — a platform probe, a binary compared and maybe
        // uploaded, a terminfo, a hub, a peer link. Started at the pane
        // instead, the account was empty for the whole wait and then
        // arrived all at once at the end, which is a spinner followed by
        // a flash rather than progress.
        ConnectProgress.begin(for: command.agentID)

        // FAST PATH (WI-2026-08-08-063): a host whose tunnel is already
        // connected opens a new session immediately — no setup-host run
        // (5-6 SSH round trips + terminfo scp even with a live master),
        // no .connecting status flicker. The ControlMaster is verified
        // off-main; a dead master reconnects in the background. connect.sh
        // falls back to a fresh tunnel when no master exists, so the
        // session is safe either way. Binary/terminfo freshness stays on
        // the slow path (first connect / reconnect).
        if tunnelStates[host.id] == .connected {
            ConnectProgress.note("this host is already connected", for: command.agentID)
            verifyLiveMaster(for: host)
            return command.agentID
        }

        // Only start setup if not already in progress
        let currentStatus = tunnelStates[host.id]
        if currentStatus == .connecting || currentStatus == .reconnecting {
            ConnectProgress.note("waiting for this host's setup to finish", for: command.agentID)
            return command.agentID // setup already running, callback queued
        }

        tunnelStates[host.id] = .connecting
        ConnectProgress.note("setting this host up", for: command.agentID)
        runSetup(for: host, account: command.agentID)
        return command.agentID
    }

    /// Fast-path master verification (WI-2026-08-08-063): fire every queued
    /// callback immediately, then check the ControlMaster off-main. Alive →
    /// nothing more to do. Dead → background reconnect so the next session
    /// is fast again.
    private func verifyLiveMaster(for host: HostEntry) {
        let socket = pool.primary(for: poolKey(for: host))
        let userAtHost = "\(effectiveUsername(for: host))@\(host.address)"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let alive = Self.sshControl(socket: socket, userAtHost: userAtHost, ctl: "check")
            DispatchQueue.main.async {
                guard let self else { return }
                // Fire ALL queued callbacks — the workspaces start now; the
                // master check only decides whether to reconnect.
                let callbacks = self.pendingCallbacks.removeValue(forKey: host.id) ?? []
                for cb in callbacks {
                    cb.onReady((cb.command, cb.agentID))
                }
                if !alive && self.tunnelStates[host.id] == .connected {
                    self.reconnectTunnel(for: host)
                }
            }
        }
    }

    // MARK: - Connect command

    /// Returns (command, agentID) so callers can store the agent ID on the session.
    /// Argument layout is FIXED so the shell scripts can shift reliably:
    /// <agent-id> <host> <port> <user> <tunnel-port> <hub-port> <key|''> <jump|''> [forwards...]
    /// `agentID` overrides the generated one so a session can ATTACH to an
    /// agent already running on that host rather than starting a new one:
    /// connect.sh attaches when a holder of that name is already running
    /// (WI-2026-08-12-013). Passing the id of a remote agent you can see
    /// in the merged view is what "go to it" means.
    /// `cwd` is where the far side's shell should START — the directory a
    /// duplicated pane is reopened in ([[RFC-0015]] C-LAYOUT). It rides
    /// the environment for the same reason the two below it do, and it
    /// reaches a session that is being STARTED; a reattach rejoins the
    /// work where it already is, which is the answer that matters more.
    func connectCommand(for host: HostEntry, agentID overrideID: String? = nil,
                        cwd: String? = nil) -> PaneLaunch {
        let script = scriptPath("connect")
        // THE NAMESPACE [[RFC-0008]] C-IDENTITY RESERVES FOR EXACTLY THIS.
        // A pane with no resume_ref registers under its wrapper id, and
        // that id is `local-XXXX`. This minted `<host label>-<4 hex>`
        // instead — a third namespace nothing describes — so all three
        // predicates that decide whether an id must be qualified before it
        // crosses a relay said "not a fallback id" about one, and every
        // remote pane was advertised unqualified in violation of
        // [[RFC-0009]] C-IDENTITY-SCOPE.
        //
        // The label was doing a second, accidental job: keeping two hosts'
        // panes apart in tables the workbench keys by agent id. That job
        // belongs to the key, not to the name — the id is unique within
        // ONE machine and never promised more, which is why the qualifier
        // exists at all. See `paneTenant`.
        let freshID = "local-\(UUID().uuidString.prefix(4).lowercased())"
        let agentID = overrideID ?? freshID
        let username = effectiveUsername(for: host)
        let port = effectivePort(for: host)
        // Always pass key and jump (empty string when absent) so positional
        // parsing in the script is unambiguous.
        let key = effectiveKeyPath(for: host) ?? ""
        let jump = effectiveProxyJump(for: host) ?? ""
        // THROUGH `env`, NOT AS A BARE ASSIGNMENT. What runs this string is
        // `exec -l <command>`, and `exec` has no notion of a VAR=value
        // prefix — it takes the first word as the program to become, so a
        // bare assignment is executed as a PATH lookup for a file named
        // "SYNAPTY_BIN=/…". Found the first time a real connection was
        // attempted, as a shell reporting "No such file or directory"
        // about a path that is plainly there.
        //
        // Two things ride here rather than in the positional list, which
        // ends in a variadic run of forwarding rules: the human's
        // durability opt-out, and where the local client can find itself
        // — a bundled application cannot rely on a bare name on PATH
        // ([[WI-2026-08-17-009]]).
        var environment: [String] = []
        if let bin = SynaptyBinary.resolve() {
            environment.append("SYNAPTY_BIN=" + Shell.quote(bin))
        }
        if !host.durableSessions { environment.append("SYNAPTY_DURABLE=0") }
        // THE NAME TO START UNDER, if the one to return to is not running
        // there ([[RFC-0015]] C-PERSIST: a recorded id is a record and not
        // a grant). The far side picks; this side knows both names, so it
        // does not have to be told which was used — only one of them can
        // exist, and the registration says which one did.
        environment.append("SYNAPTY_FRESH_ID=" + Shell.quote(freshID))
        // WHICH CONNECTION THIS PANE RIDES ([[RFC-0013]] C-BROKER). Chosen
        // here rather than derived in the script, because "the connection
        // for this host" is no longer one answer — a pane must not land on
        // the one a port forward is saturating, and only this side has the
        // measurements that say which that is. Absent when the host holds
        // nothing yet, and the script then opens its own as it always has.
        //
        // CLAIMED ONCE PER PANE, not once per call, and claiming is
        // idempotent because one tenant has one record. A command can be
        // built more than once for the same pane; writing the same name
        // twice writes the same name.
        let tenant = Self.paneTenant(hostID: host.id, agentID: agentID)
        let tenantFile = MasterPool.tenantDirectory.appendingPathComponent(tenant).path
        environment.append("SYNAPTY_SOCKET_FILE=" + Shell.quote(tenantFile))
        environment.append("SYNAPTY_PID_FILE=" + Shell.quote(tenantFile + ".pid"))
        if let held = pool.carrier(of: tenant, for: poolKey(for: host)) {
            environment.append("SYNAPTY_SOCKET=" + Shell.quote(held))
        } else if let socket = pool.placeWithoutOpening(poolKey(for: host), tenant: tenant) {
            environment.append("SYNAPTY_SOCKET=" + Shell.quote(socket))
        }
        if let cwd, !cwd.isEmpty { environment.append("SYNAPTY_START_CWD=" + Shell.quote(cwd)) }
        // WHERE THE CONNECTION SAYS WHAT IT IS DOING ([[WI-2026-08-17-016]]).
        // Named in the environment so the launch script and the client it
        // hands over to write to the same place. EMPTYING IT IS THE
        // READER'S, not this — a command can be built more than once per
        // pane, and doing it here wiped the account of a connection that
        // had already happened.
        let channel = ConnectProgress.prepare(for: agentID)
        environment.append("SYNAPTY_CONNECT_LOG=" + Shell.quote(channel.path))
        var parts: [String] = environment.isEmpty ? [] : ["env"] + environment
        parts += ["bash", Shell.quote(script), Shell.quote(agentID),
                     Shell.quote(host.address), "\(port)",
                     Shell.quote(username), "\(tunnelPort)", "\(hubPort)",
                     Shell.quote(key), Shell.quote(jump)]
        // Optional port-forwarding rules ("local 8080 localhost 80" each).
        for fwd in effectiveForwardings(for: host) {
            parts.append(fwd.kind.rawValue)
            parts.append("\(fwd.listenPort)")
            parts.append(Shell.quote(fwd.targetHost))
            parts.append("\(fwd.targetPort)")
        }
        // THE OTHER NAME, only where there are two. With no recorded id
        // to return to, `agentID` IS the fresh one and there is nothing to
        // disambiguate later.
        return PaneLaunch(command: parts.joined(separator: " "),
                          agentID: agentID,
                          candidateID: overrideID == nil ? nil : freshID)
    }

    /// Returns (command, agentID) for local workspaces.
    /// `agentID` overrides the generated one so a restored pane RETURNS
    /// to the session it left rather than starting a second one beside it
    /// — the same parameter `connectCommand` takes, for the same reason.
    /// [[RFC-0014]] C-SCOPE: a workbench that mints a fresh name for a
    /// restored pane has not satisfied the recoverability that clause
    /// requires of a session's name.
    func localCommand(agentID overrideID: String? = nil) -> PaneLaunch {
        // A RECORDED ID IS A RECORD AND NOT A GRANT ([[RFC-0015]]
        // C-PERSIST). It names a session to RETURN to; where that session
        // is gone, a fresh child must not inherit it — another agent's
        // A2A traffic is routed by that name, and a new process wearing
        // it receives mail addressed to the one it replaced.
        //
        // ASKED BEFORE THE COMMAND IS BUILT, because afterwards is too
        // late: the id is on the command line and the child has it.
        let fresh = "local-\(UUID().uuidString.prefix(4).lowercased())"
        // ASKED ONCE, OF THE ONE THING THAT DECIDES IT. This asked only
        // whether the session was live, and the durability opt-out was not
        // consulted until twenty-five lines later — by which point the
        // name was already on the command line. With durability off the
        // child is run directly, so it is by construction a NEW child, and
        // it was being handed a surviving session's name
        // ([[RFC-0015]] C-PERSIST, [[WI-2026-08-30-007]]).
        let rejoining = Rejoining.local(
            recorded: overrideID, durable: SynaptySettings.shared.localDurableSessions)
        let agentID = (rejoining == .rejoined ? overrideID : nil) ?? fresh
        let synaptyBin = Self.localSynaptyBin()
        // START, THEN ATTACH — the same two requests connect.sh makes on
        // a remote host ([[RFC-0014]] C-START), because the machine the
        // child is on was never what made the difference. A start against
        // a name already held fails and says so, which IS the reattach
        // path: the attach that follows joins the running session.
        //
        // WITHOUT DURABILITY, THE CHILD IS RUN DIRECTLY and hangs up when
        // this workbench exits ([[RFC-0014]] C-OPT-OUT: with durability
        // off a session has no holder and ends with its connection).
        // `--parent-pid` is what performs that: an unsupervised wrapper is
        // reparented to init and keeps its pty, so the pane would outlive
        // the window that was told it would not.
        // Dev/test: `--pane-command` replaces the shell in the FIRST
        // local pane. This is the healthy spawn path — the launch-time
        // `--pane terminal` route stalls its surface (display id 0), so a
        // verification that needs CONTENT in a terminal rides this one.
        let shell = DevLaunchArgs.paneCommand.map { "sh -c \(Shell.quote($0))" }
            ?? "${SHELL:-/bin/zsh} -l"
        guard SynaptySettings.shared.localDurableSessions else {
            let cmd = "\(Shell.quote(synaptyBin)) run --id \(Shell.quote(agentID)) --hub 127.0.0.1:\(hubPort)"
                + " --parent-pid \(ProcessInfo.processInfo.processIdentifier)"
                + " -- \(shell)"
            return PaneLaunch(command: cmd, agentID: agentID, rejoining: rejoining)
        }
        let bin = Shell.quote(synaptyBin)
        let id = Shell.quote(agentID)
        let inner = "\(bin) run --hold --detach --id \(id) --hub 127.0.0.1:\(hubPort)"
            + " -- \(shell) >/dev/null 2>&1; exec \(bin) attach --client gui --id \(id)"
        // NO SECOND CANDIDATE ON THIS MACHINE: the record was read and
        // the kernel asked, so which name this pane comes back under is
        // already settled.
        return PaneLaunch(command: "/bin/sh -c \(Shell.quote(inner))", agentID: agentID,
                          rejoining: rejoining)
    }


    // MARK: - Peer links ([[ADR-0008]] stage 3b)

    /// Local loopback port assigned to each peered host, keyed by host id.
    /// PER HOST, not shared. The tunnel is a FORWARD forward bound HERE,
    /// so two hosts sharing one port means the second host's -L fails
    /// outright (ExitOnForwardFailure) and that host silently never peers.
    /// A single global port is only safe for a REVERSE forward, where the
    /// port is bound on the remote side and every machine can have its
    /// own 9000.
    private var assignedPeerPorts: [UUID: Int] = [:]
    /// peer id (as the PEER reported it) -> the loopback port that reaches
    /// it. Distinct from assignedPeerPorts, which is keyed by host and
    /// records what we allocated: under [[RFC-0010]] a machine names
    /// itself, so the id we learn from the handshake is not derivable from
    /// anything on this side.
    private var livePeerPorts: [String: Int] = [:]

    /// Base of the peer-port range. Deliberately clear of the hub's own
    /// ladder (9000 + 1..9) so a busy dev machine cannot have a peer
    /// forward and a hub fighting over the same number.
    static let peerPortBase = 9200

    /// Give this host's peer port back — AND WITH IT THE NAME THAT PORT
    /// ANSWERED TO.
    ///
    /// `peerPort` hands the lowest free number to the next host, so a
    /// released port is reused; `livePeerPorts` still mapped the departed
    /// peer's name to it, and both lookups match on VALUE. So the question
    /// "which machine is on this port" had two answers and returned
    /// whichever the dictionary reached first — the wrong machine about
    /// half the time, on the lookup whose entire job is to say which
    /// machine this is.
    ///
    /// ONE METHOD BECAUSE THERE ARE TWO CALLERS: an explicit disconnect,
    /// and a setup that found the port already bound. Written twice, one
    /// of them would eventually do half of it.
    private func releasePeerPort(for hostID: UUID) {
        guard let freed = assignedPeerPorts.removeValue(forKey: hostID) else { return }
        for (name, port) in livePeerPorts where port == freed {
            livePeerPorts.removeValue(forKey: name)
        }
    }

    /// Assign a stable, free loopback port for this host's peer link.
    func peerPort(for host: HostEntry) -> Int {
        if let existing = assignedPeerPorts[host.id] { return existing }
        let taken = Set(assignedPeerPorts.values)
        var candidate = Self.peerPortBase
        while taken.contains(candidate) || Self.portInUse(candidate) {
            candidate += 1
            if candidate > Self.peerPortBase + 200 { break }
        }
        assignedPeerPorts[host.id] = candidate
        return candidate
    }

    /// Probe rather than assume: another app (or a leftover forward from a
    /// previous run) may hold the number, and ssh would fail the whole
    /// connection rather than pick another.
    nonisolated static func portInUse(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound != 0
    }

    /// setup-host.sh prints `PEER_PORT=<n>` when it established a forward
    /// to the remote hub. Absent means no hub could be started there, and
    /// the caller must NOT invent a port — a dial to nothing would leave
    /// the local hub reporting a peer that does not exist.
    nonisolated static func parsePeerPort(_ setupOutput: String) -> Int? {
        for line in setupOutput.split(separator: "\n") {
            guard line.hasPrefix("PEER_PORT=") else { continue }
            return Int(line.dropFirst("PEER_PORT=".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// What build the remote hub IS, and what build it WOULD be.
    ///
    /// TWO NUMBERS, BECAUSE THE BUG IS THAT THEY DISAGREE. `hub.json` is
    /// written by the hub at startup, so it names the running PROCESS;
    /// the binary on disk names only what would run next. An upload that
    /// lands while the old hub keeps running leaves them apart, and
    /// comparing files would have reported everything fine.
    struct HubBuilds: Equatable, Sendable {
        /// The hub answering right now.
        var running: String
        /// The binary deployed there, which is what a restart would give.
        var deployed: String

        /// The state worth telling a human about.
        var isSkewed: Bool {
            !running.isEmpty && !deployed.isEmpty && running != deployed
        }
    }

    /// Per host, from the last connect. Not persisted: it describes a
    /// process that may not outlive this session, and a remembered answer
    /// about a hub that has since restarted is worse than no answer.
    private(set) var hubBuilds: [UUID: HubBuilds] = [:]

    func hubBuilds(for host: HostEntry) -> HubBuilds? { hubBuilds[host.id] }

    /// setup-host.sh prints both figures after the hub is ensured. Absent
    /// means the host never answered, which is NOT skew — reporting an
    /// unreachable machine as out of date would be a wrong answer where
    /// none was available.
    nonisolated static func parseHubBuilds(_ setupOutput: String) -> HubBuilds? {
        var running: String?
        var deployed: String?
        for line in setupOutput.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("HUB_BUILD=") {
                running = String(text.dropFirst("HUB_BUILD=".count))
            } else if text.hasPrefix("HUB_BINARY=") {
                deployed = String(text.dropFirst("HUB_BINARY=".count))
            }
        }
        guard let running, let deployed, !running.isEmpty, !deployed.isEmpty else { return nil }
        return HubBuilds(running: running, deployed: deployed)
    }


    /// A SUGGESTION, AND ONLY EVER THAT. [[RFC-0010]] C-PEER-IDENTITY put
    /// the naming authority on the machine being named: it mints its own
    /// id, persists it, and everyone else accepts what it reports. This
    /// derives a plausible name from the human's label for the two places
    /// a suggestion is admissible and refused where it would do harm —
    /// `PEER_ID` for a host that has not minted one yet, and
    /// `self_peer_id`, which our own hub accepts only when it has no name
    /// at all.
    ///
    /// IT MUST NOT BE COMPARED AGAINST A REPORTED ID. The two differ by
    /// construction — a host the human calls `deskmac` reports
    /// `deskmac-2630` — so every such comparison missed silently. Use
    /// `host(forPeer:)` and `reportedPeer(forHost:)`, which join on the
    /// port, the one fact both sides agree about.
    nonisolated static func peerID(for label: String) -> String {
        // SHORT name, not the FQDN. The hub's own fallback (sys.hostName)
        // truncates at the first dot, and the workbench must agree or the
        // same machine ends up with two names: a hub that started unnamed
        // says "deskmac", then the first peer_connect renames it to
        // "deskmac.local" — and any peer that already cached the old one
        // holds a stale directory entry for a machine that still exists.
        // Live-observed: hub_info reported "deskmac" while list_agents
        // reported hosting_peer "deskmac.local" for the same hub.
        let short = label.split(separator: ".").first.map(String.init) ?? label
        let mapped = short.lowercased().map { ch -> Character in
            if ch.isASCII && (ch.isLetter || ch.isNumber) { return ch }
            if ch == "-" || ch == "_" || ch == "." { return ch }
            return "-"
        }
        return String(mapped.prefix(64))
    }

    /// Set by ContentView so a new peer link also brings the peer's hub
    /// into the merged view ([[ADR-0008]] stage 5). Two separate things
    /// happen per host and they are not interchangeable: the local HUB
    /// dials the peer so messages can route, and the WORKBENCH subscribes
    /// to the peer so the human can see what is over there. Routing
    /// carries identity and reachability only (RFC-0009 C-DIRECTORY), so
    /// without the second one a remote agent is addressable but has no
    /// tool, no session and no status.
    var onPeerLinked: ((String, Int) -> Void)?
    /// The human unpeered this host. Distinct from a link DROPPING — only
    /// this removes the machine's agents from the merged view.
    var onPeerUnlinked: ((String) -> Void)?

    /// Close every ControlMaster we own. Called on app teardown, because
    /// ControlPersist=yes no longer reaps them for us.
    func closeAllMasters(hosts: [HostEntry]) {
        for host in hosts {
            // EVERY MEMBER, WHICH IS NOT A LIST WE CAN WRITE DOWN. The pool
            // reads the socket directory, so a connection this launch never
            // opened — one a crashed run left behind — is closed here too.
            // ControlPersist=yes means nothing else ever would.
            //
            // SYNCHRONOUS, BECAUSE THE CALLER IS QUITTING. Dispatched
            // asynchronously, this returned immediately and the process
            // exited before the `-O exit` reached the socket — and with
            // ControlPersist=yes, a master that does not get the message
            // is a master that lives forever. A teardown that races the
            // teardown is not a teardown. The pool bounds each exit for
            // the same reason the forward withdrawal does: an unreachable
            // host must not hold the quit open.
            pool.closeAll(for: poolKey(for: host))
        }
    }

    /// Take over relay links the hub already holds (WI-2026-08-12-010
    /// follow-up). The hub outlives the workbench by design, so a fresh
    /// launch that assumed "no peers" left itself with no subscription and
    /// no port assignment while the hub was federated — which silently
    /// disabled the merged view's rich data AND made the redial guard fail
    /// for want of a port. Found live: after a relaunch the hub still had
    /// its remotehost link and the workbench had no connection to the
    /// forward at all.
    ///
    /// Adopts only DIALED links (port > 0); one the hub accepted has no
    /// local port that reaches the peer, so there is nothing to adopt.
    func adoptExistingPeers(_ peers: [(peer: String, port: Int)], capabilities: [String: Set<String>] = [:]) {
        if !capabilities.isEmpty { peerCapabilities = capabilities }
        for entry in peers where entry.port > 0 {
            livePeerPorts[entry.peer] = entry.port
            // MATCHED ON THE PORT. This compared the peer's reported name
            // against one derived from the human's label — two strings
            // that differ by construction, so the match never succeeded
            // and no host was ever given back its port after a relaunch.
            if let host = hostStore?.hosts.first(where: { assignedPeerPorts[$0.id] == entry.port })
                ?? hostStore?.hosts.first(where: {
                    ($0.label.isEmpty ? $0.address : $0.label).lowercased()
                        == federationLabel(of: entry.peer)
                }) {
                assignedPeerPorts[host.id] = entry.port
            }
            HubLogLevel.applyCurrent(port: entry.port)
            onPeerLinked?(entry.peer, entry.port)
        }
    }

    /// What the human should be able to see about federation
    /// (WI-2026-08-12-013). Peering is not a separate thing you manage: it
    /// follows the host connection, and unpeering is disconnecting the
    /// host. That is a deliberate unification rather than a missing
    /// control — a second lifecycle to keep in sync would be one more way
    /// for the two to disagree — but it has to be SAID, and the peer id
    /// has to be VISIBLE: a hub calling itself `deskmac` while the
    /// workbench addresses `deskmac.local` is undiagnosable otherwise.
    struct PeerSummary: Identifiable {
        var id: String { peerID }
        let peerID: String
        let hostLabel: String
        let loopbackPort: Int
        /// The peer has reported its own id at least once. False means we
        /// have a port assigned and nothing has ever answered on it.
        let linked: Bool
        let linkFailed: Bool
        /// Capabilities this build expects that the peer did NOT declare.
        /// The absence is what a human needs; the presence is invisible by
        /// working ([[RFC-0010]] C-DIAGNOSABILITY).
        ///
        /// NIL IS NOT AN EMPTY LIST. Empty means "it declared everything
        /// we use"; nil means "it has never told us", which is what an
        /// unlinked peer has done. Collapsing the two makes an unreachable
        /// machine look like an incapable one.
        let missing: [String]?
    }

    /// Capabilities this build knows about, so a peer's omissions can be
    /// named rather than merely counted.
    static let knownCapabilities = ["presence_relay"]
    /// peer id -> what it declared. Filled from hub_info.
    private var peerCapabilities: [String: Set<String>] = [:]

    /// What this host's HUB is doing, which is a different question from
    /// what its TUNNEL is doing.
    ///
    /// A tunnel can be up while the machine's hub never answered — the
    /// SSH forward exists and nothing is listening behind it. The host
    /// card reported "connected" for that, which is true of the tunnel and
    /// false about everything the human wants to do with the machine: no
    /// A2A, no directory entry, no mail either way.
    enum PeerState {
        /// No peering attempted for this host.
        case none
        /// A port is assigned and the peer has never reported itself.
        case notReached
        /// Linked and answering.
        case linked
        /// Linked once, dropped, and we have stopped retrying.
        case gaveUp
    }

    func peerState(for host: HostEntry) -> PeerState {
        guard let port = assignedPeerPorts[host.id] else { return .none }
        guard let reported = livePeerPorts.first(where: { $0.value == port })?.key else {
            return .notReached
        }
        return peerLinkFailed.contains(reported) ? .gaveUp : .linked
    }

    var peerSummaries: [PeerSummary] {
        assignedPeerPorts.compactMap { hostID, port in
            let label = self.label(forHostID: hostID)
            guard !label.isEmpty else { return nil }
            // THE ID COMES FROM THE PEER, joined to our host by the
            // loopback port we dialled it on.
            //
            // Deriving it from our own host LABEL and looking THAT up in
            // sets keyed by the id the peer REPORTS cannot work:
            // [[RFC-0010]] gives naming authority to the machine, so the
            // two differ by construction — a host we call "remotehost"
            // reports "remotehost-4e84". Every such lookup misses
            // silently, which reads as `linkFailed` being permanently
            // false, on the one surface whose entire job is to show that
            // we gave up. Exactly the defect already fixed one function
            // away in scheduleRedial, left standing in the summary that
            // feeds the UI.
            let reported = livePeerPorts.first { $0.value == port }?.key
            let declared = reported.flatMap { peerCapabilities[$0] } ?? []
            return PeerSummary(
                peerID: reported ?? Self.peerID(for: label),
                hostLabel: label,
                loopbackPort: port,
                // Absent until the link comes up. "Never linked" and "we
                // gave up" are different facts and the UI renders them
                // differently, so the distinction is carried rather than
                // collapsed into one boolean.
                linked: reported != nil,
                linkFailed: reported.map { peerLinkFailed.contains($0) } ?? false,
                // NIL WHEN THERE IS NOTHING TO ASK. `declared` is empty
                // for a peer that never linked, so filtering against it
                // reported every capability as MISSING — rendering "this
                // machine does not relay presence" about a machine we
                // simply could not reach.
                //
                // That is the exact thing [[RFC-0010]] C-DIAGNOSABILITY
                // forbids: absence of evidence is not evidence of absence.
                // A capability gap is an answer that only exists once the
                // link is up, so the type says so.
                missing: reported == nil
                    ? nil
                    : Self.knownCapabilities.filter { !declared.contains($0) })
        }.sorted { $0.peerID < $1.peerID }
    }

    // MARK: - Peer link recovery (WI-2026-08-12-010)

    /// Attempts made since the last successful link, per peer id.
    private var peerRedialAttempts: [String: Int] = [:]
    private var peerRedialTasks: [String: Task<Void, Never>] = [:]
    /// Peers whose link is down and which we have stopped retrying. Read
    /// by the UI: "we gave up" is exactly the state a human needs to see,
    /// and a silent stop is indistinguishable from a working link.
    private(set) var peerLinkFailed: Set<String> = []

    static let maxPeerRedials = 6

    /// Local-hub event intake. The hub REPORTS that a relay link dropped;
    /// this side decides whether to redial, because only the workbench
    /// knows whether the SSH forward is still supposed to exist — a hub
    /// retrying forever against a tunnel the human tore down is noise.
    ///
    /// Driving both from here is also what keeps the two channels honest.
    /// The subscription (AgentMonitor) and the relay link (the hub) are
    /// separate sockets and can drop independently; if each healed on its
    /// own schedule, the merged view could show a machine as reachable
    /// while the channel that actually carries messages was still down.
    func handleHubEvent(_ payload: [String: Any]) {
        guard let kind = payload["kind"] as? String,
              let peer = payload["peer"] as? String, !peer.isEmpty
        else { return }
        switch kind {
        case "peer_link_up":
            // Learn the port that reaches this peer under the id IT
            // reported, which is the only key a redial can use.
            if let port = payload["generation"] as? Int, port > 0 {
                livePeerPorts[peer] = port
            } else if let sole = assignedPeerPorts.values.first, assignedPeerPorts.count == 1 {
                livePeerPorts[peer] = sole
            }
            // THE LINK EXISTS AND THE MACHINE HAS NAMED ITSELF, which is
            // the first moment both are true. Announced here rather than
            // where the dial was requested, so the merged view learns one
            // name for one machine instead of an invented one now and a
            // reported one later.
            if let port = livePeerPorts[peer] {
                HubLogLevel.applyCurrent(port: port)
                onPeerLinked?(peer, port)
            }
            peerRedialTasks[peer]?.cancel()
            peerRedialTasks[peer] = nil
            peerRedialAttempts[peer] = 0
            notePeerRecovered(peer)
        case "peer_link_down":
            scheduleRedial(peer)
        default:
            break
        }
    }

    /// The retry must DRIVE ITSELF. The first version scheduled one
    /// attempt in response to the peer_link_down event and relied on
    /// another event to schedule the next — but a redial that fails to
    /// CONNECT produces no event at all (the dialer returns before it can
    /// report a link up or down), so the chain stopped after exactly one
    /// try and went silent, never even reaching the give-up marker. Found
    /// live: the remote hub was down for the length of a binary upload,
    /// which is far longer than the single 1s attempt.
    ///
    /// So this loop owns the whole sequence and only a peer_link_up (which
    /// cancels it) or exhaustion ends it.
    private func scheduleRedial(_ peer: String) {
        // Already trying. A second peer_link_down while a chain is running
        // must not start a competing one.
        //
        // The chain clears its own slot when it ends (see below), so this
        // guard means what it says. Testing `!isCancelled` instead would
        // NOT: it is also false for a task that ran to exhaustion, so the
        // guard would read "already tried" while claiming "already
        // trying". Those coincide only while a give-up stays final until
        // peer_link_up resets it — nothing enforces that, and a guard
        // that is right by coincidence is the kind that stops being
        // right when someone adds a second way in.
        if let existing = peerRedialTasks[peer], !existing.isCancelled { return }
        // No tunnel for this peer means the human unpeered it; a redial
        // would be dialing a port nothing is listening on.
        // Key on what the PEER reported, not on what this workbench calls
        // the host. [[RFC-0010]] moved naming authority to the machine, so
        // those two diverge BY CONSTRUCTION — a host labelled "remotehost"
        // here reports "remotehost-7f3a". Matching on the local label
        // silently disabled the redial the moment the machine owned its
        // own name.
        guard let port = livePeerPorts[peer] else { return }
        peerRedialAttempts[peer] = 0
        peerRedialTasks[peer] = Task { @MainActor [weak self] in
            for attempt in 0..<Self.maxPeerRedials {
                let delay = UInt64(min(30, 1 << attempt)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.peerRedialAttempts[peer] = attempt + 1
                HubEventClient.sendPeerConnect(
                    port: self.hubPort, peerLoopbackPort: port,
                    selfPeerID: Self.peerID(for: ProcessInfo.processInfo.hostName))
            }
            guard !Task.isCancelled, let self else { return }
            self.notePeerGaveUp(peer)
            // Release the slot: this chain is over, and leaving a finished
            // task parked here makes the entry-guard above indistinguishable
            // from a running one.
            self.peerRedialTasks[peer] = nil
        }
    }

    /// Record that we have stopped retrying this peer.
    ///
    /// A named method rather than four lines inside the redial closure,
    /// because the real path takes six exponential backoffs — about a
    /// minute — so nothing could drive it in a test, and a state that only
    /// the UI reads is exactly the kind that gets published and never
    /// verified. `peer` is the id the PEER reported, which is the only key
    /// anything else here may match on ([[RFC-0010]] C-PEER-IDENTITY).
    func notePeerGaveUp(_ peer: String) {
        guard peerLinkFailed.insert(peer).inserted else { return }
        // The log answers WHY (which peer, how many attempts); the UI and
        // the notification answer WHAT. See AppLog's two-channel rule —
        // these strings are deliberately not the same.
        AppLog.tunnelManager.error(
            "peer \(peer, privacy: .public): giving up after \(Self.maxPeerRedials) redials")
        NotificationForwarder.postFailure(
            id: NotificationForwarder.peerFailureID(peer),
            title: "\(hostLabel(forPeer: peer) ?? peer) lost contact",
            body: peerFailureBody(peer))
    }

    /// The consequence, in the terms the human cares about: not that a
    /// link dropped, but that whatever they left running there is now
    /// uncoordinated. This is the sentence the product exists to say.
    func peerFailureBodyForTesting(_ peer: String) -> String { peerFailureBody(peer) }

    private func peerFailureBody(_ peer: String) -> String {
        let n = agentCountForPeer?(peer) ?? 0
        guard n > 0 else {
            return "Messages to and from this machine are queued. Reconnect the host to retry."
        }
        let subject = n == 1 ? "1 agent on this machine is" : "\(n) agents on this machine are"
        return "\(subject) working without coordination. Reconnect the host to retry."
    }

    /// Injected by the workbench so this class does not have to know how
    /// presence is assembled. nil in tests that do not care.
    var agentCountForPeer: ((String) -> Int)?

    /// THE PORT IS THE JOIN, and it is the only thing both sides agree
    /// about. A peer's name is MINTED BY THAT MACHINE ([[RFC-0010]]
    /// C-PEER-IDENTITY) — `deskmac-2630` — while this side only ever knew
    /// the human's label for it, `deskmac`. Comparing the two never
    /// matches, and it never matched loudly: the lookup simply missed and
    /// whatever depended on it silently did not happen.
    func host(forPeer reported: String) -> HostEntry? {
        guard let port = livePeerPorts[reported],
              let hostID = assignedPeerPorts.first(where: { $0.value == port })?.key
        else { return nil }
        return hostStore?.hosts.first { $0.id == hostID }
    }

    /// The label a reported peer id was minted from — `deskmac-2630` was
    /// minted from `deskmac` ([[RFC-0010]] C-PEER-IDENTITY mints a 4-hex
    /// suffix). Used ONLY where no port assignment survives to match on,
    /// which is a fresh launch adopting links the hub already held.
    private func federationLabel(of reported: String) -> String {
        guard let dash = reported.lastIndex(of: "-") else { return reported.lowercased() }
        let suffix = reported[reported.index(after: dash)...]
        guard suffix.count == 4, suffix.allSatisfy(\.isHexDigit) else { return reported.lowercased() }
        return String(reported[..<dash]).lowercased()
    }

    /// The name this host reported for itself, or nil while it has not.
    /// NIL IS AN ANSWER: a peer that has never spoken has no name of its
    /// own yet, and inventing one is how the two-buckets defect above got
    /// in.
    func reportedPeer(forHost host: HostEntry) -> String? {
        guard let port = assignedPeerPorts[host.id] else { return nil }
        return livePeerPorts.first { $0.value == port }?.key
    }

    private func hostLabel(forPeer peer: String) -> String? {
        guard let port = livePeerPorts[peer],
              let hostID = assignedPeerPorts.first(where: { $0.value == port })?.key
        else { return nil }
        let l = label(forHostID: hostID)
        return l.isEmpty ? nil : l
    }

    /// The state ended. Take the notification back — an unreachability
    /// notice that outlives the unreachability is a lie the human has no
    /// way to check.
    private func notePeerRecovered(_ peer: String) {
        guard peerLinkFailed.remove(peer) != nil else { return }
        NotificationForwarder.clearFailure(id: NotificationForwarder.peerFailureID(peer))
        AppLog.tunnelManager.info("peer \(peer, privacy: .public): link restored")
    }

    /// DID THIS HOST WANT A PASSWORD?
    ///
    /// Synapty has no password path at all: `setup-host.sh` runs in the
    /// background with pipes and a timeout, so ssh has no terminal to
    /// prompt on, and the interactive session runs behind `synapty
    /// attach`, whose stdin carries FRAMES — a human's keystrokes go into
    /// ssh wrapped in the holder protocol and are read as a password made
    /// of frame bytes. Auth fails and the pane closes, which reads as "the
    /// connection dropped by itself".
    ///
    /// So the least this can do is name it. Detection is on ssh's own
    /// words rather than an exit code, because the methods it lists are
    /// the only place it says WHAT it wanted.
    nonisolated static func wantsPassword(_ combined: String) -> Bool {
        let s = combined.lowercased()
        if s.contains("permission denied") {
            return s.contains("password") || s.contains("keyboard-interactive")
        }
        // A prompt that was never answered: the run timed out holding it.
        return s.contains("password:") || s.contains("password for")
    }

    private func label(forHostID id: UUID) -> String {
        guard let host = hostStore?.hosts.first(where: { $0.id == id }) else { return "" }
        return host.label.isEmpty ? host.address : host.label
    }

    private func connectPeer(host: HostEntry, loopbackPort: Int) {
        let selfID = Self.peerID(for: ProcessInfo.processInfo.hostName)
        HubEventClient.sendPeerConnect(
            port: hubPort, peerLoopbackPort: loopbackPort, selfPeerID: selfID)
        // NOT ANNOUNCED HERE. This said a link was up at the moment one
        // was REQUESTED, under a name derived from the human's label —
        // while the machine names itself, so the merged view then held one
        // machine under two names, the invented one and the reported one.
        // `peer_link_up` announces it, when there is a link and a name
        // that machine chose.
        AppLog.tunnelManager.info(
            "peer link requested: local hub -> 127.0.0.1:\(loopbackPort, privacy: .public) for \(host.address, privacy: .public)")
    }

    // MARK: - Setup (background process)

    private func runSetup(for host: HostEntry, account: String? = nil) {
        let script = scriptPath("setup-host")
        // Process.arguments are passed as argv (no shell interpolation), so no escaping needed here.
        // The script itself uses $1, $2 etc. which are safe in bash.
        // Fixed layout: <host> <port> <user> <tunnel-port> <hub-port> <key|''> <jump|''> [forwards...]
        var args = [script, host.address, "\(effectivePort(for: host))", effectiveUsername(for: host), "\(peerPort(for: host))", "\(hubPort)"]
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
        // [[RFC-0009]] C-BOUNDARIES: the human's host LABEL is the
        // authoritative peer id, not the machine's hostname. The workbench
        // is the only party that knows the whole fleet, so it is the only
        // one that can keep the ids unique — two cloud VMs are routinely
        // both called "ubuntu", and two peers answering to one name is a
        // configuration error whose silent resolution would misroute every
        // message between them.
        let peerID = Self.peerID(for: host.label.isEmpty ? host.address : host.label)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // The script says what it is doing into the same account, so
            // its slow steps are visible AS THEY HAPPEN rather than in the
            // block of output it returns when it is already over.
            var env = ["PEER_ID": peerID]
            if let account { env["SYNAPTY_CONNECT_LOG"] = ConnectProgress.channel(for: account).path }
            let output = SubprocessRunner.run(
                executable: "/bin/bash",
                arguments: args,
                environment: env,
                timeout: 60
            )
            DispatchQueue.main.async {
                guard let self else { return }
                if output.error == nil && !output.timedOut {
                    self.tunnelStates[host.id] = .connected
                    self.recordConfiguredForwards(for: host)
                    // [[ADR-0008]] stage 3b: setup-host.sh started a hub on
                    // the remote machine and opened an SSH -L forward to
                    // it. Tell the LOCAL hub to dial that peer, so agents
                    // on the two machines can still reach each other now
                    // that they no longer share a hub (RFC-0009).
                    if let peerPort = Self.parsePeerPort(output.stdout) {
                        self.connectPeer(host: host, loopbackPort: peerPort)
                    }
                    self.hubBuilds[host.id] = Self.parseHubBuilds(output.stdout)
                    // Recency stamp for MRU ordering (WI-2026-08-09-006).
                    self.hostStore?.markConnected(host.id)
                    // Silent OS probe once connected (WI-2026-08-09-002).
                    self.probeOS(for: host)
                    // Fire all pending callbacks with the command captured
                    // at request time (WI-2026-08-08-031).
                    let callbacks = self.pendingCallbacks.removeValue(forKey: host.id) ?? []
                    for cb in callbacks {
                        cb.onReady((cb.command, cb.agentID))
                    }
                } else {
                    if let error = output.error {
                        AppLog.tunnelManager.error("setup launch failed: \(error, privacy: .public)")
                    } else if output.timedOut {
                        AppLog.tunnelManager.error("setup for \(host.address, privacy: .public) timed out after 60s")
                    }
                    // A port that was free when probed can be taken before
                    // ssh binds it. The assignment is CACHED, so without
                    // this the same occupied port is retried on every
                    // reconnect and the host never peers again until the
                    // human disconnects by hand.
                    let combined = output.stderr + output.stdout
                    if combined.lowercased().contains("address already in use")
                        || combined.lowercased().contains("cannot listen to port")
                    {
                        self.releasePeerPort(for: host.id)
                    }
                    let lastLine = Self.wantsPassword(combined)
                        ? "this host asks for a password, and Synapty can only use SSH keys — add a key for it, or run `ssh-copy-id` once from a terminal"
                        : output.stderr.split(separator: "\n").last.map(String.init)
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
        // In-flight guard: two concurrent setups fight over one ControlPath
        // and a failing second one can flip a good .connected to .failed
        // (WI-2026-08-08-031).
        if tunnelStates[host.id] == .reconnecting || tunnelStates[host.id] == .connecting {
            return
        }
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
        let key = poolKey(for: host)
        let pool = self.pool
        // READ BEFORE THE TEARDOWN DROPS THE PORT the lookup goes through.
        let reported = reportedPeer(forHost: host)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Disconnecting means disconnecting: any member surviving the
            // human's explicit teardown is a connection they believe they
            // closed ([[RFC-0013]] C-BROKER).
            pool.closeAll(for: key)
            DispatchQueue.main.async {
                guard let self else { return }
                self.tunnelStates[host.id] = .disconnected
                self.trackedHosts.removeValue(forKey: host.id)
                // Stop peering too. ControlPersist=yes means the master
                // will not time out on its own any more — that is the
                // point (the peer link must not die because nobody has a
                // pane open), and it makes this explicit teardown the ONLY
                // thing that ends it. Releasing the port matters as much:
                // a leaked assignment would push the next host further up
                // the range on every reconnect.
                self.releasePeerPort(for: host.id)
                // The master is gone, so the forwards riding it are too.
                // Dropping them from the model as well is what keeps the
                // Forwarding overview from listing local ports that no
                // longer reach anything — a stale row there is worse than
                // no row, because it is read as an open door.
                Task { @MainActor in await PortForwardService.shared?.withdrawAll(hostID: host.id) }
                // UNDER THE NAME IT WAS LINKED AS, read before the port
                // assignment above is dropped. A peer that never reported
                // one was never in the merged view under any name, so
                // there is nothing to take out.
                if let reported { self.onPeerUnlinked?(reported) }
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

    /// Hosts whose ssh -O check is still in flight — a wedged master must
    /// not pile up one blocked check per 10s tick (WI-2026-08-08-031).
    private var checksInFlight: Set<UUID> = []

    private func runHeartbeat() {
        let hostsToCheck = trackedHosts.filter { tunnelStates[$0.key] == .connected }

        for (hostID, host) in hostsToCheck where !checksInFlight.contains(hostID) {
            // Resolve everything the check needs on the main actor; the
            // blocking ssh spawn then runs off-main (WI-2026-08-08-009).
            let key = poolKey(for: host)
            let pool = self.pool
            let sockets = pool.members(for: key)
            let userAtHost = "\(effectiveUsername(for: host))@\(host.address)"
            checksInFlight.insert(hostID)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                // TWO PROBES PER CONNECTION, BECAUSE THEY ANSWER DIFFERENT
                // QUESTIONS AND ONLY ONE OF THEM TOUCHES THE NETWORK.
                //
                // `ssh -O check` asks the LOCAL master process for its pid
                // over a unix socket. Measured against a host whose real
                // round trip is 0.55s, it returns in 0.00-0.01s — it never
                // leaves this machine. Timing it would have produced a load
                // signal that can never rise, and a placement rule that
                // reads as load-aware while being inert.
                //
                // A command run OVER the master is the round trip C-BROKER
                // measured: it opens a session channel, crosses the link
                // and comes back, which is exactly what a channel filling
                // the send buffer makes slow. It is not a substitute for
                // the check — a dead master does not fail this, it falls
                // back to a direct connection and answers cheerfully.
                var alive = false
                for socket in sockets.isEmpty ? [pool.primary(for: key)] : sockets {
                    guard Self.sshControl(socket: socket, userAtHost: userAtHost, ctl: "check")
                    else { continue }
                    alive = true
                    let probe = Self.sshRoundTrip(socket: socket, userAtHost: userAtHost)
                    if probe.refused {
                        // The probe IS a session channel, so it finds the
                        // remote's bound by walking into it — no setting is
                        // read and none is assumed, which is what makes this
                        // right on a host permitting five and on one
                        // permitting a hundred.
                        pool.markFull(socket: socket)
                    } else if let trip = probe.trip {
                        pool.observe(roundTrip: trip, on: socket)
                    }
                }
                // OPENED AHEAD OF THE PANE THAT WILL WANT IT. Growth has to
                // happen where authenticating is affordable, and this pass
                // is off-main and has just measured every member — so when
                // everything a host holds is carrying load, the quiet
                // connection is standing ready before anyone asks.
                pool.growIfLoaded(key)
                let reachable = alive
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.checksInFlight.remove(hostID)
                    if !reachable && self.tunnelStates[hostID] == .connected {
                        return self.reconnectTunnel(for: host)
                    }
                    self.migrateStalledPanes(for: host)
                }
            }
        }
    }

    /// How long a trivial command takes OVER this master — the quantity
    /// [[RFC-0013]] C-BROKER measures, and the one that rises when a
    /// channel on the same connection is filling the send buffer. Nil when
    /// the command did not complete, since a failure has no duration worth
    /// comparing against a quiet one.
    ///
    /// Bounded well above the stall being looked for: C-BROKER saw 17.90s,
    /// and a probe that gave up at ten would report nothing in exactly the
    /// case it exists to detect.
    nonisolated private static func sshRoundTrip(
        socket: String, userAtHost: String
    ) -> (trip: TimeInterval?, refused: Bool) {
        let began = Date()
        let output = SubprocessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: ["-S", socket, "-o", "BatchMode=yes", userAtHost, "true"],
            timeout: 40)
        // THE EXIT STATUS IS NO USE HERE, and that is the whole reason this
        // reads the text. Measured against an sshd set to MaxSessions=1: a
        // client whose session channel is refused prints the refusal, then
        // opens a connection of ITS OWN and exits zero. The command runs,
        // nobody is told, and the connection it used is one the pool has
        // never heard of.
        let refused = output.stderr.contains(MasterPool.channelRefusal)
        // A trip that fell back to its own connection measured the wrong
        // thing — a fresh authentication, not this connection's round trip.
        guard !refused, output.error == nil, !output.timedOut else {
            return (nil, refused)
        }
        return (Date().timeIntervalSince(began), false)
    }

    /// Spawn `ssh -S <socket> -O <ctl> <user@host>` against a ControlMaster
    /// socket. Pure process spawn with no shared-state access, so it can run
    /// off the main actor without isolation warnings.
    nonisolated private static func sshControl(
        socket: String, userAtHost: String, ctl: String, timeout: TimeInterval = 10
    ) -> Bool {
        // Delegates to SubprocessRunner.runQuiet — shared timeout/kill
        // discipline (WI-2026-08-08-031, WI-2026-08-08-036).
        SubprocessRunner.runQuiet(
            executable: "/usr/bin/ssh",
            arguments: ["-S", socket, "-O", ctl, userAtHost],
            timeout: timeout
        )
    }
}
