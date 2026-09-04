import XCTest
@testable import Synapty

/// ZOOM ([[WI-2026-09-02-006]]): one position takes the whole split area
/// and gives it back exactly. The rules live on the workspace model and
/// are pinned here; the view only draws what `visibleSlots` says.
///
/// THE RULE FOR WHAT ENDS A ZOOM, in one place: the arrangement of
/// positions changing (a position added or removed), or focus moving to a
/// pane in another position. Switching or reordering tabs INSIDE the
/// zoomed position keeps it — those change what the position shows, not
/// where it is.
@MainActor
final class ZoomTests: XCTestCase {

    /// `addLocalWorkspace()` asks TunnelManager.shared for the local
    /// command and opens an EMPTY workspace without one (RFC-0015
    /// C-EMPTY) — so a manager made without this has no pane to split,
    /// and every rule below is asked about nothing. Held strongly here
    /// because the global is weak.
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

    // MARK: - Zooming

    /// With one position there is nothing to take the area from.
    func testOnePositionCannotZoom() {
        let m = makeManager(slots: 1)
        m.toggleZoom()
        XCTAssertFalse(m.activeWorkspace!.isZoomed)
    }

    func testZoomShowsOnlyTheFocusedPosition() {
        let m = makeManager(slots: 3)
        let focused = m.activeWorkspace!.focusedPaneID!
        m.toggleZoom()
        let ws = m.activeWorkspace!
        XCTAssertTrue(ws.isZoomed)
        XCTAssertEqual(ws.visibleSlots.count, 1)
        XCTAssertEqual(ws.visibleSlots.first?.activePaneID, focused)
        XCTAssertEqual(m.visibleLeafIDs, [focused], "hidden positions have no visible leaf")
        XCTAssertEqual(ws.slots.count, 3, "the layout itself is untouched")
    }

    /// THE LAYOUT COMES BACK EXACTLY — same tree, same ratios. A zoom
    /// that changed anything on the way back would be a layout edit
    /// wearing a viewing mode's name.
    func testToggleRestoresTheLayoutExactly() {
        let m = makeManager(slots: 3)
        let before = m.activeWorkspace!.layout
        m.toggleZoom()
        m.toggleZoom()
        let ws = m.activeWorkspace!
        XCTAssertFalse(ws.isZoomed)
        XCTAssertEqual(ws.layout, before)
        XCTAssertEqual(ws.visibleSlots.count, 3)
    }

    // MARK: - What ends a zoom

    func testAddingAPositionEndsTheZoom() {
        let m = makeManager(slots: 2)
        m.toggleZoom()
        m.splitFocusedLeaf(direction: .vertical)
        XCTAssertFalse(m.activeWorkspace!.isZoomed)
        XCTAssertEqual(m.activeWorkspace!.visibleSlots.count, 3)
    }

    func testRemovingAnotherPositionEndsTheZoom() {
        let m = makeManager(slots: 2)
        let other = m.activeWorkspace!.slots.first { $0.activePaneID != m.activeWorkspace!.focusedPaneID }!
        m.toggleZoom()
        m.archivePane(other.activePaneID)
        XCTAssertFalse(m.activeWorkspace!.isZoomed, "one position left, nothing to be zoomed against")
    }

    func testFocusingAPaneInAnotherPositionEndsTheZoom() {
        let m = makeManager(slots: 2)
        let other = m.activeWorkspace!.slots.first { $0.activePaneID != m.activeWorkspace!.focusedPaneID }!
        m.toggleZoom()
        m.focusLeaf(other.activePaneID)
        XCTAssertFalse(m.activeWorkspace!.isZoomed)
        XCTAssertEqual(m.activeWorkspace!.focusedPaneID, other.activePaneID)
    }

    /// The keyboard's way to the next position works while zoomed, and
    /// lands unzoomed — a hidden position cannot be the focused one.
    func testFocusNextPositionWhileZoomedUnzooms() {
        let m = makeManager(slots: 2)
        m.toggleZoom()
        m.requestFocusNextSlot()
        XCTAssertFalse(m.activeWorkspace!.isZoomed)
    }

    /// SWITCHING TABS INSIDE THE ZOOMED POSITION KEEPS IT. The human
    /// zoomed a position, not a tab; changing which of its tabs is in
    /// front is the position doing its job.
    func testSwitchingTabsInsideTheZoomedPositionKeepsIt() {
        let m = makeManager(slots: 2)
        let ws = m.activeWorkspaceID!
        let focusedSlot = m.activeWorkspace!.focusedSlot!
        let second = m.addPane(content: .terminal(command: nil), toWorkspace: ws)!
        // addPane stacks into the focused position and fronts the new tab.
        XCTAssertEqual(m.activeWorkspace!.layout?.slot(containing: second)?.id, focusedSlot.id)
        m.toggleZoom()
        m.activatePane(focusedSlot.activePaneID)
        XCTAssertTrue(m.activeWorkspace!.isZoomed)
        m.activatePane(second)
        XCTAssertTrue(m.activeWorkspace!.isZoomed)
        XCTAssertEqual(m.visibleLeafIDs, [second])
    }

    func testReorderingTabsInsideTheZoomedPositionKeepsIt() {
        let m = makeManager(slots: 2)
        let ws = m.activeWorkspaceID!
        let first = m.activeWorkspace!.focusedPaneID!
        let second = m.addPane(content: .terminal(command: nil), toWorkspace: ws)!
        m.toggleZoom()
        m.movePane(second, before: first)
        XCTAssertTrue(m.activeWorkspace!.isZoomed)
    }

    // MARK: - Across a restart

    func testZoomSurvivesASnapshotRoundTrip() {
        let m = makeManager(slots: 3)
        m.toggleZoom()
        let zoomedPane = m.activeWorkspace!.focusedPaneID!
        let restored = WorkspaceManager()
        _ = restored.restore(from: m.snapshot(planFor: { _ in nil }), hostStore: nil)
        let ws = restored.activeWorkspace!
        XCTAssertTrue(ws.isZoomed)
        XCTAssertEqual(ws.visibleSlots.count, 1)
        XCTAssertEqual(ws.slots.count, 3)
        // Identity is the position's index, not the pane's UUID (the
        // restored panes may be new terminals); what the human sees is
        // the same position, alone.
        XCTAssertEqual(ws.slots.firstIndex { $0.id == ws.visibleSlots[0].id },
                       m.activeWorkspace!.slots.firstIndex { $0.panes.contains { $0.id == zoomedPane } })
    }
}
