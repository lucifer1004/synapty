import XCTest
@testable import Synapty

/// A RECORDED AGENT ID IS A RECORD, NOT A GRANT ([[RFC-0015]] C-PERSIST,
/// [[WI-2026-08-19-006]]).
///
/// It may re-associate a pane with a child that SURVIVED. Conferred on a
/// newly started one, it routes another agent's mail to a process that
/// never was it — and nothing errors, because the name is perfectly valid.
@MainActor
final class SessionIdentityTests: XCTestCase {

    private var tmp: URL!
    private var claims: [Int32] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try TestTempStorage.makeDir()
        ConfigPaths.rootOverride = tmp
        try FileManager.default.createDirectory(at: SessionRecord.directory(),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        for fd in claims { close(fd) }
        claims = []
        ConfigPaths.rootOverride = nil
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    /// A record with no holder behind it: both files present and nothing
    /// holding either, which is what a holder that died leaves behind.
    private func writeRecord(_ name: String, pid: Int32) throws {
        let url = SessionRecord.url(for: name)
        try Data("{\"pid\":\(pid)}".utf8).write(to: url)
        FileManager.default.createFile(
            atPath: SessionRecord.lockURL(for: name).path, contents: Data())
    }

    /// A record a holder is holding — the claim the Zig side takes and
    /// keeps open for the session's life. ON THE LOCK, not on the record:
    /// the record is rewritten in the course of a session's life and a
    /// claim sharing that file does not survive it
    /// ([[WI-2026-09-03-009]]). Closed in tearDown.
    @discardableResult
    private func claimRecord(_ name: String) throws -> Int32 {
        try writeRecord(name, pid: ProcessInfo.processInfo.processIdentifier)
        let url = SessionRecord.lockURL(for: name)
        let fd = open(url.path, O_RDONLY)
        try XCTUnwrap(fd >= 0 ? true : nil)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "the test could not take the claim")
        claims.append(fd)
        return fd
    }

    // MARK: - What the record answers

    func testARecordItsHolderStillHoldsIsLive() throws {
        try claimRecord("local-alive")
        XCTAssertTrue(SessionRecord.isLive("local-alive"))
    }

    func testARecordWhoseProcessIsGoneIsNotLive() throws {
        // A pid that cannot be running: beyond any plausible allocation.
        try writeRecord("local-dead", pid: 999_999)
        XCTAssertFalse(SessionRecord.isLive("local-dead"))
    }

    /// A PID IS A NUMBER, NOT AN IDENTITY — and here that is the whole
    /// security property. This record names a process unquestionably
    /// running (this one) and yet no holder owns it, which is exactly what
    /// a reused pid looks like. Read as live, the workbench would confer a
    /// dead session's name on a newly started child: the thing
    /// [[RFC-0015]] C-PERSIST forbids, and the thing that routes another
    /// agent's mail to a process that never was it.
    func testARecordWhoseHolderIsGoneIsNotLiveEvenIfItsPidIsInUse() throws {
        try writeRecord("local-reused", pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(kill(ProcessInfo.processInfo.processIdentifier, 0), 0,
                       "the pid this test relies on is not running, so it proved nothing")
        XCTAssertFalse(SessionRecord.isLive("local-reused"),
                       "a dead session was called live because something else wore its pid")
    }

    func testNoRecordIsNotLive() {
        XCTAssertFalse(SessionRecord.isLive("local-never-existed"))
    }

    // MARK: - What the workbench does with the answer

    /// THE SURVIVING SESSION IS RETURNED TO, which is the whole reason the
    /// id is persisted at all.
    func testAPaneReturnsToARecordedIdWhoseHolderIsStillRunning() throws {
        try claimRecord("local-kept")
        let manager = TunnelManager()

        let result = manager.localCommand(agentID: "local-kept")

        XCTAssertEqual(result.agentID, "local-kept")
    }

    /// AND A DEAD ONE IS NOT INHERITED. This is the security half: the
    /// name routes A2A mail, so a fresh child wearing it receives what was
    /// addressed to the one it replaced.
    func testAFreshChildNeverTakesTheIdOfTheOneItReplaced() throws {
        try writeRecord("local-gone", pid: 999_999)
        let manager = TunnelManager()

        let result = manager.localCommand(agentID: "local-gone")

        XCTAssertNotEqual(result.agentID, "local-gone",
                          "a new child was handed the identity of a dead one")
        XCTAssertTrue(result.agentID.hasPrefix("local-"))
        XCTAssertFalse(result.command.contains("local-gone"),
                       "the dead id is still on the command line")
    }

    /// A pane that never had one is unaffected.
    func testAPaneWithNoRecordedIdGetsAFreshOne() {
        let manager = TunnelManager()
        let result = manager.localCommand()
        XCTAssertTrue(result.agentID.hasPrefix("local-"))
    }
}

/// A WORKSPACE'S IDENTITY OUTLIVES THE PROCESS ([[RFC-0015]] C-WORKSPACE,
/// [[WI-2026-08-19-006]]).
@MainActor
final class WorkspaceIdentityTests: XCTestCase {

    func testAWorkspaceKeepsItsIdentityAcrossARelaunch() throws {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard let before = manager.activeWorkspaceID else { return XCTFail() }

        let data = try JSONEncoder().encode(manager.snapshot(planFor: { _ in nil }))
        let restored = WorkspaceManager()
        _ = restored.restore(from: try JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
                             hostStore: nil)

        XCTAssertEqual(restored.workspaces.first?.id, before,
                       "the identifier the workbench hands agents resolved to nothing after a restart")
    }

    /// A snapshot that carries none still restores — under a new identity,
    /// which is better than dropping the arrangement.
    func testAWorkspaceWithNoRecordedIdentityStillComesBack() throws {
        var snapshot = WorkspaceSnapshot()
        snapshot.workspaces = [.init(id: nil, label: "Local")]
        let restored = WorkspaceManager()
        _ = restored.restore(from: snapshot, hostStore: nil)
        XCTAssertEqual(restored.workspaces.count, 1)
        XCTAssertEqual(restored.workspaces.first?.label, "Local")
    }
}

/// THE FAR SIDE PICKS, AND THE REGISTRATION SAYS WHICH ([[PaneLaunch]],
/// [[WI-2026-08-19-006]]).
@MainActor
final class RemoteIdentityTests: XCTestCase {

    private func host() -> HostEntry {
        HostEntry(label: "builder", address: "builder.example", username: "someone")
    }

    /// A pane that is RETURNING carries two names: the one it hopes to
    /// rejoin, and the one to start under if that session is gone.
    func testAReattachingPaneCarriesBothNames() {
        let manager = TunnelManager()
        let launch = manager.connectCommand(for: host(), agentID: "builder-4b28")

        XCTAssertEqual(launch.agentID, "builder-4b28")
        let fresh = try? XCTUnwrap(launch.candidateID)
        XCTAssertNotNil(fresh)
        XCTAssertNotEqual(fresh, "builder-4b28",
                          "the name to start under is the name to return to")
        XCTAssertTrue(launch.command.contains("SYNAPTY_FRESH_ID="),
                      "the far side was not told what to start under")
    }

    /// A pane with nothing to return to has one name and nothing to
    /// disambiguate later.
    func testAFirstConnectionCarriesOneName() {
        let manager = TunnelManager()
        let launch = manager.connectCommand(for: host())
        XCTAssertNil(launch.candidateID)
    }

    /// EITHER NAME FINDS THE LEAF, and the one that registers becomes the
    /// only one — which is how the workbench learns the far side's choice
    /// without being told it.
    func testWhicheverNameRegistersBecomesTheLeafsOwn() {
        let manager = WorkspaceManager()
        let leaf = UUID()
        manager.recordLeafCandidates(leaf, settled: "builder-4b28", candidate: "builder-9f01")

        XCTAssertEqual(manager.leafID(forAgent: "builder-9f01"), leaf,
                       "the name the far side started under did not find its pane")
        XCTAssertEqual(manager.agentID(forLeaf: leaf), "builder-9f01",
                       "the leaf kept a name nothing is running under")
        XCTAssertNil(manager.leafID(forAgent: "builder-4b28"),
                     "a name that turned out not to exist still finds the pane")
    }

    func testReturningToTheRecordedSessionKeepsItsName() {
        let manager = WorkspaceManager()
        let leaf = UUID()
        manager.recordLeafCandidates(leaf, settled: "builder-4b28", candidate: "builder-9f01")

        XCTAssertEqual(manager.leafID(forAgent: "builder-4b28"), leaf)
        XCTAssertEqual(manager.agentID(forLeaf: leaf), "builder-4b28")
    }
}

/// ONE QUESTION, ASKED ONCE ([[WI-2026-08-30-007]]).
///
/// Whether a restored local pane may keep its recorded name was decided
/// twice: `Rejoining.local` consulted the durability opt-out, and the id
/// on the command line was chosen from liveness alone. With durability off
/// the child is run directly — no holder, no attach, so by construction a
/// NEW child — and it was handed the surviving session's name, which is
/// the [[RFC-0015]] C-PERSIST violation the whole shape exists to prevent.
@MainActor
final class DurabilityAndIdentityTests: XCTestCase {

    private var tmp: URL!
    private var claims: [Int32] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try TestTempStorage.makeDir()
        ConfigPaths.rootOverride = tmp
        try FileManager.default.createDirectory(at: SessionRecord.directory(),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        for fd in claims { close(fd) }
        claims = []
        ConfigPaths.rootOverride = nil
        SynaptySettings.shared.localDurableSessions = true
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    /// A record its holder is holding.
    ///
    /// THE BODY IS NOT WHAT THIS SIDE READS. `isLive` takes the claim and
    /// never parses the file, so the JSON here only has to be something
    /// [[holder.Record.read]] accepts on the other side; what is being
    /// exercised is the flock ([[WI-2026-08-30-010]]) — and the flock is
    /// on the lock beside the record ([[WI-2026-09-03-009]]).
    private func claimRecord(_ name: String) throws {
        let url = SessionRecord.url(for: name)
        try Data("{\"pid\":\(ProcessInfo.processInfo.processIdentifier)}".utf8).write(to: url)
        let lock = SessionRecord.lockURL(for: name)
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let fd = open(lock.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        claims.append(fd)
    }

    func testWithDurabilityOffASurvivingSessionsNameIsNotHandedToANewChild() throws {
        try claimRecord("local-kept")
        XCTAssertTrue(SessionRecord.isLive("local-kept"), "the fixture is not live")
        SynaptySettings.shared.localDurableSessions = false

        let launch = TunnelManager().localCommand(agentID: "local-kept")

        XCTAssertNotEqual(launch.agentID, "local-kept",
                          "a directly-run child was given a live session's identity")
        XCTAssertFalse(launch.command.contains("local-kept"),
                       "the name is still on the command line")
    }

    /// AND THE NOTICE AGREES WITH THE NAME, because they are now one
    /// answer rather than two.
    func testTheDecisionTheCommandWasBuiltFromIsTheOneCarriedBack() throws {
        try claimRecord("local-kept")
        SynaptySettings.shared.localDurableSessions = false
        let off = TunnelManager().localCommand(agentID: "local-kept")
        XCTAssertEqual(off.rejoining, .restarted(.durabilityOff(machine: "this Mac")))

        SynaptySettings.shared.localDurableSessions = true
        let on = TunnelManager().localCommand(agentID: "local-kept")
        XCTAssertEqual(on.rejoining, .rejoined)
        XCTAssertEqual(on.agentID, "local-kept")
    }
}
