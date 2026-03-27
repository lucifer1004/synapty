import XCTest
@testable import Synapty

final class TerminalPaneManagerTests: XCTestCase {

    // MARK: - Initialization

    func testInitCreatesOneLocalPane() {
        let manager = TerminalPaneManager()
        XCTAssertEqual(manager.panes.count, 1)
        XCTAssertEqual(manager.panes.first?.label, "Local")
        XCTAssertNil(manager.panes.first?.command)
        XCTAssertNotNil(manager.activePaneID)
        XCTAssertEqual(manager.activePaneID, manager.panes.first?.id)
    }

    // MARK: - Adding Panes

    func testAddLocalPaneIncreasesCount() {
        let manager = TerminalPaneManager()
        let initialCount = manager.panes.count
        manager.addLocalPane()
        XCTAssertEqual(manager.panes.count, initialCount + 1)
    }

    func testAddLocalPaneSetsActive() {
        let manager = TerminalPaneManager()
        let firstID = manager.activePaneID
        manager.addLocalPane()
        XCTAssertNotEqual(manager.activePaneID, firstID)
        XCTAssertEqual(manager.activePaneID, manager.panes.last?.id)
    }

    func testAddRemotePaneSetsCommandAndLabel() {
        let manager = TerminalPaneManager()
        manager.addRemotePane(label: "GPU Box", command: "ssh user@gpu -- bash")
        let remote = manager.panes.last!
        XCTAssertEqual(remote.label, "GPU Box")
        XCTAssertEqual(remote.command, "ssh user@gpu -- bash")
        XCTAssertEqual(manager.activePaneID, remote.id)
    }

    // MARK: - Stable Identity

    func testPaneIDsAreStableAfterAddingMore() {
        let manager = TerminalPaneManager()
        let firstID = manager.panes.first!.id
        manager.addLocalPane()
        manager.addRemotePane(label: "Remote", command: "ssh x")
        // The first pane's ID must not have changed
        XCTAssertEqual(manager.panes.first!.id, firstID)
    }

    func testPaneIDsAreUniqueAcrossAllPanes() {
        let manager = TerminalPaneManager()
        manager.addLocalPane()
        manager.addLocalPane()
        manager.addRemotePane(label: "R1", command: "cmd1")
        manager.addRemotePane(label: "R2", command: "cmd2")
        let ids = manager.panes.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "All pane IDs should be unique")
    }

    // MARK: - Removing Panes

    func testRemovePaneDecreasesCount() {
        let manager = TerminalPaneManager()
        manager.addLocalPane()
        let count = manager.panes.count
        let pane = manager.panes.last!
        manager.removePane(pane)
        XCTAssertEqual(manager.panes.count, count - 1)
    }

    func testRemoveActivePaneSwitchesToAnother() {
        let manager = TerminalPaneManager()
        manager.addLocalPane() // now 2 panes
        let second = manager.panes.last!
        XCTAssertEqual(manager.activePaneID, second.id)
        manager.removePane(second)
        XCTAssertNotNil(manager.activePaneID)
        XCTAssertNotEqual(manager.activePaneID, second.id)
    }

    func testRemoveInactivePaneKeepsActiveUnchanged() {
        let manager = TerminalPaneManager()
        let first = manager.panes.first!
        manager.addLocalPane()
        let activeID = manager.activePaneID
        manager.removePane(first)
        XCTAssertEqual(manager.activePaneID, activeID)
    }

    func testRemoveAllPanesSetsActiveNil() {
        let manager = TerminalPaneManager()
        let pane = manager.panes.first!
        manager.removePane(pane)
        XCTAssertTrue(manager.panes.isEmpty)
        XCTAssertNil(manager.activePaneID)
    }

    func testRemoveDoesNotAffectOtherPaneIDs() {
        let manager = TerminalPaneManager()
        manager.addLocalPane()
        manager.addLocalPane()
        let ids = manager.panes.map { $0.id }
        manager.removePane(manager.panes[1]) // remove middle
        let remainingIDs = manager.panes.map { $0.id }
        // First and last IDs should still be present
        XCTAssertTrue(remainingIDs.contains(ids[0]))
        XCTAssertTrue(remainingIDs.contains(ids[2]))
    }

    // MARK: - Activation

    func testActivateSetsActivePaneID() {
        let manager = TerminalPaneManager()
        manager.addLocalPane()
        let first = manager.panes.first!
        manager.activate(first)
        XCTAssertEqual(manager.activePaneID, first.id)
    }

    func testActivePaneReturnsCorrectPane() {
        let manager = TerminalPaneManager()
        manager.addRemotePane(label: "R", command: "cmd")
        let remote = manager.panes.last!
        manager.activate(remote)
        XCTAssertEqual(manager.activePane?.id, remote.id)
        XCTAssertEqual(manager.activePane?.label, "R")
    }

    func testActivePaneFallsBackToFirstWhenIDNil() {
        let manager = TerminalPaneManager()
        manager.addLocalPane()
        manager.activePaneID = nil
        XCTAssertEqual(manager.activePane?.id, manager.panes.first?.id)
    }

    // MARK: - Ordering

    func testPanesOrderIsInsertionOrder() {
        let manager = TerminalPaneManager()
        manager.addRemotePane(label: "A", command: "a")
        manager.addRemotePane(label: "B", command: "b")
        manager.addRemotePane(label: "C", command: "c")
        let labels = manager.panes.map { $0.label }
        XCTAssertEqual(labels, ["Local", "A", "B", "C"])
    }
}
