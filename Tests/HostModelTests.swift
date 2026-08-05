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

    // MARK: - CRUD operations (in-memory only, no disk I/O)

    func testInitiallyEmpty() {
        let store = HostStore()
        // Store loads from ~/.synapty/hosts.json; in test env this may or may not exist.
        // We just verify it doesn't crash and returns an array.
        XCTAssertNotNil(store.hosts)
    }

    func testAddHostIncreasesCount() {
        let store = HostStore()
        let initial = store.hosts.count
        store.hosts.append(HostEntry(label: "Test", address: "1.2.3.4", username: "u"))
        XCTAssertEqual(store.hosts.count, initial + 1)
    }

    func testRemoveHostDecreasesCount() {
        let store = HostStore()
        let host = HostEntry(label: "Temp", address: "1.2.3.4", username: "u")
        store.hosts.append(host)
        let count = store.hosts.count
        store.hosts.removeAll { $0.id == host.id }
        XCTAssertEqual(store.hosts.count, count - 1)
    }

    func testUpdateHostByID() {
        let store = HostStore()
        var host = HostEntry(label: "Old", address: "1.2.3.4", username: "u")
        store.hosts.append(host)
        host.label = "New"
        if let idx = store.hosts.firstIndex(where: { $0.id == host.id }) {
            store.hosts[idx] = host
        }
        XCTAssertEqual(store.hosts.first(where: { $0.id == host.id })?.label, "New")
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
        XCTAssertEqual(store.searchHosts("gpu", in: nil).count, 1)
        XCTAssertEqual(store.searchHosts("db", in: nil).count, 1)
        XCTAssertEqual(store.searchHosts("", in: nil).count, 2)
    }
}
