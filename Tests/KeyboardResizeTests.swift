import XCTest
@testable import Synapty

/// RESIZING FROM THE KEYBOARD, AND EQUALISING ([[WI-2026-09-02-008]]).
///
/// THE VERB IS "PUSH THIS EDGE OUT". A pane has four edges; the arrow
/// names one, and the split that owns that edge is the nearest ancestor
/// on that axis in which the pane sits on the near side — for the right
/// edge, the nearest horizontal split holding the pane in its FIRST
/// child, whose divider is that edge. A pane whose right edge is the
/// window's has no such split, and the key does nothing: there is no
/// edge to push. This is tmux's resize-pane -R and ghostty's
/// resize_split:right.
final class KeyboardResizeTests: XCTestCase {

    private func pane() -> SplitNode.Pane {
        SplitNode.Pane(label: "p", content: .terminal(command: nil), connectionID: UUID())
    }

    /// `a | b` — one horizontal split, ratio 0.5.
    private func twoColumns() -> (SplitNode, a: UUID, b: UUID) {
        let a = SplitNode.Slot(pane: pane()), b = SplitNode.Slot(pane: pane())
        return (.split(.init(direction: .horizontal, first: .slot(a), second: .slot(b))), a.id, b.id)
    }

    private func onlyRatio(_ node: SplitNode) -> CGFloat {
        guard case .split(let d) = node else { XCTFail("not a split"); return -1 }
        return d.ratio
    }

    // MARK: - Which edge, which split

    func testPushingTheLeftPanesRightEdgeGrowsIt() {
        let (tree, a, _) = twoColumns()
        let after = tree.pushingEdge(.right, ofSlot: a, by: 0.1)
        XCTAssertEqual(onlyRatio(after), 0.6, accuracy: 0.0001)
    }

    func testPushingTheRightPanesLeftEdgeGrowsIt() {
        let (tree, _, b) = twoColumns()
        let after = tree.pushingEdge(.left, ofSlot: b, by: 0.1)
        XCTAssertEqual(onlyRatio(after), 0.4, accuracy: 0.0001, "the divider moves left; b grows")
    }

    /// The left pane's LEFT edge is the window's. Nothing owns it.
    func testAnOuterEdgeIsNotPushable() {
        let (tree, a, _) = twoColumns()
        XCTAssertEqual(tree.pushingEdge(.left, ofSlot: a, by: 0.1), tree)
        XCTAssertEqual(tree.pushingEdge(.up, ofSlot: a, by: 0.1), tree, "no vertical split at all")
    }

    /// `a | (b | c)`: b's LEFT edge is the outer split's divider, its
    /// RIGHT edge the inner one's. Each arrow finds its own split.
    func testANestedPaneFindsTheSplitThatOwnsEachEdge() {
        let a = SplitNode.Slot(pane: pane()), b = SplitNode.Slot(pane: pane()), c = SplitNode.Slot(pane: pane())
        let inner = SplitNode.split(.init(direction: .horizontal, first: .slot(b), second: .slot(c)))
        let tree = SplitNode.split(.init(direction: .horizontal, first: .slot(a), second: inner))

        let left = tree.pushingEdge(.left, ofSlot: b.id, by: 0.1)
        guard case .split(let outer) = left, case .split(let innerAfterLeft) = outer.second else { return XCTFail() }
        XCTAssertEqual(outer.ratio, 0.4, accuracy: 0.0001, "outer divider moved left")
        XCTAssertEqual(innerAfterLeft.ratio, 0.5, accuracy: 0.0001, "inner untouched")

        let right = tree.pushingEdge(.right, ofSlot: b.id, by: 0.1)
        guard case .split(let outer2) = right, case .split(let innerAfterRight) = outer2.second else { return XCTFail() }
        XCTAssertEqual(outer2.ratio, 0.5, accuracy: 0.0001, "outer untouched")
        XCTAssertEqual(innerAfterRight.ratio, 0.6, accuracy: 0.0001, "inner divider moved right")
    }

    func testTheStepIsClampedLikeADrag() {
        let (tree, a, _) = twoColumns()
        var t = tree
        for _ in 0..<20 { t = t.pushingEdge(.right, ofSlot: a, by: 0.1) }
        XCTAssertEqual(onlyRatio(t), SplitNode.ratioRange.upperBound, accuracy: 0.0001)
    }

    // MARK: - Equalise

    /// A chain `a | (b | c)` at 0.5/0.5 gives a half the width and b, c a
    /// quarter each. Equalised, every position along the axis is a third.
    func testEqualisingAChainGivesEveryPositionTheSameWidth() {
        let a = SplitNode.Slot(pane: pane()), b = SplitNode.Slot(pane: pane()), c = SplitNode.Slot(pane: pane())
        let inner = SplitNode.split(.init(direction: .horizontal, first: .slot(b), second: .slot(c)))
        let tree = SplitNode.split(.init(direction: .horizontal, first: .slot(a), second: inner, ratio: 0.5))
        let even = tree.equalised()
        let frames = SplitLayout.computeFrames(node: even, in: CGRect(x: 0, y: 0, width: 3000, height: 600))
        let widths = [a.id, b.id, c.id].map { frames[$0]!.width }
        XCTAssertEqual(widths.max()! - widths.min()!, 0, accuracy: 4, "within the divider's own width")
    }

    /// Equalising touches ratios only: same positions, same panes, same
    /// order — a layout edit in nothing but proportion.
    func testEqualisingKeepsThePositions() {
        let (tree, _, _) = twoColumns()
        let even = tree.equalised()
        XCTAssertEqual(even.slots.map(\.id), tree.slots.map(\.id))
    }

    /// The manager's verbs act on the FOCUSED position of the active
    /// workspace and need more than one position to mean anything.
    @MainActor
    func testTheManagerPushesTheFocusedPositionsEdge() {
        let tunnel = TunnelManager(); TunnelManager.shared = tunnel
        defer { TunnelManager.shared = nil }
        let m = WorkspaceManager()
        m.addLocalWorkspace()
        m.resizeFocusedPosition(.right)
        XCTAssertNotNil(m.activeWorkspace?.layout, "one position: nothing to push, nothing broken")
        m.splitFocusedLeaf(direction: .horizontal)   // focus lands on the new, right-hand position
        let before = m.activeWorkspace!.layout!
        m.resizeFocusedPosition(.left)
        guard case .split(let d) = m.activeWorkspace!.layout!, case .split(let b) = before else { return XCTFail() }
        XCTAssertLessThan(d.ratio, b.ratio, "the right-hand pane grew leftward")
        m.equalizePositions()
        guard case .split(let e) = m.activeWorkspace!.layout! else { return XCTFail() }
        XCTAssertEqual(e.ratio, 0.5, accuracy: 0.0001)
    }
}
