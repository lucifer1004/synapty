import Foundation
import Observation
import os

/// Local ports that reach a remote host's own services, so an agent can
/// show a human what it is running.
///
/// THE FORWARD RIDES THE CONNECTION THAT ALREADY EXISTS. `ssh -O forward`
/// adds one to a live ControlMaster — measured against a live host: exit 0,
/// the remote service answered through it, and `-O cancel` withdrew it,
/// with no reconnection and no second authentication.
///
/// [[RFC-0013]] C-PRIMITIVES, [[WI-2026-08-15-011]]
@MainActor @Observable final class PortForwardService {

    static weak var shared: PortForwardService?

    weak var tunnelManager: TunnelManager?

    /// WHOSE PORT A LOOPBACK PORT IS. Local exposures own ports too — a
    /// local service at :3000 and a forward that once carried a remote
    /// host's :3000 would be ONE web origin, which is the thing this
    /// bookkeeping exists to prevent, and "the local machine" is as much a
    /// party to that as any host.
    enum Owner: Equatable {
        case local
        case host(UUID)

        init(_ hostID: UUID?) { self = hostID.map { .host($0) } ?? .local }
    }

    struct Exposure: Identifiable, Equatable {
        let id: UUID
        /// The machine the service is on — `nil` is this Mac
        /// ([[RFC-0015]] C-CONTENT: a services leaf names any connection).
        let hostID: UUID?
        let remotePort: Int
        let localPort: Int
        /// The agent that asked. There is no anonymous exposure.
        let agent: String
        /// The agent's own words for what this is.
        let title: String?
        /// Where on the service the agent is pointing. Already validated —
        /// see [[ExposedPath]] for why it is a path and never a URL.
        var path: String = ExposedPath.root


        /// Always loopback. A forward bound to anything else would put a
        /// remote host's service on the network this Mac is on.
        var url: URL {
            // THE FALLBACK CANNOT FAIL, and the `!` should not make a
            // reader go and check: `localPort` is an integer from this
            // service's own range, so the string is a valid URL by
            // construction. It is unreachable in practice too — `path` was
            // validated when the exposure was created, so the call above
            // only returns nil for input that could never have been stored.
            ExposedPath.url(localPort: localPort, path: path)
                ?? URL(string: "http://127.0.0.1:\(localPort)/")!
        }

        /// The whole address, for a human deciding whether to open it.
        var display: String { ExposedPath.display(localPort: localPort, path: path) }
    }

    private(set) var exposures: [Exposure] = []

    /// A LOCAL PORT IS NEVER REUSED ACROSS HOSTS, for as long as this
    /// process lives.
    ///
    /// Every forward is reached as `http://127.0.0.1:<port>`, and a web
    /// origin is scheme plus host plus port — the host part is the same
    /// loopback address for all of them. So a port that served host A and
    /// is later handed to host B makes the two ONE ORIGIN: B inherits A's
    /// cookies, localStorage and service workers, inside an application
    /// whose entire premise is that hosts are separate. The data store is
    /// partitioned per host as well; this is the second wall, because a
    /// partition that is ever misapplied would otherwise have nothing
    /// behind it.
    private var portOwners: [Int: Owner] = [:]

    /// Search range for a free loopback port. High and unregistered, so it
    /// collides with as little as possible — but collide it will, which is
    /// why availability is probed rather than assumed.
    private let searchRange = 39000..<39500

    private static let log = Logger(subsystem: "com.synapty.app", category: "Forward")

    /// The name this forward's slot is recorded under in the pool. One
    /// tenant, one record, one place the answer lives.
    static func tenant(of exposureID: UUID) -> String { "forward.\(exposureID.uuidString)" }

    enum Outcome: Equatable {
        case ok(Exposure)
        case refused(String)
    }

    // MARK: - Exposing

    /// AN OFFER, WHICH IS NOT THE SAME THING AS A FORWARD.
    ///
    /// [[RFC-0013]] C-PRIMITIVES: `expose` is reached by a forward "where
    /// one is needed — on the local connection nothing is unreachable and
    /// no forward is opened, and the offer is the naming and the
    /// attribution rather than the reach". A local agent's expose was
    /// REFUSED on the grounds that its port was already reachable, which
    /// mistook the mechanism for the primitive: the human was told nothing,
    /// and the services pane on this Mac could never have anything in it.
    func expose(hostID: UUID?, remotePort: Int, agent: String, title: String?,
                path rawPath: String? = nil) async -> Outcome {
        guard (1...65535).contains(remotePort) else {
            return .refused("\(remotePort) is not a port")
        }
        let path: String
        switch ExposedPath.parse(rawPath) {
        case .failure(let why): return .refused(why.message)
        case .success: path = rawPath.flatMap { $0.isEmpty ? nil : $0 } ?? ExposedPath.root
        }
        let owner = Owner(hostID)
        var host: HostEntry?
        if let hostID {
            guard let found = tunnelManager?.hostStore?.hosts.first(where: { $0.id == hostID })
            else { return .refused("no such host") }
            host = found
        }

        // Asking twice for the same thing is not an error and must not open
        // a second forward: an agent that restarts and re-exposes should
        // find its view where it left it.
        if let idx = exposures.firstIndex(where: {
            $0.hostID == hostID && $0.remotePort == remotePort
        }) {
            // The forward is per PORT, so a second call cannot open another
            // one — but the agent may now be pointing somewhere else on the
            // same service, and that is the whole of what changes.
            exposures[idx].path = path
            return .ok(exposures[idx])
        }

        let local: Int
        var carrier = ""
        var exposureID = UUID()
        if let host {
            guard let allocated = allocatePort(for: owner) else {
                return .refused("no free local port in \(searchRange.lowerBound)-\(searchRange.upperBound)")
            }
            guard let tunnelManager else { return .refused("no connection to \(host.label)") }
            // A FORWARD IS A LONG-LIVED TENANT and is placed like one: on
            // the connection carrying the fewest, and counted, so the next
            // pane does not land on top of a forward that is about to carry
            // a replication stream ([[RFC-0013]] C-BROKER).
            let key = tunnelManager.poolKey(for: host)
            // THE ID IS MINTED BEFORE THE SLOT IS TAKEN, because the slot
            // is recorded under it. A tenant that cannot be named cannot
            // be released.
            exposureID = UUID()
            let tenant = Self.tenant(of: exposureID)
            // OFF THE MAIN ACTOR ([[WI-2026-09-02-022]]): placing may open a
            // master — a full SSH authentication — and the forward is an
            // ssh control round trip with a ten-second bound. An agent's
            // view.expose ran both on the main actor: up to thirty seconds
            // of frozen UI per call.
            let pool = tunnelManager.pool
            let spec = "127.0.0.1:\(allocated):127.0.0.1:\(remotePort)"
            var connection = tunnelManager.connection(for: host)
            let ctl = control
            let placed: (socket: String?, ok: Bool) = await Task.detached(priority: .userInitiated) {
                guard let socket = pool.place(key, tenant: tenant) else { return (nil, false) }
                connection.controlPath = socket
                return (socket, ctl(connection, "forward", spec, 10))
            }.value
            guard let socket = placed.socket else {
                portOwners.removeValue(forKey: allocated)
                return .refused("no connection to \(host.label)")
            }
            let ok = placed.ok
            guard ok else {
                tunnelManager.pool.release(tenant: Self.tenant(of: exposureID))
                portOwners.removeValue(forKey: allocated)
                return .refused("the host would not open a forward for port \(remotePort)")
            }
            // ASKED AGAIN AFTER THE AWAIT. The idempotency check above ran
            // before the round trip and another expose for the same port
            // can have landed during it; the one that finished first is
            // the exposure, and this one's forward is closed rather than
            // kept as a second door ([[WI-2026-09-02-033]]).
            if let idx = exposures.firstIndex(where: {
                $0.hostID == hostID && $0.remotePort == remotePort
            }) {
                var opened = tunnelManager.connection(for: host)
                opened.controlPath = socket
                let loser = Self.tenant(of: exposureID)
                // The port is ours until the cancel has come back: released
                // before that, the next allocation could hand out a port
                // whose forward is still open ([[WI-2026-09-02-036]]).
                await Task.detached(priority: .utility) {
                    _ = ctl(opened, "cancel", spec, 10)
                    pool.release(tenant: loser)
                }.value
                portOwners.removeValue(forKey: allocated)
                exposures[idx].path = path
                return .ok(exposures[idx])
            }
            local = allocated
            carrier = socket
        } else {
            // NOTHING TO OPEN. The service is already on this Mac's
            // loopback at the port it is listening on, so the local port
            // IS the remote port.
            //
            // The origin rule still applies, and this is the one place it
            // can be broken from: a port this session has forwarded for a
            // remote host would be the same web origin as a local service
            // on that port, and the browser would hand one the other's
            // cookies.
            if case .host = self.owner(ofPort: remotePort) {
                return .refused("port \(remotePort) has carried a remote host's service "
                    + "in this session; showing a local one there would make them one site")
            }
            portOwners[remotePort] = .local
            local = remotePort
        }

        let exposure = Exposure(id: exposureID, hostID: hostID, remotePort: remotePort,
                                localPort: local, agent: agent, title: title, path: path)
        exposures.append(exposure)
        Self.log.info(
            "\(agent, privacy: .public) exposed remote \(remotePort) as 127.0.0.1:\(local)")
        return .ok(exposure)
    }

    func withdraw(_ id: UUID, timeout: TimeInterval = 10) async {
        guard let cancel = forget(id, timeout: timeout) else { return }
        // The cancel is an ssh round trip; the slot is released when it
        // returns, not while the main actor waits for it
        // ([[WI-2026-09-02-022]]) — disconnecting a host with N exposures
        // used to cost N × timeout on the main thread.
        await Task.detached(priority: .utility) { cancel() }.value
    }

    /// Drops the exposure from the list and hands back the work that
    /// closes the door on the wire, so the caller decides which thread
    /// pays for the round trip. `nil` when there is nothing to cancel.
    private func forget(_ id: UUID, timeout: TimeInterval) -> (@Sendable () -> Void)? {
        guard let idx = exposures.firstIndex(where: { $0.id == id }) else { return nil }
        let exposure = exposures[idx]
        exposures.remove(at: idx)
        // The port stays OWNED after withdrawal. Releasing it back into the
        // pool is exactly how one origin comes to serve two hosts.
        // A LOCAL EXPOSURE HAS NOTHING TO CANCEL: no forward was opened,
        // and withdrawing it is withdrawing the offer.
        guard let hostID = exposure.hostID,
              let tunnelManager,
              let host = tunnelManager.hostStore?.hosts.first(where: { $0.id == hostID })
        else { return nil }
        var connection = tunnelManager.connection(for: host)
        // THE ONE THAT HOLDS IT, ASKED OF THE RECORD RATHER THAN A COPY.
        // Anything else is a cancel that succeeds quietly and leaves the
        // door open, and a copy of the answer is a second thing that can
        // be right while the first is wrong.
        let tenant = Self.tenant(of: exposure.id)
        // UNVERIFIED ON PURPOSE: cancelling a forward on a connection
        // that is already gone is a no-op, and asking the live member set
        // first would skip the cancel on exactly the connection that is
        // about to be torn down. This read forgets rather than decides.
        if let held = tunnelManager.pool.recordedCarrier(of: tenant) { connection.controlPath = held }
        let pool = tunnelManager.pool
        let spec = "127.0.0.1:\(exposure.localPort):127.0.0.1:\(exposure.remotePort)"
        let ctl = control
        return {
            _ = ctl(connection, "cancel", spec, timeout)
            pool.release(tenant: tenant)
        }
    }

    /// Every exposure for a host, withdrawn — for a disconnect, where the
    /// forwards would otherwise outlive the connection carrying them.
    func withdrawAll(hostID: UUID) async {
        for exposure in exposures.filter({ $0.hostID == hostID }) {
            await withdraw(exposure.id)
        }
    }

    /// AN EXPOSURE MUST NOT OUTLIVE THE PROCESS THAT KNEW ABOUT IT.
    ///
    /// `ControlPersist=yes` is what makes this necessary rather than
    /// tidy. The master does not die with the application, so a forward
    /// added to it does not either: measured, a loopback port was still
    /// serving a remote host's admin UI after the application that opened
    /// it was gone, with nothing anywhere able to name it. The only record
    /// an exposure has is `exposures`, in memory — so quitting turned a
    /// capability into one nobody could enumerate, which is the same thing
    /// [[TransferAuthority]] refuses to allow a grant to become.
    ///
    /// A SHORT TIMEOUT, because this runs on the way out: a host that has
    /// gone unreachable must not hold the quit open. A cancel that does
    /// not land loses to the master being torn down or timing out, which
    /// is the failure this can afford.
    func withdrawEverything() {
        // Quitting: the app is leaving, so the main thread is the one that
        // waits — there is no one else left to hand the round trip to.
        for exposure in exposures { forget(exposure.id, timeout: 3)?() }
    }

    // MARK: - Ports

    /// The first port that is not currently forwarding and has never
    /// served a DIFFERENT host.
    ///
    /// A host may take back a port it owned before: same host, same origin,
    /// nothing to leak. Refusing that would burn a port per expose/withdraw
    /// cycle and exhaust the range in a long session.
    func allocatePort(for owner: Owner) -> Int? {
        let live = Set(exposures.map(\.localPort))
        for port in searchOrder(for: owner) where !live.contains(port) {
            switch self.owner(ofPort: port) {
            case .some(let existing) where existing != owner:
                // Another host's, permanently. Handing it over would make
                // the two one web origin.
                continue
            case .none:
                // Never used by us. Something else on this Mac may hold it
                // — not hypothetical: the first port probed while designing
                // this was taken by an unrelated application.
                guard Self.isFree(port) else { continue }
            case .some:
                break  // ours already, and not currently forwarding
            }
            portOwners[port] = owner
            return port
        }
        return nil
    }

    /// Whose a port is, or nil if it has never been used.
    func owner(ofPort port: Int) -> Owner? { portOwners[port] }

    /// The range, rotated to start at this host's own slot.
    ///
    /// A HOST KEEPS ITS PORT ACROSS RESTARTS, and that matters the moment
    /// an address leaves this process. `portOwners` dies with us, which is
    /// exactly right while the only reader is our own web view — its data
    /// store is non-persistent, so the two forget together. A browser does
    /// not forget: hand it `127.0.0.1:39000` for host A today and for host
    /// B tomorrow and B inherits A's cookies from a jar we do not control.
    ///
    /// DERIVED RATHER THAN RECORDED. Persisting the assignment table would
    /// also work and costs a file, a location, a migration and a decision
    /// about whether it syncs. Rotating the scan by a hash of the host id
    /// buys the same stability with no state at all — and when two hosts do
    /// land on one slot, the loser simply walks forward from there, which
    /// is deterministic too.
    private func searchOrder(for owner: Owner) -> [Int] {
        // Only a host ever allocates from this range — a local exposure
        // uses the port the service is already on — so `.local` has no
        // slot of its own to start from.
        guard case .host(let hostID) = owner else { return Array(searchRange) }
        let span = searchRange.count
        let start = Int(Self.stableHash(hostID) % UInt64(span))
        return (0..<span).map { searchRange.lowerBound + (start + $0) % span }
    }

    /// FNV-1a over the id's bytes.
    ///
    /// NOT `hashValue`: Swift seeds its hasher per process, so the standard
    /// one gives a different answer on every launch — which is the single
    /// property this must not have.
    static func stableHash(_ id: UUID) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01B3
            }
        }
        return hash
    }

    /// Can this Mac bind it right now?
    nonisolated static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    // MARK: - Plumbing

    /// The ssh control command, swappable.
    ///
    /// EVERYTHING DOWNSTREAM OF A SUCCESSFUL EXPOSURE WAS UNTESTABLE
    /// WITHOUT THIS, because reaching it required a live ControlMaster —
    /// so withdrawal, enumeration and mortality had no coverage at all,
    /// and `withdrawAll` sat with zero callers long enough for forwards to
    /// start outliving the process. A seam here is narrower than the
    /// alternative of trusting that code by inspection.
    var control: (_ connection: RemoteConnection, _ action: String, _ spec: String,
                  _ timeout: TimeInterval) -> Bool = PortForwardService.sshControl

    nonisolated private static func sshControl(
        connection: RemoteConnection, action: String, spec: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        SubprocessRunner.runQuiet(
            executable: "/usr/bin/ssh",
            arguments: ["-S", connection.controlPath, "-O", action, "-L", spec,
                        connection.userAtHost],
            timeout: timeout)
    }
}
