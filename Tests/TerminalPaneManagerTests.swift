import XCTest
@testable import Synapty

final class TerminalPaneManagerTests: XCTestCase {

    // MARK: - Initialization

    func testInitCreatesOneLocalSession() {
        let manager = TerminalPaneManager()
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(manager.sessions.first!.isLocal)
        XCTAssertEqual(manager.sessions.first!.label, "Local")
        XCTAssertNotNil(manager.activeSessionID)
    }

    func testInitSessionHasOnePane() {
        let manager = TerminalPaneManager()
        let session = manager.sessions.first!
        XCTAssertEqual(session.panes.count, 1)
        XCTAssertEqual(session.panes.first!.label, "Shell")
        XCTAssertNotNil(session.activePaneID)
    }

    // MARK: - Session Management

    func testAddLocalSessionIncreasesCount() {
        let manager = TerminalPaneManager()
        manager.addLocalSession()
        XCTAssertEqual(manager.sessions.count, 2)
    }

    func testAddLocalSessionSetsActive() {
        let manager = TerminalPaneManager()
        let firstID = manager.activeSessionID
        manager.addLocalSession()
        XCTAssertNotEqual(manager.activeSessionID, firstID)
        XCTAssertEqual(manager.activeSessionID, manager.sessions.last?.id)
    }

    func testAddRemoteSession() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = TerminalPaneManager()
        manager.addRemoteSession(label: "GPU Box", hostEntry: host, command: "bash connect.sh agent-1 10.0.1.5 22 user 9000")
        let session = manager.sessions.last!
        XCTAssertEqual(session.label, "GPU Box")
        XCTAssertFalse(session.isLocal)
        XCTAssertNotNil(session.hostEntry)
        XCTAssertEqual(manager.activeSessionID, session.id)
    }

    func testRemoveSession() {
        let manager = TerminalPaneManager()
        manager.addLocalSession()
        let count = manager.sessions.count
        let session = manager.sessions.last!
        manager.removeSession(session)
        XCTAssertEqual(manager.sessions.count, count - 1)
    }

    func testRemoveActiveSessionSwitchesToAnother() {
        let manager = TerminalPaneManager()
        manager.addLocalSession()
        let second = manager.sessions.last!
        manager.removeSession(second)
        XCTAssertNotNil(manager.activeSessionID)
        XCTAssertNotEqual(manager.activeSessionID, second.id)
    }

    func testRemoveAllSessionsSetsActiveNil() {
        let manager = TerminalPaneManager()
        let session = manager.sessions.first!
        manager.removeSession(session)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.activeSessionID)
    }

    // MARK: - Pane Management

    func testAddPaneToActiveSession() {
        let manager = TerminalPaneManager()
        let initialCount = manager.sessions.first!.panes.count
        manager.addPaneToActiveSession()
        XCTAssertEqual(manager.sessions.first!.panes.count, initialCount + 1)
    }

    func testRemovePaneClosesSessionIfLast() {
        let manager = TerminalPaneManager()
        let pane = manager.sessions.first!.panes.first!
        manager.removePane(pane)
        // Removing the only pane removes the session
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    // MARK: - Split Tree

    func testSplitFocusedLeaf() {
        let manager = TerminalPaneManager()
        let leafID = manager.activePane!.focusedLeafID!
        manager.splitFocusedLeaf(direction: .horizontal)
        // After split, focused leaf should be the NEW leaf (not the original)
        let newFocusedID = manager.activePane!.focusedLeafID!
        XCTAssertNotEqual(newFocusedID, leafID)
        // Should now have 2 leaves
        XCTAssertEqual(manager.activePane!.splitRoot.leaves.count, 2)
    }

    func testSplitNonRightmostLeafFocusesCorrectly() {
        let manager = TerminalPaneManager()
        // Create initial split: [A | B]
        manager.splitFocusedLeaf(direction: .horizontal)
        let leaves = manager.activePane!.splitRoot.leaves
        XCTAssertEqual(leaves.count, 2)
        let leafA = leaves[0].id
        let leafB = leaves[1].id

        // Focus leaf A (left side)
        manager.focusLeaf(leafA)
        XCTAssertEqual(manager.activePane!.focusedLeafID, leafA)

        // Split leaf A: [A1 | A2] | B
        manager.splitFocusedLeaf(direction: .horizontal)
        let newFocused = manager.activePane!.focusedLeafID!
        // New focused should NOT be B
        XCTAssertNotEqual(newFocused, leafB)
        // New focused should NOT be the original A
        XCTAssertNotEqual(newFocused, leafA)
        // Should now have 3 leaves
        XCTAssertEqual(manager.activePane!.splitRoot.leaves.count, 3)
    }

    func testCloseFocusedLeaf() {
        let manager = TerminalPaneManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        XCTAssertEqual(manager.activePane!.splitRoot.leaves.count, 2)
        manager.closeFocusedLeaf()
        XCTAssertEqual(manager.activePane!.splitRoot.leaves.count, 1)
    }

    func testFocusNextLeafCycles() {
        let manager = TerminalPaneManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let leaves = manager.activePane!.splitRoot.leaves
        let firstID = leaves[0].id
        let secondID = leaves[1].id
        // Currently focused on second (new leaf)
        XCTAssertEqual(manager.activePane!.focusedLeafID, secondID)
        manager.focusNextLeaf()
        XCTAssertEqual(manager.activePane!.focusedLeafID, firstID)
        manager.focusNextLeaf()
        XCTAssertEqual(manager.activePane!.focusedLeafID, secondID)
    }

    // MARK: - All Leaves

    func testAllLeavesSpansAllSessions() {
        let manager = TerminalPaneManager()
        manager.addLocalSession()
        // Two sessions, each with 1 leaf = 2 total
        XCTAssertEqual(manager.allLeaves.count, 2)
    }

    func testAllLeavesIncludesSplits() {
        let manager = TerminalPaneManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        // One session, one pane, 2 leaves from split
        XCTAssertEqual(manager.allLeaves.count, 2)
    }

    // MARK: - Session IDs Stable

    func testSessionIDsStableAcrossOperations() {
        let manager = TerminalPaneManager()
        let firstID = manager.sessions.first!.id
        manager.addLocalSession()
        XCTAssertEqual(manager.sessions.first!.id, firstID)
    }
}
