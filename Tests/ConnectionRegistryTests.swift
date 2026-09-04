import XCTest
@testable import Synapty

/// [[RFC-0015]] C-CONNECTION, C-DIAL, C-RELEASE: a connection is a shared
/// resource with a reference count, not a container.
@MainActor
final class ConnectionRegistryTests: XCTestCase {

    private func makeHost(_ label: String) -> HostEntry {
        HostEntry(label: label, address: "10.0.0.1", username: "u")
    }

    /// A clock the test moves by hand — the grace period is measured in
    /// tens of seconds and no test may wait for one.
    private func makeRegistry() -> (ConnectionRegistry, () -> Void) {
        let registry = ConnectionRegistry()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        registry.now = { clock }
        return (registry, { clock += registry.grace + 1 })
    }

    // MARK: - One connection per host (C-CONNECTION)

    func testSecondLeafOnSameHostReusesTheConnection() {
        let (registry, _) = makeRegistry()
        let host = makeHost("remotehost")

        guard case .opened(let first) = registry.acquire(host: host) else {
            return XCTFail("the first acquisition must open a connection")
        }
        guard case .reused(let second) = registry.acquire(host: host) else {
            return XCTFail("the second acquisition must reuse, not dial again")
        }
        XCTAssertEqual(first, second)
        XCTAssertEqual(registry.remoteConnections.count, 1)
    }

    func testTwoHostsGetTwoConnections() {
        let (registry, _) = makeRegistry()
        guard case .opened(let a) = registry.acquire(host: makeHost("remotehost")),
              case .opened(let b) = registry.acquire(host: makeHost("otherhost"))
        else { return XCTFail("each host opens its own connection") }
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(registry.remoteConnections.count, 2)
    }

    /// A host still dialling is still THE connection for that host — a
    /// second pane opened before the first has answered must attach to
    /// the dial in flight rather than starting another (C-DIAL).
    func testAcquiringAHostThatIsStillDiallingReusesTheDialInFlight() {
        let (registry, _) = makeRegistry()
        let host = makeHost("remotehost")
        guard case .opened(let id) = registry.acquire(host: host) else {
            return XCTFail("first acquisition opens")
        }
        XCTAssertEqual(registry.connection(id)?.state, .connecting)
        guard case .reused(let again) = registry.acquire(host: host) else {
            return XCTFail("a dial in flight must be joined, not duplicated")
        }
        XCTAssertEqual(id, again)
    }

    // MARK: - Local is a connection like any other (C-CONNECTION)

    func testLocalConnectionExistsAndIsConnected() {
        let (registry, _) = makeRegistry()
        let local = registry.connection(registry.localID)
        XCTAssertNotNil(local)
        XCTAssertTrue(local!.isLocal)
        XCTAssertEqual(local!.state, .connected)
    }

    /// "Never released" is the claim; this is the sweep that would do it.
    func testLocalConnectionIsNeverReleasedEvenWithNoLeaves() {
        let (registry, advancePastGrace) = makeRegistry()
        registry.updateReferences([])
        advancePastGrace()
        registry.sweep()
        XCTAssertNotNil(registry.connection(registry.localID))
    }

    // MARK: - Release (C-RELEASE)

    func testConnectionSurvivesWhileALeafStillReferencesIt() {
        let (registry, advancePastGrace) = makeRegistry()
        guard case .opened(let id) = registry.acquire(host: makeHost("remotehost")) else { return XCTFail() }
        registry.updateReferences([id])
        advancePastGrace()
        registry.sweep()
        XCTAssertNotNil(registry.connection(id), "a referenced connection must never be released")
    }

    /// The failure that would be immediately visible: closing one of two
    /// panes on a host tearing down the link the other is using.
    func testClosingOneOfTwoLeavesLeavesTheLinkUp() {
        let (registry, advancePastGrace) = makeRegistry()
        let host = makeHost("remotehost")
        guard case .opened(let id) = registry.acquire(host: host) else { return XCTFail() }
        _ = registry.acquire(host: host)

        registry.updateReferences([id, id])
        registry.updateReferences([id])          // one pane closed
        advancePastGrace()
        registry.sweep()

        XCTAssertNotNil(registry.connection(id), "the surviving pane's link must stay up")
    }

    func testConnectionIsNotReleasedBeforeTheGracePeriodElapses() {
        let (registry, _) = makeRegistry()
        guard case .opened(let id) = registry.acquire(host: makeHost("remotehost")) else { return XCTFail() }
        registry.updateReferences([id])
        registry.updateReferences([])
        registry.sweep()                          // clock has not moved
        XCTAssertNotNil(registry.connection(id), "release must wait out the grace period")
    }

    func testConnectionIsReleasedOnceUnreferencedPastTheGracePeriod() {
        let (registry, advancePastGrace) = makeRegistry()
        var released: [HostEntry] = []
        registry.onRelease = { released.append($0.host!) }
        guard case .opened(let id) = registry.acquire(host: makeHost("remotehost")) else { return XCTFail() }
        registry.updateReferences([id])
        registry.updateReferences([])
        advancePastGrace()
        registry.sweep()

        XCTAssertNil(registry.connection(id))
        XCTAssertEqual(released.map(\.label), ["remotehost"],
                       "release must hand the transport back for closing")
    }

    /// The grace period exists to absorb churn: closing a pane and opening
    /// another on the same host is one gesture, not a teardown.
    func testReacquiringWithinTheGracePeriodCancelsThePendingRelease() {
        let (registry, advancePastGrace) = makeRegistry()
        let host = makeHost("remotehost")
        guard case .opened(let id) = registry.acquire(host: host) else { return XCTFail() }
        registry.updateReferences([id])
        registry.updateReferences([])

        guard case .reused(let again) = registry.acquire(host: host) else {
            return XCTFail("the connection is still there to be reused")
        }
        XCTAssertEqual(id, again)
        registry.updateReferences([id])
        advancePastGrace()
        registry.sweep()
        XCTAssertNotNil(registry.connection(id), "reacquiring must cancel the pending release")
    }

    /// An explicit act does not wait — archive and quit release at once.
    func testReleaseNowSkipsTheGracePeriod() {
        let (registry, _) = makeRegistry()
        var released = 0
        registry.onRelease = { _ in released += 1 }
        guard case .opened(let id) = registry.acquire(host: makeHost("remotehost")) else { return XCTFail() }
        registry.updateReferences([])
        registry.releaseNow(id)
        XCTAssertNil(registry.connection(id))
        XCTAssertEqual(released, 1)
    }

    func testReleaseNowRefusesToReleaseAReferencedConnection() {
        let (registry, _) = makeRegistry()
        guard case .opened(let id) = registry.acquire(host: makeHost("remotehost")) else { return XCTFail() }
        registry.updateReferences([id])
        registry.releaseNow(id)
        XCTAssertNotNil(registry.connection(id),
                        "an explicit release must still not cut a link something is using")
    }

    func testReleaseNowWillNotReleaseLocal() {
        let (registry, _) = makeRegistry()
        registry.updateReferences([])
        registry.releaseNow(registry.localID)
        XCTAssertNotNil(registry.connection(registry.localID))
    }

    // MARK: - State (C-FAILURE)

    func testFailureCarriesItsReason() {
        let (registry, _) = makeRegistry()
        guard case .opened(let id) = registry.acquire(host: makeHost("remotehost")) else { return XCTFail() }
        registry.markFailed(id, "no route to host")
        XCTAssertEqual(registry.connection(id)?.state, .failed("no route to host"))
    }

    // MARK: - Somebody has to ask (C-RELEASE)

    /// THE WHOLE RELEASE PATH WAS UNREACHABLE and every registry test
    /// passed: `sweep()` was called only from this file, and `onRelease`
    /// was wired to nothing — so a connection could be released in
    /// principle while the running app never asked and never hung up the
    /// ssh. These hold the manager to doing both.
    func testTheManagerAsksTheRegistryToReleaseAndHangsUp() {
        let manager = WorkspaceManager()
        var hungUp: [String] = []
        manager.startReleasingIdleConnections()
        // The production wiring reaches for TunnelManager; this replaces
        // it, because what needs proving is that SOMETHING is called.
        manager.connections.onRelease = { hungUp.append($0.host?.label ?? "local") }

        guard case .opened(let id) = manager.connections.acquire(host: makeHost("remotehost"))
        else { return XCTFail() }
        manager.connections.updateReferences([id])
        manager.connections.updateReferences([])
        manager.connections.grace = 0
        manager.connections.sweep()

        XCTAssertEqual(hungUp, ["remotehost"],
                       "releasing a connection must close the transport behind it")
    }

    /// Quitting does not wait out the grace period.
    func testQuittingReleasesEveryConnectionAtOnce() {
        let manager = WorkspaceManager()
        var hungUp = 0
        manager.startReleasingIdleConnections()
        manager.connections.onRelease = { _ in hungUp += 1 }
        manager.connections.acquire(host: makeHost("remotehost"))
        manager.connections.acquire(host: makeHost("otherhost"))

        manager.releaseAllConnections()

        XCTAssertEqual(hungUp, 2)
        XCTAssertTrue(manager.connections.remoteConnections.isEmpty)
    }

    /// A failed connection is still the host's connection: reconnecting
    /// re-dials it rather than opening a second one (C-DIAL).
    func testRedialReusesTheFailedConnectionRatherThanOpeningASecond() {
        let (registry, _) = makeRegistry()
        let host = makeHost("remotehost")
        guard case .opened(let id) = registry.acquire(host: host) else { return XCTFail() }
        registry.markFailed(id, "no route to host")

        registry.redial(id)
        XCTAssertEqual(registry.connection(id)?.state, .connecting)
        XCTAssertEqual(registry.remoteConnections.count, 1)
    }
}
