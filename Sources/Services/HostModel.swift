import Foundation

// ===========================================================================
// Host management data model — Termius-style organization.
//
// - HostGroup: nested groups; groups can carry default credentials (via an
//   Identity) and connection settings inherited by hosts and subgroups.
// - Identity: reusable credentials (username + SSH key path). A host, group,
//   or the app default can reference an identity.
// - HostEntry: a connectable host with optional group membership, tags and
//   an identity reference. Direct fields (username, sshKeyPath) override
//   inherited values.
// ===========================================================================

// MARK: - Identity (reusable credentials)

struct Identity: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var username: String
    /// Absolute path to the SSH private key; nil for password/default auth.
    var sshKeyPath: String?
}

// MARK: - HostGroup (nested, with inherited settings)

struct HostGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    /// Parent group ID; nil for root-level groups.
    var parentID: UUID?
    /// Optional identity applied to hosts in this group (inherited).
    var identityID: UUID?
    /// Optional default port inherited by hosts in this group.
    var port: Int?
    /// Optional default username inherited by hosts in this group.
    var username: String?
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
    /// Reusable credentials reference; overrides group inheritance.
    var identityID: UUID?

    /// Resolved display address (username@address).
    var displayAddress: String { "\(username)@\(address)" }

    // MARK: Codable — tolerant of legacy v1 JSON (missing new fields).
    // The synthesized decoder requires every key; a legacy hosts.json
    // without `tags`/`groupID`/`identityID` would throw and the user's
    // hosts would be silently lost on migration.

    private enum CodingKeys: String, CodingKey {
        case id, label, address, port, username, sshKeyPath, groupID, tags, identityID
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
        identityID: UUID? = nil
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
    }
}

// MARK: - Store

@MainActor final class HostStore: ObservableObject {
    @Published var hosts: [HostEntry] = []
    @Published var groups: [HostGroup] = []
    @Published var identities: [Identity] = []

    private static var storageURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".synapty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts.json")
    }

    /// Rolling backup of the previous hosts.json. Written before every save
    /// so a bad migration or accidental overwrite can be rolled back.
    private static var backupURL: URL {
        storageURL.deletingPathExtension().appendingPathExtension("json.bak")
    }

    init() {
        load()
    }

    // MARK: - Persistence

    /// Versioned payload so the old flat [HostEntry] format keeps loading.
    private struct Payload: Codable {
        var version: Int = 2
        var hosts: [HostEntry]
        var groups: [HostGroup]
        var identities: [Identity]

        init(hosts: [HostEntry], groups: [HostGroup], identities: [Identity]) {
            self.hosts = hosts
            self.groups = groups
            self.identities = identities
        }
    }

    func load() {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return }

        // Try the versioned payload first.
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            hosts = payload.hosts
            groups = payload.groups
            identities = payload.identities
            return
        }

        // Legacy v1: flat [HostEntry] array (fields not present decode with
        // defaults thanks to optional/defaulted properties).
        if let legacy = try? JSONDecoder().decode([HostEntry].self, from: data) {
            hosts = legacy
            groups = []
            identities = []
            save()
        }
    }

    func save() {
        // Keep a rolling backup of the previous file so a bad migration or
        // accidental overwrite is never irreversible.
        if FileManager.default.fileExists(atPath: Self.storageURL.path) {
            try? FileManager.default.removeItem(at: Self.backupURL)
            try? FileManager.default.copyItem(at: Self.storageURL, to: Self.backupURL)
        }
        let payload = Payload(hosts: hosts, groups: groups, identities: identities)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    /// Attempt to restore the last saved state from the rolling backup.
    /// Returns true on success.
    func restoreFromBackup() -> Bool {
        guard FileManager.default.fileExists(atPath: Self.backupURL.path),
              let data = try? Data(contentsOf: Self.backupURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return false }
        hosts = payload.hosts
        groups = payload.groups
        identities = payload.identities
        return true
    }

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
        save()
    }

    /// All hosts in a group, including those in descendant subgroups.
    func hosts(inGroup groupID: UUID?) -> [HostEntry] {
        var descendantIDs = Set<UUID>()
        collectGroupIDs(groupID, into: &descendantIDs)
        return hosts.filter { host in
            guard let gid = host.groupID else { return groupID == nil }
            return descendantIDs.contains(gid)
        }
    }

    private func collectGroupIDs(_ groupID: UUID?, into set: inout Set<UUID>) {
        guard let groupID else { return }
        set.insert(groupID)
        for child in groups where child.parentID == groupID {
            collectGroupIDs(child.id, into: &set)
        }
    }

    /// Immediate children of a group.
    func childGroups(of groupID: UUID?) -> [HostGroup] {
        groups.filter { $0.parentID == groupID }.sorted { $0.label < $1.label }
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
        // Descendants move to the deleted group's parent.
        let parent = group.parentID
        var affected = Set<UUID>()
        collectGroupIDs(group.id, into: &affected)
        for gid in affected {
            if let idx = groups.firstIndex(where: { $0.id == gid }) {
                groups[idx].parentID = parent
            }
        }
        groups.removeAll { $0.id == group.id }

        // Hosts in the deleted group (and subgroups) become ungrouped.
        for i in hosts.indices where affected.contains(hosts[i].groupID ?? UUID()) {
            hosts[i].groupID = nil
        }
        save()
    }

    /// Renames a group (label only; identity/port/username untouched).
    func renameGroup(_ group: HostGroup, to newLabel: String) {
        var updated = group
        updated.label = newLabel
        updateGroup(updated)
    }

    /// The chain of group labels from the root down to (and including) the
    /// given group — used for display like "Prod / GPU Box".
    func groupPath(for groupID: UUID?) -> [String] {
        guard let groupID else { return [] }
        guard let group = groups.first(where: { $0.id == groupID }) else { return [] }
        var path = groupPath(for: group.parentID)
        path.append(group.label)
        return path
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
        save()
    }

    // MARK: - Resolution

    /// Resolved effective username for a host: host field → identity →
    /// group (walking up) → default.
    func effectiveUsername(for host: HostEntry) -> String {
        if !host.username.isEmpty { return host.username }
        if let identityID = host.identityID,
           let identity = identities.first(where: { $0.id == identityID }) {
            return identity.username
        }
        if let groupID = host.groupID,
           let username = inheritedGroupValue(groupID, keyPath: \.username) {
            return username
        }
        return NSUserName()
    }

    /// Resolved SSH key path for a host, or nil.
    func effectiveKeyPath(for host: HostEntry) -> String? {
        if let key = host.sshKeyPath, !key.isEmpty { return key }
        if let identityID = host.identityID,
           let identity = identities.first(where: { $0.id == identityID }),
           let key = identity.sshKeyPath, !key.isEmpty {
            return key
        }
        if let groupID = host.groupID,
           let key = inheritedGroupValue(groupID, keyPath: \.identityID),
           let identity = identities.first(where: { $0.id == key }),
           let keyPath = identity.sshKeyPath, !keyPath.isEmpty {
            return keyPath
        }
        return nil
    }

    /// Resolved effective port for a host.
    func effectivePort(for host: HostEntry) -> Int {
        if host.port != 22 { return host.port }
        if let groupID = host.groupID,
           let port = inheritedGroupValue(groupID, keyPath: \.port) {
            return port
        }
        return 22
    }

    /// Walks up the group chain looking for the nearest non-nil value.
    private func inheritedGroupValue<T>(_ groupID: UUID, keyPath: KeyPath<HostGroup, T?>) -> T? {
        var current: UUID? = groupID
        while let gid = current {
            guard let group = groups.first(where: { $0.id == gid }) else { break }
            if let value = group[keyPath: keyPath] { return value }
            current = group.parentID
        }
        return nil
    }

    /// All tags currently in use, sorted, deduplicated.
    var allTags: [String] {
        var set = Set<String>()
        for host in hosts {
            for tag in host.tags { set.insert(tag) }
        }
        return set.sorted()
    }

    /// Hosts filtered by search text (label, address, tags, group path).
    func searchHosts(_ query: String, in groupID: UUID?) -> [HostEntry] {
        let base = hosts(inGroup: groupID)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return base }
        let needle = trimmed.lowercased()
        return base.filter { host in
            host.label.lowercased().contains(needle) ||
            host.address.lowercased().contains(needle) ||
            host.username.lowercased().contains(needle) ||
            host.tags.contains { $0.lowercased().contains(needle) } ||
            groupPath(for: host.groupID).joined(separator: "/").lowercased().contains(needle)
        }
    }
}
