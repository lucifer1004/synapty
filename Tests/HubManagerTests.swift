import XCTest
@testable import Synapty

/// WI-2026-08-12-001 / [[ADR-0008]]: the adoption handshake. Silently
/// adopting a version-skewed hub is the exact failure that started this
/// line of work, so the decision is a pure function and tested per case.
final class HubManagerTests: XCTestCase {

    private func info(build: String, spawned: Bool, supervisors: Int? = 0) -> HubManager.HubInfo {
        HubManager.HubInfo(
            build: build, pid: 4242, workbenchSpawned: spawned, port: 9000,
            supervisors: supervisors)
    }

    func testAdoptsOnBuildMatch() {
        XCTAssertEqual(
            HubManager.decideAdoption(info: info(build: "abc123", spawned: true), expectedBuild: "abc123"),
            .adopt)
        // An adopted SERVICE hub (not workbench-spawned) is equally fine
        // when the build matches — that is the remote/detached case.
        XCTAssertEqual(
            HubManager.decideAdoption(info: info(build: "abc123", spawned: false), expectedBuild: "abc123"),
            .adopt)
    }

    /// Two sides that could not determine their build are two absences,
    /// not agreement.
    ///
    /// This is the shape the check had for its entire life: both sides
    /// reported the constant "dev", so every comparison succeeded and no
    /// skew was detectable (WI-2026-08-14-005). "unknown" is now the only
    /// value either side reports when it does not know, and it must never
    /// match itself.
    func testTwoUnknownBuildsDoNotAdopt() {
        XCTAssertEqual(
            HubManager.decideAdoption(info: info(build: "unknown", spawned: true), expectedBuild: "unknown"),
            .takeOver)
        guard case .conflict = HubManager.decideAdoption(
            info: info(build: "unknown", spawned: false), expectedBuild: "unknown")
        else { return XCTFail("an unknown foreign hub must be surfaced, not adopted") }
    }

    func testTakesOverItsOwnStaleHub() {
        // A workbench-spawned hub from a previous generation is ours to
        // replace. This is precisely the case that used to be adopted
        // silently, leaving a new GUI talking to an old router.
        XCTAssertEqual(
            HubManager.decideAdoption(info: info(build: "old", spawned: true), expectedBuild: "new"),
            .takeOver)
    }

    func testRefusesForeignListenerLoudly() {
        // Someone else's hub with a different build: not ours to kill,
        // not safe to use. The human must be told.
        guard case .conflict = HubManager.decideAdoption(
            info: info(build: "other", spawned: false), expectedBuild: "mine")
        else { return XCTFail("a foreign build mismatch must be a conflict") }

        // A listener that does not answer hub_info at all is never
        // assumed to be a hub.
        guard case .conflict = HubManager.decideAdoption(info: nil, expectedBuild: "mine")
        else { return XCTFail("an unidentified listener must be a conflict") }
    }

    func testPreferredPortHonoursTheSingleOverride() {
        // Without the env var the default stands; the hub's own ladder
        // handles contention from there.
        XCTAssertEqual(HubManager.preferredPort(), 9000)
    }
}

extension HubManagerTests {

    /// The hub outlives the workbench, so hub_info has to be able to say
    /// what it is already peered with. A workbench that assumed otherwise
    /// held no subscription and no port assignment while the hub was
    /// federated — which disabled the merged view's rich data and made the
    /// redial guard fail for want of a port.
    func testParsePeersReadsWhatTheHubAlreadyHolds() {
        let peers = HubManager.parsePeers([
            "peers": [
                ["peer": "remotehost", "port": 9202],
                ["peer": "buildbox", "port": 9203],
            ]
        ])
        XCTAssertEqual(peers.count, 2)
        XCTAssertEqual(peers.first?.peer, "remotehost")
        XCTAssertEqual(peers.first?.port, 9202)
    }

    func testAcceptedLinksAndGarbageAreNotAdoptable() {
        // port 0 means the hub ACCEPTED that link rather than dialing it:
        // there is no local port that reaches the peer, so there is
        // nothing for a workbench to re-establish.
        let peers = HubManager.parsePeers([
            "peers": [
                ["peer": "inbound", "port": 0],
                ["peer": "", "port": 9202],
                ["port": 9203],
                ["peer": "ok", "port": 9204],
            ]
        ])
        XCTAssertEqual(peers.map(\.peer), ["ok"])
        XCTAssertTrue(HubManager.parsePeers([:]).isEmpty)
        XCTAssertTrue(HubManager.parsePeers(["peers": "not an array"]).isEmpty)
    }
}

extension HubManagerTests {

    /// WI-2026-08-12-016: what a peer does NOT provide is the part a human
    /// needs, and it is only derivable from what it declared it does.
    func testPeerCapabilitiesDistinguishEmptyFromAbsent() {
        let caps = HubManager.parsePeerCapabilities([
            "peers": [
                ["peer": "modern-7f3a", "port": 9202, "capabilities": ["presence_relay"]],
                ["peer": "oldbuild-1c4e", "port": 9203, "capabilities": []],
            ]
        ])
        XCTAssertEqual(caps["modern-7f3a"], ["presence_relay"])
        // Present with NOTHING is a real state and must not read as absent:
        // that peer is linked and provides nothing optional, which is the
        // whole case this exists to make visible.
        XCTAssertEqual(caps["oldbuild-1c4e"], [])
        XCTAssertNil(caps["never-linked"])
    }

    func testMissingCapabilitiesKeyIsAnEmptySetNotADrop() {
        // A pre-negotiation hub answers hub_info without the field at all.
        // It is still a linked peer that provides nothing optional.
        let caps = HubManager.parsePeerCapabilities([
            "peers": [["peer": "ancient-0001", "port": 9204]]
        ])
        XCTAssertEqual(caps["ancient-0001"], [])
    }

    /// A hub another workbench is USING is not a stale hub.
    ///
    /// Takeover SIGTERMs, so a live second instance would have its A2A
    /// pulled out from under it. The machine's hub is meant to be REUSED
    /// by a second instance — one identity, one discovery entry, one set
    /// of agents that can see each other ([[WI-2026-08-14-009]]).
    func testDoesNotTakeOverAHubAnotherWorkbenchIsUsing() {
        guard case .conflict = HubManager.decideAdoption(
            info: info(build: "other", spawned: true, supervisors: 1),
            expectedBuild: "mine")
        else { return XCTFail("a hub with a live supervisor must not be terminated") }

        // With no supervisor it IS stale, and reclaiming is correct.
        XCTAssertEqual(
            HubManager.decideAdoption(
                info: info(build: "other", spawned: true, supervisors: 0),
                expectedBuild: "mine"),
            .takeOver)
    }

    /// A matching build is adopted whether or not someone else is on it —
    /// that IS the second-instance case, and sharing is the point.
    func testASecondInstanceOfTheSameBuildAdoptsRatherThanReplacing() {
        XCTAssertEqual(
            HubManager.decideAdoption(
                info: info(build: "same", spawned: true, supervisors: 1),
                expectedBuild: "same"),
            .adopt)
    }

    /// A hub that CANNOT SAY whether it is in use must not be terminated.
    ///
    /// A hub built before the supervisor count existed reports no such
    /// field, and defaulting that to zero reads "nobody is using it" —
    /// which would kill a live workbench's hub during exactly the upgrade
    /// window the guard exists for ([[WI-2026-08-14-015]]).
    func testAHubThatCannotReportItsSupervisorsIsNotTakenOver() {
        guard case .conflict = HubManager.decideAdoption(
            info: info(build: "old", spawned: true, supervisors: nil),
            expectedBuild: "new")
        else { return XCTFail("silence must not be read as 'nobody is using it'") }
    }
}

// MARK: - Loss and recovery ([[WI-2026-09-02-029]])

/// A hub that goes away is announced once and comes back on its own. The
/// policy is pure so the backoff, the give-up and the one-announcement
/// rule are each a line to read, not a timer to wait on.
final class HubRecoveryTests: XCTestCase {

    func testTheBackoffDoublesFromOneSecondAndThenGivesUp() {
        XCTAssertEqual(HubManager.nextRecovery(afterAttempts: 0), .retry(afterSeconds: 1))
        XCTAssertEqual(HubManager.nextRecovery(afterAttempts: 1), .retry(afterSeconds: 2))
        XCTAssertEqual(HubManager.nextRecovery(afterAttempts: 4), .retry(afterSeconds: 16))
        XCTAssertEqual(HubManager.nextRecovery(afterAttempts: 5), .giveUp)
        XCTAssertEqual(HubManager.nextRecovery(afterAttempts: 9), .giveUp)
    }

    /// A crash loop is ONE outage: the first loss is announced, the losses
    /// that follow while it stands are not.
    func testOnlyTheFirstLossOfAnOutageIsAnnounced() {
        let (first, announce1) = HubManager.Outage.noticed(nil)
        XCTAssertTrue(announce1)
        var standing = first
        standing.attempts = 2
        let (same, announce2) = HubManager.Outage.noticed(standing)
        XCTAssertFalse(announce2)
        XCTAssertEqual(same, standing, "the attempts already made are not forgotten")
    }

    /// One silent probe is a slow hub after wake; two, a grace apart, is a
    /// loss. Spawning beside a live hub is what this protects against.
    func testALossNeedsTwoSilentProbes() {
        let alive = HubManager.HubInfo(build: "b", pid: 1, workbenchSpawned: true, port: 9000, supervisors: 0)
        XCTAssertFalse(HubManager.lossConfirmed(first: nil, second: alive))
        XCTAssertFalse(HubManager.lossConfirmed(first: alive, second: nil))
        XCTAssertTrue(HubManager.lossConfirmed(first: nil, second: nil))
    }

    /// The adopted-hub signal, driven end to end with an injected probe:
    /// a disconnect while the port still answers changes nothing, and one
    /// where it stays silent through the grace becomes a loss.
    @MainActor
    func testADisconnectIsALossOnlyWhenThePortStaysSilent() async {
        let manager = HubManager()
        manager.lossGrace = 0.05
        var answers: [HubManager.HubInfo?] = [
            HubManager.HubInfo(build: "b", pid: 1, workbenchSpawned: false, port: 9000, supervisors: 1),
        ]
        let lock = NSLock()
        manager.probe = { _ in lock.withLock { answers.isEmpty ? nil : answers.removeFirst() } }
        manager.adoptForTesting(port: 9000)

        manager.subscriberDisconnected()
        await settle()
        XCTAssertTrue(manager.status.isRunning, "a hub that still answers was not lost")

        manager.subscriberDisconnected()
        await settle()
        guard case .lost(let why, let attempt) = manager.status else {
            return XCTFail("expected lost, got \(manager.status)")
        }
        XCTAssertTrue(why.contains("9000"), why)
        XCTAssertEqual(attempt, 0)
        XCTAssertNil(manager.boundPort)
    }

    /// The spawned-hub signal: our own process exiting is a loss too, and
    /// a shutdown we asked for is not.
    @MainActor
    func testAnExitWeAskedForIsNotALoss() {
        let manager = HubManager()
        manager.adoptForTesting(port: 9000)
        manager.shutdown()
        XCTAssertEqual(manager.status, .stopped)
        manager.hubLost("the hub exited with code 1")
        XCTAssertTrue(manager.status.isRecovering)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}

/// WHAT THE HUMAN IS TOLD WHEN A HUB IS REFUSED ([[WI-2026-09-04-001]]).
///
/// `decideAdoption` produces a reason and `Status.label` spells it, and
/// both surfaces that a human actually reads threw it away: the status bar
/// said "Hub: down" and the popover said "The hub is not running", with a
/// Start button that cannot help. A hub of the wrong build IS running —
/// down is what a crash looks like, and it suggests waiting or restarting,
/// which is exactly what does not resolve a build conflict.
final class HubRefusalWordingTests: XCTestCase {

    func testARefusedHubIsNotDescribedAsDown() {
        let why = "a hub of build old is here and cannot say whether it is in use"
        let status = HubManager.HubStatus.conflict(why)

        XCTAssertFalse(status.isRunning)
        XCTAssertFalse(status.isRecovering)
        // The distinction the two surfaces need, and did not have.
        XCTAssertTrue(status.isRefused,
                      "a conflict must be tellable from a hub that is simply not there")
        XCTAssertEqual(status.refusalReason, why)
    }

    func testAHubThatIsSimplyAbsentIsNotARefusal() {
        XCTAssertFalse(HubManager.HubStatus.stopped.isRefused)
        XCTAssertFalse(HubManager.HubStatus.failed("no binary").isRefused)
        XCTAssertFalse(HubManager.HubStatus.lost("socket closed", attempt: 0).isRefused)
        XCTAssertNil(HubManager.HubStatus.stopped.refusalReason)
    }
}
