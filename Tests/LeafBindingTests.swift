import XCTest
@testable import Synapty

/// [[RFC-0015]] C-LEAF-BINDING: a pane carries the connection it runs on,
/// and every "which machine is this?" is answered from the pane rather
/// than from the container it happens to be sitting in.
@MainActor
final class LeafBindingTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    private func makeHost(_ label: String) -> HostEntry {
        HostEntry(label: label, address: "10.0.0.1", username: "u")
    }

    // MARK: - The binding survives every layout operation

    /// Splitting a remote pane must give a remote pane. The new pane
    /// inherits the connection of the one it was split from — nothing
    /// else in the tree knows which machine that was.
    func testSplittingALeafInheritsItsConnection() {
        let connection = UUID()
        let original = SplitNode.Pane(connectionID: connection)
        let root = SplitNode.slot(SplitNode.Slot(pane: original))
        guard case .slot(let slot) = root else { return XCTFail() }

        let added = SplitNode.Pane(connectionID: original.connectionID)
        let (split, newSlot) = root.splitSlot(slot.id, direction: .horizontal, newPane: added)
        guard newSlot != nil, let created = split.findPane(added.id) else {
            return XCTFail("the split must produce a pane")
        }
        XCTAssertEqual(created.connectionID, connection,
                       "a split of a remote pane is another pane on that host")
    }

    /// `arranged` folds existing POSITIONS into a new shape and reuses
    /// them verbatim — the surfaces and ptys are keyed by pane id. The
    /// connection has to ride along with them.
    func testRearrangingPreservesEveryLeafsConnection() {
        let a = SplitNode.Pane(connectionID: UUID())
        let b = SplitNode.Pane(connectionID: UUID())
        let c = SplitNode.Pane(connectionID: UUID())

        let arranged = SplitNode.arranged(
            slots: [.init(pane: a), .init(pane: b), .init(pane: c)], preset: .grid)

        XCTAssertEqual(arranged.findPane(a.id)?.connectionID, a.connectionID)
        XCTAssertEqual(arranged.findPane(b.id)?.connectionID, b.connectionID)
        XCTAssertEqual(arranged.findPane(c.id)?.connectionID, c.connectionID)
    }

    /// A stack rides along with the position holding it, so a pane behind
    /// a tab keeps its machine through a rearrange it never appeared in.
    func testRearrangingCarriesAStackedPanesConnection() {
        let front = SplitNode.Pane(connectionID: UUID())
        let behind = SplitNode.Pane(connectionID: UUID())
        let lone = SplitNode.Pane(connectionID: UUID())

        let arranged = SplitNode.arranged(
            slots: [.init(panes: [front, behind]), .init(pane: lone)], preset: .rows)

        XCTAssertEqual(arranged.findPane(behind.id)?.connectionID, behind.connectionID)
        XCTAssertEqual(arranged.panes.count, 3)
    }

    func testRemovingALeafDoesNotDisturbItsSiblingsConnection() {
        let keep = SplitNode.Pane(connectionID: UUID())
        let drop = SplitNode.Pane(connectionID: UUID())
        let root = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .slot(.init(pane: keep)), second: .slot(.init(pane: drop))))

        guard case .removed(let after) = root.removePane(drop.id) else {
            return XCTFail("the pane was there to remove")
        }
        XCTAssertEqual(after.findPane(keep.id)?.connectionID, keep.connectionID)
    }

    // MARK: - The machine is read downward (the docking guarantee)

    /// The claim docking rests on: a pane moved into a position belonging
    /// to another machine still reports its own.
    func testALeafReportsItsOwnHostAfterMovingIntoAnotherSessionsTab() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let host = makeHost("remotehost")
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: host,
                                 command: "bash connect.sh a 10.0.0.1 22 u 9000")

        guard let localLeaf = manager.workspaces[0].panes.first?.id,
              let localSlot = manager.workspaces[0].slots.first?.id,
              let remoteLeaf = manager.workspaces[1].panes.first?.id
        else { return XCTFail("both workspaces start with a pane") }

        XCTAssertNil(manager.host(ofLeaf: localLeaf))
        XCTAssertEqual(manager.host(ofLeaf: remoteLeaf)?.label, "remotehost")

        // Put the remote pane into the LOCAL workspace's position — the
        // arrangement docking produces, and now ONE operation on ONE type.
        manager.stackPane(remoteLeaf, intoSlot: localSlot)

        XCTAssertEqual(manager.host(ofLeaf: remoteLeaf)?.label, "remotehost",
                       "the answer never lived in the tree it was moved out of")
        XCTAssertNil(manager.host(ofLeaf: localLeaf),
                     "and the pane it landed beside is unchanged")
    }

    func testATabCanHoldLeavesFromTwoMachines() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: makeHost("remotehost"),
                                 command: "bash connect.sh a 10.0.0.1 22 u 9000")
        guard let localSlot = manager.workspaces[0].slots.first?.id,
              let remoteLeaf = manager.workspaces[1].panes.first?.id
        else { return XCTFail() }

        manager.stackPane(remoteLeaf, intoSlot: localSlot)

        guard let slot = manager.workspaces[0].slots.first else { return XCTFail() }
        XCTAssertTrue(slot.isStacked, "two panes in one position")
        let hosts = slot.panes.map { manager.host(ofLeaf: $0.id)?.label }
        XCTAssertEqual(Set(hosts.map { $0 ?? "local" }), ["local", "remotehost"],
                       "one position, two machines — the arrangement this model exists to permit")
    }

    /// The other half of docking: dropped on an EDGE rather than a centre,
    /// the pane becomes a position of its own and still answers for itself.
    func testAMovedLeafKeepsItsMachineWhenItBecomesItsOwnPosition() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: makeHost("remotehost"),
                                 command: "bash connect.sh a 10.0.0.1 22 u 9000")
        guard let localSlot = manager.workspaces[0].slots.first?.id,
              let remoteLeaf = manager.workspaces[1].panes.first?.id
        else { return XCTFail() }

        manager.movePane(remoteLeaf, besideSlot: localSlot, direction: .vertical)

        XCTAssertEqual(manager.workspaces[0].slots.count, 2, "a new position, not a tab")
        XCTAssertEqual(manager.host(ofLeaf: remoteLeaf)?.label, "remotehost")
    }

    /// Local is a connection like any other, so "is this pane local" is
    /// the same question asked the same way.
    func testLocalLeavesResolveThroughTheLocalConnection() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard let leaf = manager.workspaces[0].panes.first
        else { return XCTFail() }
        XCTAssertEqual(leaf.connectionID, manager.connections.localID)
        XCTAssertNil(manager.host(ofLeaf: leaf.id))
    }

    /// A second pane on a host already connected must not open a second
    /// link ([[RFC-0015]] C-DIAL).
    func testASecondPaneOnTheSameHostSharesTheConnection() {
        let manager = WorkspaceManager()
        let host = makeHost("remotehost")
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: host,
                                 command: "bash connect.sh a 10.0.0.1 22 u 9000")
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: host,
                                 command: "bash connect.sh b 10.0.0.1 22 u 9000")

        XCTAssertEqual(manager.connections.remoteConnections.count, 1,
                       "one host, one link")
        let leaves = manager.workspaces.flatMap(\.panes)
        XCTAssertEqual(Set(leaves.map(\.connectionID)).count, 1)
    }

    /// Splitting a remote pane must not dial a second time either.
    func testSplittingARemotePaneSharesTheSameConnection() {
        let manager = WorkspaceManager()
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: makeHost("remotehost"),
                                 command: "bash connect.sh a 10.0.0.1 22 u 9000")
        guard let leaf = manager.workspaces[0].panes.first
        else { return XCTFail() }

        manager.focusLeaf(leaf.id)
        manager.splitFocusedLeaf(direction: .horizontal)

        let leaves = manager.workspaces[0].panes
        XCTAssertEqual(leaves.count, 2)
        XCTAssertEqual(Set(leaves.map(\.connectionID)).count, 1)
        XCTAssertEqual(manager.connections.remoteConnections.count, 1)
    }
}
