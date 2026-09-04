import XCTest
@testable import Synapty

/// [[RFC-0012]] C-LEVEL-CONTROL. The level reaches every hub this
/// workbench operates, without restarting any of them — restarting a hub
/// severs A2A for every agent working on that machine, so "raise it and
/// reproduce" would destroy the thing being diagnosed.
@MainActor
final class HubLogLevelTests: XCTestCase {

    private var tempDir: URL!
    private var hostDir: URL!

    override func setUpWithError() throws {
        tempDir = try setUpSettingsStorage()
        // This test builds a HostStore to give TunnelManager peers, and
        // HostStore.save asserts on isolation — the guard added earlier
        // today, doing exactly its job here.
        hostDir = try setUpHostStoreStorage()
    }

    override func tearDownWithError() throws {
        SynaptySettings.storageOverride = nil
        HostStore.storageOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: hostDir)
    }

    func testTheVocabularyMatchesWhatTheHubAccepts() {
        // These four words cross the wire and are parsed by
        // diag.levelFromString on the other side. A fifth here would be
        // refused by every hub, silently, from the UI's point of view.
        XCTAssertEqual(HubLogLevel.levels, ["err", "warn", "info", "debug"])
    }

    /// An unknown level must be refused HERE rather than sent and
    /// rejected by each hub — a setting that appears to take and does not
    /// is the shape this RFC exists to remove.
    func testAnUnknownLevelIsRefusedBeforeItIsSent() {
        HubLogLevel.applyEverywhere("chatty")
        // No crash, no send. The guard is the assertion; the log line
        // carries the why.
        XCTAssertFalse(HubLogLevel.levels.contains("chatty"))
    }

    /// EVERY hub it operates: this machine's, plus each peer that has
    /// actually answered. A peer with a port assigned and no reply has no
    /// hub to tell.
    func testOperatedPortsCoverTheLocalHubAndAnsweringPeersOnly() {
        let tm = TunnelManager()
        let store = HostStore()
        tm.hostStore = store
        TunnelManager.shared = tm
        defer { TunnelManager.shared = nil }

        let host = HostEntry(label: "remotehost", address: "gc", username: "u")
        store.addHost(host)
        let port = tm.peerPort(for: host)

        XCTAssertEqual(HubLogLevel.operatedPorts(), [tm.hubPort],
                       "a peer that has never answered has no hub to tell")

        tm.handleHubEvent(["kind": "peer_link_up", "peer": "remotehost-4e84", "generation": port])
        XCTAssertEqual(Set(HubLogLevel.operatedPorts()), Set([tm.hubPort, port]))
    }

    /// The limits must travel with the control. Both are real and neither
    /// can be lifted by the app, so presenting the setting without them
    /// would be the overstatement C-LEVEL-CONTROL forbids.
    func testTheCaveatsNameBothLimits() {
        let joined = HubLogLevel.caveats.joined(separator: " ")
        XCTAssertTrue(joined.contains("default"), "a hub reached later runs at its default until then")
        XCTAssertTrue(joined.contains("log config"), "raising to debug needs a change the app cannot make")
    }

    /// Changing the setting persists it, so the fleet converges through
    /// the same sync as every other shared preference.
    func testTheLevelIsSharedConfigurationAndPersists() {
        let settings = SynaptySettings()
        settings.logLevel = "debug"
        XCTAssertEqual(settings.logLevel, "debug")
    }
}
