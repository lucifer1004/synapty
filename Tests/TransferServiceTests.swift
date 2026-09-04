import XCTest
@testable import Synapty

/// [[WI-2026-08-15-009]] / [[RFC-0013]]. These pin the properties whose
/// failure is SILENT — a transfer that quietly re-authenticates, a relay
/// that delivers a file under the wrong name, a drop that does the other
/// thing. Each of those looks like success from the outside.
final class TransferServiceTests: XCTestCase {

    private let hostA = UUID()
    private let hostB = UUID()

    private func conn(_ userAtHost: String, _ socket: String,
                      port: Int = 22, identity: String? = nil) -> RemoteConnection {
        RemoteConnection(userAtHost: userAtHost, port: port,
                         controlPath: socket, identity: identity)
    }

    // MARK: - What a drop means

    /// TWO MACHINES MEANS THE BYTES HAVE TO MOVE.
    func testDroppingAFileFromOneHostOntoAnotherTransfers() {
        let outcome = DropRule.outcome(
            dragging: FileEndpoint(hostID: hostB, path: "/home/z/out.tar"),
            onto: FileEndpoint(hostID: hostA, path: "/home/z/incoming"))
        XCTAssertEqual(outcome, .transfer)
    }

    /// ONE MACHINE MEANS THE FILE IS ALREADY THERE. Sending it to itself
    /// would be a slow no-op; what the human wants is its name on the
    /// command line.
    func testDroppingAFileOntoItsOwnHostPastesThePath() {
        let outcome = DropRule.outcome(
            dragging: FileEndpoint(hostID: hostA, path: "/home/z/out.tar"),
            onto: FileEndpoint(hostID: hostA, path: "/home/z"))
        XCTAssertEqual(outcome, .pastePath)
    }

    /// LOCAL IS A MACHINE LIKE ANY OTHER, in both directions. Neither of
    /// these may fall through to the wrong branch because `nil` was read as
    /// "unknown" rather than as "this Mac".
    func testLocalCountsAsAMachineOnBothSidesOfTheRule() {
        XCTAssertEqual(
            DropRule.outcome(dragging: FileEndpoint(hostID: nil, path: "/tmp/a"),
                             onto: FileEndpoint(hostID: nil, path: "/tmp")),
            .pastePath,
            "a local file dropped on a local terminal is already where it would be sent")
        XCTAssertEqual(
            DropRule.outcome(dragging: FileEndpoint(hostID: nil, path: "/tmp/a"),
                             onto: FileEndpoint(hostID: hostA, path: "/home/z")),
            .transfer,
            "local onto remote is an upload, not a paste")
        XCTAssertEqual(
            DropRule.outcome(dragging: FileEndpoint(hostID: hostA, path: "/home/z/a"),
                             onto: FileEndpoint(hostID: nil, path: "/tmp")),
            .transfer,
            "remote onto local is a download, not a paste")
    }

    // MARK: - The relay

    /// TWO REMOTE ENDS RELAY THROUGH HERE. Not a limitation worked around:
    /// it is the only topology in which neither host acquires a credential
    /// for the other, and scp takes one ControlPath while these are two
    /// masters.
    func testATransferBetweenTwoHostsRelaysAndOneInvolvingThisMacDoesNot() {
        let remoteA = TransferPlan.Leg.remote(conn("z@a", "/tmp/a.sock"), path: "/home/z/f")
        let remoteB = TransferPlan.Leg.remote(conn("z@b", "/tmp/b.sock"), path: "/home/z")

        XCTAssertTrue(TransferPlan(from: remoteA, to: remoteB).needsRelay)
        XCTAssertFalse(TransferPlan(from: remoteA, to: .local("/tmp")).needsRelay)
        XCTAssertFalse(TransferPlan(from: .local("/tmp/f"), to: remoteB).needsRelay)
    }

    /// A RELAY MUST NOT DELIVER ITS STAGING NAME. The middle of a relay is
    /// a temp file named after a UUID; without carrying the original name
    /// forward the human receives `synapty-relay-6F2A…` on the far side and
    /// the transfer still reports success.
    func testTheDestinationKeepsTheOriginalFileNameNotTheStagingName() {
        let dest = TransferRunner.destinationLeg(.local("/tmp/incoming"), defaultName: "out.tar")
        XCTAssertEqual(dest.path, "/tmp/incoming/out.tar")

        let remote = TransferRunner.destinationLeg(
            .remote(conn("z@b", "/tmp/b.sock"), path: "/home/z/incoming"),
            defaultName: "out.tar")
        XCTAssertEqual(remote.path, "/home/z/incoming/out.tar")
    }

    /// THE CONFLICT POLICY RENAMES THE FILE, NEVER THE DIRECTORY IT LANDS
    /// IN. A relay's second hop took the drop's destination directly, so
    /// `nonColliding` was handed the DIRECTORY — which of course exists —
    /// and renamed that instead. Measured against a live pair:
    ///
    ///     failed remotehost:/home/operator/Caddyfile -> otherhost:~:
    ///     /usr/bin/scp: expand ~ 2: no such user
    ///
    /// `~` became `~ 2`, which sshd reads as the home of a user named "2".
    func testTheConflictPolicyRenamesTheFileAndNotTheDirectory() throws {
        let home = TransferPlan.Leg.remote(conn("z@b", "/tmp/b.sock"), path: "~")
        let out = try TransferRunner.delivery(to: home, named: "Caddyfile",
                                              onConflict: .rename, taken: { _ in .absent })
        XCTAssertEqual(out.path, "~/Caddyfile")
    }

    /// AND THE RENAME KEEPS THE TILDE LEADING. `withoutTilde` only strips a
    /// tilde that starts the path, correctly — so a renamed `~` is a tilde
    /// it can no longer reach, and one that reaches scp is the bug above.
    func testARenamedDeliveryStillHasAStrippableTilde() throws {
        let home = TransferPlan.Leg.remote(conn("z@b", "/tmp/b.sock"), path: "~")
        let out = try TransferRunner.delivery(to: home, named: "Caddyfile",
                                              onConflict: .rename,
                                              taken: { $0.path == "~/Caddyfile" ? .present : .absent })
        XCTAssertEqual(out.path, "~/Caddyfile 2")
        XCTAssertEqual(TransferRunner.withoutTilde(out).path, "./Caddyfile 2")
    }

    /// REPLACE STILL NAMES THE FILE. The policy decides whether to step
    /// aside, not what is being written.
    func testReplaceDeliversIntoTheDirectoryUnderTheSourceName() throws {
        let out = try TransferRunner.delivery(to: .local("/tmp/incoming"), named: "out.tar",
                                              onConflict: .replace, taken: { _ in .present })
        XCTAssertEqual(out.path, "/tmp/incoming/out.tar")
    }

    /// A PROBE THAT CANNOT ANSWER IS NOT A NAME THAT IS FREE. `test -e`
    /// over ssh came back as one bit, so an unreachable host read as an
    /// empty directory and the policy handed scp the original name to
    /// overwrite ([[WI-2026-09-02-023]]). Now it refuses, and says so.
    func testAnUnansweredProbeRefusesTheDeliveryInsteadOfOverwriting() {
        let home = TransferPlan.Leg.remote(conn("z@b", "/tmp/b.sock"), path: "/srv")
        XCTAssertThrowsError(
            try TransferRunner.delivery(to: home, named: "Caddyfile",
                                        onConflict: .rename, taken: { _ in .unknown })
        ) { error in
            XCTAssertEqual(error as? TransferRunner.DeliveryRefusal,
                           .destinationUnknown("/srv/Caddyfile"))
        }
    }

    /// AND AN EXHAUSTED SERIES REFUSES TOO. It used to return the original
    /// name — the one name in the series known to be taken.
    func testAnExhaustedSeriesRefusesRatherThanReturningTheTakenName() {
        XCTAssertThrowsError(
            try TransferRunner.delivery(to: .local("/tmp/incoming"), named: "out.tar",
                                        onConflict: .rename, taken: { _ in .present })
        ) { error in
            XCTAssertEqual(error as? TransferRunner.DeliveryRefusal, .namesExhausted("out.tar"))
        }
        XCTAssertNil(ConflictName.available(for: "out.tar") { _ in true })
    }

    // MARK: - Connection reuse

    /// THE TRANSFER MUST RIDE THE EXISTING MASTER.
    ///
    /// Measured against a live host: a cold sftp costs 2.97s and
    /// re-authenticates, the same operation over the master costs 1.07s and
    /// does not. Reuse is also what lets a password-only host transfer at
    /// all, because BatchMode refuses to prompt. Nothing observable at
    /// runtime distinguishes reuse from a fast second handshake, so the
    /// argument list is the only place this can be asserted.
    func testTransfersRideTheExistingMasterAndNeverPrompt() {
        let args = TransferRunner.arguments(
            from: .remote(conn("z@b", "/tmp/b.sock", port: 2222), path: "/home/z/f"),
            to: .local("/tmp/f"))

        XCTAssertTrue(args.contains("ControlPath=/tmp/b.sock"), "must reuse the master")
        XCTAssertTrue(args.contains("ControlMaster=no"), "must not become a second master")
        XCTAssertTrue(args.contains("BatchMode=yes"), "a prompt in a background transfer hangs it")
        XCTAssertTrue(args.contains("2222"), "a non-default port must survive into the copy")
    }

    /// A HOST THAT NAMES NO KEY GETS NO `-i`, for the reason WI-2026-08-15-008
    /// established the hard way: offering this machine's dedicated key to a
    /// host that never authorised it turns a working connection into
    /// "Permission denied". The transfer path must not reintroduce it.
    func testAHostWithNoConfiguredKeyIsOfferedNoIdentity() {
        let args = TransferRunner.arguments(
            from: .remote(conn("z@b", "/tmp/b.sock"), path: "/home/z/f"),
            to: .local("/tmp/f"))
        XCTAssertFalse(args.contains("-i"))
    }

    /// A REMOTE PATH IS PASSED AS BYTES, NOT SHELL-QUOTED.
    ///
    /// This test asserted the opposite and was green: it pinned a quoted
    /// path, faithfully, and the quotes became part of the filename on the
    /// far side. Measured against a live host, `host:'/tmp/probe.txt'` fails
    /// with `dest open "'/tmp/probe.txt'"` while the unquoted form succeeds,
    /// spaces and all — because SFTP mode has no remote shell to expand it.
    /// Nothing offline could have told the two apart.
    func testARemotePathIsPassedLiterallyBecauseThereIsNoRemoteShell() {
        let args = TransferRunner.arguments(
            from: .remote(conn("z@b", "/tmp/b.sock"), path: "/home/z/my report.pdf"),
            to: .local("/tmp"))
        XCTAssertEqual(args.first { $0.hasPrefix("z@b:") }, "z@b:/home/z/my report.pdf")
        XCTAssertTrue(args.contains("-s"),
                      "and SFTP mode is forced, so the quoting rule cannot change under us")
    }

    // MARK: - The queue is the service's, not a view's

    /// A TRANSFER OUTLIVES WHATEVER STARTED IT. The panel that began this
    /// can be switched to another view, pointed at a different host, or
    /// closed; none of that is allowed to lose the work. This is the
    /// property stage two depends on, because the CLI enters the same queue.
    @MainActor
    func testTheQueueBelongsToTheServiceAndSurvivesItsCaller() {
        let service = TransferService()
        // No tunnel manager: the transfer cannot run, which is exactly the
        // condition under which a queue held by a view would lose it.
        let id = service.enqueue(
            from: FileEndpoint(hostID: hostB, path: "/home/z/out.tar"),
            to: FileEndpoint(hostID: hostA, path: "/home/z"))

        XCTAssertEqual(service.transfers.count, 1)
        XCTAssertEqual(service.transfers.first?.id, id)
        XCTAssertEqual(service.transfers.first?.initiator, .human)
    }

    /// EVERY TRANSFER IS ATTRIBUTED. A plane serving both a human's gesture
    /// and an agent's call must be able to say which it was serving; an
    /// unattributed entry in the record is one nobody can act on.
    @MainActor
    func testAnAgentInitiatedTransferIsRecordedAsTheAgentsNotAsAGesture() {
        let service = TransferService()
        var seen: [TransferService.Initiator] = []
        service.onEvent = { seen.append($0.initiator) }

        service.enqueue(from: FileEndpoint(hostID: hostB, path: "/home/z/out.tar"),
                        to: FileEndpoint(hostID: hostA, path: "/home/z"),
                        initiator: .agent("api-7f3c"))

        XCTAssertTrue(seen.contains(.agent("api-7f3c")))
        XCTAssertFalse(seen.contains(.human))
    }

    /// A host the workbench cannot reach fails the transfer with a reason,
    /// rather than leaving it queued forever looking like it is about to
    /// start.
    @MainActor
    func testATransferToAHostWithNoConnectionFailsRatherThanWaiting() {
        let service = TransferService()
        service.enqueue(from: FileEndpoint(hostID: hostB, path: "/home/z/out.tar"),
                        to: FileEndpoint(hostID: hostA, path: "/home/z"))
        guard case .failed = service.transfers.first?.state else {
            return XCTFail("expected a failure, got \(String(describing: service.transfers.first?.state))")
        }
    }

    /// DROPPING SEVERAL FILES MUST NOT OPEN A COPY PER FILE. They share one
    /// connection with the human's keystrokes, and parallel copies over it
    /// are slower than a few at a time as well as more disruptive.
    ///
    /// Asserted synchronously: everything up to the detached copy runs on
    /// this actor, so no completion can interleave before the next line.
    @MainActor
    func testTheThirdSimultaneousDropWaitsInsteadOfOpeningAThirdCopy() {
        let service = TransferService()
        let ids = (0..<3).map { i in
            service.enqueue(from: FileEndpoint(hostID: nil, path: "/tmp/synapty-test-src\(i)"),
                            to: FileEndpoint(hostID: nil, path: "/tmp"))
        }
        XCTAssertEqual(service.transfers.filter { $0.state == .running }.count, 2)
        XCTAssertEqual(service.transfers.filter { $0.state == .queued }.count, 1)

        // And cancelling the one that has not started finishes it, rather
        // than leaving a row a later pump would still pick up.
        service.cancel(ids[2])
        XCTAssertEqual(service.transfers.first { $0.id == ids[2] }?.state, .cancelled)
    }

    /// Progress that cannot be computed must not be reported as zero. A bar
    /// sitting at 0% and a bar that does not know are different claims, and
    /// only one of them is true before a size is known.
    @MainActor
    func testUnknownProgressIsAbsentRatherThanZero() {
        let service = TransferService()
        service.enqueue(from: FileEndpoint(hostID: nil, path: "/tmp/a"),
                        to: FileEndpoint(hostID: nil, path: "/tmp/b"))
        XCTAssertNil(service.transfers.first?.fraction)
    }

    // MARK: - Which connection a transfer rides

    /// A TRANSFER TAKES A CONNECTION CARRYING NOTHING ELSE, and gives it
    /// back ([[RFC-0013]] C-BROKER). Measured: an interactive round trip
    /// was 0.36-0.39s idle and 8.06-17.90s during a 60 MB transfer on the
    /// SAME connection; on a separate one it stayed at 0.36-0.38s. The
    /// cause is below SSH — one TCP connection, in-order delivery, a bulk
    /// channel filling the send buffer — so no SSH setting reaches it.
    @MainActor
    func testATransferDoesNotRideTheConnectionAPaneIsOn() throws {
        let dir = try TestTempStorage.makeDir()
        MasterPool.socketDirectoryOverride = dir
        MasterPool.tenantDirectoryOverride = dir.appendingPathComponent("tenants")
        defer {
            MasterPool.socketDirectoryOverride = nil
            MasterPool.tenantDirectoryOverride = nil
            TestTempStorage.removeDir(dir)
        }

        let pool = MasterPool()
        pool.openMaster = { _, path in
            FileManager.default.createFile(atPath: path, contents: nil); return true
        }
        let key = MasterPool.HostKey(userAtHost: "someone@builder.example", port: 22)
        let pane = pool.place(key, tenant: "pane.a")

        let riding = RemoteConnection(
            userAtHost: key.userAtHost, port: key.port,
            controlPath: pool.existing(key) ?? pool.primary(for: key), identity: nil)
        let plan = TransferPlan(from: .local("/tmp/report.html"),
                                to: .remote(riding, path: "~/report.html"),
                                toPool: .init(pool: pool, key: key))

        let (bound, release) = plan.takingExclusiveConnections()
        guard case .remote(let taken, _) = bound.to else {
            return XCTFail("the remote leg must stay remote")
        }
        XCTAssertNotEqual(taken.controlPath, pane,
                          "one socket is one TCP connection is the whole defect")
        XCTAssertEqual(pool.members(for: key).count, 2)

        release()
        XCTAssertEqual(pool.placeExclusive(key, tenant: "transfer.probe"), taken.controlPath,
                       "a finished transfer hands its connection back rather than growing the pool for the next one")
    }

    /// A LISTING NEVER AUTHENTICATES. It rides whatever the host already
    /// holds, because it is resolved on the main thread where opening a
    /// connection would be a beachball.
    @MainActor
    func testAListingRidesAnExistingConnectionRatherThanOpeningOne() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        let dir = try TestTempStorage.makeDir()
        MasterPool.socketDirectoryOverride = dir
        MasterPool.tenantDirectoryOverride = dir.appendingPathComponent("tenants")
        defer {
            MasterPool.socketDirectoryOverride = nil
            MasterPool.tenantDirectoryOverride = nil
            TestTempStorage.removeDir(dir)
        }

        let tm = TunnelManager()
        tm.hostStore = HostStore()
        var opens = 0
        tm.pool.openMaster = { _, path in
            opens += 1
            FileManager.default.createFile(atPath: path, contents: nil); return true
        }
        let host = HostEntry(label: "builder", address: "builder.example", username: "someone")
        let key = tm.poolKey(for: host)
        let connecting = tm.pool.place(key, tenant: "pane.a")
        opens = 0

        XCTAssertEqual(tm.connection(for: host).controlPath, connecting)
        XCTAssertEqual(opens, 0, "resolving a listing must not authenticate")
    }

    // MARK: - Progress, and waiting on a transfer

    /// PROGRESS IS A MEASUREMENT, AND ABSENT UNTIL THERE IS ONE.
    ///
    /// `bytesWritten` used to be set only at COMPLETION, which made the
    /// determinate branch of the progress view unreachable: every transfer
    /// showed an indeterminate spinner, which cannot tell "moving" from
    /// "wedged". It is now polled from the destination while the copy runs
    /// — coarse, because scp buffers, but measured rather than estimated.
    @MainActor
    func testProgressIsAbsentUntilThereIsSomethingToReport() {
        let service = TransferService()
        service.enqueue(from: FileEndpoint(hostID: nil, path: "/tmp/synapty-test-none"),
                        to: FileEndpoint(hostID: nil, path: "/tmp"))
        XCTAssertNil(service.transfers.first?.fraction,
                     "a bar at zero and a bar that does not know are different claims")
    }

    /// A caller holding something open — a file promise a receiver is
    /// waiting on — must be told when the transfer lands, and exactly once.
    @MainActor
    func testACallerCanWaitForATransferToFinish() {
        let service = TransferService()
        var reported: [TransferService.State] = []
        // No tunnel manager, so this fails immediately and terminally.
        let id = service.enqueue(from: FileEndpoint(hostID: UUID(), path: "/tmp/a"),
                                 to: FileEndpoint(hostID: UUID(), path: "/tmp"))
        service.whenFinished(id) { reported.append($0) }

        XCTAssertEqual(reported.count, 1, "already finished, so answered at once")
        if case .failed = reported.first {} else { XCTFail("expected a failure") }
    }

    /// Waiting on something that never existed answers rather than hanging
    /// — a promise nobody completes is a drag that never ends.
    @MainActor
    func testWaitingOnAnUnknownTransferAnswersImmediately() {
        let service = TransferService()
        var answered = false
        service.whenFinished(UUID()) { _ in answered = true }
        XCTAssertTrue(answered)
    }

    // MARK: - Directories

    /// A DIRECTORY'S SIZE IS A WALK, NOT A STAT.
    ///
    /// `attributesOfItem` on a directory reports the size of the ENTRY —
    /// 128 bytes for a tree holding fifty megabytes. Anything that decides
    /// on size and accepts a directory has to walk it, or the decision is
    /// about a number that means something else. The limit protecting a
    /// human from an agent is exactly such a decision.
    func testADirectorysSizeIsItsContentsNotItsEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-tree-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 4096).write(to: root.appendingPathComponent("a.bin"))
        try Data(count: 8192).write(to: nested.appendingPathComponent("b.bin"))

        let entry = try XCTUnwrap(TransferRunner.localFileSize(root.path))
        let contents = try XCTUnwrap(TransferRunner.localTreeSize(root.path))
        XCTAssertGreaterThanOrEqual(contents, 12288, "every byte under it")
        XCTAssertLessThan(entry, contents, "the entry is not the tree")
    }

    /// A tree is copied recursively, and a file is not — scp refuses a
    /// directory without `-r` with a message that reads like a permission
    /// problem.
    func testATreeIsCopiedRecursivelyAndAFileIsNot() {
        let leg = TransferPlan.Leg.remote(conn("z@b", "/tmp/b.sock"), path: "/home/z/build")
        XCTAssertTrue(TransferRunner.arguments(from: leg, to: .local("/tmp"), recursive: true)
            .contains("-r"))
        XCTAssertFalse(TransferRunner.arguments(from: leg, to: .local("/tmp"))
            .contains("-r"))
    }
}

extension TransferServiceTests {

    // MARK: - The inbox that never received anything

    /// `~` IS A SHELL'S, AND NOTHING IN A TRANSFER HAS ONE.
    ///
    /// scp with -s speaks SFTP, which has no tilde, and a LOCAL path
    /// never passes through a shell either — so `~/.synapty/inbox` reached
    /// `cp` verbatim and became a relative directory named `~`. Measured:
    /// `cp: ~/.synapty/inbox/src.txt: No such file or directory`.
    ///
    /// Which is why AgentInbox had never delivered a byte despite being
    /// the documented destination for every agent transfer — the verbs
    /// were exercised with an explicit `--into /tmp`, a path with no
    /// tilde to expand.
    func testALocalTildeIsResolvedAgainstThisMacsHome() {
        guard case .local(let path) = TransferRunner.withoutTilde(
            .local(AgentInbox.path)) else { return XCTFail("expected a local leg") }
        XCTAssertFalse(path.contains("~"), path)
        XCTAssertTrue(path.hasPrefix(NSHomeDirectory()), path)
        XCTAssertTrue(path.hasSuffix("/.synapty/inbox"), path)
    }

    /// THE TWO ENDS RESOLVE DIFFERENTLY AND MUST. This Mac's home is known
    /// here; the remote's is not. `.` is what the SFTP subsystem opens in,
    /// which IS the remote home — an exact substitution rather than a
    /// guess at one.
    func testARemoteTildeBecomesTheSubsystemsOwnDirectory() {
        let connection = RemoteConnection(
            userAtHost: "u@h", port: 22, controlPath: "/tmp/cp", identity: nil)
        guard case .remote(_, let path) = TransferRunner.withoutTilde(
            .remote(connection, path: AgentInbox.path)) else { return XCTFail("expected a remote leg") }
        XCTAssertEqual(path, "./.synapty/inbox")
        XCTAssertFalse(path.contains("~"), path)
        XCTAssertFalse(path.hasPrefix(NSHomeDirectory()),
                       "this Mac's home says nothing about the other machine's")
    }

    /// A path with no tilde is left exactly as the human wrote it.
    func testAnOrdinaryPathIsUntouched() {
        guard case .local(let path) = TransferRunner.withoutTilde(.local("/tmp/out.tar"))
        else { return XCTFail("expected a local leg") }
        XCTAssertEqual(path, "/tmp/out.tar")
    }
}

extension TransferServiceTests {

    // MARK: - Nothing is replaced without someone saying so

    /// SILENT OVERWRITE IS THE WORST OF THE THREE OUTCOMES. A refusal is
    /// visible and a rename is visible; a file replaced by another of the
    /// same name is not, and what it destroyed is gone with no record it
    /// existed.
    func testATakenNameYieldsTheNextOne() {
        let taken: Set<String> = ["report.html"]
        XCTAssertEqual(
            ConflictName.available(for: "report.html") { taken.contains($0) },
            "report 2.html")
    }

    /// The series continues rather than restarting, so a shared inbox
    /// accumulates instead of fighting over one alternative name.
    func testTheSeriesWalksPastEveryTakenName() {
        let taken: Set<String> = ["report.html", "report 2.html", "report 3.html"]
        XCTAssertEqual(
            ConflictName.available(for: "report.html") { taken.contains($0) },
            "report 4.html")
    }

    /// A free name is left exactly alone — the common case must cost
    /// nothing and change nothing.
    func testAFreeNameIsUntouched() {
        XCTAssertEqual(ConflictName.available(for: "report.html") { _ in false }, "report.html")
    }

    /// THE EXTENSION SURVIVES. `report.html 2` stops opening in the thing
    /// that opens html, which makes the rescue worse than the collision.
    func testTheExtensionStaysWhereItBelongs() throws {
        let taken: Set<String> = ["out.tar.gz"]
        let next = try XCTUnwrap(ConflictName.available(for: "out.tar.gz") { taken.contains($0) })
        XCTAssertTrue(next.hasSuffix(".gz"), next)
        XCTAssertEqual(next, "out.tar 2.gz")
    }

    /// A DOTFILE HAS NO EXTENSION, it has a name beginning with a dot.
    /// `NSString.pathExtension` reads `.zshrc` as extension "zshrc", and
    /// believing it produces " 2.zshrc" — a different file entirely rather
    /// than a second copy of this one.
    func testADotfileIsNotAnExtension() {
        let taken: Set<String> = [".zshrc"]
        XCTAssertEqual(
            ConflictName.available(for: ".zshrc") { taken.contains($0) },
            ".zshrc 2")
        XCTAssertEqual(ConflictName.split(".zshrc").ext, "")
    }

    /// A name with no extension keeps having none.
    func testANameWithNoExtension() {
        let taken: Set<String> = ["Makefile"]
        XCTAssertEqual(
            ConflictName.available(for: "Makefile") { taken.contains($0) },
            "Makefile 2")
    }

    /// AN AGENT NEVER OVERWRITES, and the default is what enforces it: a
    /// plan built without anyone answering carries `.rename`, so the path
    /// that destroys something is only reachable by someone saying so.
    func testTheDefaultPolicyDestroysNothing() {
        let plan = TransferPlan(from: .local("/tmp/a"), to: .local("/tmp/b"))
        XCTAssertEqual(plan.onConflict, .rename)
    }
}

@MainActor
extension TransferServiceTests {

    // MARK: - Asking, and what the answer does

    /// Drives the REAL path rather than setting the state by hand: a local
    /// destination that genuinely already holds the name, enqueued as a
    /// human's drag. Poking `.awaitingChoice` in would have tested the
    /// sheet's plumbing against a condition nothing produced.
    private func pausedTransfer() throws -> (TransferService, UUID, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("source/a.txt")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "new".write(to: source, atomically: true, encoding: .utf8)
        // The name is already taken at the destination.
        try "old".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let service = TransferService()
        let id = service.enqueue(
            from: FileEndpoint(hostID: nil, path: source.path),
            to: FileEndpoint(hostID: nil, path: dir.path),
            initiator: .human)
        return (service, id, dir)
    }

    private func waitForPause(_ service: TransferService, _ id: UUID) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .awaitingChoice = service.transfers.first(where: { $0.id == id })?.state {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// A human transfer whose destination probe is held open until the
    /// test lets go, so a cancel can land inside the window.
    private func transferHeldInProbe(answer: TransferRunner.Presence) throws
        -> (service: TransferService, id: UUID, dir: URL, release: DispatchSemaphore, probed: DispatchSemaphore)
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("source/a.txt")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "new".write(to: source, atomically: true, encoding: .utf8)

        let service = TransferService()
        let release = DispatchSemaphore(value: 0)
        let probed = DispatchSemaphore(value: 0)
        service.probe = { _ in
            probed.signal()
            release.wait()
            return answer
        }
        let id = service.enqueue(
            from: FileEndpoint(hostID: nil, path: source.path),
            to: FileEndpoint(hostID: nil, path: dir.path),
            initiator: .human)
        return (service, id, dir, release, probed)
    }

    /// A CANCEL THAT LANDS WHILE THE DESTINATION IS BEING PROBED IS
    /// HONOURED. The probe's continuation went straight to the copy, so
    /// the row said cancelled while scp ran ([[WI-2026-09-02-023]]).
    func testACancelDuringTheProbeStopsTheCopy() throws {
        let (service, id, dir, release, probed) = try transferHeldInProbe(answer: .absent)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(probed.wait(timeout: .now() + 5), .success, "the probe never ran")

        service.cancel(id)
        release.signal()
        waitUntil(service.transfers.first { $0.id == id }?.state == .cancelled)

        XCTAssertEqual(service.transfers.first { $0.id == id }?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path),
                       "the copy ran after the cancel")
    }

    /// A PROBE THAT CANNOT ANSWER FAILS THE TRANSFER VISIBLY rather than
    /// treating the destination as empty.
    func testAnUnansweredProbeFailsTheTransferWithoutWriting() throws {
        let (service, id, dir, release, probed) = try transferHeldInProbe(answer: .unknown)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(probed.wait(timeout: .now() + 5), .success)
        release.signal()
        waitUntil(service.transfers.first { $0.id == id }?.state.isFinished == true)

        guard case .failed(let why)? = service.transfers.first(where: { $0.id == id })?.state else {
            return XCTFail("expected failure, got \(String(describing: service.transfers.first { $0.id == id }?.state))")
        }
        XCTAssertTrue(why.contains("nothing was written"), why)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
    }

    /// A HUMAN IS PRESENT AND CAN BE ASKED, so their transfer stops rather
    /// than quietly landing under a name they did not drag. Waiting is not
    /// failing — it resumes the moment they answer.
    func testAHumansTransferStopsOnANameThatIsTaken() throws {
        let (service, id, dir) = try pausedTransfer()
        defer { try? FileManager.default.removeItem(at: dir) }
        waitForPause(service, id)

        let transfer = try XCTUnwrap(service.transfers.first { $0.id == id })
        XCTAssertEqual(transfer.state, .awaitingChoice("a.txt"))
        XCTAssertFalse(transfer.state.isFinished, "it is a question, not an outcome")
        // AND IT HAS NOT TOUCHED THE FILE while it waits.
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8), "old")
    }

    /// COUNTED WITH EVERYTHING ELSE BLOCKED ON A HUMAN. A second place to
    /// look is what one badge exists to prevent.
    func testAPausedTransferCountsAsWaiting() throws {
        let (service, id, dir) = try pausedTransfer()
        defer { try? FileManager.default.removeItem(at: dir) }
        waitForPause(service, id)

        XCTAssertEqual(
            AppNotifications.waitingCount(authority: nil, questions: nil, transfers: service), 1)

        // AND IT IS ONE OF THE SENTENCES UNDER THE NUMBER. The badge summed
        // three sources while the tooltip beneath it enumerated two, so a
        // human read "3" and hovered onto two lines ([[WI-2026-08-30-009]]).
        let lines = AppNotifications.waitingLines(
            authority: nil, questions: nil, transfers: service)
        XCTAssertEqual(lines.count, 1, "the number counts something the list does not say")
        XCTAssertTrue(lines.first?.contains("a.txt") == true,
                      "the line does not name the transfer that is waiting: \(lines)")
    }

    /// "Keep Both" is the same answer an agent always takes, and it leaves
    /// the file that was there alone.
    func testKeepingBothLeavesTheOriginalAlone() throws {
        let (service, id, dir) = try pausedTransfer()
        defer { try? FileManager.default.removeItem(at: dir) }
        waitForPause(service, id)

        service.resolveConflict(id, .rename)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              service.transfers.first(where: { $0.id == id })?.state.isFinished != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8), "old",
            "the file that was already there is what must not change")
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("a 2.txt"), encoding: .utf8), "new")
    }

    /// Answering something that is NOT waiting changes nothing — a stale
    /// click on a sheet whose transfer already finished must not restart
    /// it.
    func testAnsweringATransferThatIsNotWaitingIsIgnored() throws {
        let (service, id, dir) = try pausedTransfer()
        defer { try? FileManager.default.removeItem(at: dir) }
        waitForPause(service, id)

        service.cancel(id)
        service.resolveConflict(id, .replace)
        XCTAssertNil(service.transfers.first { $0.id == id }?.conflictChoice)
    }
}

/// [[ProcessCwd]] — the kernel's answer for a shell that never volunteers one.
final class ProcessCwdTests: XCTestCase {

    /// AGAINST A REAL PROCESS, which is the only way this can be wrong in
    /// an interesting way: the struct is read by size and a short read
    /// would hand back uninitialised bytes that still look like a path.
    func testItReadsThisProcessesOwnDirectory() throws {
        let cwd = try XCTUnwrap(ProcessCwd.of(pid: getpid()))
        XCTAssertEqual(real(cwd), real(FileManager.default.currentDirectoryPath))
    }

    /// `realpath`, not `resolvingSymlinksInPath`: Foundation deliberately
    /// leaves `/var` alone while the kernel answers `/private/var`, so the
    /// two disagree about paths that are perfectly equivalent.
    private func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// It FOLLOWS the process rather than reporting where it started.
    func testItFollowsAChangeOfDirectory() throws {
        let original = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(original) }
        let elsewhere = NSTemporaryDirectory()
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(elsewhere))
        XCTAssertEqual(real(try XCTUnwrap(ProcessCwd.of(pid: getpid()))), real(elsewhere))
    }

    /// NO PROCESS, NO GUESS. `ghostty_surface_foreground_pid` answers 0 for
    /// a surface whose child is gone, and a fabricated path would be worse
    /// than the "unknown" this exists to replace.
    func testItRefusesAPidThatCannotBeRead() {
        XCTAssertNil(ProcessCwd.of(pid: 0))
        XCTAssertNil(ProcessCwd.of(pid: -1))
    }

    // MARK: - WHICH process ([[WI-2026-08-18-004]])
    //
    // The rule is fed a chain rather than a live process table, so the
    // shapes that defeated the two earlier rules can be written down
    // instead of waited for.

    /// A chain, deepest first, as (pid, name, ppid).
    private func table(_ rows: [(pid_t, String, pid_t)])
    -> (parent: (pid_t) -> pid_t?, name: (pid_t) -> String?) {
        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.0, $0) })
        return ({ byPID[$0]?.2 }, { byPID[$0]?.1 })
    }

    private func shell(_ rows: [(pid_t, String, pid_t)], from pid: pid_t) -> pid_t? {
        let t = table(rows)
        return ProcessCwd.shell(from: pid, parent: t.parent, name: t.name)
    }

    /// THE CASE THIS EXISTS FOR. `jenv rehash` runs from every `.zshrc`
    /// here and `cd`s into the shim directory; it is a bash script, so
    /// neither its name nor its job-control position tells it apart from
    /// the shell above it. Its PARENT does.
    func testAScriptTheShellIsRunningIsNotTheShell() {
        let chain: [(pid_t, String, pid_t)] = [
            (400, "sleep", 300),
            (300, "bash", 200),          // jenv-rehash: #!/usr/bin/env bash
            (200, "zsh", 100),           // the pane's shell
            (100, "synapty", 50),        // our wrapper
            (50, "login", 1),
        ]
        XCTAssertEqual(shell(chain, from: 400), 200)
    }

    /// An idle pane: the shell IS the foreground process, and the walk
    /// stops on it rather than climbing past.
    func testAnIdleShellIsItsOwnAnswer() {
        let chain: [(pid_t, String, pid_t)] = [
            (200, "zsh", 100), (100, "synapty", 50), (50, "login", 1),
        ]
        XCTAssertEqual(shell(chain, from: 200), 200)
    }

    /// A chain that is not one of ours — no wrapper anywhere — yields
    /// nothing, and the caller keeps the foreground process it had.
    func testAChainWithNoWrapperAnswersNothing() {
        let chain: [(pid_t, String, pid_t)] = [
            (400, "vim", 200), (200, "zsh", 50), (50, "login", 1),
        ]
        XCTAssertNil(shell(chain, from: 400))
        XCTAssertNil(ProcessCwd.shell(from: 0))
    }

    /// A parent link that points at itself, or in a circle, must not spin.
    func testACorruptParentLinkTerminates() {
        XCTAssertNil(shell([(7, "zsh", 7)], from: 7))
        XCTAssertNil(shell([(1, "a", 2), (2, "b", 1)], from: 1))
    }

    /// The wrapper's own child is the answer even when that child is not a
    /// shell at all — `exec`ing something else over the shell is the
    /// human's business, and whatever the wrapper spawned is the pane.
    func testWhateverTheWrapperSpawnedIsThePane() {
        let chain: [(pid_t, String, pid_t)] = [
            (400, "sleep", 300), (300, "bash", 100), (100, "synapty", 50), (50, "login", 1),
        ]
        XCTAssertEqual(shell(chain, from: 400), 300)
    }
}

/// [[RemotePwd]] — a session line, and the shapes that are not a
/// destination.
final class RemotePwdTests: XCTestCase {

    /// THE COLUMNS ARE A CONTRACT with `synapty workspaces`: name, attached
    /// state, child state, the foreground group's working directory, its
    /// command, the SHELL's working directory. A reader that counted from
    /// the left and guessed would send files somewhere nobody asked for.
    func testItTakesTheWorkingDirectoryColumn() {
        XCTAssertEqual(
            RemotePwd.parse(
                stdout: "gc-9a9e\tattached\trunning\t/home/z/work\tzsh\t/home/z/work\n",
                exitCode: 0),
            "/home/z/work")
        XCTAssertEqual(
            RemotePwd.parse(stdout: "gc-9a9e\tdetached\trunning\t/etc\t-\t/etc\n", exitCode: 0),
            "/etc")
    }

    /// THE SHELL'S, NOT THE FOREGROUND GROUP'S ([[WI-2026-08-18-004]]).
    /// They differ whenever the session is running anything that has
    /// `cd`d — `jenv rehash` is a bash script that lives in the shim
    /// directory — and this answer places things.
    func testItPrefersTheShellsDirectoryOverTheForegroundCommands() {
        XCTAssertEqual(
            RemotePwd.parse(
                stdout: "gc-9a9e\tattached\trunning\t/home/z/.jenv/shims\tbash\t/home/z/work\n",
                exitCode: 0),
            "/home/z/work")
    }

    /// A HOLDER OLD ENOUGH TO WRITE FIVE COLUMNS ANSWERS NOTHING. It
    /// outlives a deploy by design, so the skew is real — and reading its
    /// fourth column would be keeping the wrong answer in the one place
    /// nothing marks it. Unknown is a state the drag hint says out loud.
    func testAnOlderHolderIsNotReadForADirectionItCannotGive() {
        XCTAssertNil(
            RemotePwd.parse(stdout: "gc-9a9e\tattached\trunning\t/home/z/work\tzsh\n", exitCode: 0))
    }

    /// A HOLDER THAT COULD NOT DETERMINE ONE WRITES "-", and unknown must
    /// stay visibly unknown rather than become a guess at home.
    func testUnknownStaysUnknown() {
        XCTAssertNil(RemotePwd.parse(stdout: "gc-9a9e\tdetached\trunning\t-\t-\t-\n", exitCode: 0))
        XCTAssertNil(RemotePwd.parse(stdout: "", exitCode: 0))
        XCTAssertNil(RemotePwd.parse(
            stdout: "gc-9a9e\tdetached\trunning\trelative/path\tzsh\trelative/path\n", exitCode: 0))
    }

    /// NO SESSION IS NO ANSWER: a name nothing holds exits non-zero, and
    /// a non-zero exit is not a destination however the line reads.
    func testNoSessionIsNoAnswer() {
        XCTAssertNil(RemotePwd.parse(stdout: "", exitCode: 2))
        XCTAssertNil(RemotePwd.parse(stdout: "gc\tattached\trunning\t/etc\tzsh\n", exitCode: 2))
    }


}

