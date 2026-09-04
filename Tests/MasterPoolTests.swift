import XCTest
@testable import Synapty

/// [[RFC-0013]] C-BROKER: a host's connections are a pool whose size is
/// observed, not declared. [[WI-2026-08-26-001]].
///
/// The opener is injected and writes the socket file itself, because the
/// property under test is that MEMBERSHIP IS THE FILESYSTEM — a pool that
/// answered from memory would pass a test whose fake opener recorded
/// nothing, and then leave masters running after a crash.
@MainActor
final class MasterPoolTests: XCTestCase {

    private var dir: URL!
    private var pool: MasterPool!
    private var opened: [String] = []
    private var closed: [String] = []
    private var openShouldFail = false

    private let key = MasterPool.HostKey(userAtHost: "u@10.0.0.1", port: 22)

    /// A NAME PER CALL, because claiming is idempotent per tenant: two
    /// channels are two names, and a test that reused one would be
    /// asserting about one channel while believing it had two.
    private var minted = 0
    private func t() -> String { minted += 1; return "pane.test.\(minted)" }


    override func setUpWithError() throws {
        dir = try TestTempStorage.makeDir()
        MasterPool.socketDirectoryOverride = dir
        MasterPool.tenantDirectoryOverride = dir.appendingPathComponent("tenants")
        opened = []; closed = []; openShouldFail = false
        pool = MasterPool()
        pool.openMaster = { [weak self] _, path in
            guard let self, !self.openShouldFail else { return false }
            self.opened.append(path)
            FileManager.default.createFile(atPath: path, contents: nil)
            return true
        }
        pool.closeMaster = { [weak self] _, path in
            self?.closed.append(path)
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    override func tearDown() {
        MasterPool.socketDirectoryOverride = nil
        MasterPool.tenantDirectoryOverride = nil
        TestTempStorage.removeDir(dir)
        super.tearDown()
    }

    private func name(_ path: String?) -> String {
        (path as NSString?)?.lastPathComponent ?? "<nil>"
    }

    // MARK: - Nothing is pre-opened

    func testAFreshPoolHoldsNothing() {
        XCTAssertEqual(pool.members(for: key), [],
                       "a host nobody has reached holds no connections")
    }

    func testSeveralOrdinaryChannelsShareOneConnection() {
        let a = pool.place(key, tenant: t())
        let b = pool.place(key, tenant: t())
        let c = pool.place(key, tenant: t())
        XCTAssertEqual(a, b); XCTAssertEqual(b, c)
        XCTAssertEqual(pool.members(for: key).count, 1,
                       "an unloaded host stays at one connection")
        XCTAssertEqual(opened.count, 1)
    }

    // MARK: - The record is the slot, whoever wrote it

    /// THE CASE THE TWO COPIES DISAGREED ON. The first pane on a host got
    /// no socket from the pool — nothing was open yet — so the launch
    /// script resolved one itself and wrote it into the pane's file, while
    /// this object's separate ledger counted nothing. The pane rode a
    /// connection the pool believed was empty.
    ///
    /// There is no ledger now: the file IS the slot, so a record this
    /// process did not write counts exactly like one it did.
    func testASlotRecordedBySomebodyElseCountsLikeAnyOther() {
        let base = pool.primary(for: key)
        FileManager.default.createFile(atPath: base, contents: nil)
        // Exactly what the launch script writes when it resolved its own.
        pool.claim(tenant: "pane.builder.local-1a2b", on: base)

        XCTAssertNotEqual(pool.placeExclusive(key, tenant: "transfer.a"), base,
                          "a transfer must not take a connection a pane is already on")
    }

    /// AND RELEASING IS DELETING THE RECORD, so there is no count to get
    /// wrong — releasing something that was never claimed changes nothing
    /// rather than pushing a counter below zero.
    func testReleasingSomethingNeverClaimedIsHarmless() {
        let base = pool.primary(for: key)
        FileManager.default.createFile(atPath: base, contents: nil)
        pool.claim(tenant: "pane.builder.local-1a2b", on: base)
        pool.release(tenant: "pane.builder.never-existed")

        XCTAssertNotEqual(pool.placeExclusive(key, tenant: "transfer.a"), base,
                          "the pane's slot survives a release aimed at nobody")
    }

    /// A RECORD NAMING A CONNECTION THIS HOST NO LONGER HOLDS IS IGNORED,
    /// which is what makes the records self-cleaning across a crash: a
    /// pane whose process died leaves its file, and the connection it
    /// named is gone at the next teardown.
    func testARecordNamingADeadConnectionDoesNotCount() {
        let base = pool.primary(for: key)
        FileManager.default.createFile(atPath: base, contents: nil)
        pool.claim(tenant: "pane.builder.ghost", on: dir.appendingPathComponent("u@10.0.0.1:22#9").path)

        XCTAssertEqual(pool.placeExclusive(key, tenant: "transfer.a"), base,
                       "a record for a connection that is gone must not make a live one look busy")
    }

    // MARK: - A transfer gets a connection carrying nothing else

    func testATransferDoesNotLandOnAConnectionCarryingAPane() {
        let pane = pool.place(key, tenant: t())
        let transfer = pool.placeExclusive(key, tenant: t())
        XCTAssertNotEqual(pane, transfer,
                          "a transfer sharing a connection with a pane is what C-BROKER measured at 17.90s")
        XCTAssertEqual(pool.members(for: key).count, 2)
    }

    func testATransferReusesAConnectionThatIsCarryingNothing() {
        let pane = pool.place(key, tenant: "pane.a")
        let first = pool.placeExclusive(key, tenant: "transfer.a")
        pool.release(tenant: "transfer.a")
        let second = pool.placeExclusive(key, tenant: "transfer.b")
        XCTAssertEqual(first, second, "an idle connection is free for the next transfer")
        XCTAssertNotEqual(second, pane)
        XCTAssertEqual(pool.members(for: key).count, 2, "nothing grew for the second transfer")
    }

    func testTwoTransfersAtOnceDoNotShare() {
        let a = pool.placeExclusive(key, tenant: t())
        let b = pool.placeExclusive(key, tenant: t())
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Placement goes to the least loaded

    func testANewChannelLandsOnTheConnectionCarryingTheFewest() {
        // Two connections exist because a transfer forced a second one.
        let first = pool.place(key, tenant: "pane.a")
        _ = pool.place(key, tenant: "pane.b")            // first now carries two
        let second = pool.placeExclusive(key, tenant: "transfer.a")
        pool.release(tenant: "transfer.a")  // second now carries none

        XCTAssertEqual(pool.place(key, tenant: t()), second,
                       "the emptier connection takes the next channel")
        XCTAssertNotEqual(pool.place(key, tenant: t()), first)
    }

    // MARK: - A refused channel grows the pool (the remote session bound)

    func testARefusedChannelOpensAnotherConnectionAndPlacesTheChannelThere() {
        let first = pool.place(key, tenant: t())
        let retry = pool.placeAfterRefusal(on: first!, key, tenant: t())
        XCTAssertNotNil(retry)
        XCTAssertNotEqual(retry, first, "the channel retries somewhere it can actually open")
        XCTAssertEqual(pool.members(for: key).count, 2)
    }

    /// AND SOMETHING SHIPPED HAS TO ASK. `placeAfterRefusal` had these
    /// tests and no production caller for a fortnight, because the half
    /// that shipped was DETECTION: the heartbeat probes each member and
    /// marks a refusing one full, so demand arriving LATER is placed
    /// elsewhere. A transfer that walked into the bound between two probes
    /// simply failed with the remote's own message, and the pool learnt
    /// nothing from it — which is a wait, not the retry the clause asks
    /// for.
    func testARealChannelRefusalMovesTheCopyToAnotherConnection() {
        let tenant = t()
        guard let first = pool.place(key, tenant: tenant) else { return XCTFail("no socket") }
        let binding = TransferPlan.PoolBinding(pool: pool, key: key, tenant: tenant)
        let from = TransferPlan.Leg.remote(
            RemoteConnection(userAtHost: key.userAtHost, port: 22, controlPath: first),
            path: "/srv/artifact.bin")
        let plan = TransferPlan(from: from, to: .local("/tmp"), fromPool: binding)

        // THE MESSAGE A REAL REFUSAL CARRIES, not a paraphrase.
        let moved = TransferRunner.movedAfterRefusal(
            "mux_client_request_session: session request failed: "
                + MasterPool.channelRefusal,
            from: from, to: .local("/tmp"), plan: plan)

        guard case .remote(let connection, let path)? = moved?.from else {
            return XCTFail("the copy was not moved")
        }
        XCTAssertNotEqual(connection.controlPath, first,
                          "it retried on the connection that had just said no")
        XCTAssertEqual(path, "/srv/artifact.bin", "the same copy, elsewhere")
        XCTAssertTrue(pool.isFullForTesting(first),
                      "the refusing connection was not marked, so it will be offered again")
        XCTAssertEqual(pool.members(for: key).count, 2)
    }

    /// A FAILURE THAT IS NOT A REFUSAL MUST NOT GROW THE POOL. Every scp
    /// error would otherwise open a connection, which is the opposite of a
    /// pool whose size is observed.
    func testAnOrdinaryFailureNeitherMovesTheCopyNorGrowsThePool() {
        let tenant = t()
        guard let first = pool.place(key, tenant: tenant) else { return XCTFail("no socket") }
        let binding = TransferPlan.PoolBinding(pool: pool, key: key, tenant: tenant)
        let from = TransferPlan.Leg.remote(
            RemoteConnection(userAtHost: key.userAtHost, port: 22, controlPath: first),
            path: "/srv/artifact.bin")
        let plan = TransferPlan(from: from, to: .local("/tmp"), fromPool: binding)

        XCTAssertNil(TransferRunner.movedAfterRefusal(
            "scp: /srv/artifact.bin: No such file or directory",
            from: from, to: .local("/tmp"), plan: plan))
        XCTAssertFalse(pool.isFullForTesting(first))
        XCTAssertEqual(pool.members(for: key).count, 1)
    }

    func testAConnectionThatRefusedIsNotOfferedAgainWhileItIsFull() {
        let first = pool.place(key, tenant: t())
        _ = pool.placeAfterRefusal(on: first!, key, tenant: t())
        // `first` carries one channel; the second carries one. Least-loaded
        // alone would be a coin toss, and half the time it picks the one
        // that has already said no.
        for _ in 0..<5 {
            XCTAssertNotEqual(pool.place(key, tenant: t()), first,
                              "a connection at its session bound must not be offered again")
        }
    }

    /// The bound is found by walking into it, and recording that is a
    /// separate act from placing anything: the probe that discovered it is
    /// not a channel anybody wanted.
    func testAConnectionFoundToBeAtItsBoundStopsTakingChannels() {
        let first = pool.place(key, tenant: t())
        pool.markFull(socket: first!)
        XCTAssertTrue(pool.isFullForTesting(first!))

        let next = pool.place(key, tenant: t())
        XCTAssertNotEqual(next, first)
        XCTAssertEqual(pool.members(for: key).count, 2,
                       "somewhere that can actually open a channel had to be opened")
        XCTAssertNil(pool.existing(key).map { $0 == first! ? $0 : nil } ?? nil,
                     "and a short command must not be sent there either")
    }

    func testAConnectionStopsBeingFullWhenAChannelLeavesIt() {
        let first = pool.place(key, tenant: "pane.a")
        _ = pool.placeAfterRefusal(on: first!, key, tenant: "pane.b")
        pool.release(tenant: "pane.a")
        pool.noteSlotFreed(on: first!)
        XCTAssertEqual(pool.place(key, tenant: t()), first,
                       "a freed slot on a full connection is a usable slot")
    }

    /// The human's own forwarding rules go up with the first connection,
    /// put there by the launch script rather than through the pool. Unless
    /// they are adopted the pool believes that connection carries nothing.
    func testAConnectionCarryingForwardsTheScriptAddedIsNotTreatedAsEmpty() {
        let base = pool.primary(for: key)
        FileManager.default.createFile(atPath: base, contents: nil)
        pool.claim(tenant: "hostfwd.a", on: base)
        pool.claim(tenant: "hostfwd.b", on: base)

        XCTAssertNotEqual(pool.placeExclusive(key, tenant: t()), base,
                          "a transfer must not take a connection three forwards are on")
    }

    // MARK: - Load, which channel count cannot see

    /// The reported symptom. A port forward and a pane are one channel
    /// each, so counting alone puts the pane straight on top of a forward
    /// that is carrying a sync — which is the 8-18 second stall C-BROKER
    /// measured, in the tenant the old two-lane split did not classify.
    func testAPaneDoesNotLandOnAConnectionWhoseRoundTripHasClimbed() {
        let carrying = pool.place(key, tenant: t())          // the human's port forward
        pool.observe(roundTrip: 0.37, on: carrying!)
        pool.observe(roundTrip: 9.1, on: carrying!)

        let pane = pool.place(key, tenant: t())
        XCTAssertNotEqual(pane, carrying,
                          "a connection several times its own quiet round trip is carrying something")
        XCTAssertEqual(pool.members(for: key).count, 2)
    }

    func testOrdinaryJitterIsNotLoad() {
        let first = pool.place(key, tenant: t())
        pool.observe(roundTrip: 0.36, on: first!)
        pool.observe(roundTrip: 0.61, on: first!)

        XCTAssertEqual(pool.place(key, tenant: t()), first,
                       "a slower-than-usual round trip is not a reason to authenticate again")
        XCTAssertEqual(pool.members(for: key).count, 1)
    }

    func testAConnectionBecomesUsableAgainWhenTheLoadPasses() {
        let first = pool.place(key, tenant: t())
        pool.observe(roundTrip: 0.37, on: first!)
        pool.observe(roundTrip: 9.1, on: first!)
        _ = pool.place(key, tenant: t())                     // grew away from it
        pool.observe(roundTrip: 0.39, on: first!)

        XCTAssertEqual(pool.members(for: key).count, 2,
                       "the transfer finishing is not a reason to open a third")
        XCTAssertEqual(pool.place(key, tenant: t()), first,
                       "the quietest connection takes the next channel once it is quiet again")
    }

    /// A CONGESTED LINK IS NOT A CROWDED CONNECTION, and the difference is
    /// what stops this growing without bound. If a connection carrying
    /// nothing at all still reads as slow, the slowness is the network, and
    /// another connection would be just as slow.
    func testAPoolDoesNotClimbWhenTheLINKIsTheSlowThing() {
        let first = pool.place(key, tenant: t())
        pool.observe(roundTrip: 0.37, on: first!)
        pool.observe(roundTrip: 9.1, on: first!)
        let second = pool.place(key, tenant: "pane.b")       // one growth, reasonably
        pool.release(tenant: "pane.b")
        // Carrying nothing, and still slow: the link is the problem.
        pool.observe(roundTrip: 0.40, on: second!)
        pool.observe(roundTrip: 8.8, on: second!)

        for _ in 0..<10 { _ = pool.place(key, tenant: t()) }
        XCTAssertEqual(pool.members(for: key).count, 2,
                       "authenticating ten more times does not make a congested link faster")
    }

    /// A PANE'S COMMAND IS BUILT ON THE MAIN THREAD, so its placement may
    /// not authenticate. The quiet connection is opened ahead of it, in the
    /// background, by the same pass that measured the load.
    func testAPanePlacementNeverAuthenticates() {
        XCTAssertNil(pool.placeWithoutOpening(key, tenant: t()))
        XCTAssertEqual(opened, [], "building a pane command must not open a connection")
    }

    func testTheHeartbeatOpensTheQuietConnectionBeforeAPaneAsksForIt() {
        let carrying = pool.place(key, tenant: t())
        pool.observe(roundTrip: 0.37, on: carrying!)
        pool.observe(roundTrip: 9.1, on: carrying!)

        let ready = pool.growIfLoaded(key)
        XCTAssertNotNil(ready)
        XCTAssertEqual(pool.placeWithoutOpening(key, tenant: t()), ready,
                       "the pane lands on the quiet one without opening anything itself")
    }

    func testNothingIsOpenedAheadOfNeedWhileTheHostIsQuiet() {
        let first = pool.place(key, tenant: t())
        pool.observe(roundTrip: 0.37, on: first!)
        XCTAssertNil(pool.growIfLoaded(key))
        XCTAssertEqual(pool.members(for: key).count, 1)
    }

    func testOneSpareIsEnough() {
        let first = pool.place(key, tenant: t())
        pool.observe(roundTrip: 0.37, on: first!)
        pool.observe(roundTrip: 9.1, on: first!)
        let spare = try? XCTUnwrap(pool.growIfLoaded(key))
        pool.observe(roundTrip: 0.38, on: spare!)

        XCTAssertNil(pool.growIfLoaded(key),
                     "a quiet connection standing ready is the whole point; a second one is not")
        XCTAssertEqual(pool.members(for: key).count, 2)
    }

    // MARK: - Somewhere better to be

    func testAQuietConnectionIsNotWorthMovingOff() {
        let first = pool.place(key, tenant: t())
        pool.observe(roundTrip: 0.37, on: first!)
        _ = pool.placeExclusive(key, tenant: t())            // a second one exists
        XCTAssertNil(pool.betterThan(first!, for: key),
                     "a pane that is not stalled must not be moved; the move costs a repaint")
    }

    func testAStalledPaneIsOfferedTheQuietConnection() {
        let carrying = pool.place(key, tenant: t())
        pool.observe(roundTrip: 0.37, on: carrying!)
        pool.observe(roundTrip: 9.1, on: carrying!)
        let ready = pool.growIfLoaded(key)

        XCTAssertEqual(pool.betterThan(carrying!, for: key), ready)
    }

    func testThereIsNowhereBetterWhenEverythingIsLoaded() {
        let first = pool.place(key, tenant: t())
        pool.observe(roundTrip: 0.37, on: first!)
        pool.observe(roundTrip: 9.1, on: first!)
        let second = try? XCTUnwrap(pool.growIfLoaded(key))
        pool.observe(roundTrip: 0.38, on: second!)
        pool.observe(roundTrip: 8.4, on: second!)

        XCTAssertNil(pool.betterThan(first!, for: key),
                     "moving from one stalled connection to another buys a repaint and nothing else")
    }

    func testAPaneOnAConnectionAtItsBoundHasSomewhereToGo() {
        let first = pool.place(key, tenant: "pane.a")
        let second = pool.placeExclusive(key, tenant: "transfer.a")
        pool.release(tenant: "transfer.a")
        pool.markFull(socket: first!)

        XCTAssertEqual(pool.betterThan(first!, for: key), second,
                       "a connection that will take no more channels is a reason to move even when it is quiet")
    }

    func testAnotherHostsConnectionIsNeverOfferedAsBetter() {
        XCTAssertTrue(pool.belongs(pool.primary(for: key), to: key))
        let other = MasterPool.HostKey(userAtHost: "u@10.0.0.1", port: 220)
        XCTAssertFalse(pool.belongs(pool.primary(for: other), to: key))
    }

    /// CLOSING IS INSEPARABLE FROM UNRECORDING, symmetric with the rule
    /// that opening is inseparable from recording. Without it the records
    /// outlive both the connections they name and the process that wrote
    /// them — and because a socket path is re-minted from the host's own
    /// name, a stale record starts counting again the moment that host
    /// reconnects. Every key mismatch that used to cost one process's
    /// lifetime would cost forever.
    func testTearingDownAConnectionTakesItsRecordsWithIt() {
        let base = pool.place(key, tenant: "pane.builder.a")
        pool.claim(tenant: "pane.builder.a.pid", on: "12345")
        XCTAssertNotNil(pool.recordedCarrier(of: "pane.builder.a"))

        pool.closeAll(for: key)

        XCTAssertNil(pool.recordedCarrier(of: "pane.builder.a"),
                     "a record for a connection that has been closed must not survive it")
        XCTAssertNotNil(base)
    }

    /// AND A RECORD IS NOT ALLOWED TO DECIDE WHERE TRAFFIC GOES UNLESS IT
    /// STILL NAMES SOMETHING. The unverified read stays available for the
    /// paths that FORGET rather than decide, and is spelled differently so
    /// reaching for the wrong one is visible.
    func testAStaleRecordDoesNotPlaceAChannel() {
        let ghost = dir.appendingPathComponent("u@10.0.0.1:22#9").path
        pool.claim(tenant: "pane.builder.a", on: ghost)

        XCTAssertNil(pool.carrier(of: "pane.builder.a", for: key),
                     "a previous process must not decide where this one's traffic goes")
        XCTAssertEqual(pool.recordedCarrier(of: "pane.builder.a"), ghost,
                       "and the raw read still answers, for the paths that only need to forget")
    }

    /// RELEASING A SLOT CLEARS THE REFUSAL IN THE SAME CALL. This was two
    /// steps the caller had to remember, and one caller did not: a
    /// transfer released its record and left the connection excluded from
    /// every later placement until teardown. A two-step protocol between
    /// one fact and its consequence is the same shape as two records of
    /// one fact — it works until somebody does half of it.
    func testReleasingASlotEndsTheRefusalItWasHolding() {
        let first = pool.place(key, tenant: "transfer.a")
        pool.markFull(socket: first!)
        XCTAssertTrue(pool.isFullForTesting(first!))

        pool.release(tenant: "transfer.a")

        XCTAssertFalse(pool.isFullForTesting(first!),
                       "a freed slot on a connection that refused one is a usable slot")
        XCTAssertEqual(pool.place(key, tenant: "pane.a"), first,
                       "and it is offered again rather than avoided until teardown")
    }

    /// A HOST WHOSE EVERY CONNECTION HAS REFUSED A CHANNEL GETS ANOTHER
    /// ONE. [[RFC-0013]] C-BROKER: "A channel a connection refuses to open
    /// MUST cause a further connection to that host to be opened." The
    /// growth-ahead pass guarded on there being a connection that had NOT
    /// refused, so the one case the clause names was the one case that
    /// opened nothing.
    func testEveryConnectionAtItsBoundIsAReasonToOpenAnother() {
        let first = pool.place(key, tenant: "pane.a")
        pool.markFull(socket: first!)

        XCTAssertNotNil(pool.growIfLoaded(key),
                        "the remote said no to every connection this host holds")
        XCTAssertEqual(pool.members(for: key).count, 2)
    }

    /// AND A REFUSAL IS NOT CONGESTION. The link-congestion guard stops
    /// endless growth when a connection carrying nothing is still slow;
    /// it must not stop growth when the remote has actually refused,
    /// because another connection is precisely what it said yes to.
    func testARefusalGrowsEvenWhereCongestionWouldNot() {
        let first = pool.place(key, tenant: "pane.a")
        let spare = pool.placeExclusive(key, tenant: "transfer.a")
        pool.release(tenant: "transfer.a")
        // Congested link: an idle connection that still answers slowly.
        pool.observe(roundTrip: 0.40, on: spare!)
        pool.observe(roundTrip: 8.8, on: spare!)
        XCTAssertNil(pool.growIfLoaded(key), "congestion alone must not grow the pool")

        pool.markFull(socket: first!)
        pool.markFull(socket: spare!)
        XCTAssertNotNil(pool.growIfLoaded(key),
                        "but a refusal from every one of them must")
    }

    // MARK: - Teardown reads the filesystem, not a list of names

    func testDisconnectingClosesEveryConnectionTheHostGrew() {
        _ = pool.place(key, tenant: t())
        _ = pool.placeExclusive(key, tenant: t())
        let third = pool.placeExclusive(key, tenant: t())
        XCTAssertNotNil(third)
        XCTAssertEqual(pool.members(for: key).count, 3)

        pool.closeAll(for: key)
        XCTAssertEqual(closed.count, 3, "every member is closed, not a fixed pair")
        XCTAssertEqual(pool.members(for: key), [])
    }

    func testTeardownFindsAConnectionThisProcessNeverOpened() {
        // A previous launch died. Its sockets are still there, and
        // ControlPersist=yes means nothing else will ever reap them.
        let orphan = dir.appendingPathComponent("u@10.0.0.1:22#7").path
        FileManager.default.createFile(atPath: orphan, contents: nil)

        XCTAssertEqual(pool.members(for: key), [orphan],
                       "membership is what is on disk, not what this process remembers")
        pool.closeAll(for: key)
        XCTAssertEqual(closed, [orphan])
    }

    func testAnotherHostsConnectionsAreNotClosed() {
        _ = pool.place(key, tenant: t())
        let other = MasterPool.HostKey(userAtHost: "u@10.0.0.1", port: 220)
        _ = pool.place(other, tenant: t())

        pool.closeAll(for: key)
        XCTAssertEqual(pool.members(for: other).count, 1,
                       "a port that shares a prefix is a different host")
    }

    // MARK: - Short-lived commands ride along without being counted

    func testAListingDoesNotOpenAConnectionAndSaysSoRatherThanGuessing() {
        XCTAssertNil(pool.existing(key),
                     "a host holding nothing has nowhere to put a listing, and authenticating on the main thread to find out is not the answer")
        XCTAssertEqual(opened, [])
    }

    func testAListingDoesNotCountAgainstTheConnectionItRode() {
        let first = pool.place(key, tenant: "pane.a")
        let second = pool.placeExclusive(key, tenant: "transfer.a")
        pool.release(tenant: "transfer.a")

        for _ in 0..<20 { _ = pool.existing(key) }

        XCTAssertEqual(pool.place(key, tenant: "pane.b"), second,
                       "listings never release, so counting them would make the emptiest connection look like the fullest")
        XCTAssertNotEqual(second, first)
    }

    // MARK: - A host that will not hold a connection

    func testPlacementFailsRatherThanReturningASocketWithNoMasterBehindIt() {
        openShouldFail = true
        XCTAssertNil(pool.place(key, tenant: t()))
        XCTAssertEqual(pool.members(for: key), [],
                       "a socket path with nothing listening on it is worse than no answer")
    }
}

/// EVERY SSH THIS WORKBENCH OPENS CARRIES THE SAME POLICY
/// ([[WI-2026-08-30-010]]).
///
/// It was written out three times and the copies were not the same: the
/// one-off opener and the file-browser session carried BatchMode and a
/// timeout and NOT the host-key policy, so a first connection to a host the
/// human had just added succeeded through the pooled master and hung
/// through the other two.
@MainActor
final class SSHPolicyTests: XCTestCase {

    private func value(after option: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(where: { $0.hasPrefix(option + "=") })
        else { return nil }
        return String(args[i].dropFirst(option.count + 1))
    }

    func testAnOpenerRefusesToPromptAndAcceptsANewHost() {
        let args = SSHPolicy.opening(connectTimeout: 7)
        XCTAssertEqual(value(after: "BatchMode", in: args), "yes",
                       "a host that would prompt could hang on a password nobody can see")
        XCTAssertEqual(value(after: "StrictHostKeyChecking", in: args), "accept-new",
                       "a first connection to a newly added host would hang")
        XCTAssertEqual(value(after: "ConnectTimeout", in: args), "7")
    }

    /// A link that has silently died is discovered rather than waited on.
    func testAnOpenerKeepsTheLinkHonest() {
        let args = SSHPolicy.opening(connectTimeout: 10)
        XCTAssertEqual(value(after: "ServerAliveInterval", in: args), "15")
        XCTAssertEqual(value(after: "ServerAliveCountMax", in: args), "3")
    }

    /// THE ONE-OFF PATH CARRIES IT TOO, which is the half that was missing.
    func testTheOneOffOpenerCarriesTheSamePolicy() {
        let host = HostEntry(label: "builder", address: "b.example", username: "someone")
        let args = TunnelManager().oneOffArgs(for: host, connectTimeout: 5, remote: "true")
        for option in SSHPolicy.opening(connectTimeout: 5) where option != "-o" {
            XCTAssertTrue(args.contains(option), "the one-off opener dropped \(option)")
        }
    }
}

/// Whether a socket is one of this host's — asked only by tests, so it
/// lives with them ([[WI-2026-09-02-036]]).
extension MasterPool {
    func belongs(_ socket: String, to key: HostKey) -> Bool {
        MasterPool.base(ofSocket: socket) == key.socketBase
    }
}
