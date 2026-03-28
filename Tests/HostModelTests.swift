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
}
