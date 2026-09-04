import XCTest
@testable import Synapty

/// A REMOTE ARRANGEMENT COMES BACK AS IT WAS ([[RFC-0015]] C-PERSIST,
/// C-RESTORE, [[WI-2026-08-17-025]]).
///
/// It used to be written as a label and a host id and nothing else, which
/// was correct while nothing on the far side outlived the client: a
/// restored remote layout would have pointed at dead ptys. The holder
/// removes that premise.
@MainActor
final class RemoteArrangementTests: XCTestCase {

    private var tmp: URL!
    private var store: HostStore!
    private var builder: HostEntry!
    private var runner: HostEntry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
        store = HostStore()
        builder = HostEntry(label: "builder", address: "builder.example", username: "someone")
        runner = HostEntry(label: "runner", address: "runner.example", username: "someone")
        store.hosts.append(contentsOf: [builder, runner])
    }

    override func tearDown() {
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    /// Two machines in one workspace, split, each leaf standing somewhere.
    private func mixedWorkspace() -> WorkspaceManager {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard let workspace = manager.activeWorkspaceID else { return manager }
        let onBuilder = manager.connections.acquire(host: builder).id
        let onRunner = manager.connections.acquire(host: runner).id
        let a = SplitNode.Pane(label: "build", content: .terminal(command: "x"),
                               workingDirectory: "/srv/build", connectionID: onBuilder)
        let b = SplitNode.Pane(label: "files", content: .files(directory: "/srv/out"),
                               connectionID: onRunner)
        manager.workspaces[0].setLayout(.split(SplitNode.SplitData(
            direction: .vertical,
            first: .slot(SplitNode.Slot(pane: a)),
            second: .slot(SplitNode.Slot(pane: b)),
            ratio: 0.35)))
        _ = workspace
        return manager
    }

    private func roundTrip(_ manager: WorkspaceManager,
                           hostStore: HostStore?) throws -> WorkspaceManager {
        let data = try JSONEncoder().encode(manager.snapshot(planFor: { _ in nil }))
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        let restored = WorkspaceManager()
        _ = restored.restore(from: decoded, hostStore: hostStore)
        return restored
    }

    func testTheShapeOfARemoteArrangementSurvives() throws {
        let restored = try roundTrip(mixedWorkspace(), hostStore: store)

        guard let layout = restored.workspaces.first?.layout,
              case .split(let split) = layout else {
            return XCTFail("the split did not come back: \(String(describing: restored.workspaces.first?.layout))")
        }
        XCTAssertEqual(split.direction, .vertical)
        XCTAssertEqual(split.ratio, 0.35, accuracy: 0.001, "the ratio was not restored")
    }

    func testEachLeafComesBackOnItsOwnMachineAndInItsOwnDirectory() throws {
        let restored = try roundTrip(mixedWorkspace(), hostStore: store)
        let panes = restored.workspaces.flatMap(\.panes)
        XCTAssertEqual(panes.count, 2)

        let build = panes.first { $0.label == "build" }
        XCTAssertEqual(restored.host(ofLeaf: build?.id ?? UUID())?.label, "builder")
        XCTAssertEqual(build?.workingDirectory, "/srv/build",
                       "a leaf came back somewhere other than where it was")

        let files = panes.first { $0.content.fileDirectory != nil }
        XCTAssertEqual(restored.host(ofLeaf: files?.id ?? UUID())?.label, "runner")
        XCTAssertEqual(files?.content.fileDirectory, "/srv/out")
    }

    /// ONE CONNECTION PER HOST, however many leaves name it.
    func testTwoLeavesOnOneHostShareOneConnection() throws {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let onBuilder = manager.connections.acquire(host: builder).id
        let a = SplitNode.Pane(content: .terminal(command: "x"), connectionID: onBuilder)
        let b = SplitNode.Pane(content: .terminal(command: "y"), connectionID: onBuilder)
        manager.workspaces[0].setLayout(.slot(SplitNode.Slot(panes: [a, b])))

        let restored = try roundTrip(manager, hostStore: store)
        let ids = Set(restored.workspaces.flatMap(\.panes).map(\.connectionID))
        XCTAssertEqual(ids.count, 1, "two leaves on one host took two connections")
    }

    /// REMOVING A HOST IS NOT AN INSTRUCTION TO DISCARD THE LAYOUTS THAT
    /// MENTIONED IT.
    func testALeafWhoseHostIsGoneIsKeptRatherThanDropped() throws {
        let manager = mixedWorkspace()
        let emptied = HostStore()   // the host store no longer has either

        let restored = try roundTrip(manager, hostStore: emptied)

        XCTAssertEqual(restored.workspaces.flatMap(\.panes).count, 2,
                       "a leaf was discarded because its host had been deleted")
    }

    /// A store with nothing in it still yields somewhere to work.
    func testARestoreWithNoWorkspacesLeavesOneEmptyOne() {
        let restored = WorkspaceManager()
        _ = restored.restore(from: WorkspaceSnapshot(), hostStore: store)
        XCTAssertEqual(restored.workspaces.count, 1,
                       "a restore that found nothing left the human with nowhere to work")
        XCTAssertNil(restored.workspaces.first?.layout, "the workspace should be empty, not populated")
    }
}
