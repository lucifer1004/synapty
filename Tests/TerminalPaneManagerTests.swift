import XCTest
@testable import Synapty

@MainActor
final class TerminalPaneManagerTests: XCTestCase {

    /// Established explicitly — addLocalSession() consults
    /// TunnelManager.shared for the local command; riding the hosted
    /// app's ContentView.onAppear made these tests pass by accident
    /// (WI-2026-08-08-020).
    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    /// Helper: creates a manager with one local session (mimics ContentView.onAppear).
    private func makeManager() -> TerminalPaneManager {
        let m = TerminalPaneManager()
        m.addLocalSession()
        return m
    }

    // MARK: - Initialization

    func testInitStartsEmpty() {
        let manager = TerminalPaneManager()
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.activeSessionID)
    }

    func testAddLocalSessionCreatesSession() {
        let manager = makeManager()
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(manager.sessions.first!.isLocal)
        XCTAssertEqual(manager.sessions.first!.label, "Local")
        XCTAssertNotNil(manager.activeSessionID)
        let session = manager.sessions.first!
        XCTAssertEqual(session.panes.count, 1)
        XCTAssertEqual(session.panes.first!.label, "Shell")
    }

    // MARK: - Session Management

    func testAddLocalSessionIncreasesCount() {
        let manager = makeManager()
        manager.addLocalSession()
        XCTAssertEqual(manager.sessions.count, 2)
    }

    func testAddLocalSessionSetsActive() {
        let manager = makeManager()
        let firstID = manager.activeSessionID
        manager.addLocalSession()
        XCTAssertNotEqual(manager.activeSessionID, firstID)
        XCTAssertEqual(manager.activeSessionID, manager.sessions.last?.id)
    }

    func testAddRemoteSession() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = makeManager()
        manager.addRemoteSession(label: "GPU Box", hostEntry: host, command: "bash connect.sh agent-1 10.0.1.5 22 user 9000")
        let session = manager.sessions.last!
        XCTAssertEqual(session.label, "GPU Box")
        XCTAssertFalse(session.isLocal)
        XCTAssertNotNil(session.hostEntry)
        XCTAssertEqual(manager.activeSessionID, session.id)
    }

    func testRemoveSession() {
        let manager = makeManager()
        manager.addLocalSession()
        let count = manager.sessions.count
        let session = manager.sessions.last!
        manager.removeSession(session)
        XCTAssertEqual(manager.sessions.count, count - 1)
    }

    func testRemoveActiveSessionSwitchesToAnother() {
        let manager = makeManager()
        manager.addLocalSession()
        let second = manager.sessions.last!
        manager.removeSession(second)
        XCTAssertNotNil(manager.activeSessionID)
        XCTAssertNotEqual(manager.activeSessionID, second.id)
    }

    func testRemoveAllSessionsSetsActiveNil() {
        let manager = makeManager()
        let session = manager.sessions.first!
        manager.removeSession(session)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.activeSessionID)
    }

    // MARK: - Remote Placeholder (WI-2026-03-31-003)

    /// A connecting placeholder must not create a Pane: a nil-command Pane
    /// would make ghostty spawn a spurious local shell.
    func testRemotePlaceholderHasNoPane() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = TerminalPaneManager()
        let sessionID = manager.addRemoteSessionPlaceholder(label: "GPU Box", hostEntry: host)
        let session = manager.sessions.first!
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertTrue(session.panes.isEmpty)
        XCTAssertNil(session.activePaneID)
        XCTAssertEqual(manager.allLeaves.count, 0)
    }

    /// connectSession keeps the placeholder's UUID and creates the real pane.
    func testConnectSessionPreservesIDAndCreatesPane() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = TerminalPaneManager()
        let sessionID = manager.addRemoteSessionPlaceholder(label: "GPU Box", hostEntry: host)
        manager.connectSession(id: sessionID, command: "bash connect.sh agent-1 10.0.1.5 22 user 9000", agentID: "agent-1")
        let session = manager.sessions.first!
        XCTAssertEqual(session.id, sessionID, "placeholder UUID must be preserved")
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.agentID, "agent-1")
        XCTAssertEqual(session.panes.count, 1)
        XCTAssertEqual(session.panes.first!.hostCommand, "bash connect.sh agent-1 10.0.1.5 22 user 9000")
        XCTAssertEqual(manager.allLeaves.count, 1)
    }

    /// connectSession must NOT steal focus: if the user switched to another
    /// session while this one was connecting, the completion callback should
    /// not yank them away.
    func testConnectSessionDoesNotSwitchActiveSession() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = TerminalPaneManager()
        manager.addLocalSession()
        let localID = manager.activeSessionID
        let remoteID = manager.addRemoteSessionPlaceholder(label: "GPU Box", hostEntry: host)
        // User moves back to the local session while remote connects.
        manager.activeSessionID = localID
        manager.connectSession(id: remoteID, command: "bash connect.sh agent-1 10.0.1.5 22 user 9000", agentID: "agent-1")
        XCTAssertEqual(manager.activeSessionID, localID, "completing a background connection must not steal focus")
        XCTAssertEqual(manager.sessions.first { $0.id == remoteID }?.state, .connected)
    }

    /// failSession keeps the placeholder session with no panes.
    func testFailSessionKeepsPlaceholderWithoutPane() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = TerminalPaneManager()
        let sessionID = manager.addRemoteSessionPlaceholder(label: "GPU Box", hostEntry: host)
        manager.failSession(id: sessionID, error: "Connection refused")
        let session = manager.sessions.first!
        XCTAssertEqual(session.id, sessionID)
        if case .failed(let msg) = session.state {
            XCTAssertEqual(msg, "Connection refused")
        } else {
            XCTFail("expected failed state")
        }
        XCTAssertTrue(session.panes.isEmpty)
    }

    // MARK: - Pane Management

    func testAddPaneToActiveSession() {
        let manager = makeManager()
        let initialCount = manager.sessions.first!.panes.count
        manager.addPaneToActiveSession()
        XCTAssertEqual(manager.sessions.first!.panes.count, initialCount + 1)
    }

    func testRemovePaneClosesSessionIfLast() {
        let manager = makeManager()
        let pane = manager.sessions.first!.panes.first!
        manager.removePane(pane)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    // MARK: - Split Tree

    func testSplitFocusedLeaf() {
        let manager = makeManager()
        let leafID = manager.activePane!.focusedLeafID!
        manager.splitFocusedLeaf(direction: .horizontal)
        let newFocusedID = manager.activePane!.focusedLeafID!
        XCTAssertNotEqual(newFocusedID, leafID)
        XCTAssertEqual(manager.activePane!.splitRoot.leaves.count, 2)
    }

    func testSplitNonRightmostLeafFocusesCorrectly() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let leaves = manager.activePane!.splitRoot.leaves
        XCTAssertEqual(leaves.count, 2)
        let leafA = leaves[0].id
        let leafB = leaves[1].id

        manager.focusLeaf(leafA)
        XCTAssertEqual(manager.activePane!.focusedLeafID, leafA)

        manager.splitFocusedLeaf(direction: .horizontal)
        let newFocused = manager.activePane!.focusedLeafID!
        XCTAssertNotEqual(newFocused, leafB)
        XCTAssertNotEqual(newFocused, leafA)
        XCTAssertEqual(manager.activePane!.splitRoot.leaves.count, 3)
    }

    func testCloseFocusedLeaf() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        XCTAssertEqual(manager.activePane!.splitRoot.leaves.count, 2)
        manager.closeFocusedLeaf()
        XCTAssertEqual(manager.activePane!.splitRoot.leaves.count, 1)
    }

    func testFocusNextLeafCycles() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let leaves = manager.activePane!.splitRoot.leaves
        let firstID = leaves[0].id
        let secondID = leaves[1].id
        XCTAssertEqual(manager.activePane!.focusedLeafID, secondID)
        manager.focusNextLeaf()
        XCTAssertEqual(manager.activePane!.focusedLeafID, firstID)
        manager.focusNextLeaf()
        XCTAssertEqual(manager.activePane!.focusedLeafID, secondID)
    }

    // MARK: - All Leaves

    func testAllLeavesSpansAllSessions() {
        let manager = makeManager()
        manager.addLocalSession()
        XCTAssertEqual(manager.allLeaves.count, 2)
    }

    func testAllLeavesIncludesSplits() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        XCTAssertEqual(manager.allLeaves.count, 2)
    }

    // MARK: - Session IDs Stable

    func testSessionIDsStableAcrossOperations() {
        let manager = makeManager()
        let firstID = manager.sessions.first!.id
        manager.addLocalSession()
        XCTAssertEqual(manager.sessions.first!.id, firstID)
    }

    // MARK: - Focus (background connections must not steal session focus)

    func testFocusLeafDoesNotSwitchActiveSession() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = TerminalPaneManager()
        manager.addLocalSession()
        let localID = manager.activeSessionID
        // Remote session connects while user is in the local session.
        manager.addRemoteSession(label: "GPU Box", hostEntry: host,
                                command: "bash connect.sh agent-1 10.0.1.5 22 user 9000", agentID: "agent-1")
        let remoteLeaf = manager.sessions.last!.panes.first!.splitRoot.leaves.first!.id
        manager.activeSessionID = localID

        // A background surface becoming first responder focuses its pane…
        manager.focusLeaf(remoteLeaf)
        // …but must not switch the active session.
        XCTAssertEqual(manager.activeSessionID, localID, "focusLeaf must not steal session focus")
    }
}
