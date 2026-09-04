import Foundation
import Observation

// ===========================================================================
// Host management data model — Termius-style organization (flat, single
// level; nesting was a false need — WI-2026-08-08-065).
//
// - HostGroup: single-level groups carrying connection defaults (username,
//   port, jump host, forwardings) that hosts fall back to.
// - Identity: reusable credentials (username + SSH key path), referenced by
//   hosts AND groups (WI-2026-08-08-067, WI-2026-08-09-001).
// - HostEntry: a connectable host with optional group membership, tags and
//   an identity reference. Direct fields (username, sshKeyPath) override
//   the identity; group defaults are the last fallback.
// ===========================================================================

// MARK: - Identity (reusable credentials)

struct Identity: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var username: String
    /// Absolute path to the SSH private key; nil for password/default auth.
    var sshKeyPath: String?
}

// MARK: - Port forwarding

/// An SSH port forwarding rule, applied when the tunnel is established.
/// Mirrors OpenSSH's -L / -R semantics.
struct PortForward: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case local   // -L: forward local port to remote target
        case remote  // -R: forward remote port to local target
    }

    var id = UUID()
    var kind: Kind = .local
    /// Port on the near side (local for -L, remote for -R).
    var listenPort: Int = 8080
    /// Target host on the far side (empty = localhost).
    var targetHost: String = "localhost"
    /// Target port on the far side.
    var targetPort: Int = 80

    /// `-L listen:targetHost:targetPort` / `-R ...` OpenSSH fragment.
    var sshFlag: String {
        "\(kind.rawValue) \(listenPort):\(targetHost):\(targetPort)"
    }
}

/// One row of the global Forwarding overview (WI-2026-08-09-008): a
/// host's effective rule, tagged with its origin.
struct ForwardingOverviewEntry: Identifiable, Equatable {
    /// Compound identity: the same group rule appears under EVERY
    /// rule-less member host — rule.id alone would collide in ForEach.
    var id: String { "\(hostID.uuidString)/\(rule.id.uuidString)" }
    let hostID: UUID
    let rule: PortForward
    /// Group whose rules the host inherits; nil = the host's own rule.
    let inheritedFromGroupID: UUID?
}

// MARK: - HostGroup (single level, with defaults)

/// Single-level group (WI-2026-08-08-065): hosts in the group fall back to
/// its defaults. Legacy `parentID` keys from earlier JSON versions are
/// ignored by the synthesized Decodable (unknown keys), so old hosts.json
/// still loads.
struct HostGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    /// Optional default port used by hosts in this group.
    var port: Int?
    /// Optional default username used by hosts in this group — a weak
    /// hint; an attached Identity beats it (WI-2026-08-09-001).
    var username: String?
    /// Optional jump host used by hosts in this group (ProxyJump).
    var proxyJump: String?
    /// Optional port-forwarding rules used by hosts in this group.
    var forwardings: [PortForward]?
    /// Reusable credentials for the whole group (WI-2026-08-09-001):
    /// rotate one Identity, every member host follows. Hosts' own
    /// credentials (inline or identity) still win.
    var identityID: UUID?
}

// MARK: - Host list filter

/// Which hosts the Hosts page shows. All/ungrouped are distinct: previously
/// both collapsed to "groupID == nil", so selecting Ungrouped could not be
/// undone and "All" only showed ungrouped hosts.
enum HostFilter: Hashable {
    case all
    case ungrouped
    case group(UUID)
}

// MARK: - HostEntry

struct HostEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var address: String
    var port: Int = 22
    var username: String
    var sshKeyPath: String?
    /// Group membership (nil = ungrouped).
    var groupID: UUID?
    /// Free-form tags (e.g. "prod", "gpu", "ubuntu").
    var tags: [String] = []
    /// Reusable credentials reference (host-level, WI-2026-08-08-067);
    /// overrides the host's inline fields.
    var identityID: UUID?
    /// Jump host for ProxyJump, e.g. "user@bastion:22" (host-level override).
    var proxyJump: String?
    /// Port forwarding rules applied when the tunnel is established.
    var forwardings: [PortForward] = []
    /// OS identity for the card avatar (WI-2026-08-09-002): lowercase id —
    /// "macos" / "windows" / "linux" or a distro id ("ubuntu", "debian").
    /// nil/empty = auto: detection may fill it after a successful connect;
    /// a manual pick in the editor is never overwritten by detection.
    var osHint: String?
    /// TMUX IS A DEPENDENCY WITH A KNOWN FAILURE MODE, so there is a way
    /// out of it.
    ///
    /// Everything durable about a remote session rides on it: surviving a
    /// disconnect ([[ADR-0008]] stage 3a), reattaching after a restart, and
    /// the working directory a drop delivers into ([[RemotePwd]]). But it
    /// also sits between the human and their shell — its own idea of the
    /// terminal's size, its own restoration when a client returns — and
    /// when that goes wrong the human needs a way out that does not
    /// involve the host. Off, a session runs direct, and mortal.
    ///
    /// Defaulted rather than optional: a host recorded before this had it,
    /// because that is what it was doing.
    var durableSessions: Bool = true
    /// Last successful connect (WI-2026-08-09-006) — drives MRU ordering
    /// in the quick-connect palette and the Hosts-page Recent sort.
    var lastConnectedAt: Date?

    var displayAddress: String { "\(username)@\(address)" }

    // MARK: Codable — written out because defaults and absent optionals
    // are ordinary here, not because anything old needs humouring.
    // `sshKeyPath` and `identityID` appear in no record on disk and
    // `groupID`/`proxyJump`/`osHint` in only some, so a synthesised
    // decoder would throw on the missing key and take every host with it.

    /// HALF-SYNTHESISED CODABLE IS A TRAP, and this is the half that
    /// bites: `encode` is synthesised from these keys, `init(from:)` below
    /// is written out. Add a property and it is WRITTEN to disk and never
    /// read back — the value survives a save, dies on the next launch, and
    /// nothing fails to compile.
    ///
    /// The decoder cannot simply go away: Swift's synthesised one ignores
    /// a property's default value and throws on a missing key, and the
    /// encoder omits nil optionals — so a record without an ssh key would
    /// fail to load at all.
    ///
    /// So the guarantee is moved to where it can be enforced —
    /// `HostEntryCodingTests` checks that every stored property has a key
    /// here, that the fixture exercises every key, and that every key
    /// survives a round trip. A forgotten line below fails there.
    ///
    /// CaseIterable and internal for exactly that: the test enumerates them.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, address, port, username, sshKeyPath, groupID, tags, identityID, proxyJump, forwardings, osHint, lastConnectedAt, durableSessions
    }

    init(
        id: UUID = UUID(),
        label: String,
        address: String,
        port: Int = 22,
        username: String,
        sshKeyPath: String? = nil,
        groupID: UUID? = nil,
        tags: [String] = [],
        identityID: UUID? = nil,
        proxyJump: String? = nil,
        forwardings: [PortForward] = [],
        osHint: String? = nil,
        lastConnectedAt: Date? = nil,
        durableSessions: Bool = true
    ) {
        self.id = id
        self.label = label
        self.address = address
        self.port = port
        self.username = username
        self.sshKeyPath = sshKeyPath
        self.groupID = groupID
        self.tags = tags
        self.identityID = identityID
        self.proxyJump = proxyJump
        self.forwardings = forwardings
        self.osHint = osHint
        self.lastConnectedAt = lastConnectedAt
        self.durableSessions = durableSessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decode(String.self, forKey: .label)
        address = try c.decode(String.self, forKey: .address)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        sshKeyPath = try c.decodeIfPresent(String.self, forKey: .sshKeyPath)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        identityID = try c.decodeIfPresent(UUID.self, forKey: .identityID)
        proxyJump = try c.decodeIfPresent(String.self, forKey: .proxyJump)
        forwardings = try c.decodeIfPresent([PortForward].self, forKey: .forwardings) ?? []
        osHint = try c.decodeIfPresent(String.self, forKey: .osHint)
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        // ABSENT MEANS ON. Every host recorded before this had a durable
        // session, because that is what the code was doing; defaulting to
        // off would silently take it away from all of them on one launch.
        durableSessions = try c.decodeIfPresent(Bool.self, forKey: .durableSessions) ?? true
    }
}

// MARK: - Store

@MainActor @Observable final class HostStore {
    var hosts: [HostEntry] = []
    var groups: [HostGroup] = []
    var identities: [Identity] = []

    /// WHAT TO CALL A MACHINE IN A SENTENCE ADDRESSED TO THE HUMAN, nil
    /// being this one.
    ///
    /// The workbench had ten near-copies of this, disagreeing on whether
    /// this Mac is capitalised — which is visible when two of them appear
    /// in the same flow, as the approval sheet and the list of what that
    /// sheet granted now do. A grant a human withdraws must read exactly
    /// as it did when they made it, so the two cannot be allowed to drift.
    func displayName(of hostID: UUID?) -> String {
        guard let hostID else { return "This Mac" }
        guard let host = hosts.first(where: { $0.id == hostID }) else { return "a host" }
        return host.label.isEmpty ? host.address : host.label
    }

    /// Test seam: redirect storage to a temp directory so tests never
    /// read/write the real host records (WI-2026-08-08-020).
    static var storageOverride: URL?

    /// ONE RECORD PER ENTITY — WI-2026-08-13-004.
    ///
    /// A single hosts.json decides the ceiling on what any sync layer can
    /// do, before a sync layer is chosen: two machines that edit anything
    /// concurrently produce two whole-file versions and one wins, taking
    /// an unrelated host with it. Per record, concurrent additions of
    /// DIFFERENT hosts survive as a set union, and a concurrent edit of
    /// the SAME host becomes a per-record conflict carrying enough
    /// information to merge field-wise — CloudKit hands back the original,
    /// the server copy and the client copy, and none of that helps if the
    /// record is the whole file.
    ///
    /// It also earns its keep single-machine: editing one host no longer
    /// rewrites the others, which closes the corruption window the rolling
    /// backup existed to survive.
    ///
    /// SHARED by classification (ConfigPaths): hosts are the human's
    /// intent and belong on every machine they own.
    private static var recordsRoot: URL {
        storageOverride ?? ConfigPaths.shared
    }

    private static func recordDir(_ kind: String) -> URL {
        let dir = recordsRoot.appendingPathComponent(kind)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        load()
    }

    // MARK: - Persistence

    /// Records come back in RECORD-ID order, not insertion order, and that
    /// is a contract rather than an accident.
    ///
    /// The single document preserved the order the user happened to add
    /// things in. Per-record storage cannot, and neither can anything
    /// built on it: the whole point (WI-2026-08-13-004) is that two
    /// machines' concurrent additions merge as a SET UNION, and a union
    /// has no canonical order. Promising insertion order would be
    /// promising something the sync layer is structurally unable to keep.
    ///
    /// So the order is made DETERMINISTIC instead — the same on every
    /// machine and every launch — and display order belongs entirely to
    /// the view layer, which already sorts explicitly by recency or label.
    /// Nothing should index into this array expecting the order it wrote.
    private static func readRecords<T: Codable & Identifiable>(_ kind: String, _ type: T.Type) -> [T] {
        let dir = recordDir(kind)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
            // A single unreadable record loses ONE entity, not the file.
            // That is the other half of what per-record buys.
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }

    /// Writes what this store HAS. It never infers deletions from
    /// absence, and that restraint is the whole point: "I do not have it"
    /// can mean "I never knew about it". A reconciling save would have one
    /// store delete records another just wrote — the whole-file problem
    /// re-created one directory up, which is exactly what per-record
    /// storage is here to remove. Deletion is an explicit act
    /// (`deleteRecord`), because only the caller doing the deleting knows
    /// it is one.
    /// Returns the ids it could NOT persist, so save() can surface them.
    @discardableResult
    private static func writeRecords<T: Codable>(_ kind: String, _ items: [T], ids: [String]) -> [String] {
        var failures: [String] = []
        let dir = recordDir(kind)
        let encoder = JSONEncoder()
        // A STABLE KEY ORDER, because the skip below is a BYTE comparison.
        // JSONEncoder's keyed container is unordered: one value encoded
        // two hundred times in one process produced ELEVEN distinct byte
        // strings, same keys, same values, same length. So "has this
        // record changed?" answered yes for records nothing had touched,
        // and `save()` offers every record it writes to the sync engine —
        // which put unchanged hosts on the wire, to a last-writer-wins
        // transport, on every save. That is the whole thing the per-record
        // layout exists to prevent.
        //
        // The three other stores that persist through this project already
        // do it ([[KeymapStore]], [[SynaptySettings]], [[WorkspaceStore]]);
        // this was the one that compares bytes and did not
        // ([[WI-2026-08-28-015]]).
        encoder.outputFormatting = [.sortedKeys]
        for (item, id) in zip(items, ids) {
            let url = dir.appendingPathComponent("\(id).json")
            do {
                let data = try encoder.encode(item)
                // Write only what CHANGED: editing one host must not
                // rewrite the others, or the per-record layout buys
                // nothing on a last-writer-wins transport.
                if let existing = try? Data(contentsOf: url), existing == data { continue }
                try data.write(to: url, options: .atomic)
            } catch {
                // NOT swallowed. A disk-full, a permissions change or a
                // sandbox denial must not let save() return normally with
                // the human believing their host was stored. A store that
                // cannot persist must SAY so — it is the one failure the
                // user cannot detect by looking, because the in-memory list
                // still shows exactly what they typed.
                AppLog.hostStore.error(
                    "could not persist \(kind, privacy: .public)/\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failures.append(id)
            }
        }
        return failures
    }

    static func deleteRecord(_ kind: String, id: UUID) {
        try? FileManager.default.removeItem(
            at: recordDir(kind).appendingPathComponent("\(id.uuidString).json"))
    }

    func load() {
        hosts = Self.readRecords("hosts", HostEntry.self)
        groups = Self.readRecords("groups", HostGroup.self)
        identities = Self.readRecords("identities", Identity.self)
    }


    func save() {
        // WRITES from tests MUST go to isolated storage: a unit test that
        // forgot the override once REPLACED the user's real host list with
        // fixture data. The guard sits on save(), not load — the app
        // running as the unit-test HOST legitimately loads real data but
        // never mutates it during a run (WI-2026-08-09-002 incident).
        // TestHost.isActive for the same reason WorkspaceStore carries it: a
        // hosted app writing into the per-process test root is isolated
        // already, and trapping there kills the whole suite rather than
        // protecting anything.
        assert(
            Self.storageOverride != nil || TestHost.isActive
                || NSClassFromString("XCTestCase") == nil,
            "HostStore.storageOverride must be set in tests (setUpHostStoreStorage)"
        )
        var failed: [String] = []
        failed += Self.writeRecords("hosts", hosts, ids: hosts.map { $0.id.uuidString })
        failed += Self.writeRecords("groups", groups, ids: groups.map { $0.id.uuidString })
        failed += Self.writeRecords("identities", identities, ids: identities.map { $0.id.uuidString })
        // Observable, so a view can tell the human their edit did not
        // reach disk. Cleared on a clean save, so a transient failure does
        // not stick around claiming to be current.
        unpersistedRecordIDs = failed

        // TELL THE SYNC ENGINE. Without this the engine only ever sees
        // what was on disk when it started, so an edit made after launch
        // sits locally until the next relaunch — which is "converges at
        // startup", not "converges", and the difference is invisible in
        // any test that restarts the app between writing and reading.
        for kind in ["hosts", "groups", "identities"] {
            for id in recordIDs(kind) where !failed.contains(id) {
                SyncEngine.shared.noteLocalChange(path: "\(kind)/\(id).json")
            }
        }
    }

    /// Ids currently present on disk for a kind — the sync engine is told
    /// about what IS, not about what changed, because the engine
    /// deduplicates and a missed change costs more than a redundant one.
    private func recordIDs(_ kind: String) -> [String] {
        switch kind {
        case "hosts": return hosts.map { $0.id.uuidString }
        case "groups": return groups.map { $0.id.uuidString }
        default: return identities.map { $0.id.uuidString }
        }
    }

    /// Records whose merge could not be resolved without a human, keyed
    /// by record id, with the fields both machines moved.
    ///
    /// [[WI-2026-08-13-005]] forbids resolving these by discarding a side,
    /// which leaves exactly one honest option: say so. A conflict that is
    /// recorded and never shown is the same silent loss with an audit
    /// trail nobody reads.
    private(set) var conflictedRecords: [String: [String]] = [:]

    func noteConflict(recordID: String, fields: [String]) {
        guard !fields.isEmpty else { return }
        conflictedRecords[recordID] = fields
        AppLog.sync.error(
            "merge conflict on \(recordID, privacy: .public): \(fields.joined(separator: ", "), privacy: .public)")
    }

    func clearConflict(recordID: String) { conflictedRecords.removeValue(forKey: recordID) }

    /// Conflicted fields for a host, or nil. The id form matches what
    /// SyncDomain.recordID produces, so one key works on both sides.
    func conflict(for host: HostEntry) -> [String]? {
        conflictedRecords["hosts/\(host.id.uuidString).json"]
    }

    /// Record ids the last save() could not write. Empty is the normal
    /// state; non-empty means the in-memory list and the disk disagree,
    /// which the human cannot see by looking at the list.
    private(set) var unpersistedRecordIDs: [String] = []

    // MARK: - Hosts

    func addHost(_ host: HostEntry) {
        hosts.append(host)
        save()
    }

    func updateHost(_ host: HostEntry) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
            save()
        }
    }

    func removeHost(_ host: HostEntry) {
        hosts.removeAll { $0.id == host.id }
        // Explicit, because save() deliberately does not infer deletions
        // from absence — see writeRecords.
        Self.deleteRecord("hosts", id: host.id)
        // And explicit to the sync engine for the same reason: a deletion
        // that only happens locally is a host that comes back from the
        // other Mac.
        SyncEngine.shared.noteLocalDeletion(path: "hosts/\(host.id.uuidString).json")
        save()
    }

    /// Batch group-membership change (drag-and-drop, WI-2026-08-08-057):
    /// moves the given hosts into `groupID`, or out of groups when nil.
    /// No-op hosts already in the target state are skipped.
    func moveHosts(_ ids: [UUID], toGroup groupID: UUID?) {
        var changed = false
        for i in hosts.indices where ids.contains(hosts[i].id) {
            if hosts[i].groupID != groupID {
                hosts[i].groupID = groupID
                changed = true
            }
        }
        if changed { save() }
    }

    /// All hosts in a group — flat membership (single level,
    /// WI-2026-08-08-065); nil = ungrouped hosts.
    func hosts(inGroup groupID: UUID?) -> [HostEntry] {
        hosts.filter { $0.groupID == groupID }
    }

    // MARK: - Groups

    func addGroup(_ group: HostGroup) {
        groups.append(group)
        save()
    }

    func updateGroup(_ group: HostGroup) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
            save()
        }
    }

    func removeGroup(_ group: HostGroup) {
        groups.removeAll { $0.id == group.id }
        // Hosts in the deleted group become ungrouped.
        for i in hosts.indices where hosts[i].groupID == group.id {
            hosts[i].groupID = nil
        }
        Self.deleteRecord("groups", id: group.id)
        SyncEngine.shared.noteLocalDeletion(path: "groups/\(group.id.uuidString).json")
        save()
    }

    /// Detection may only fill an EMPTY osHint — a manual editor pick is
    /// never overwritten (WI-2026-08-09-002).
    func setDetectedOS(_ hint: String, for hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        guard hosts[index].osHint == nil || hosts[index].osHint?.isEmpty == true else { return }
        hosts[index].osHint = hint
        save()
    }


    /// Stamp a successful connect (WI-2026-08-09-006).
    func markConnected(_ hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[index].lastConnectedAt = Date()
        save()
    }

    /// Recency comparator (WI-2026-08-09-006): most recently connected
    /// first; never-connected hosts last, alphabetically.
    nonisolated static func byRecency(_ a: HostEntry, _ b: HostEntry) -> Bool {
        switch (a.lastConnectedAt, b.lastConnectedAt) {
        case let (l?, r?): return l > r
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil):
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    // MARK: - Identities

    func addIdentity(_ identity: Identity) {
        identities.append(identity)
        save()
    }

    func updateIdentity(_ identity: Identity) {
        if let index = identities.firstIndex(where: { $0.id == identity.id }) {
            identities[index] = identity
            save()
        }
    }

    func removeIdentity(_ identity: Identity) {
        identities.removeAll { $0.id == identity.id }
        // Hosts referencing it fall back to their own fields.
        Self.deleteRecord("identities", id: identity.id)
        SyncEngine.shared.noteLocalDeletion(path: "identities/\(identity.id.uuidString).json")
        save()
    }

    // MARK: - Resolution

    /// The group's attached Identity, if any (WI-2026-08-09-001). Dangling
    /// references (identity deleted) resolve to nil and fall through.
    private func groupIdentity(for host: HostEntry) -> Identity? {
        guard let groupID = host.groupID,
              let group = groups.first(where: { $0.id == groupID }),
              let identityID = group.identityID
        else { return nil }
        return identities.first(where: { $0.id == identityID })
    }

    /// Resolved effective username: host field → host's identity → group's
    /// identity → group inline default → built-in default
    /// (WI-2026-08-08-067, WI-2026-08-09-001 — the group's Identity is a
    /// deliberate credential bundle, so it beats the loose inline default).
    func effectiveUsername(for host: HostEntry) -> String {
        if !host.username.isEmpty { return host.username }
        if let identityID = host.identityID,
           let identity = identities.first(where: { $0.id == identityID }) {
            return identity.username
        }
        if let identity = groupIdentity(for: host) {
            return identity.username
        }
        if let groupID = host.groupID,
           let group = groups.first(where: { $0.id == groupID }),
           let username = group.username, !username.isEmpty {
            return username
        }
        return NSUserName()
    }

    /// Resolved SSH key path: host field → host's identity → group's
    /// identity → nil (WI-2026-08-09-001).
    /// WHAT THE RECORD SAYS — host, then its identity, then its group.
    /// A question about configuration, not about this machine: whether
    /// the file is present here is `TunnelManager.effectiveKeyPath`'s
    /// business, because only the party about to connect needs the answer.
    func effectiveKeyPath(for host: HostEntry) -> String? {
        if let key = host.sshKeyPath, !key.isEmpty { return key }
        if let identityID = host.identityID,
           let identity = identities.first(where: { $0.id == identityID }),
           let key = identity.sshKeyPath, !key.isEmpty {
            return key
        }
        if let identity = groupIdentity(for: host),
           let key = identity.sshKeyPath, !key.isEmpty {
            return key
        }
        return nil
    }

    /// Resolved effective port: host field → group default → 22.
    func effectivePort(for host: HostEntry) -> Int {
        if host.port != 22 { return host.port }
        if let groupID = host.groupID,
           let group = groups.first(where: { $0.id == groupID }),
           let port = group.port {
            return port
        }
        return 22
    }

    /// Resolved jump host (ProxyJump): host-level → group default.
    func effectiveProxyJump(for host: HostEntry) -> String? {
        if let jump = host.proxyJump, !jump.isEmpty { return jump }
        guard let groupID = host.groupID,
              let group = groups.first(where: { $0.id == groupID }) else { return nil }
        return group.proxyJump
    }

    /// Effective forwarding rules: host-level rules, or the group's if the
    /// host defines none. (Forwarding rules are not merged to keep the
    /// command line predictable.)
    func effectiveForwardings(for host: HostEntry) -> [PortForward] {
        if !host.forwardings.isEmpty { return host.forwardings }
        guard let groupID = host.groupID,
              let group = groups.first(where: { $0.id == groupID }),
              let forwardings = group.forwardings else { return [] }
        return forwardings
    }

    // MARK: - Infrastructure workbench overview (WI-2026-08-09-008)

    /// How many hosts / groups reference an identity — the Identities
    /// tab's usage counts.
    func identityUsage(for identityID: UUID) -> (hosts: Int, groups: Int) {
        (hosts.filter { $0.identityID == identityID }.count,
         groups.filter { $0.identityID == identityID }.count)
    }

    /// Global forwarding overview: every host's EFFECTIVE rules
    /// (host-level replaces group-level — effectiveForwardings semantics),
    /// in host-label order. Rule-less hosts are omitted.
    func forwardingOverview() -> [ForwardingOverviewEntry] {
        hosts
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            .flatMap { host -> [ForwardingOverviewEntry] in
                let rules = effectiveForwardings(for: host)
                guard !rules.isEmpty else { return [] }
                let origin: UUID? = host.forwardings.isEmpty ? host.groupID : nil
                return rules.map {
                    ForwardingOverviewEntry(hostID: host.id, rule: $0, inheritedFromGroupID: origin)
                }
            }
    }

    /// All tags currently in use, sorted, deduplicated.
    var allTags: [String] {
        var set = Set<String>()
        for host in hosts {
            for tag in host.tags { set.insert(tag) }
        }
        return set.sorted()
    }

    /// Hosts filtered by search text (label, address, tags, group label).
    /// - `.all`: every host; `.ungrouped`: no group; `.group(id)`: that group.
    func searchHosts(_ query: String, in filter: HostFilter) -> [HostEntry] {
        let base = hosts(inFilter: filter)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return base }
        let needle = trimmed.lowercased()
        return base.filter { host in
            let groupLabel = host.groupID
                .flatMap { gid in groups.first(where: { $0.id == gid }) }?
                .label.lowercased() ?? ""
            return host.label.lowercased().contains(needle) ||
            host.address.lowercased().contains(needle) ||
            host.username.lowercased().contains(needle) ||
            host.tags.contains { $0.lowercased().contains(needle) } ||
            groupLabel.contains(needle)
        }
    }

    /// All hosts matching a filter (no search term applied).
    func hosts(inFilter filter: HostFilter) -> [HostEntry] {
        switch filter {
        case .all:
            return hosts
        case .ungrouped:
            return hosts.filter { $0.groupID == nil }
        case .group(let id):
            return hosts(inGroup: id)
        }
    }
}

// MARK: - OS probe (WI-2026-08-09-002)

/// Remote-OS detection: one ssh exec of `command`, parsed into an osHint
/// id. Pure parsing is separated for tests; failures return nil and the
/// caller stays silent (happy-path V1).
enum OSProbe {
    /// Executed over BatchMode ssh after a successful connect/test.
    static let command = "uname -s; cat /etc/os-release 2>/dev/null | grep ^ID="

    /// Map raw probe output to an osHint id ("macos", "windows", distro
    /// id like "ubuntu", or "linux" when no os-release ID is present).
    static func parse(_ output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("darwin") { return "macos" }
        if lower.contains("windows") || lower.contains("msys") || lower.contains("cygwin") {
            return "windows"
        }
        if lower.contains("linux") {
            if let idLine = lower
                .split(separator: "\n")
                .first(where: { $0.hasPrefix("id=") }) {
                let id = idLine.dropFirst(3)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !id.isEmpty { return id }
            }
            return "linux"
        }
        return nil
    }

    /// Coarse OS class for avatar tinting (WI-2026-08-09-006).
    enum OSFamily { case macos, windows, linux }

    /// Family for an osHint; nil = unknown (keep the hash-hue avatar).
    static func family(for hint: String?) -> OSFamily? {
        guard let hint, !hint.isEmpty else { return nil }
        switch hint {
        case "macos": return .macos
        case "windows": return .windows
        default: return .linux // any distro id
        }
    }

    /// SF Symbol replacing the avatar initials when the OS is known; nil
    /// keeps initials. Neutral marks only — no trademarked distro logos.
    static func glyph(for hint: String?) -> String? {
        guard let hint, !hint.isEmpty else { return nil }
        switch hint {
        case "macos": return "apple.logo"
        case "windows": return "desktopcomputer"
        default: return "terminal" // linux family (any distro id)
        }
    }
}

// MARK: - ~/.ssh/config import

extension HostStore {
    /// Parse ~/.ssh/config into importable host entries. Returns entries with
    /// resolved HostName/User/Port/IdentityFile/ProxyJump where available.
    /// Skips wildcard and pattern Host entries.
    static func parseSSHConfig(_ content: String) -> [HostEntry] {
        var entries: [HostEntry] = []
        var current: [String: String] = [:]
        var currentHost: String?

        func flush() {
            guard let hostName = current["hostname"],
                  let host = currentHost,
                  !host.contains("*") && !host.contains("?") else {
                current = [:]
                currentHost = nil
                return
            }
            let user = current["user"] ?? NSUserName()
            let entry = HostEntry(
                label: host,
                address: hostName,
                port: Int(current["port"] ?? "") ?? 22,
                username: user,
                sshKeyPath: current["identityfile"]?.split(separator: " ").first.map(String.init),
                proxyJump: current["proxyjump"]
            )
            entries.append(entry)
            current = [:]
            currentHost = nil
        }

        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // ssh config allows "Key=Value" or "Key Value"; split on first
            // whitespace or '='.
            let parts: [String]
            if let eq = line.firstIndex(of: "=") {
                parts = [String(line[..<eq]), String(line[line.index(after: eq)...])]
            } else {
                parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if key == "host" {
                flush()
                currentHost = value
            } else if let currentHost, currentHost != "" {
                current[key] = value
            }
        }
        flush()
        return entries
    }
}
