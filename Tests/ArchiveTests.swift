import XCTest
@testable import Synapty

/// PUTTING WORK AWAY MUST ACTUALLY PUT IT AWAY ([[RFC-0015]] C-ARCHIVE,
/// [[WI-2026-08-17-027]]).
///
/// "A workspace that is archived while its links and tunnels stay open has
/// not been archived; it has been hidden, and the resources the human
/// meant to reclaim are still spent."
@MainActor
final class ArchiveTests: XCTestCase {

    private var tmp: URL!
    private var store: HostStore!
    private var builder: HostEntry!
    private var runner: HostEntry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
        store = HostStore()
        builder = HostEntry(label: "builder", address: "b.example", username: "someone")
        runner = HostEntry(label: "runner", address: "r.example", username: "someone")
        store.hosts.append(contentsOf: [builder, runner])
    }

    override func tearDown() {
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    /// A workspace with a split across two machines, and a working
    /// directory on each.
    private func makeManager() -> (WorkspaceManager, UUID) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let onBuilder = manager.connections.acquire(host: builder).id
        let a = SplitNode.Pane(label: "build", content: .terminal(command: "x"),
                               workingDirectory: "/srv/build", connectionID: onBuilder)
        let b = SplitNode.Pane(label: "files", content: .files(directory: "/srv/out"),
                               connectionID: manager.connections.localID)
        manager.workspaces[0].setLayout(.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .slot(SplitNode.Slot(pane: a)),
            second: .slot(SplitNode.Slot(pane: b)),
            ratio: 0.6)))
        manager.syncReferencesForTest()
        return (manager, manager.workspaces[0].id)
    }

    // MARK: - It releases

    func testArchivingReleasesTheConnectionNothingOpenStillNeeds() {
        let (manager, workspace) = makeManager()
        XCTAssertEqual(manager.connections.connections.count, 2, "local plus builder")

        manager.archiveWorkspace(workspace)

        XCTAssertNil(manager.connections.connection(forHost: builder.id),
                     "the link was left open, so the work was hidden rather than put away")
    }

    /// IMMEDIATELY. The grace period absorbs accidental churn; it is not
    /// there to delay a decision the human has stated.
    func testTheReleaseDoesNotWaitOutTheGracePeriod() {
        let (manager, workspace) = makeManager()
        manager.connections.grace = 3600   // nothing would ever sweep

        manager.archiveWorkspace(workspace)

        XCTAssertNil(manager.connections.connection(forHost: builder.id))
    }

    /// ARCHIVING ONE MUST NOT DISTURB ANOTHER.
    func testAConnectionAnotherOpenWorkspaceIsUsingSurvives() {
        let (manager, workspace) = makeManager()
        // A second workspace with a pane on the SAME machine.
        manager.addLocalWorkspace()
        let shared = manager.connections.acquire(host: builder).id
        let pane = SplitNode.Pane(content: .terminal(command: "y"), connectionID: shared)
        manager.workspaces[1].setLayout(.slot(SplitNode.Slot(pane: pane)))
        manager.syncReferencesForTest()

        manager.archiveWorkspace(workspace)

        XCTAssertNotNil(manager.connections.connection(forHost: builder.id),
                        "putting one workspace away cut a link another was holding")
    }

    // MARK: - It comes back

    func testAnArchivedWorkspaceIsStillListedWithItsName() {
        let (manager, workspace) = makeManager()
        manager.archiveWorkspace(workspace)

        let put = manager.workspaces.first { $0.id == workspace }
        XCTAssertNotNil(put, "the workspace disappeared instead of being put away")
        XCTAssertEqual(put?.label, "Local")
        XCTAssertTrue(put?.isArchived == true)
        XCTAssertTrue(put?.panes.isEmpty == true, "an archived workspace holds no panes")
    }

    func testARoundTripReturnsTheSameArrangement() {
        let (manager, workspace) = makeManager()
        manager.archiveWorkspace(workspace)

        XCTAssertTrue(manager.unarchiveWorkspace(workspace, hostStore: store))

        guard let layout = manager.workspaces.first(where: { $0.id == workspace })?.layout,
              case .split(let split) = layout else {
            return XCTFail("the split did not come back")
        }
        XCTAssertEqual(split.direction, .horizontal)
        XCTAssertEqual(split.ratio, 0.6, accuracy: 0.001)

        let panes = manager.workspaces.first { $0.id == workspace }?.panes ?? []
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.first { $0.label == "build" }?.workingDirectory, "/srv/build")
        XCTAssertEqual(panes.first { $0.content.fileDirectory != nil }?.content.fileDirectory,
                       "/srv/out")
    }

    /// AND WHERE THE HUMAN WAS WORKING. A round trip that returns the
    /// arrangement with the focus moved has returned a picture of it.
    func testTheRoundTripReturnsTheHumanToThePaneTheyWereIn() {
        let (manager, workspace) = makeManager()
        let second = manager.workspaces[0].panes.first { $0.label == "files" }!
        manager.workspaces[0].focus(second.id)

        manager.archiveWorkspace(workspace)
        _ = manager.unarchiveWorkspace(workspace, hostStore: store)

        let back = manager.workspaces.first { $0.id == workspace }
        XCTAssertEqual(back?.focusedPane?.content.fileDirectory, "/srv/out",
                       "it came back with the focus on the wrong pane")
    }

    /// And the machine each pane was on.
    func testEachPaneComesBackOnItsOwnMachine() {
        let (manager, workspace) = makeManager()
        manager.archiveWorkspace(workspace)
        _ = manager.unarchiveWorkspace(workspace, hostStore: store)

        let panes = manager.workspaces.first { $0.id == workspace }?.panes ?? []
        let build = panes.first { $0.label == "build" }
        XCTAssertEqual(manager.host(ofLeaf: build?.id ?? UUID())?.label, "builder")
        let files = panes.first { $0.content.fileDirectory != nil }
        XCTAssertNil(manager.host(ofLeaf: files?.id ?? UUID()), "the local pane went remote")
    }

    // MARK: - Pin changes ordering and nothing else

    func testAPinnedWorkspaceIsListedFirstAndAnArchivedOneLast() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addLocalWorkspace()
        manager.addLocalWorkspace()
        let (first, middle, last) = (manager.workspaces[0].id, manager.workspaces[1].id,
                                     manager.workspaces[2].id)

        manager.setPinned(last, true)
        manager.archiveWorkspace(first)

        XCTAssertEqual(manager.orderedWorkspaces.map(\.id), [last, middle, first])
    }

    /// PINNING IS ORDERING AND NOTHING ELSE, so two pinned workspaces keep
    /// the order the human dragged them into.
    func testPinningPreservesTheHumansOwnOrderWithinTheGroup() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addLocalWorkspace()
        let (a, b) = (manager.workspaces[0].id, manager.workspaces[1].id)
        manager.setPinned(b, true)
        manager.setPinned(a, true)

        XCTAssertEqual(manager.orderedWorkspaces.map(\.id), [a, b])
    }

    func testPinningDoesNotTouchLifetimeOrConnections() {
        let (manager, workspace) = makeManager()
        let before = manager.connections.connections.count

        manager.setPinned(workspace, true)

        XCTAssertTrue(manager.workspaces.first { $0.id == workspace }?.isPinned == true)
        XCTAssertEqual(manager.connections.connections.count, before,
                       "pinning changed what the workbench was holding")
        XCTAssertFalse(manager.workspaces.first { $0.id == workspace }?.isArchived == true)
        XCTAssertEqual(manager.workspaces.first { $0.id == workspace }?.panes.count, 2)
    }

    /// A REOPENED REMOTE WORKSPACE IS DIALLED.
    ///
    /// `archiveWorkspace` releases the connections, so reopening mints
    /// fresh ones in `.connecting` that nothing marks — and a leaf whose
    /// connection is not up refuses to build a terminal at all. There is
    /// no Try Again either: that renders only for `.failed`. So a human
    /// who put remote work away and took it back out got a dial spinner
    /// and no terminal, until some unrelated act happened to dial the same
    /// host. [[RFC-0015]] C-UNARCHIVE says unarchiving MUST acquire
    /// connections by host exactly as restore does.
    func testReopeningARemoteWorkspaceAsksForItToBeDialled() {
        let (manager, workspace) = makeManager()
        _ = manager.takeWorkspacesAwaitingDial()

        manager.archiveWorkspace(workspace)
        XCTAssertTrue(manager.takeWorkspacesAwaitingDial().isEmpty,
                      "putting work away is not a reason to dial anything")

        XCTAssertTrue(manager.unarchiveWorkspace(workspace, hostStore: store))
        XCTAssertEqual(manager.takeWorkspacesAwaitingDial(), [workspace],
                       "the reopened workspace has a remote pane and nobody was asked to dial it")
    }

    /// TAKEN, NOT READ. The consumer is a view that may run more than
    /// once, and dialling twice must be the same as dialling once.
    func testTheDialRequestIsTakenOnce() {
        let (manager, workspace) = makeManager()
        manager.archiveWorkspace(workspace)
        _ = manager.unarchiveWorkspace(workspace, hostStore: store)

        XCTAssertEqual(manager.takeWorkspacesAwaitingDial(), [workspace])
        XCTAssertTrue(manager.takeWorkspacesAwaitingDial().isEmpty,
                      "a second read asked for the same dial again")
    }

    /// A LOCAL-ONLY WORKSPACE ASKS FOR NOTHING. There is no host to reach,
    /// and a dial request for one would be a request nobody can meet.
    func testReopeningALocalWorkspaceAsksForNoDial() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let workspace = manager.workspaces[0].id
        _ = manager.takeWorkspacesAwaitingDial()

        manager.archiveWorkspace(workspace)
        _ = manager.unarchiveWorkspace(workspace, hostStore: store)

        XCTAssertTrue(manager.takeWorkspacesAwaitingDial().isEmpty,
                      "a workspace with nothing remote in it was queued for a dial")
    }
}

/// PUT AWAY STAYS PUT AWAY ACROSS A RESTART ([[RFC-0015]] C-ARCHIVE).
@MainActor
final class ArchivePersistenceTests: XCTestCase {

    private var tmp: URL!
    private var store: HostStore!
    private var host: HostEntry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
        store = HostStore()
        host = HostEntry(label: "builder", address: "b.example", username: "someone")
        store.hosts.append(host)
    }

    override func tearDown() {
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    private func archivedManager() -> (WorkspaceManager, UUID) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let remote = manager.connections.acquire(host: host).id
        let pane = SplitNode.Pane(label: "build", content: .terminal(command: "x"),
                                  workingDirectory: "/srv/build", connectionID: remote)
        manager.workspaces[0].setLayout(.slot(SplitNode.Slot(pane: pane)))
        manager.syncReferencesForTest()
        let id = manager.workspaces[0].id
        manager.archiveWorkspace(id)
        return (manager, id)
    }

    private func restart(_ manager: WorkspaceManager) throws -> WorkspaceManager {
        let data = try JSONEncoder().encode(manager.snapshot(planFor: { _ in nil }))
        let restored = WorkspaceManager()
        _ = restored.restore(from: try JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
                             hostStore: store)
        return restored
    }

    /// A WORKSPACE WHOSE PUT-AWAY STATE DID NOT SURVIVE would spend, on
    /// the next launch, precisely what putting it away reclaimed.
    func testAnArchivedWorkspaceComesBackArchivedAndDialsNothing() throws {
        let (manager, id) = archivedManager()
        let restored = try restart(manager)

        let put = restored.workspaces.first { $0.id == id }
        XCTAssertTrue(put?.isArchived == true, "it came back open and dialling")
        XCTAssertNil(restored.connections.connection(forHost: host.id),
                     "restoring an archived workspace opened the link it had let go")
    }

    /// AND ITS ARRANGEMENT IS STILL THERE, so taking it back out after a
    /// restart returns what was put away.
    func testTakingItBackOutAfterARestartReturnsTheArrangement() throws {
        let (manager, id) = archivedManager()
        let restored = try restart(manager)

        XCTAssertTrue(restored.unarchiveWorkspace(id, hostStore: store))
        let panes = restored.workspaces.first { $0.id == id }?.panes ?? []
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes.first?.workingDirectory, "/srv/build")
        XCTAssertEqual(restored.host(ofLeaf: panes[0].id)?.label, "builder")
    }

    /// FOCUS SURVIVES THE ARCHIVE AND THE RESTART BOTH, since the
    /// arrangement is written down once and read back once.
    func testTheFocusedPositionSurvivesARestartWhileArchived() throws {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let local = manager.connections.localID
        let a = SplitNode.Pane(label: "left", content: .terminal(command: "x"),
                               connectionID: local)
        let b = SplitNode.Pane(label: "right", content: .terminal(command: "y"),
                               connectionID: local)
        manager.workspaces[0].setLayout(.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .slot(SplitNode.Slot(pane: a)),
            second: .slot(SplitNode.Slot(pane: b)),
            ratio: 0.5)))
        manager.syncReferencesForTest()
        manager.workspaces[0].focus(b.id)
        let id = manager.workspaces[0].id
        manager.archiveWorkspace(id)

        let restored = try restart(manager)
        XCTAssertTrue(restored.unarchiveWorkspace(id, hostStore: store))
        XCTAssertEqual(restored.workspaces.first { $0.id == id }?.focusedPane?.label, "right")
    }

    func testPinSurvivesARestart() throws {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let id = manager.workspaces[0].id
        manager.setPinned(id, true)

        let restored = try restart(manager)
        XCTAssertTrue(restored.workspaces.first { $0.id == id }?.isPinned == true)
    }
}

/// WHAT AN ARCHIVED ROW CAN SAY ABOUT ITSELF ([[RFC-0015]] C-ARCHIVE: it
/// is reopenable "without the human remembering what was in it").
@MainActor
final class ArchivedSummaryTests: XCTestCase {

    private func manager(_ layout: (WorkspaceManager) -> SplitNode) -> (WorkspaceManager, UUID) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.workspaces[0].setLayout(layout(manager))
        let id = manager.workspaces[0].id
        manager.archiveWorkspace(id)
        return (manager, id)
    }

    private func pane(_ manager: WorkspaceManager) -> SplitNode.Pane {
        SplitNode.Pane(content: .terminal(command: "x"),
                       connectionID: manager.connections.localID)
    }

    func testItCountsTheTabsItWasHolding() {
        let (manager, id) = manager { .slot(SplitNode.Slot(panes: [pane($0), pane($0)])) }
        let put = manager.workspaces.first { $0.id == id }!
        XCTAssertEqual(manager.archivedSummary(put), "2 tabs")
    }

    func testItCountsTheSplitsWhereThereIsMoreThanOnePosition() {
        let (manager, id) = manager { m in
            .split(SplitNode.SplitData(
                direction: .vertical,
                first: .slot(SplitNode.Slot(pane: pane(m))),
                second: .slot(SplitNode.Slot(pane: pane(m))),
                ratio: 0.5))
        }
        let put = manager.workspaces.first { $0.id == id }!
        XCTAssertEqual(manager.archivedSummary(put), "2 tabs · 2 splits")
    }

    func testAnOpenWorkspaceHasNoSuchSummary() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        XCTAssertEqual(manager.archivedSummary(manager.workspaces[0]), "")
    }
}

/// A SNAPSHOT WITHOUT THE FLAGS IS STILL A SNAPSHOT ([[RFC-0015]]
/// C-PERSIST).
///
/// Swift's synthesised decoder throws on a missing key even where the
/// property has a default, and one thrown key discards the whole file.
/// Adding `isArchived`/`isPinned` made every session.json already written
/// unreadable — the next launch would have found nothing and written a
/// fresh empty workspace over the human's arrangement. The bytes below
/// are what the previous build wrote, byte for byte.
final class SnapshotToleranceTests: XCTestCase {

    private let asPreviouslyWritten = """
    {"version":1,"workspaces":[{"label":"Local","focusedSlotIndex":0,
    "root":{"kind":"slot","slot":{"activeIndex":0,"panes":[
    {"label":"Shell","userRenamed":false,"pwd":"/tmp","wakeArmed":false,
    "agentID":"local-4e79","content":{"kind":"terminal"}}]}}}]}
    """

    /// AND THE SAME LINE IS OWED BY EVERY FIELD ADDED SINCE. `setAside`
    /// was the next one ([[RFC-0015]] C-PANE-ARCHIVE); without its
    /// `decodeIfPresent` the bytes above throw and the arrangement is gone.
    func testAWorkspaceWrittenBeforeArchivedPanesExistedStillLoads() throws {
        let snap = try JSONDecoder().decode(
            WorkspaceSnapshot.self, from: Data(asPreviouslyWritten.utf8))

        XCTAssertEqual(snap.workspaces.count, 1, "the whole file was discarded over a missing key")
        XCTAssertEqual(snap.workspaces[0].archivedPanes, [])
    }

    func testAWorkspaceWithNoFlagsInTheFileLoadsAsNeitherPinnedNorArchived() throws {
        let snap = try JSONDecoder().decode(
            WorkspaceSnapshot.self, from: Data(asPreviouslyWritten.utf8))

        XCTAssertEqual(snap.workspaces.count, 1, "the whole file was discarded over a missing flag")
        XCTAssertFalse(snap.workspaces[0].isArchived)
        XCTAssertFalse(snap.workspaces[0].isPinned)
        XCTAssertEqual(snap.workspaces[0].root?.slotEntries.first?.panes.first?.pwd, "/tmp",
                       "and it still carries what it was holding")
    }

    /// THE COST OF GETTING THIS WRONG, stated as a test because the
    /// symptom is silent: an unreadable file is an empty workbench, and an
    /// empty workbench writes itself over the file it could not read.
    @MainActor
    func testARestoreFromThatFileKeepsTheWorkspace() throws {
        let snap = try JSONDecoder().decode(
            WorkspaceSnapshot.self, from: Data(asPreviouslyWritten.utf8))
        let manager = WorkspaceManager()
        _ = manager.restore(from: snap, hostStore: nil)

        XCTAssertEqual(manager.workspaces.map(\.label), ["Local"])
        XCTAssertEqual(manager.workspaces[0].panes.count, 1)
    }
}

/// WHAT ENDING A WORKSPACE OWES ITS PANES, and what putting one away and
/// taking it back out owes them ([[WI-2026-08-30-007]]).
@MainActor
final class WorkspaceEndingTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
    }

    override func tearDown() {
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    /// A workspace with one pane, built rather than inherited: what
    /// `addLocalWorkspace` produces depends on globals this test has no
    /// business depending on.
    private func makeManager() -> (WorkspaceManager, UUID) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let pane = SplitNode.Pane(label: "shell", content: .terminal(command: "x"),
                                  connectionID: manager.connections.localID)
        manager.workspaces[0].setLayout(.slot(SplitNode.Slot(pane: pane)))
        return (manager, pane.id)
    }

    /// ARCHIVING AND CLOSING ARE THE SAME END STATE for the panes, and one
    /// of them forgot them while the other did not — so a closed
    /// workspace held its pool tenants and kept per-leaf state for panes
    /// that no longer existed.
    func testClosingAWorkspaceForgetsItsPanesLikeArchivingDoes() {
        let (manager, leafID) = makeManager()
        manager.setWakeArmed(leafID, true)
        XCTAssertTrue(manager.isWakeArmed(leafID))

        manager.removeWorkspace(manager.workspaces[0])

        XCTAssertFalse(manager.isWakeArmed(leafID),
                       "a closed workspace kept per-leaf state for a pane that is gone")
    }

    /// THE ARM IS IN THE ARCHIVED TREE THE WHOLE TIME. It was collected on
    /// unarchive and dropped, because re-applying it lived in a loop only
    /// `restore` runs.
    func testAnUnarchivedPaneComesBackArmedIfItWentAwayArmed() {
        let (manager, leafID) = makeManager()
        let workspaceID = manager.workspaces[0].id
        manager.setWakeArmed(leafID, true)

        manager.archiveWorkspace(workspaceID)
        XCTAssertTrue(manager.workspaces[0].isArchived)
        XCTAssertTrue(manager.unarchiveWorkspace(workspaceID, hostStore: nil))

        guard let back = manager.workspaces[0].panes.first
        else { return XCTFail("the workspace came back with no panes") }
        XCTAssertTrue(manager.isWakeArmed(back.id),
                      "a pane armed for wake came back disarmed")
    }
}
