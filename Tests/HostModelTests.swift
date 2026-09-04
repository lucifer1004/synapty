import XCTest
@testable import Synapty

final class HostEntryTests: XCTestCase {

    // MARK: - Initialization

    func testDefaultPort() {
        let host = HostEntry(label: "Dev", address: "10.0.0.1", username: "root")
        XCTAssertEqual(host.port, 22)
    }

    func testCustomPort() {
        let host = HostEntry(label: "Dev", address: "10.0.0.1", port: 2222, username: "root")
        XCTAssertEqual(host.port, 2222)
    }

    func testSSHKeyPathDefaultsToNil() {
        let host = HostEntry(label: "Dev", address: "10.0.0.1", username: "root")
        XCTAssertNil(host.sshKeyPath)
    }

    func testUniqueIDsPerEntry() {
        let a = HostEntry(label: "A", address: "1.1.1.1", username: "u")
        let b = HostEntry(label: "B", address: "2.2.2.2", username: "u")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let original = HostEntry(
            label: "GPU Box",
            address: "10.0.1.5",
            port: 2222,
            username: "ml",
            sshKeyPath: "~/.ssh/gpu_key"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HostEntry.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.label, original.label)
        XCTAssertEqual(decoded.address, original.address)
        XCTAssertEqual(decoded.port, original.port)
        XCTAssertEqual(decoded.username, original.username)
        XCTAssertEqual(decoded.sshKeyPath, original.sshKeyPath)
    }

    func testCodableRoundTripWithoutOptionalFields() throws {
        let original = HostEntry(label: "Minimal", address: "localhost", username: "user")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HostEntry.self, from: data)
        XCTAssertEqual(decoded.label, original.label)
        XCTAssertNil(decoded.sshKeyPath)
    }

    func testArrayCodableRoundTrip() throws {
        let hosts = [
            HostEntry(label: "A", address: "1.1.1.1", username: "u1"),
            HostEntry(label: "B", address: "2.2.2.2", port: 3000, username: "u2", sshKeyPath: "/key"),
        ]
        let data = try JSONEncoder().encode(hosts)
        let decoded = try JSONDecoder().decode([HostEntry].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].label, "A")
        XCTAssertEqual(decoded[1].port, 3000)
        XCTAssertEqual(decoded[1].sshKeyPath, "/key")
    }
}

@MainActor
final class HostStoreTests: XCTestCase {

    /// Shared temp-storage harness (WI-2026-08-08-037) — HostStoreTests
    /// must never touch the developer's real ~/.synapty/hosts.json.
    private var tempDir: URL!
    /// Saved by isolatedRoot() so a per-test root NESTS inside the
    /// class-level isolation instead of replacing it.
    private var savedHostStoreOverride: URL?

    override func setUpWithError() throws {
        tempDir = try setUpHostStoreStorage()
    }

    override func tearDownWithError() throws {
        // THE GUARD. A test that drops the override leaves the next one
        // reading the developer's real ~/.config/synapty, and the failure
        // surfaces as a confusing assertion in an unrelated test rather
        // than here. Checked at teardown so the test that actually did it
        // is the one that fails.
        XCTAssertNotNil(HostStore.storageOverride,
                        "a test dropped the storage override — the next test would read real config")
        restoreStorageOverrides(tempDir)
    }

    private func makeStore() -> HostStore {
        HostStore()
    }

    // MARK: - CRUD operations (isolated, no real-home I/O)

    func testInitiallyEmpty() {
        let store = makeStore()
        XCTAssertTrue(store.hosts.isEmpty)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(store.identities.isEmpty)
    }

    func testAddHostIncreasesCount() {
        let store = makeStore()
        XCTAssertTrue(store.hosts.isEmpty)
        store.hosts.append(HostEntry(label: "Test", address: "1.2.3.4", username: "u"))
        XCTAssertEqual(store.hosts.count, 1)
    }

    func testRemoveHostDecreasesCount() {
        let store = makeStore()
        let host = HostEntry(label: "Temp", address: "1.2.3.4", username: "u")
        store.hosts.append(host)
        XCTAssertEqual(store.hosts.count, 1)
        store.hosts.removeAll { $0.id == host.id }
        XCTAssertTrue(store.hosts.isEmpty)
    }

    func testUpdateHostByID() {
        let store = makeStore()
        var host = HostEntry(label: "Old", address: "1.2.3.4", username: "u")
        store.hosts.append(host)
        host.label = "New"
        if let idx = store.hosts.firstIndex(where: { $0.id == host.id }) {
            store.hosts[idx] = host
        }
        XCTAssertEqual(store.hosts.first(where: { $0.id == host.id })?.label, "New")
    }

    // MARK: - Persistence (temp dir)

    func testSaveThenReloadRoundTrip() throws {
        let store = makeStore()
        store.hosts.append(HostEntry(label: "GPU Box", address: "10.0.1.5", port: 2222, username: "ml", sshKeyPath: "~/.ssh/gpu_key"))
        store.groups.append(HostGroup(id: UUID(), label: "Lab"))
        store.identities.append(Identity(id: UUID(), label: "ml", username: "ml", sshKeyPath: "~/.ssh/ml_key"))
        store.save()

        // A fresh store over the same temp dir must load everything back.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.hosts.count, 1)
        XCTAssertEqual(reloaded.hosts[0].label, "GPU Box")
        XCTAssertEqual(reloaded.hosts[0].address, "10.0.1.5")
        XCTAssertEqual(reloaded.hosts[0].port, 2222)
        XCTAssertEqual(reloaded.hosts[0].sshKeyPath, "~/.ssh/gpu_key")
        XCTAssertEqual(reloaded.groups.count, 1)
        XCTAssertEqual(reloaded.groups[0].label, "Lab")
        XCTAssertEqual(reloaded.identities.count, 1)
        XCTAssertEqual(reloaded.identities[0].username, "ml")
    }


    func testAnUntouchedRecordSurvivesAnotherStoresSave() throws {
        // Replaces testSaveWritesRollingBackup. The rolling backup existed
        // to survive the whole-file rewrite window, and per-record storage
        // closes that window instead of insuring against it: a save writes
        // only what it has and never infers a deletion from absence, so a
        // second store cannot erase the first one's work. That property is
        // what the backup was standing in for.
        let a = makeStore()
        let first = HostEntry(label: "first", address: "1.1.1.1", username: "u")
        a.addHost(first)

        let b = makeStore()
        b.addHost(HostEntry(label: "second", address: "2.2.2.2", username: "u"))

        let url = tempDir.appendingPathComponent("hosts/\(first.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a store that never knew about this host must not delete it")
    }

    // MARK: - Groups (Termius-style)

    /// Flat membership (single-level groups, WI-2026-08-08-065).
    func testHostsInGroupFlat() {
        let store = HostStore()
        let group = HostGroup(label: "Prod")
        store.groups = [group]
        let h1 = HostEntry(label: "db", address: "1.1.1.1", username: "u", groupID: group.id)
        let h2 = HostEntry(label: "unassigned", address: "2.2.2.2", username: "u")
        store.hosts = [h1, h2]
        XCTAssertEqual(store.hosts(inGroup: group.id).count, 1)
        XCTAssertEqual(store.hosts(inGroup: nil).count, 1)
    }

    /// Batch group-membership change used by drag-and-drop
    /// (WI-2026-08-08-057).
    func testMoveHostsToGroupAndBack() {
        let store = HostStore()
        let group = HostGroup(label: "Prod")
        store.groups = [group]
        let h1 = HostEntry(label: "db", address: "1.1.1.1", username: "u")
        let h2 = HostEntry(label: "web", address: "2.2.2.2", username: "u")
        let h3 = HostEntry(label: "other", address: "3.3.3.3", username: "u")
        store.hosts = [h1, h2, h3]

        // Move two hosts into the group in one batch.
        store.moveHosts([h1.id, h2.id], toGroup: group.id)
        XCTAssertEqual(store.hosts(inGroup: group.id).count, 2)
        XCTAssertEqual(store.hosts(inGroup: nil).count, 1)

        // Moving back out (Ungrouped drop target) clears membership.
        store.moveHosts([h1.id], toGroup: nil)
        XCTAssertEqual(store.hosts(inGroup: group.id).count, 1)
        XCTAssertTrue(store.hosts(inGroup: nil).contains { $0.id == h1.id })

        // No-op moves do not corrupt state.
        store.moveHosts([h3.id], toGroup: nil)
        XCTAssertEqual(store.hosts(inGroup: nil).count, 2)
        XCTAssertNil(store.hosts.first { $0.id == h3.id }?.groupID)
    }

    /// Deleting a group ungroups its hosts; no reparenting exists in the
    /// flat model (WI-2026-08-08-065).
    func testRemoveGroupUngroupsHosts() {
        let store = HostStore()
        let group = HostGroup(label: "Prod")
        let other = HostGroup(label: "Dev")
        store.groups = [group, other]
        let h1 = HostEntry(label: "db", address: "1.1.1.1", username: "u", groupID: group.id)
        let h2 = HostEntry(label: "web", address: "2.2.2.2", username: "u", groupID: other.id)
        store.hosts = [h1, h2]

        store.removeGroup(group)
        XCTAssertNil(store.groups.first(where: { $0.id == group.id }))
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertNil(store.hosts.first { $0.id == h1.id }?.groupID)
        XCTAssertEqual(store.hosts.first { $0.id == h2.id }?.groupID, other.id)
    }

    /// Legacy nested-era hosts.json carries a parentID key; the synthesized
    /// Decodable ignores unknown keys, so old data still loads flat
    /// (WI-2026-08-08-065).
    func testLegacyGroupJSONWithParentIDLoads() throws {
        let json = #"[{"id":"11111111-1111-1111-1111-111111111111","label":"Prod","parentID":"22222222-2222-2222-2222-222222222222"}]"#
        let groups = try JSONDecoder().decode([HostGroup].self, from: Data(json.utf8))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].label, "Prod")
    }

    // MARK: - Credential inheritance

    func testEffectiveUsernameFromIdentity() {
        let store = HostStore()
        let identity = Identity(label: "GPU Creds", username: "ml", sshKeyPath: "/keys/gpu")
        store.identities = [identity]
        let host = HostEntry(label: "gpu1", address: "10.0.1.5", username: "", identityID: identity.id)
        XCTAssertEqual(store.effectiveUsername(for: host), "ml")
        XCTAssertEqual(store.effectiveKeyPath(for: host), "/keys/gpu")
    }

    /// Host in a group inherits the group's own defaults — flat, no parent
    /// chain (WI-2026-08-08-065).
    func testEffectiveUsernameFromGroup() {
        let store = HostStore()
        let group = HostGroup(label: "GPU", username: "deploy")
        store.groups = [group]
        let host = HostEntry(label: "gpu1", address: "10.0.1.5", username: "", groupID: group.id)
        XCTAssertEqual(store.effectiveUsername(for: host), "deploy")
        XCTAssertEqual(store.effectivePort(for: host), 22)
    }

    func testEffectivePortFromGroup() {
        let store = HostStore()
        let group = HostGroup(label: "AltPort", port: 2222)
        store.groups = [group]
        let host = HostEntry(label: "h", address: "1.1.1.1", username: "u", groupID: group.id)
        XCTAssertEqual(store.effectivePort(for: host), 2222)
    }

    func testHostFieldOverridesGroup() {
        let store = HostStore()
        let group = HostGroup(label: "Prod", username: "deploy")
        store.groups = [group]
        let host = HostEntry(label: "h", address: "1.1.1.1", username: "root", groupID: group.id)
        XCTAssertEqual(store.effectiveUsername(for: host), "root")
    }

    // MARK: - Group-level identity (WI-2026-08-09-001)

    /// A host with no credentials of its own resolves through the GROUP's
    /// identity — rotate one Identity, the whole fleet follows.
    func testEffectiveCredentialsFromGroupIdentity() {
        let store = HostStore()
        let identity = Identity(label: "Fleet", username: "ops", sshKeyPath: "/keys/fleet")
        store.identities = [identity]
        var group = HostGroup(label: "Prod")
        group.identityID = identity.id
        store.groups = [group]
        let host = HostEntry(label: "h", address: "1.1.1.1", username: "", groupID: group.id)
        XCTAssertEqual(store.effectiveUsername(for: host), "ops")
        XCTAssertEqual(store.effectiveKeyPath(for: host), "/keys/fleet")
    }

    /// The host's own identity is more specific than the group's.
    func testHostIdentityBeatsGroupIdentity() {
        let store = HostStore()
        let hostIdentity = Identity(label: "Mine", username: "me", sshKeyPath: "/keys/me")
        let groupIdentity = Identity(label: "Fleet", username: "ops", sshKeyPath: "/keys/fleet")
        store.identities = [hostIdentity, groupIdentity]
        var group = HostGroup(label: "Prod")
        group.identityID = groupIdentity.id
        store.groups = [group]
        let host = HostEntry(
            label: "h", address: "1.1.1.1", username: "",
            groupID: group.id, identityID: hostIdentity.id
        )
        XCTAssertEqual(store.effectiveUsername(for: host), "me")
        XCTAssertEqual(store.effectiveKeyPath(for: host), "/keys/me")
    }

    /// An attached Identity is a deliberate credential bundle — it beats
    /// the group's loose inline username default (WI-2026-08-09-001).
    func testGroupIdentityBeatsGroupInlineUsername() {
        let store = HostStore()
        let identity = Identity(label: "Fleet", username: "ops", sshKeyPath: nil)
        store.identities = [identity]
        var group = HostGroup(label: "Prod", username: "deploy")
        group.identityID = identity.id
        store.groups = [group]
        let host = HostEntry(label: "h", address: "1.1.1.1", username: "", groupID: group.id)
        XCTAssertEqual(store.effectiveUsername(for: host), "ops")
    }

    /// A dangling identity reference (identity deleted) falls back to the
    /// group's inline username instead of failing.
    func testRemovedIdentityFallsBackToGroupUsername() {
        let store = HostStore()
        var group = HostGroup(label: "Prod", username: "deploy")
        group.identityID = UUID() // dangling
        store.groups = [group]
        let host = HostEntry(label: "h", address: "1.1.1.1", username: "", groupID: group.id)
        XCTAssertEqual(store.effectiveUsername(for: host), "deploy")
        XCTAssertNil(store.effectiveKeyPath(for: host))
    }

    /// HostGroup.identityID round-trips; legacy JSON without it loads.
    func testGroupIdentityCodableRoundTrip() throws {
        var group = HostGroup(label: "Prod")
        group.identityID = UUID()
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(HostGroup.self, from: data)
        XCTAssertEqual(decoded.identityID, group.identityID)

        let legacy = #"{"id":"11111111-1111-1111-1111-111111111111","label":"Old"}"#
        let old = try JSONDecoder().decode(HostGroup.self, from: Data(legacy.utf8))
        XCTAssertNil(old.identityID)
    }

    func testTagsAndSearch() {
        let store = HostStore()
        let h1 = HostEntry(label: "gpu-node", address: "10.0.1.5", username: "ml", tags: ["gpu", "prod"])
        let h2 = HostEntry(label: "db", address: "10.0.2.5", username: "ml", tags: ["db"])
        store.hosts = [h1, h2]
        XCTAssertEqual(store.allTags, ["db", "gpu", "prod"])
        XCTAssertEqual(store.searchHosts("gpu", in: .all).count, 1)
        XCTAssertEqual(store.searchHosts("db", in: .all).count, 1)
        XCTAssertEqual(store.searchHosts("", in: .all).count, 2)
    }

    func testHostFilterDistinguishesAllAndUngrouped() {
        let store = HostStore()
        let group = HostGroup(label: "Prod")
        store.groups = [group]
        let grouped = HostEntry(label: "web", address: "10.0.0.2", username: "u", groupID: group.id)
        let ungrouped = HostEntry(label: "laptop", address: "10.0.0.9", username: "u")
        store.hosts = [grouped, ungrouped]
        // .all sees everything; .ungrouped only the free hosts.
        XCTAssertEqual(store.hosts(inFilter: .all).count, 2)
        XCTAssertEqual(store.hosts(inFilter: .ungrouped).count, 1)
        XCTAssertEqual(store.hosts(inFilter: .group(group.id)).count, 1)
    }

    // MARK: - Legacy v1 migration

    /// Old hosts.json was a flat [HostEntry] array. New fields have defaults,
    /// so decoding must succeed and preserve every legacy field.
    func testLegacyV1ArrayDecodes() throws {
        let legacyJSON = """
        [{"id":"11111111-2222-3333-4444-555555555555","label":"GPU Box",
          "address":"10.0.0.7","port":22,"username":"operator",
          "sshKeyPath":"/Users/operator/.ssh/id_ed25519"}]
        """
        let data = legacyJSON.data(using: .utf8)!
        let hosts = try JSONDecoder().decode([HostEntry].self, from: data)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].label, "GPU Box")
        XCTAssertEqual(hosts[0].address, "10.0.0.7")
        XCTAssertEqual(hosts[0].username, "operator")
        XCTAssertEqual(hosts[0].sshKeyPath, "/Users/operator/.ssh/id_ed25519")
        XCTAssertNil(hosts[0].groupID)
        XCTAssertTrue(hosts[0].tags.isEmpty)
        XCTAssertNil(hosts[0].identityID)
    }

    /// The versioned payload round-trips hosts/groups/identities together.
    func testPayloadRoundTrip() throws {
        let group = HostGroup(label: "Prod", username: "deploy")
        let identity = Identity(label: "CI", username: "ci", sshKeyPath: "/keys/ci")
        let host = HostEntry(
            label: "web", address: "10.0.0.2", username: "",
            groupID: group.id, tags: ["prod"], identityID: identity.id
        )
        // Encode via the same JSON shape HostStore uses.
        struct Payload: Codable {
            var version: Int
            var hosts: [HostEntry]
            var groups: [HostGroup]
            var identities: [Identity]
        }
        let payload = Payload(version: 2, hosts: [host], groups: [group], identities: [identity])
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        XCTAssertEqual(decoded.hosts[0].label, "web")
        XCTAssertEqual(decoded.hosts[0].groupID, group.id)
        XCTAssertEqual(decoded.hosts[0].identityID, identity.id)
        XCTAssertEqual(decoded.hosts[0].tags, ["prod"])
        XCTAssertEqual(decoded.groups[0].username, "deploy")
        XCTAssertEqual(decoded.identities[0].label, "CI")
    }
}

// MARK: - Port forwarding & ProxyJump (Termius parity 2/3/4)

final class PortForwardTests: XCTestCase {
    func testLocalForwardFlag() {
        let fwd = PortForward(kind: .local, listenPort: 8080, targetHost: "localhost", targetPort: 80)
        XCTAssertEqual(fwd.sshFlag, "local 8080:localhost:80")
    }

    func testRemoteForwardFlag() {
        let fwd = PortForward(kind: .remote, listenPort: 9090, targetHost: "127.0.0.1", targetPort: 9000)
        XCTAssertEqual(fwd.sshFlag, "remote 9090:127.0.0.1:9000")
    }

    func testHostEntryCodableWithNewFields() throws {
        let fwd = PortForward(kind: .local, listenPort: 8080, targetHost: "localhost", targetPort: 80)
        let host = HostEntry(
            label: "web", address: "10.0.0.2", username: "u",
            proxyJump: "user@bastion:22", forwardings: [fwd]
        )
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(HostEntry.self, from: data)
        XCTAssertEqual(decoded.proxyJump, "user@bastion:22")
        XCTAssertEqual(decoded.forwardings.count, 1)
        XCTAssertEqual(decoded.forwardings[0].sshFlag, "local 8080:localhost:80")
    }
}

@MainActor
final class SSHConfigImportTests: XCTestCase {
    func testParseSSHConfigBasic() {
        let content = """
        Host bastion
            HostName 203.0.113.1
            User admin
            Port 2222

        Host gpu-1
            HostName 10.0.1.5
            User ml
            IdentityFile ~/.ssh/gpu_key
            ProxyJump admin@bastion:2222

        Host *.example.com
            HostName example.com
        """
        let entries = HostStore.parseSSHConfig(content)
        XCTAssertEqual(entries.count, 2) // wildcard skipped

        let bastion = entries.first { $0.label == "bastion" }
        XCTAssertEqual(bastion?.address, "203.0.113.1")
        XCTAssertEqual(bastion?.username, "admin")
        XCTAssertEqual(bastion?.port, 2222)

        let gpu = entries.first { $0.label == "gpu-1" }
        XCTAssertEqual(gpu?.address, "10.0.1.5")
        XCTAssertEqual(gpu?.username, "ml")
        XCTAssertEqual(gpu?.sshKeyPath, "~/.ssh/gpu_key")
        XCTAssertEqual(gpu?.proxyJump, "admin@bastion:2222")
    }

    func testParseSSHConfigEqualSyntaxAndComments() {
        let content = """
        # comment
        Host db
            HostName=10.0.2.5
            User=root
        """
        let entries = HostStore.parseSSHConfig(content)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].label, "db")
        XCTAssertEqual(entries[0].address, "10.0.2.5")
        XCTAssertEqual(entries[0].username, "root")
    }
}

// MARK: - Infrastructure workbench model layer (WI-2026-08-09-008)

@MainActor
final class InfraWorkbenchTests: XCTestCase {

    /// Shared temp-storage harness (WI-2026-08-08-037) — store-backed
    /// tests must never touch the developer's real ~/.synapty/hosts.json.
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try setUpHostStoreStorage()
    }

    override func tearDownWithError() throws {
        restoreStorageOverrides(tempDir)
    }

    // MARK: - Identity usage counts

    func testIdentityUsageCounts() {
        let store = HostStore()
        let used = Identity(label: "Fleet", username: "ops", sshKeyPath: nil)
        let unused = Identity(label: "Spare", username: "x", sshKeyPath: nil)
        store.identities = [used, unused]
        var group = HostGroup(label: "Prod")
        group.identityID = used.id
        store.groups = [group]
        store.hosts = [
            HostEntry(label: "a", address: "1.1.1.1", username: "u", identityID: used.id),
            HostEntry(label: "b", address: "2.2.2.2", username: "u", identityID: used.id),
            HostEntry(label: "c", address: "3.3.3.3", username: "u"),
        ]
        let usage = store.identityUsage(for: used.id)
        XCTAssertEqual(usage.hosts, 2)
        XCTAssertEqual(usage.groups, 1)
        let none = store.identityUsage(for: unused.id)
        XCTAssertEqual(none.hosts, 0)
        XCTAssertEqual(none.groups, 0)
    }

    // MARK: - Global forwarding overview

    func testForwardingOverviewHostOwnRules() {
        let store = HostStore()
        let ruleA = PortForward(kind: .local, listenPort: 8080, targetHost: "localhost", targetPort: 80)
        let ruleB = PortForward(kind: .remote, listenPort: 9001, targetHost: "localhost", targetPort: 9001)
        let host = HostEntry(label: "web", address: "1.1.1.1", username: "u", forwardings: [ruleA, ruleB])
        store.hosts = [host]
        let overview = store.forwardingOverview()
        XCTAssertEqual(overview.count, 2)
        XCTAssertEqual(overview[0].hostID, host.id)
        XCTAssertNil(overview[0].inheritedFromGroupID)
        XCTAssertEqual(overview[0].rule.listenPort, 8080)
    }

    /// Group rules are inherited by rule-less members; a host's own rules
    /// REPLACE the group's (effectiveForwardings semantics — not merged).
    func testForwardingOverviewGroupInheritanceAndPrecedence() {
        let store = HostStore()
        var group = HostGroup(label: "Prod")
        group.forwardings = [PortForward(kind: .remote, listenPort: 9000, targetHost: "localhost", targetPort: 9000)]
        store.groups = [group]
        let bare = HostEntry(label: "bare", address: "1.1.1.1", username: "u", groupID: group.id)
        let own = HostEntry(
            label: "own", address: "2.2.2.2", username: "u", groupID: group.id,
            forwardings: [PortForward(kind: .local, listenPort: 3000, targetHost: "localhost", targetPort: 3000)]
        )
        store.hosts = [bare, own]
        let overview = store.forwardingOverview()
        let bareRows = overview.filter { $0.hostID == bare.id }
        XCTAssertEqual(bareRows.count, 1)
        XCTAssertEqual(bareRows[0].inheritedFromGroupID, group.id)
        XCTAssertEqual(bareRows[0].rule.kind, .remote)
        let ownRows = overview.filter { $0.hostID == own.id }
        XCTAssertEqual(ownRows.count, 1)
        XCTAssertNil(ownRows[0].inheritedFromGroupID)
        XCTAssertEqual(ownRows[0].rule.listenPort, 3000)
    }

    /// Rule-less hosts are omitted; the SAME group rule listed under two
    /// member hosts must still yield unique row IDs (ForEach identity).
    func testForwardingOverviewOmitsRulelessHostsAndKeepsUniqueIDs() {
        let store = HostStore()
        var group = HostGroup(label: "Prod")
        group.forwardings = [PortForward(kind: .local, listenPort: 8080, targetHost: "localhost", targetPort: 80)]
        store.groups = [group]
        let a = HostEntry(label: "a", address: "1.1.1.1", username: "u", groupID: group.id)
        let b = HostEntry(label: "b", address: "2.2.2.2", username: "u", groupID: group.id)
        let quiet = HostEntry(label: "quiet", address: "3.3.3.3", username: "u")
        store.hosts = [a, b, quiet]
        let overview = store.forwardingOverview()
        XCTAssertEqual(overview.count, 2)
        XCTAssertEqual(Set(overview.map(\.id)).count, 2)
    }

    /// Overview rows come out in host-label order for a stable list.
    func testForwardingOverviewSortedByHostLabel() {
        let store = HostStore()
        let rule = PortForward(kind: .local, listenPort: 8080, targetHost: "localhost", targetPort: 80)
        store.hosts = [
            HostEntry(label: "zeta", address: "1.1.1.1", username: "u", forwardings: [rule]),
            HostEntry(label: "Alpha", address: "2.2.2.2", username: "u", forwardings: [rule]),
        ]
        let overview = store.forwardingOverview()
        XCTAssertEqual(overview.count, 2)
        let alphaFirst = store.hosts.first(where: { $0.label == "Alpha" })!.id
        XCTAssertEqual(overview[0].hostID, alphaFirst)
    }
}

// MARK: - WI-2026-08-13-004: one record per host

extension HostStoreTests {

    /// A per-test root, NESTED inside the class-level isolation rather
    /// than replacing it.
    ///
    /// This used to just assign storageOverride, and every caller undid it
    /// with `= nil`. That dropped the tempDir setUpHostStoreStorage had
    /// installed for the whole class, so the NEXT test in the file ran
    /// with no override at all and read the developer's real
    /// ~/.config/synapty. Order-dependent, therefore invisible until the
    /// order changed. The standing rule for this repo is that store-backed
    /// tests must never reach real storage, and remembering to restore is
    /// not a mechanism — pairing is.
    private func isolatedRoot() -> URL {
        savedHostStoreOverride = HostStore.storageOverride
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-hosts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        HostStore.storageOverride = root
        return root
    }

    private func releaseIsolatedRoot(_ root: URL) {
        HostStore.storageOverride = savedHostStoreOverride
        savedHostStoreOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// THE case a whole-file store cannot survive. Two machines each add a
    /// DIFFERENT host and both save; with one document the second write
    /// wins and takes an unrelated host with it. Per record they union.
    @MainActor
    func testConcurrentAddsOfDifferentHostsBothSurvive() {
        let root = isolatedRoot()
        defer { releaseIsolatedRoot(root) }

        // Two stores over one directory, as two machines would be.
        let a = HostStore()
        let b = HostStore()
        a.addHost(HostEntry(label: "remotehost", address: "remotehost", username: "u"))
        b.addHost(HostEntry(label: "buildbox", address: "buildbox", username: "u"))

        let reread = HostStore()
        let labels = Set(reread.hosts.map(\.label))
        XCTAssertEqual(labels, ["remotehost", "buildbox"],
                       "a concurrent add on another machine must not be lost")
    }

    /// Editing one host must not rewrite the others — otherwise the
    /// per-record layout buys nothing on a last-writer-wins transport.
    @MainActor
    func testEditingOneHostDoesNotTouchAnother() throws {
        let root = isolatedRoot()
        defer { releaseIsolatedRoot(root) }

        let store = HostStore()
        let keep = HostEntry(label: "remotehost", address: "remotehost", username: "u")
        var edit = HostEntry(label: "buildbox", address: "buildbox", username: "u")
        store.addHost(keep)
        store.addHost(edit)

        let keepURL = root.appendingPathComponent("hosts/\(keep.id.uuidString).json")
        let before = try FileManager.default.attributesOfItem(atPath: keepURL.path)[.modificationDate] as? Date

        Thread.sleep(forTimeInterval: 0.05)
        edit.label = "buildbox-2"
        store.updateHost(edit)

        let after = try FileManager.default.attributesOfItem(atPath: keepURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "an untouched host's record must not be rewritten")
    }

    /// SAVING AGAIN WITHOUT CHANGING ANYTHING WRITES NOTHING.
    ///
    /// The neighbour above asserts this for ONE record and was
    /// intermittently red for it. The cause was not timing: `JSONEncoder`'s
    /// keyed container is unordered, so encoding one unchanged value twice
    /// produced different BYTES — same keys, same values, same length,
    /// different order — and the skip in `writeRecords` is a byte
    /// comparison. Two hundred encodes of one value in one process gave
    /// eleven distinct strings.
    ///
    /// It is not a test-only defect. `save()` hands every record it writes
    /// to the sync engine, so unchanged hosts went on the wire to a
    /// last-writer-wins transport on every save.
    ///
    /// TWENTY ROUNDS, because one round would have caught it most of the
    /// time — and "most of the time" is what let it read as a flake.
    @MainActor
    func testSavingAgainRewritesNothingThatDidNotChange() throws {
        let root = isolatedRoot()
        defer { releaseIsolatedRoot(root) }

        let store = HostStore()
        for name in ["alpha", "beta", "gamma"] {
            store.addHost(HostEntry(label: name, address: name, username: "u"))
        }

        let dir = root.appendingPathComponent("hosts")
        func written() throws -> [String: Date] {
            var out: [String: Date] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
                let attrs = try FileManager.default.attributesOfItem(
                    atPath: dir.appendingPathComponent(name).path)
                out[name] = attrs[.modificationDate] as? Date
            }
            return out
        }

        let first = try written()
        XCTAssertEqual(first.count, 3)
        for round in 1...20 {
            store.save()
            XCTAssertEqual(try written(), first,
                           "round \(round) rewrote a record nothing had changed — the "
                           + "\"write only what changed\" comparison is not seeing equal bytes")
        }
    }

    /// AND THE RECORD IT WRITES HAS A FIXED KEY ORDER, which is what makes
    /// the round-trip above deterministic rather than usually-true.
    ///
    /// The no-rewrite test is the guarantee; this is its precondition, and
    /// it is asserted separately because the guarantee fails only SOME of
    /// the time when the precondition is broken — an unordered container
    /// happens to agree with itself often enough that twenty rounds pass
    /// about half the time. A guard that catches a regression half the
    /// time is how this shipped.
    @MainActor
    func testARecordIsWrittenWithItsKeysInAFixedOrder() throws {
        let root = isolatedRoot()
        defer { releaseIsolatedRoot(root) }

        let store = HostStore()
        var host = HostEntry(label: "remotehost", address: "remotehost", username: "u")
        host.proxyJump = "admin@bastion:22"
        host.osHint = "linux"
        store.addHost(host)

        let url = root.appendingPathComponent("hosts/\(host.id.uuidString).json")
        let keys = try Self.topLevelKeys(of: Data(contentsOf: url))
        XCTAssertGreaterThan(keys.count, 6, "the fixture should exercise several keys")
        XCTAssertEqual(keys, keys.sorted(),
                       "the record's keys are in whatever order the encoder's container "
                       + "produced, so two encodings of one value need not agree: \(keys)")
    }

    /// The keys of a JSON object, in the order they appear. `JSONSerialization`
    /// hands back a Dictionary and loses exactly the thing under test.
    private static func topLevelKeys(of data: Data) throws -> [String] {
        var keys: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var current = ""
        var expectingKey = false
        for byte in data {
            let ch = Character(UnicodeScalar(byte))
            if inString {
                if escaped { current.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; continue }
                if ch == "\"" {
                    inString = false
                    if expectingKey, depth == 1 { keys.append(current) }
                    continue
                }
                current.append(ch)
                continue
            }
            switch ch {
            case "{": depth += 1; expectingKey = depth == 1
            case "}": depth -= 1
            case "[": depth += 1
            case "]": depth -= 1
            case "\"": inString = true; current = ""
            case ":": expectingKey = false
            case ",": expectingKey = depth == 1
            default: break
            }
        }
        return keys
    }

    /// A single unreadable record loses ONE entity, not the whole list.
    /// That is the other half of what per-record storage buys.
    @MainActor
    func testACorruptRecordDoesNotTakeTheOthersWithIt() throws {
        let root = isolatedRoot()
        defer { releaseIsolatedRoot(root) }

        let store = HostStore()
        store.addHost(HostEntry(label: "good1", address: "a", username: "u"))
        store.addHost(HostEntry(label: "good2", address: "b", username: "u"))
        try "not json".write(
            to: root.appendingPathComponent("hosts/broken.json"), atomically: true, encoding: .utf8)

        let reread = HostStore()
        XCTAssertEqual(Set(reread.hosts.map(\.label)), ["good1", "good2"])
    }

    /// The legacy document migrates once and is RENAMED, not deleted: it is
    /// the human's whole host list, the one thing here that cannot be
    /// reconstructed, so the migration stays reversible.
    /// A store that cannot persist must SAY so. Both the encode and the
    /// write used to be `try?`, so a disk-full or a permissions change
    /// ended with save() returning normally while the human's host existed
    /// only in memory — the one failure they cannot see, because the list
    /// on screen still shows what they typed.
    @MainActor
    func testAFailedWriteIsReportedRatherThanSwallowed() throws {
        let root = isolatedRoot()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("hosts").path)
            releaseIsolatedRoot(root)
        }

        let store = HostStore()
        store.addHost(HostEntry(label: "ok", address: "a", username: "u"))
        XCTAssertTrue(store.unpersistedRecordIDs.isEmpty, "a clean save reports nothing")

        // Take away write permission on the records directory.
        let hostsDir = root.appendingPathComponent("hosts")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: hostsDir.path)

        let doomed = HostEntry(label: "lost", address: "b", username: "u")
        store.addHost(doomed)
        XCTAssertTrue(store.unpersistedRecordIDs.contains(doomed.id.uuidString),
                      "the record that did not reach disk must be named")
    }

    /// A migration that cannot write its records must NOT archive the
    /// legacy document. The first version discarded the write results and
    /// renamed unconditionally, which is data loss with a reassuring
    /// filename: the only copy of the host list moves aside while nothing
    /// takes its place.
    @MainActor
    func testMigrationKeepsTheLegacyDocumentWhenRecordsCannotBeWritten() throws {
        let root = isolatedRoot()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("hosts").path)
            releaseIsolatedRoot(root)
        }

        let legacy = root.appendingPathComponent("hosts.json")
        try JSONEncoder().encode([HostEntry(label: "only-copy", address: "a", username: "u")])
            .write(to: legacy)
        // Records directory exists but cannot be written into.
        let hostsDir = root.appendingPathComponent("hosts")
        try FileManager.default.createDirectory(at: hostsDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: hostsDir.path)

        _ = HostStore()

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path),
                      "the only copy of the host list must stay put when the migration could not land")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.appendingPathExtension("migrated").path),
            "nothing was migrated, so nothing may be archived")
    }

    /// A pre-existing archive must not silently abort the rename. It used
    /// to: moveItem throws onto an existing path, `try?` swallowed it, the
    /// legacy file stayed, and every launch migrated it AGAIN — rewriting
    /// records for hosts the human had since deleted.
    @MainActor
    func testDeletingAHostRemovesItsRecord() {
        let root = isolatedRoot()
        defer { releaseIsolatedRoot(root) }

        let store = HostStore()
        let host = HostEntry(label: "gone", address: "g", username: "u")
        store.addHost(host)
        let url = root.appendingPathComponent("hosts/\(host.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        store.removeHost(host)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a deletion must reconcile, or the host returns on the next load")
    }
}
