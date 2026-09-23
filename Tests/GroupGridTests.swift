import XCTest
@testable import Synapty

/// OPEN A GROUP AS A GRID ([[WI-2026-09-02-009]]): one connected pane per
/// member, each in its own position, in a workspace named after the
/// group. The point where host management meets the multiplexer.
@MainActor
final class GroupGridTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
    }

    private func host(_ label: String) -> HostEntry {
        HostEntry(label: label, address: "\(label).example", username: "u")
    }

    func testEveryMemberGetsItsOwnPosition() {
        let m = WorkspaceManager()
        let opened = m.addRemoteGrid(label: "Company", hosts: ["a", "b", "c", "d"].map(host))
        let ws = m.activeWorkspace!
        XCTAssertEqual(ws.label, "Company", "the workspace is the group")
        XCTAssertEqual(ws.slots.count, 4, "a position each, not a stack")
        XCTAssertEqual(opened.count, 4)
        XCTAssertEqual(Set(opened.map(\.paneID)), Set(ws.panes.map(\.id)))
        for (paneID, entry) in opened {
            XCTAssertEqual(m.host(ofLeaf: paneID)?.label, entry.label, "each pane is on its own machine")
        }
        XCTAssertEqual(ws.focusedPaneID, opened.first?.paneID, "focus starts on the first member")
    }

    /// Four members is a 2×2: two rows of two — the grid preset's shape.
    func testFourMembersMakeATwoByTwo() {
        let m = WorkspaceManager()
        _ = m.addRemoteGrid(label: "g", hosts: ["a", "b", "c", "d"].map(host))
        guard case .split(let root) = m.activeWorkspace!.layout!,
              case .split(let top) = root.first, case .split(let bottom) = root.second
        else { return XCTFail("expected a split of two splits") }
        XCTAssertEqual(root.direction, .vertical)
        XCTAssertEqual(top.direction, .horizontal)
        XCTAssertEqual(bottom.direction, .horizontal)
    }

    func testOneMemberIsASinglePosition() {
        let m = WorkspaceManager()
        _ = m.addRemoteGrid(label: "solo", hosts: [host("a")])
        XCTAssertEqual(m.activeWorkspace!.slots.count, 1)
    }

    /// An empty group opens nothing — a workspace with no machine in it
    /// would be a container the human did not ask for.
    func testAnEmptyGroupOpensNothing() {
        let m = WorkspaceManager()
        let opened = m.addRemoteGrid(label: "empty", hosts: [])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(m.workspaces.isEmpty)
    }

    /// Opening the same group twice gives the second workspace a
    /// distinct name, as any second workspace gets.
    func testASecondOpeningIsNamedApart() {
        let m = WorkspaceManager()
        _ = m.addRemoteGrid(label: "Company", hosts: [host("a")])
        _ = m.addRemoteGrid(label: "Company", hosts: [host("a")])
        XCTAssertEqual(Set(m.workspaces.map(\.label)).count, 2)
    }
}
