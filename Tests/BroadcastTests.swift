import XCTest
@testable import Synapty

/// BROADCAST ([[WI-2026-09-02-010]]): type into several panes at once,
/// with a switch that cannot be missed and a rule that is written down.
@MainActor
final class BroadcastTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
    }

    private func makeManager(slots: Int) -> WorkspaceManager {
        let m = WorkspaceManager()
        m.addLocalWorkspace()
        for _ in 1..<slots { m.splitFocusedLeaf(direction: .horizontal) }
        return m
    }

    // MARK: - The switch

    func testArmingTakesTheVisiblePanes() {
        let m = makeManager(slots: 3)
        m.toggleBroadcast()
        XCTAssertTrue(m.isBroadcasting)
        XCTAssertEqual(Set(m.activeWorkspace!.armedBroadcastPanes), Set(m.visibleLeafIDs))
    }

    /// DISARMING IS ONE ACT: every pane, at once.
    func testTogglingAgainDisarmsEveryPane() {
        let m = makeManager(slots: 3)
        m.toggleBroadcast()
        m.toggleBroadcast()
        XCTAssertFalse(m.isBroadcasting)
        XCTAssertTrue(m.activeWorkspace!.armedBroadcastPanes.isEmpty)
    }

    /// One pane cannot broadcast to itself; the switch stays off.
    func testOnePaneCannotBroadcast() {
        let m = makeManager(slots: 1)
        m.toggleBroadcast()
        XCTAssertFalse(m.isBroadcasting)
    }

    /// A pane opened after arming is NOT armed — joining the set is an
    /// explicit act, never the consequence of opening something.
    func testANewPaneIsNotArmedByItself() {
        let m = makeManager(slots: 2)
        m.toggleBroadcast()
        m.splitFocusedLeaf(direction: .vertical)
        let newest = m.activeWorkspace!.focusedPaneID!
        XCTAssertFalse(m.isBroadcastArmed(newest))
        XCTAssertTrue(m.isBroadcasting, "the others still are")
    }

    func testAPaneCanBeArmedAndDisarmedAlone() {
        let m = makeManager(slots: 2)
        let panes = m.visibleLeafIDs
        m.setBroadcastArmed(panes[0], true)
        XCTAssertTrue(m.isBroadcastArmed(panes[0]))
        XCTAssertFalse(m.isBroadcastArmed(panes[1]))
        m.setBroadcastArmed(panes[0], false)
        XCTAssertFalse(m.isBroadcasting)
    }

    /// A closed pane leaves the set with the layout.
    func testAClosedPaneLeavesTheSet() {
        let m = makeManager(slots: 2)
        m.toggleBroadcast()
        let gone = m.visibleLeafIDs[0]
        m.archivePane(gone)
        XCTAssertFalse(m.activeWorkspace!.armedBroadcastPanes.contains(gone))
    }

    // MARK: - Where a keystroke goes

    func testTargetsAreTheOtherArmedPanesOfTheSameWorkspace() {
        let m = makeManager(slots: 3)
        m.toggleBroadcast()
        let panes = m.visibleLeafIDs
        XCTAssertEqual(Set(m.broadcastTargets(from: panes[0])), Set(panes.dropFirst()))
    }

    /// TYPING IN AN UNARMED PANE GOES NOWHERE ELSE, even while others
    /// are armed — the human left it out on purpose.
    func testAnUnarmedSourceHasNoTargets() {
        let m = makeManager(slots: 3)
        let panes = m.visibleLeafIDs
        m.setBroadcastArmed(panes[0], true)
        m.setBroadcastArmed(panes[1], true)
        XCTAssertTrue(m.broadcastTargets(from: panes[2]).isEmpty)
    }

    func testTargetsNeverCrossWorkspaces() {
        let m = makeManager(slots: 2)
        m.toggleBroadcast()
        let armed = m.visibleLeafIDs
        m.addLocalWorkspace()
        m.splitFocusedLeaf(direction: .horizontal)
        m.toggleBroadcast()
        let other = m.visibleLeafIDs
        XCTAssertEqual(Set(m.broadcastTargets(from: other[0])), Set([other[1]]))
        XCTAssertFalse(m.broadcastTargets(from: other[0]).contains(where: armed.contains))
    }

    /// NOT ACROSS A RESTART. A standing "keys go to many machines" that
    /// survived a relaunch would be armed by nobody in the room.
    func testBroadcastIsNotWrittenToTheSnapshot() {
        let m = makeManager(slots: 2)
        m.toggleBroadcast()
        let restored = WorkspaceManager()
        _ = restored.restore(from: m.snapshot(planFor: { _ in nil }), hostStore: nil)
        XCTAssertFalse(restored.isBroadcasting)
    }

    // MARK: - The rule

    func testTheDeliveryRule() {
        XCTAssertTrue(BroadcastRule.forwards(.key))
        XCTAssertTrue(BroadcastRule.forwards(.imeCommit))
        XCTAssertFalse(BroadcastRule.forwards(.imeComposing), "a composition is the focused pane's")
        XCTAssertFalse(BroadcastRule.forwards(.paste), "a paste's size is invisible at the moment of the act")
    }
}
