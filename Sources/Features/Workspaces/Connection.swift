import Foundation
import Observation

/// A live link to one host, shared by every leaf that runs on that host
/// ([[RFC-0015]] C-CONNECTION).
///
/// IT CARRIES NO AGENT IDENTITY. Every leaf runs its own child under its
/// own agent id — `connectCommand`/`localCommand` mint a fresh one per
/// spawn — so a connection holding "the" agent id would be naming one of
/// its leaves arbitrarily. The container did exactly that before this,
/// keeping the id it was dialled with, and ending it left every other
/// leaf's agent detached and unaddressable ([[WI-2026-08-17-001]]).
struct Connection: Identifiable, Equatable {
    let id: UUID
    /// The host this links to; nil is THIS machine.
    let host: HostEntry?
    var state: State

    /// Local is a connection like any other — always available, never
    /// dialled, never released — so no consumer needs a second code path
    /// to ask a local leaf which machine it is on.
    var isLocal: Bool { host == nil }

    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    init(host: HostEntry?, state: State) {
        self.id = UUID()
        self.host = host
        self.state = state
    }
}

/// Owns every connection and decides when one may go.
///
/// THE REFERENCE COUNT IS DERIVED, NOT KEPT. Callers hand over the set of
/// connection ids the live leaves name (`updateReferences`) rather than
/// balancing retain against release. A missed release would be a leaked
/// tunnel nobody sees until they look at the host, and the leaves are the
/// truth this would otherwise be a shadow of.
@MainActor @Observable final class ConnectionRegistry {

    private(set) var connections: [Connection] = []

    /// How long a connection outlives its last leaf ([[RFC-0015]]
    /// C-RELEASE).
    ///
    /// FLOORED BY MEASUREMENT. Re-establishing a connection costs a setup
    /// phase measured at roughly 3.5s and around 8s to a painted pane, and
    /// closing a pane to open another on the same host — retrying a
    /// command, replacing a shell — is one gesture rather than a teardown.
    /// Releasing immediately would charge the human that every time.
    var grace: TimeInterval = 30

    /// Injected so a test can move past the grace period without waiting
    /// one; production reads the wall clock.
    var now: () -> Date = Date.init

    /// Handed the connection when it is actually released, so the owner
    /// can close the control socket and its tunnels. This type knows what
    /// a connection IS, not how to hang one up.
    var onRelease: ((Connection) -> Void)?

    /// The local connection. Present from construction and never removed.
    let localID: UUID

    init() {
        let local = Connection(host: nil, state: .connected)
        localID = local.id
        connections = [local]
    }

    /// Everything that is not this machine.
    var remoteConnections: [Connection] { connections.filter { !$0.isLocal } }

    func connection(_ id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    func connection(forHost hostID: UUID) -> Connection? {
        connections.first { $0.host?.id == hostID }
    }

    /// Whether acquiring a host had to open a link or found one already
    /// there. Named rather than inferred because "no second dial" is a
    /// requirement, and a caller that cannot tell the two apart cannot
    /// honour it.
    enum Acquisition {
        case opened(UUID)
        case reused(UUID)

        var id: UUID {
            switch self {
            case .opened(let id), .reused(let id): return id
            }
        }
    }

    /// Reuse the host's connection if there is one — in any state,
    /// including still dialling — and open one otherwise.
    @discardableResult
    func acquire(host: HostEntry) -> Acquisition {
        if let existing = connection(forHost: host.id) {
            // Reuse cancels a pending release: this is the churn the grace
            // period exists to absorb.
            idleSince.removeValue(forKey: existing.id)
            return .reused(existing.id)
        }
        let connection = Connection(host: host, state: .connecting)
        connections.append(connection)
        return .opened(connection.id)
    }

    /// A CONNECTION FOR A HOST THIS WORKBENCH NO LONGER HAS.
    ///
    /// REMOVING A HOST IS NOT AN INSTRUCTION TO DISCARD THE LAYOUTS THAT
    /// MENTIONED IT ([[WI-2026-08-17-025]]). A restored leaf whose host is
    /// gone from the store keeps its binding and says so: the pane is
    /// there, in its position, reporting that the machine it names is not
    /// configured any more — which is a thing the human can act on, unlike
    /// a pane that silently was not restored.
    ///
    /// IT CANNOT BE DIALLED, and does not pretend otherwise. The snapshot
    /// records a host's IDENTITY, not its address, so there is nothing to
    /// dial towards; the state is `failed` from birth for that reason and
    /// not because an attempt was made and refused.
    func acquireLost(hostID: UUID, reason: String) -> UUID {
        if let existing = connection(forHost: hostID) {
            idleSince.removeValue(forKey: existing.id)
            return existing.id
        }
        var host = HostEntry(label: "(removed)", address: "", username: "")
        host.id = hostID
        let connection = Connection(host: host, state: .failed(reason))
        connections.append(connection)
        return connection.id
    }

    func markConnected(_ id: UUID) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[idx].state = .connected
    }

    func markFailed(_ id: UUID, _ reason: String) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[idx].state = .failed(reason)
    }

    /// Reconnect a failed connection. It stays the SAME connection — every
    /// leaf bound to it is bound to the host, and re-dialling must not
    /// leave them pointing at something that is gone.
    func redial(_ id: UUID) {
        guard let idx = connections.firstIndex(where: { $0.id == id }),
              !connections[idx].isLocal else { return }
        idleSince.removeValue(forKey: id)
        connections[idx].state = .connecting
    }

    // MARK: - Release

    /// When each unreferenced connection became unreferenced.
    private var idleSince: [UUID: Date] = [:]

    /// Tell the registry which connections the live leaves name. Anything
    /// remote and absent from that list starts running down its grace
    /// period; anything present has its pending release cancelled.
    func updateReferences(_ live: [UUID]) {
        let referenced = Set(live)
        for connection in connections where !connection.isLocal {
            if referenced.contains(connection.id) {
                idleSince.removeValue(forKey: connection.id)
            } else if idleSince[connection.id] == nil {
                idleSince[connection.id] = now()
            }
        }
        // A connection that has already gone leaves no timer behind.
        let known = Set(connections.map(\.id))
        idleSince = idleSince.filter { known.contains($0.key) }
    }

    /// Release every connection that has been unreferenced for longer than
    /// the grace period.
    func sweep() {
        let deadline = now().addingTimeInterval(-grace)
        for (id, idle) in idleSince where idle <= deadline {
            release(id)
        }
    }

    /// Release at once, for an act the human has stated — archiving a
    /// workspace, or quitting. The grace period absorbs accidental churn;
    /// it is not there to delay a decision.
    func releaseNow(_ id: UUID) {
        // STILL NOT WHILE IT IS IN USE. An explicit act may skip the wait;
        // it may not cut a link another pane is holding.
        guard idleSince[id] != nil else { return }
        release(id)
    }

    private func release(_ id: UUID) {
        guard let idx = connections.firstIndex(where: { $0.id == id }),
              !connections[idx].isLocal else { return }
        let connection = connections.remove(at: idx)
        idleSince.removeValue(forKey: id)
        onRelease?(connection)
    }
}
