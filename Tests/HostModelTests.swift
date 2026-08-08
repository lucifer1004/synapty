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

    override func setUpWithError() throws {
        tempDir = try setUpHostStoreStorage()
    }

    override func tearDownWithError() throws {
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
        store.groups.append(HostGroup(id: UUID(), label: "Lab", parentID: nil))
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

    func testLegacyFlatArrayMigration() throws {
        // Old v1 format: a plain [HostEntry] array. load() must migrate it
        // to the versioned payload (and rewrite the file).
        let legacy = [
            HostEntry(label: "A", address: "1.1.1.1", username: "u1"),
            HostEntry(label: "B", address: "2.2.2.2", port: 3000, username: "u2", sshKeyPath: "/key"),
        ]
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: tempDir.appendingPathComponent("hosts.json"))

        let store = makeStore()
        XCTAssertEqual(store.hosts.count, 2)
        XCTAssertEqual(store.hosts[1].port, 3000)
        // The migration re-saves in the versioned format.
        let onDisk = try Data(contentsOf: tempDir.appendingPathComponent("hosts.json"))
        let payload = try JSONDecoder().decode(HostStore.Payload.self, from: onDisk)
        XCTAssertEqual(payload.hosts.count, 2)
    }

    func testSaveWritesRollingBackup() throws {
        let store = makeStore()
        store.hosts.append(HostEntry(label: "First", address: "1.1.1.1", username: "u"))
        store.save()

        store.hosts.append(HostEntry(label: "Second", address: "2.2.2.2", username: "u"))
        store.save()

        let backupURL = tempDir.appendingPathComponent("hosts.json.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        let backup = try JSONDecoder().decode(HostStore.Payload.self, from: Data(contentsOf: backupURL))
        // The backup holds the state BEFORE the latest save.
        XCTAssertEqual(backup.hosts.map(\.label), ["First"])
    }

    // MARK: - Groups (Termius-style)

    func testChildGroupsSorted() {
        let store = HostStore()
        let parent = HostGroup(label: "Prod")
        let childB = HostGroup(label: "B", parentID: parent.id)
        let childA = HostGroup(label: "A", parentID: parent.id)
        store.groups = [parent, childB, childA]
        let children = store.childGroups(of: parent.id)
        XCTAssertEqual(children.map(\.label), ["A", "B"])
    }

    func testHostsInGroupIncludesSubgroups() {
        let store = HostStore()
        let parent = HostGroup(label: "Prod")
        let child = HostGroup(label: "GPU", parentID: parent.id)
        store.groups = [parent, child]
        let h1 = HostEntry(label: "db", address: "1.1.1.1", username: "u", groupID: parent.id)
        let h2 = HostEntry(label: "gpu1", address: "2.2.2.2", username: "u", groupID: child.id)
        let h3 = HostEntry(label: "unassigned", address: "3.3.3.3", username: "u")
        store.hosts = [h1, h2, h3]
        XCTAssertEqual(store.hosts(inGroup: parent.id).count, 2)
        XCTAssertEqual(store.hosts(inGroup: nil).count, 1)
    }

    func testGroupPath() {
        let store = HostStore()
        let root = HostGroup(label: "Prod")
        let child = HostGroup(label: "GPU", parentID: root.id)
        store.groups = [root, child]
        XCTAssertEqual(store.groupPath(for: child.id), ["Prod", "GPU"])
        XCTAssertEqual(store.groupPath(for: nil), [])
    }

    func testRemoveGroupReparentsDescendants() {
        let store = HostStore()
        let root = HostGroup(label: "Root")
        let mid = HostGroup(label: "Mid", parentID: root.id)
        let leaf = HostGroup(label: "Leaf", parentID: mid.id)
        store.groups = [root, mid, leaf]
        store.removeGroup(mid)
        // mid's children (leaf) reparent to mid's parent (root).
        XCTAssertEqual(store.groups.first(where: { $0.id == leaf.id })?.parentID, root.id)
        XCTAssertNil(store.groups.first(where: { $0.id == mid.id }))
        XCTAssertEqual(store.groups.count, 2) // root + leaf
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

    func testEffectiveUsernameFromGroupChain() {
        let store = HostStore()
        let parent = HostGroup(label: "Prod", username: "deploy")
        let child = HostGroup(label: "GPU", parentID: parent.id)
        store.groups = [parent, child]
        let host = HostEntry(label: "gpu1", address: "10.0.1.5", username: "", groupID: child.id)
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
          "address":"100.86.153.75","port":22,"username":"zihuaw",
          "sshKeyPath":"/Users/zihuaw/.ssh/id_ed25519"}]
        """
        let data = legacyJSON.data(using: .utf8)!
        let hosts = try JSONDecoder().decode([HostEntry].self, from: data)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].label, "GPU Box")
        XCTAssertEqual(hosts[0].address, "100.86.153.75")
        XCTAssertEqual(hosts[0].username, "zihuaw")
        XCTAssertEqual(hosts[0].sshKeyPath, "/Users/zihuaw/.ssh/id_ed25519")
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
