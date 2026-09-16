import XCTest
@testable import Synapty

/// SSH-target parsing for the Cmd+K quick-connect palette
/// (WI-2026-08-09-003).
final class QuickConnectParserTests: XCTestCase {

    func testUserHostPort() {
        XCTAssertEqual(
            QuickConnectParser.parse("root@10.0.0.5:2222"),
            SSHTarget(username: "root", host: "10.0.0.5", port: 2222)
        )
    }

    func testUserHost() {
        XCTAssertEqual(
            QuickConnectParser.parse("ubuntu@gpu-box"),
            SSHTarget(username: "ubuntu", host: "gpu-box", port: 22)
        )
    }

    func testHostPortOnly() {
        XCTAssertEqual(
            QuickConnectParser.parse("bastion.corp:2200"),
            SSHTarget(username: nil, host: "bastion.corp", port: 2200)
        )
    }

    func testDottedHostWithoutUser() {
        XCTAssertEqual(
            QuickConnectParser.parse("10.117.2.173"),
            SSHTarget(username: nil, host: "10.117.2.173", port: 22)
        )
    }

    /// A bare word stays a SEARCH query, not a connect target.
    func testBareWordIsNotATarget() {
        XCTAssertNil(QuickConnectParser.parse("otherhost"))
    }

    func testWhitespaceInsideRejected() {
        XCTAssertNil(QuickConnectParser.parse("root@my host"))
    }

    func testEmptyUserRejected() {
        XCTAssertNil(QuickConnectParser.parse("@host.com"))
    }

    func testDoubleAtRejected() {
        XCTAssertNil(QuickConnectParser.parse("a@b@c.com"))
    }

    func testPortBounds() {
        XCTAssertNil(QuickConnectParser.parse("host.com:0"))
        XCTAssertNil(QuickConnectParser.parse("host.com:65536"))
        XCTAssertNil(QuickConnectParser.parse("host.com:abc"))
        XCTAssertEqual(QuickConnectParser.parse("host.com:65535")?.port, 65535)
    }

    func testSurroundingWhitespaceTrimmed() {
        XCTAssertEqual(
            QuickConnectParser.parse("  dev@build.local  ")?.host,
            "build.local"
        )
    }

    func testDisplayElidesDefaults() {
        XCTAssertEqual(SSHTarget(username: nil, host: "a.b", port: 22).display, "a.b")
        XCTAssertEqual(SSHTarget(username: "u", host: "a.b", port: 2222).display, "u@a.b:2222")
    }
}

/// OS probe parsing + osHint semantics (WI-2026-08-09-002).
final class OSProbeTests: XCTestCase {

    /// Isolated storage — HostStore() without the override reads AND
    /// WRITES the real ~/.synapty/hosts.json (WI-2026-08-08-020; this
    /// exact omission clobbered live data once — never again).
    private var storageDir: URL!

    @MainActor
    override func setUpWithError() throws {
        storageDir = try setUpHostStoreStorage()
    }

    @MainActor
    override func tearDownWithError() throws {
        restoreStorageOverrides(storageDir)
    }

    func testParseDarwin() {
        XCTAssertEqual(OSProbe.parse("Darwin\n"), "macos")
    }

    func testParseLinuxWithOSRelease() {
        XCTAssertEqual(OSProbe.parse("Linux\nID=ubuntu\n"), "ubuntu")
        XCTAssertEqual(OSProbe.parse("Linux\nID=\"centos\"\n"), "centos")
    }

    func testParseLinuxWithoutOSRelease() {
        XCTAssertEqual(OSProbe.parse("Linux\n"), "linux")
    }

    func testParseWindows() {
        XCTAssertEqual(OSProbe.parse("MSYS_NT-10.0\n"), "windows")
    }

    func testParseGarbageIsNil() {
        XCTAssertNil(OSProbe.parse("command not found"))
        XCTAssertNil(OSProbe.parse(""))
    }

    func testGlyphMapping() {
        XCTAssertEqual(OSProbe.glyph(for: "macos"), "apple.logo")
        XCTAssertEqual(OSProbe.glyph(for: "windows"), "desktopcomputer")
        XCTAssertEqual(OSProbe.glyph(for: "ubuntu"), "terminal")
        XCTAssertEqual(OSProbe.glyph(for: "linux"), "terminal")
        XCTAssertNil(OSProbe.glyph(for: nil))
        XCTAssertNil(OSProbe.glyph(for: ""))
    }

    @MainActor
    func testDetectedOSOnlyFillsEmptyHint() {
        let store = HostStore()
        let auto = HostEntry(label: "a", address: "1.1.1.1", username: "u")
        let manual = HostEntry(label: "m", address: "2.2.2.2", username: "u", osHint: "macos")
        store.hosts = [auto, manual]

        store.setDetectedOS("ubuntu", for: auto.id)
        store.setDetectedOS("ubuntu", for: manual.id)

        XCTAssertEqual(store.hosts.first(where: { $0.id == auto.id })?.osHint, "ubuntu")
        // The manual pick is never clobbered by detection.
        XCTAssertEqual(store.hosts.first(where: { $0.id == manual.id })?.osHint, "macos")
    }

    func testOSFamilyMapping() {
        XCTAssertEqual(OSProbe.family(for: "macos"), .macos)
        XCTAssertEqual(OSProbe.family(for: "windows"), .windows)
        XCTAssertEqual(OSProbe.family(for: "ubuntu"), .linux)
        XCTAssertEqual(OSProbe.family(for: "linux"), .linux)
        XCTAssertEqual(OSProbe.family(for: "nixos"), .linux)
        XCTAssertNil(OSProbe.family(for: nil))
        XCTAssertNil(OSProbe.family(for: ""))
    }

    // MARK: - Recency (WI-2026-08-09-006)

    @MainActor
    func testMarkConnectedSetsTimestamp() {
        let store = HostStore()
        let host = HostEntry(label: "h", address: "1.1.1.1", username: "u")
        store.hosts = [host]
        XCTAssertNil(store.hosts[0].lastConnectedAt)
        store.markConnected(host.id)
        XCTAssertNotNil(store.hosts[0].lastConnectedAt)
    }

    func testByRecencyOrdering() {
        let old = HostEntry(label: "old", address: "1", username: "u",
                            lastConnectedAt: Date(timeIntervalSince1970: 100))
        let fresh = HostEntry(label: "fresh", address: "2", username: "u",
                              lastConnectedAt: Date(timeIntervalSince1970: 200))
        let neverA = HostEntry(label: "alpha", address: "3", username: "u")
        let neverB = HostEntry(label: "beta", address: "4", username: "u")

        let sorted = [neverB, old, neverA, fresh].sorted(by: HostStore.byRecency)
        XCTAssertEqual(sorted.map(\.label), ["fresh", "old", "alpha", "beta"])
    }

    func testLastConnectedAtCodableTolerance() throws {
        let legacy = #"{"label":"old","address":"9.9.9.9"}"#
        let host = try JSONDecoder().decode(HostEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(host.lastConnectedAt)

        var entry = HostEntry(label: "h", address: "1.1.1.1", username: "u")
        entry.lastConnectedAt = Date(timeIntervalSince1970: 12345)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HostEntry.self, from: data)
        XCTAssertEqual(decoded.lastConnectedAt, entry.lastConnectedAt)
    }

    @MainActor
    func testOSHintCodableRoundTripAndLegacy() throws {
        let host = HostEntry(label: "h", address: "1.1.1.1", username: "u", osHint: "debian")
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(HostEntry.self, from: data)
        XCTAssertEqual(decoded.osHint, "debian")

        let legacy = #"{"label":"old","address":"9.9.9.9"}"#
        let old = try JSONDecoder().decode(HostEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(old.osHint)
    }
}
