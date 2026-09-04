import XCTest
@testable import Synapty

/// A ROW IS A WORKSPACE, NOT A LOGIN ([[RFC-0015]] C-WORKSPACE,
/// [[WI-2026-08-17-026]]).
///
/// The sidebar used to give each row a connection state and a host
/// address. Once a workspace can hold panes on three machines, neither is
/// a fact it has: connectedness belongs to the pane that has the
/// connection, and "which machine is this?" is the leaf's question
/// (C-LEAF-BINDING).
///
/// WHAT MAY NOT BE LOST IN THE MOVE is failure — work put aside that has
/// broken must be visible without opening it (C-FAILURE).
@MainActor
final class SidebarRowTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
    }

    override func tearDown() {
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    private func workspaceWithFailure(_ why: String) -> (WorkspaceManager, WorkspaceManager.Workspace) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let host = HostEntry(label: "builder", address: "b.example", username: "someone")
        let remote = manager.connections.acquire(host: host).id
        manager.connections.markFailed(remote, why)
        let here = SplitNode.Pane(content: .terminal(command: "x"),
                                  connectionID: manager.connections.localID)
        let there = SplitNode.Pane(content: .terminal(command: "y"), connectionID: remote)
        manager.workspaces[0].setLayout(.slot(SplitNode.Slot(panes: [here, there])))
        return (manager, manager.workspaces[0])
    }

    /// THE REASON, NOT MERELY THE FACT. A row that says something broke
    /// without saying what sends the human in to find out, which is the
    /// trip C-FAILURE exists to save them.
    func testAWorkspaceWithABrokenConnectionSaysWhatBroke() {
        let (manager, workspace) = workspaceWithFailure("host key changed")
        XCTAssertEqual(manager.firstFailure(workspace), "host key changed")
        XCTAssertTrue(manager.hasFailedConnection(workspace))
    }

    /// A WORKSPACE THAT IS MERELY DIALLING IS NOT A FAILURE, and the row
    /// says nothing about it — the pane draws its own dial.
    func testADiallingWorkspaceReportsNoFailure() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let host = HostEntry(label: "builder", address: "b.example", username: "someone")
        let remote = manager.connections.acquire(host: host).id  // .connecting
        let pane = SplitNode.Pane(content: .terminal(command: "x"), connectionID: remote)
        manager.workspaces[0].setLayout(.slot(SplitNode.Slot(pane: pane)))

        XCTAssertNil(manager.firstFailure(manager.workspaces[0]),
                     "a dial in progress was reported as a failure")
    }

    func testAHealthyWorkspaceReportsNothing() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        XCTAssertNil(manager.firstFailure(manager.workspaces[0]))
        XCTAssertFalse(manager.hasFailedConnection(manager.workspaces[0]))
    }
}
