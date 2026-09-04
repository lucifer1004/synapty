import Foundation
import OSLog

/// WHAT EVERY SSH THIS WORKBENCH OPENS CARRIES.
///
/// ONE OWNER FOR A POLICY THAT WAS WRITTEN OUT THREE TIMES, and the copies
/// were not the same: the one-off opener and the file-browser session
/// carried BatchMode and a timeout and NOT the host-key policy, so the two
/// of them prompted or failed where the pooled master accepted a new host
/// — a first connection succeeded through one path and hung through
/// another ([[WI-2026-08-30-010]]).
///
/// BATCHMODE so a host that would prompt fails instead of hanging on a
/// password nobody can see. ACCEPT-NEW so a first connection to a host the
/// human just added is not a hang. THE KEEPALIVES so a link that has
/// silently died is discovered rather than waited on.
enum SSHPolicy {
    /// The options an ssh that is OPENING a connection needs. A caller
    /// riding an existing master adds its own `ControlPath` in front of
    /// these.
    static func opening(connectTimeout: Int) -> [String] {
        ["-o", "BatchMode=yes",
         "-o", "ConnectTimeout=\(connectTimeout)",
         "-o", "StrictHostKeyChecking=accept-new",
         "-o", "ServerAliveInterval=15",
         "-o", "ServerAliveCountMax=3"]
    }
}

/// A host's SSH connections, as a pool whose size follows what has actually
/// happened to it ([[RFC-0013]] C-BROKER).
///
/// WHY THERE IS NO LANE ENUM HERE. Splitting a host's traffic by declared
/// class means deciding in advance which tenant loads the link, and that
/// decision is not derivable: a port forward can carry a replication stream
/// for minutes while a copy is a rare event. Placement is therefore made
/// from observed load, and growth from observed refusal, so nothing has to
/// be predicted.
///
/// MEMBERSHIP IS THE SOCKET DIRECTORY, NOT A DICTIONARY IN THIS OBJECT.
/// `ControlPersist=yes` means nothing reaps a master for us, so a connection
/// this process opened but did not record is one that outlives the app with
/// nobody watching it — the state C-AUTHORIZATION exists to forbid. Reading
/// membership off the filesystem makes opening and recording the same act,
/// and it is also what lets a fresh launch close the masters a crashed one
/// left behind.
///
/// Channel counts, by contrast, live in memory and are only a heuristic: a
/// count that drifts costs latency, where a membership that drifts costs a
/// leaked authenticated connection.
///
/// THREADING. Reachable from the main actor (a view resolving where to send
/// a listing) and from utility queues (setup, a transfer starting), so the
/// state is behind a lock. The distinction that matters is which entry
/// point may OPEN: `existing` never does and is safe anywhere, `place` and
/// `placeExclusive` spawn an ssh that authenticates and so must not be
/// called on the main thread.
final class MasterPool: @unchecked Sendable {

    private let lock = NSLock()

    /// A host as the socket name sees it. Credentials are deliberately
    /// absent: two entries differing only by key are the same connection to
    /// the same account, and would otherwise get two masters.
    struct HostKey: Hashable {
        let userAtHost: String
        let port: Int

        /// The first connection's socket name, and the prefix every later
        /// one extends. Unchanged from the single-master scheme, so a
        /// master opened by the shell path is found here.
        var socketBase: String { "\(userAtHost):\(port)" }
    }

    /// Tests point this at a temp directory. Without it a run would place
    /// live sockets beside the ones the human's workbench is using.
    nonisolated(unsafe) static var socketDirectoryOverride: URL?

    static var socketDirectory: URL {
        if let socketDirectoryOverride { return socketDirectoryOverride }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".synapty/sockets")
    }

    /// Extra ssh arguments for a host — identity, jump host, timeouts.
    /// Supplied by whoever owns credential inheritance, because this type
    /// deliberately knows nothing about it.
    var sshArgs: (HostKey) -> [String] = { _ in [] }

    /// Overridden by tests so placement can be exercised without spawning
    /// ssh. The fake is expected to create the socket file, because that is
    /// the recording half of the invariant above.
    var openMaster: ((HostKey, String) -> Bool)?
    var closeMaster: ((HostKey, String) -> Void)?

    /// Tests point this at a temp directory, for the same reason the
    /// socket one is overridable.
    nonisolated(unsafe) static var tenantDirectoryOverride: URL?

    /// WHERE EACH TENANT RECORDS THE CONNECTION IT RIDES, and the only
    /// place that fact lives.
    ///
    /// This used to be a dictionary in this object, beside a second copy
    /// in TunnelManager and a third on disk that the pane's own transport
    /// re-reads. Three records of one fact, two of them writable
    /// independently — and they already disagreed in the most ordinary
    /// case there is: the FIRST pane on a host got no socket from the
    /// pool (nothing was open yet), so the launch script wrote the
    /// derived path into the file while this object counted nothing, and
    /// closing that pane released a slot on a connection it had never
    /// been on.
    ///
    /// Membership already came from the filesystem, for the reason that a
    /// connection opened without being recorded is one nothing will ever
    /// close. Occupancy is the same argument: a slot taken without being
    /// recorded is one nothing will ever give back. So each tenant writes
    /// one small file naming its socket, and the count is a scan rather
    /// than a ledger — there is no second copy left to drift.
    static var tenantDirectory: URL {
        if let tenantDirectoryOverride { return tenantDirectoryOverride }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".synapty/tenants")
    }

    /// Sockets that answered a channel request with a refusal. A remote
    /// bounds session channels per connection and the bound is its own
    /// configuration, never read here — the refusal itself is the signal,
    /// which is why this works on a host that permits five and on one that
    /// permits a hundred.
    private var full: Set<String> = []

    /// Each connection's own quietest round trip, and its most recent one.
    ///
    /// LOAD IS A RISE, NOT A FIGURE. A machine on the desk and one across an
    /// ocean differ by an order of magnitude at rest, so no millisecond
    /// threshold is right for both — and a fixed one would be the same
    /// client-side guess at a condition we can measure that a fixed session
    /// cap is at a setting we can be told. What a bulk channel filling the
    /// send buffer produces is a round trip several times a connection's
    /// OWN quiet value, and that comparison needs no constant about the
    /// network.
    private var quietest: [String: TimeInterval] = [:]
    private var latest: [String: TimeInterval] = [:]

    /// Hosts where a connection carrying NOTHING still answered slowly.
    /// That is the network rather than the connection, and another
    /// connection would be just as slow — the fact is remembered per host
    /// because the connection that proved it will not stay empty.
    private var congestedLinks: Set<String> = []

    /// How far above its own quiet value a round trip has to climb before
    /// the connection is treated as carrying load. C-BROKER measured a rise
    /// from 0.36-0.39s to 8.06-17.90s, so the gap being separated is twenty
    /// to fifty fold; four is well clear of ordinary jitter and well below
    /// the thing it is looking for.
    static let loadedMultiple: Double = 4

    private static let log = Logger(subsystem: "com.synapty.app", category: "MasterPool")

    // MARK: - Membership

    /// Every connection this host holds, from the directory.
    ///
    /// A port that is a prefix of another host's — 22 against 220 — must not
    /// pull that host's sockets in, so the suffix is matched rather than the
    /// prefix alone.
    func members(for key: HostKey) -> [String] {
        let dir = Self.socketDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let base = key.socketBase
        return names.filter { name in
            if name == base { return true }
            guard name.hasPrefix(base + "#") else { return false }
            let index = name.dropFirst(base.count + 1)
            return !index.isEmpty && index.allSatisfy(\.isNumber)
        }
        .sorted()
        .map { dir.appendingPathComponent($0).path }
    }

    // MARK: - Load

    /// A round trip measured against one connection. The heartbeat already
    /// asks every member whether it is alive; how long that took is the
    /// same question C-BROKER's measurement asked, for free.
    func observe(roundTrip: TimeInterval, on socket: String) {
        lock.lock(); defer { lock.unlock() }
        quietest[socket] = min(quietest[socket] ?? roundTrip, roundTrip)
        latest[socket] = roundTrip
        guard (occupancy(of: [socket])[socket] ?? 0) == 0 else { return }
        let base = Self.base(ofSocket: socket)
        if loadedLocked(socket) { congestedLinks.insert(base) } else { congestedLinks.remove(base) }
    }

    /// The host a socket belongs to, read back out of its name.
    static func base(ofSocket path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let hash = name.lastIndex(of: "#") else { return name }
        let index = name[name.index(after: hash)...]
        return !index.isEmpty && index.allSatisfy(\.isNumber) ? String(name[..<hash]) : name
    }

    private func loadedLocked(_ socket: String) -> Bool {
        guard let quiet = quietest[socket], let now = latest[socket], quiet > 0 else { return false }
        return now > quiet * Self.loadedMultiple
    }

    /// Growing because a connection is loaded is only worth it when another
    /// connection would be quieter, and a connection carrying NOTHING that
    /// still reads as loaded says the link itself is congested rather than
    /// the connection. Another one would be just as slow, so the pool holds
    /// where it is instead of climbing without bound.
    private func growingWouldHelpLocked(_ key: HostKey) -> Bool {
        !congestedLinks.contains(key.socketBase)
    }

    // MARK: - Placement

    /// Where an ordinary channel goes: the connection carrying the fewest,
    /// skipping any that has refused. Returns nil when the host will not
    /// hold a connection at all — a socket path with no master behind it is
    /// a worse answer than none.
    @discardableResult
    func place(_ key: HostKey, tenant: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let all = members(for: key)
        let load = occupancy(of: all)
        func count(_ s: String) -> Int { load[s] ?? 0 }
        let usable = all.filter { !full.contains($0) }
        // A LOADED CONNECTION IS NOT A CANDIDATE WHILE THERE IS ANYTHING
        // ELSE. Channel count alone cannot separate a pane from a port
        // forward carrying a replication stream — both are one channel, and
        // C-BROKER's whole measurement is about what the second one does to
        // the first.
        let quiet = usable.filter { !loadedLocked($0) }
        let candidates = quiet.isEmpty && !growingWouldHelpLocked(key) ? usable : quiet
        guard let target = candidates.min(by: { count($0) < count($1) }) ?? grow(key) else {
            return nil
        }
        claim(tenant: tenant, on: target)
        return target
    }

    /// Where a transfer goes: a connection carrying nothing else, opening
    /// one when every existing connection is occupied. This is the single
    /// placement that is not least-loaded, and it is what the latency
    /// measurement in C-BROKER requires.
    @discardableResult
    func placeExclusive(_ key: HostKey, tenant: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let all = members(for: key)
        let load = occupancy(of: all)
        let idle = all.first {
            (load[$0] ?? 0) == 0 && !full.contains($0) && !loadedLocked($0)
        }
        guard let target = idle ?? grow(key) else { return nil }
        claim(tenant: tenant, on: target)
        return target
    }

    /// Where a PANE goes. Load-aware and counted like the long-lived
    /// channel it is, but it never opens: a pane's command is built on the
    /// main thread, and authenticating there is a beachball. Nil when the
    /// host holds nothing at all, which leaves the launch script to open
    /// its own — the fallback it has always had.
    ///
    /// The connection a pane would have wanted is made ready in the
    /// background instead, by `growIfLoaded`.
    @discardableResult
    func placeWithoutOpening(_ key: HostKey, tenant: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let all = members(for: key)
        let load = occupancy(of: all)
        let usable = all.filter { !full.contains($0) }
        let quiet = usable.filter { !loadedLocked($0) }
        guard let target = (quiet.isEmpty ? usable : quiet)
            .min(by: { (load[$0] ?? 0) < (load[$1] ?? 0) })
        else { return nil }
        claim(tenant: tenant, on: target)
        return target
    }

    /// Open one connection AHEAD OF NEED when everything this host holds is
    /// carrying load.
    ///
    /// Growth has to happen somewhere that can afford to authenticate, and
    /// the two paths that can — a transfer starting, a forward being added
    /// — are not the ones the human notices. What they notice is a pane
    /// opening onto a connection a sync is already saturating. This runs
    /// from the heartbeat, which is off-main and has just measured every
    /// member, so the quiet connection is standing ready before anyone asks
    /// for it. Returns nil when nothing was opened, including when growth
    /// would not help.
    @discardableResult
    func growIfLoaded(_ key: HostKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        let all = members(for: key)
        guard !all.isEmpty else { return nil }
        let usable = all.filter { !full.contains($0) }
        // EVERY CONNECTION AT ITS BOUND IS THE STRONGEST REASON TO GROW,
        // and this returned nil for it. The guard was `!usable.isEmpty`,
        // so a host whose every connection had refused a channel — which
        // is exactly what [[RFC-0013]] C-BROKER requires a further
        // connection for — was the one case that opened nothing. Growth
        // happened only under LOAD, never under refusal.
        //
        // No `growingWouldHelp` test on this branch: that guard exists to
        // stop a congested LINK provoking endless growth, and a refusal is
        // not congestion. The remote said no; another connection is what
        // it said yes to.
        if usable.isEmpty { return grow(key) }
        guard usable.allSatisfy({ loadedLocked($0) }),
              growingWouldHelpLocked(key)
        else { return nil }
        return grow(key)
    }

    /// A connection has reached the remote's per-connection session bound.
    /// Recorded without placing anything, because the probe that found out
    /// is not itself a channel anyone wanted.
    ///
    /// WHAT THIS PREVENTS IS NOT A FAILURE. Measured against an sshd set to
    /// MaxSessions=1: the refused client prints the refusal to stderr, exits
    /// ZERO, and silently opens a connection of its own. So the pane works
    /// and nobody is told — but it paid a full authentication, it is not
    /// multiplexed with anything, and the pool believes it is on a socket it
    /// has never been near. A model that wrong is worse than an error.
    func markFull(socket: String) {
        lock.lock(); defer { lock.unlock() }
        full.insert(socket)
    }

    /// Whether a connection has been found to be at that bound.
    ///
    /// A SEAM, AND NAMED AS ONE. Placement asks `full` directly and always
    /// will; this exists so a test can observe a refusal that has no other
    /// consequence to watch — a migration refused because the pane is
    /// gone changes nothing else, and "nothing happened" is only an
    /// assertion if the flag it must not have touched can be read.
    func isFullForTesting(_ socket: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return full.contains(socket)
    }

    /// A better home for a channel that is currently on `socket`, or nil.
    ///
    /// BETTER MEANS QUIET WHERE THIS ONE IS NOT, or open where this one is
    /// at its bound. Never merely less busy: moving a pane costs a
    /// reconnect and a repaint, so a marginal improvement is not worth
    /// taking and would leave panes drifting between connections on every
    /// heartbeat.
    func betterThan(_ socket: String, for key: HostKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard loadedLocked(socket) || full.contains(socket) else { return nil }
        let all = members(for: key)
        let load = occupancy(of: all)
        return all
            .filter { $0 != socket && !full.contains($0) && !loadedLocked($0) }
            .min(by: { (load[$0] ?? 0) < (load[$1] ?? 0) })
    }

    /// WHAT OPENSSH'S MULTIPLEXING CLIENT SAYS when the far side will not
    /// open another session channel on this connection. Captured from a
    /// real refusal rather than guessed:
    ///
    ///     mux_client_request_session: session request failed:
    ///     Session open refused by peer
    ///
    /// It lives beside `markFull` because that is the fact it establishes,
    /// and because it now has two readers: the heartbeat that probes ahead
    /// of demand, and the transfer that walks into the bound while opening
    /// a real channel. Two spellings of one signature is one of them
    /// silently never matching.
    static let channelRefusal = "Session open refused by peer"

    /// A connection refused to open a channel. Grow past it and place the
    /// channel on the new connection.
    @discardableResult
    func placeAfterRefusal(on socket: String, _ key: HostKey, tenant: String) -> String? {
        lock.lock()
        full.insert(socket)
        lock.unlock()
        return place(key, tenant: tenant)
    }

    /// Where a SHORT-LIVED command goes — a directory listing, a probe, a
    /// freshness check. Among the connections this host already holds, or
    /// nowhere.
    ///
    /// TWO DIFFERENCES FROM `place`, both deliberate. It never opens, because
    /// a view resolving a listing is on the main thread and the master it
    /// needs was opened during connect; growing here would authenticate on
    /// the main thread for a case that does not arise. And it does not COUNT,
    /// because a command that finishes on its own has no moment at which
    /// anyone would call `release` — counted, these would climb and never
    /// come down, and placement would end up avoiding the connection that is
    /// in fact the emptiest.
    func existing(_ key: HostKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        let all = members(for: key)
        let load = occupancy(of: all)
        let usable = all.filter { !full.contains($0) }
        let quiet = usable.filter { !loadedLocked($0) }
        return (quiet.isEmpty ? usable : quiet).min(by: { (load[$0] ?? 0) < (load[$1] ?? 0) })
    }

    /// The connection to ask "is this host still there" — the first the pool
    /// holds, or the name the first one would have. A heartbeat is asking
    /// about the HOST, so any live member answers it.
    func primary(for key: HostKey) -> String {
        members(for: key).first
            ?? Self.socketDirectory.appendingPathComponent(key.socketBase).path
    }

    /// A channel closed. A slot freed on a connection that had refused is a
    /// usable slot, so the refusal does not outlive the condition.
    /// A connection stops being full when a channel leaves it by a route
    /// that is not a release — a migration, where the record is rewritten
    /// rather than deleted. Everything else says it by releasing.
    func noteSlotFreed(on socket: String) {
        lock.lock(); defer { lock.unlock() }
        full.remove(socket)
    }

    /// What each of this host's connections is carrying, from one scan.
    ///
    /// A TENANT NAMING A SOCKET THIS HOST NO LONGER HOLDS IS IGNORED,
    /// which is what makes the records self-cleaning: a pane whose
    /// process died leaves its file behind, and the connection it named
    /// is gone at the next teardown, so the stale record stops counting
    /// without anyone sweeping it.
    private func occupancy(of members: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        let live = Set(members)
        let dir = Self.tenantDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names {
            guard let socket = try? String(
                contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            guard live.contains(socket) else { continue }
            out[socket, default: 0] += 1
        }
        return out
    }

    /// Delete every record naming one of these sockets. The tenants are
    /// gone with the connections they rode; nothing else has to know which
    /// they were.
    private func reapRecords(naming sockets: [String]) {
        let doomed = Set(sockets)
        let dir = Self.tenantDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names {
            let file = dir.appendingPathComponent(name)
            guard let socket = try? String(contentsOf: file, encoding: .utf8),
                  doomed.contains(socket) else { continue }
            try? FileManager.default.removeItem(at: file)
            // The pid sibling goes with it: it names a transport that was
            // talking through a connection that is now closed.
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(name + ".pid"))
        }
    }

    /// Record that `tenant` rides `socket`. Idempotent by construction:
    /// one tenant, one file, so claiming twice is claiming once.
    func claim(tenant: String, on socket: String) {
        let dir = Self.tenantDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? socket.write(to: dir.appendingPathComponent(tenant),
                          atomically: true, encoding: .utf8)
    }

    /// Give the slot back. Deleting the record IS releasing it — there is
    /// no count to decrement and therefore none to get wrong.
    ///
    /// AND THE REFUSAL GOES WITH IT, IN THE SAME CALL. This used to leave
    /// the `full` flag to a second call the caller had to remember, and
    /// one caller did not: a transfer released its record and left the
    /// connection excluded from every later placement until teardown. A
    /// two-step protocol between one fact and its consequence is the same
    /// shape as two records of one fact — it works until somebody does
    /// half of it.
    func release(tenant: String) {
        lock.lock(); defer { lock.unlock() }
        let file = Self.tenantDirectory.appendingPathComponent(tenant)
        if let socket = try? String(contentsOf: file, encoding: .utf8) {
            full.remove(socket)
        }
        try? FileManager.default.removeItem(at: file)
    }

    /// The pane records this host is carrying, as (tenant, socket).
    /// Read rather than remembered, for the same reason the count is.
    func panes(on key: HostKey) -> [(String, String)] {
        let live = Set(members(for: key))
        let dir = Self.tenantDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("pane."), !name.hasSuffix(".pid") else { return nil }
            guard let socket = try? String(
                contentsOf: dir.appendingPathComponent(name), encoding: .utf8),
                live.contains(socket) else { return nil }
            return (name, socket)
        }
    }

    /// Which connection a tenant is on, IF THAT CONNECTION IS STILL ONE
    /// THIS HOST HOLDS.
    ///
    /// A RECORD OUTLIVES THE PROCESS THAT WROTE IT, and a socket path is
    /// re-minted deterministically from the host's own name — so a record
    /// from a dead run and a connection from a live one can be reunited
    /// across a process boundary without either being the same thing.
    /// Placing a channel on the strength of an unverified record is
    /// letting a previous process decide where this one's traffic goes,
    /// which is the property [[RFC-0013]] C-AUTHORIZATION's mortality rule
    /// exists to deny.
    func carrier(of tenant: String, for key: HostKey) -> String? {
        guard let socket = recordedCarrier(of: tenant),
              members(for: key).contains(socket) else { return nil }
        return socket
    }

    /// The record as written, WITHOUT asking whether it still names
    /// anything. Named so the unverified read is the one that has to be
    /// spelled out: it is right only where the answer is used to forget
    /// something rather than to decide something.
    func recordedCarrier(of tenant: String) -> String? {
        try? String(contentsOf: Self.tenantDirectory.appendingPathComponent(tenant),
                    encoding: .utf8)
    }

    // MARK: - Growth

    /// Open one more connection to this host, at the first unused name.
    /// Socket paths reserved by a grow in flight, so two placers that both
    /// find the pool short pick different names ([[WI-2026-09-02-022]]).
    private var growing: Set<String> = []

    /// CALLED WITH THE LOCK HELD, AND IT LETS GO FOR THE SPAWN
    /// ([[WI-2026-09-02-022]]). Opening a master is a full SSH
    /// authentication — up to twenty seconds — and holding the pool lock
    /// through it meant the main thread's `existing()` (every file pane,
    /// every transfer leg) beachballed behind a background connect. The
    /// name is chosen and reserved under the lock, the spawn runs without
    /// it, and the lock is retaken before returning so the caller's
    /// `defer { unlock }` still balances.
    private func grow(_ key: HostKey) -> String? {
        let dir = Self.socketDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let taken = Set(members(for: key).map { ($0 as NSString).lastPathComponent })
            .union(growing.map { ($0 as NSString).lastPathComponent })
        var name = key.socketBase
        var index = 2
        while taken.contains(name) {
            name = "\(key.socketBase)#\(index)"
            index += 1
        }
        let path = dir.appendingPathComponent(name).path
        growing.insert(path)

        lock.unlock()
        let opened = openMaster?(key, path)
            ?? Self.spawnMaster(key: key, socketPath: path, extraArgs: sshArgs(key))
        lock.lock()
        growing.remove(path)

        guard opened else {
            Self.log.error("could not open a connection to \(key.socketBase, privacy: .public)")
            return nil
        }
        return path
    }

    // MARK: - Teardown

    /// Close every connection this host holds. Driven from the directory
    /// rather than from what this process opened, so a master left by an
    /// earlier launch is reaped too.
    func closeAll(for key: HostKey) {
        lock.lock(); defer { lock.unlock() }
        // CLOSING IS INSEPARABLE FROM UNRECORDING, symmetric with opening
        // being inseparable from recording. Without this the records
        // outlive both the connections they name and the process that
        // wrote them — and because a socket path is re-minted from the
        // host's own name, a stale record starts counting again the moment
        // that host reconnects. Every mismatch that used to cost one
        // process's lifetime would cost forever.
        reapRecords(naming: members(for: key))
        for socket in members(for: key) {
            if let closeMaster {
                closeMaster(key, socket)
            } else {
                Self.exitMaster(key: key, socketPath: socket)
            }
            full.remove(socket)
            quietest.removeValue(forKey: socket)
            latest.removeValue(forKey: socket)
        }
        congestedLinks.remove(key.socketBase)
    }

    // MARK: - The real ssh

    private static func spawnMaster(key: HostKey, socketPath: String, extraArgs: [String]) -> Bool {
        var args = ["-MNf", "-S", socketPath, "-o", "ControlPersist=yes"]
            + SSHPolicy.opening(connectTimeout: 10)
            + ["-p", "\(key.port)"]
        args.append(contentsOf: extraArgs)
        args.append(key.userAtHost)
        // -MNf forks once authenticated, so this returns when the master is
        // usable rather than when the process ends.
        return SubprocessRunner.runQuiet(executable: "/usr/bin/ssh", arguments: args, timeout: 20)
    }

    private static func exitMaster(key: HostKey, socketPath: String) {
        // Bounded: an unreachable host must not hold a quit open, and a
        // missed exit loses to nothing worse than the leak this replaces.
        _ = SubprocessRunner.runQuiet(
            executable: "/usr/bin/ssh",
            arguments: ["-S", socketPath, "-O", "exit", key.userAtHost],
            timeout: 3)
    }
}
