import XCTest
@testable import Synapty

/// [[RFC-0015]] C-LAYOUT: one layout type. The tree's slots hold ordered
/// stacks of panes, and a tab is what a slot with more than one shows.
final class LayoutTreeTests: XCTestCase {

    private func pane(_ label: String = "sh") -> SplitNode.Pane {
        SplitNode.Pane(label: label, content: .terminal(command: nil), connectionID: UUID())
    }

    private func oneSlot(_ p: SplitNode.Pane) -> SplitNode { .slot(SplitNode.Slot(pane: p)) }

    // MARK: - A slot is a stack

    func testASlotStartsWithOnePaneInFront() {
        let p = pane()
        let slot = SplitNode.Slot(pane: p)
        XCTAssertEqual(slot.panes.map(\.id), [p.id])
        XCTAssertEqual(slot.activePaneID, p.id)
        XCTAssertFalse(slot.isStacked, "one pane is not a stack")
    }

    /// THE OPERATION DOCKING IS FOR: two panes in one position. It is an
    /// arrangement, not a conversion into some other type.
    func testStackingAPaneOntoASlotMakesTabs() {
        let first = pane("zsh")
        let second = pane("build")
        var root = oneSlot(first)
        guard case .slot(let s) = root else { return XCTFail() }

        root = root.stack(second, intoSlot: s.id)

        guard case .slot(let after) = root else { return XCTFail() }
        XCTAssertEqual(after.panes.map(\.label), ["zsh", "build"])
        XCTAssertTrue(after.isStacked, "two panes in one position is a stack")
        XCTAssertEqual(after.activePaneID, second.id, "what was just put there is in front")
        XCTAssertEqual(root.slots.count, 1, "stacking adds no position")
    }

    func testStackingAtAnIndexPutsThePaneThere() {
        let a = pane("a"), b = pane("b"), c = pane("c")
        var root = oneSlot(a)
        guard case .slot(let s) = root else { return XCTFail() }
        root = root.stack(b, intoSlot: s.id)
        root = root.stack(c, intoSlot: s.id, at: 1)

        guard case .slot(let after) = root else { return XCTFail() }
        XCTAssertEqual(after.panes.map(\.label), ["a", "c", "b"])
    }

    // MARK: - Splitting makes a position, not a tab

    func testSplittingASlotMakesTwoPositions() {
        let first = pane("zsh")
        let root = oneSlot(first)
        guard case .slot(let s) = root else { return XCTFail() }

        let added = pane("logs")
        let (split, newSlotID) = root.splitSlot(s.id, direction: .horizontal, newPane: added)

        XCTAssertNotNil(newSlotID)
        XCTAssertEqual(split.slots.count, 2, "a split is two positions")
        XCTAssertEqual(split.panes.map(\.label), ["zsh", "logs"])
        XCTAssertTrue(split.slots.allSatisfy { !$0.isStacked }, "neither position is a stack")
    }

    // MARK: - Closing

    func testClosingOneOfTwoStackedPanesLeavesTheSlot() {
        let a = pane("a"), b = pane("b")
        var root = oneSlot(a)
        guard case .slot(let s) = root else { return XCTFail() }
        root = root.stack(b, intoSlot: s.id)

        guard case .removed(let after) = root.removePane(b.id) else { return XCTFail() }
        XCTAssertEqual(after.panes.map(\.label), ["a"])
        XCTAssertEqual(after.slots.count, 1)
        XCTAssertEqual(after.slots[0].activePaneID, a.id, "focus falls to what is left")
    }

    /// A slot emptied by closing its last pane collapses into its sibling,
    /// exactly as removing the only leaf of a split did.
    func testClosingTheLastPaneOfASlotCollapsesIntoItsSibling() {
        let keep = pane("keep"), drop = pane("drop")
        let root = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: oneSlot(keep), second: oneSlot(drop)))

        guard case .removed(let after) = root.removePane(drop.id) else { return XCTFail() }
        XCTAssertEqual(after.slots.count, 1)
        XCTAssertEqual(after.panes.map(\.label), ["keep"])
    }

    func testRemovingAPaneThatIsNotThereIsNotFound() {
        XCTAssertEqual(oneSlot(pane()).removePane(UUID()), .notFound)
    }

    // MARK: - Identity survives every operation

    /// Surfaces and ptys are keyed by pane id, so a move that minted a new
    /// one would close the human's shell and open another in its place.
    func testAPaneKeepsItsIdentityAndItsMachineThroughStackingAndSplitting() {
        let travelling = pane("remotehost")
        let home = pane("local")
        var root = oneSlot(home)
        guard case .slot(let s) = root else { return XCTFail() }

        let (split, newSlot) = root.splitSlot(s.id, direction: .vertical, newPane: travelling)
        root = split
        guard let newSlot else { return XCTFail() }

        // …and now stack it back onto the original position.
        guard case .removed(let pulled) = root.removePane(travelling.id) else { return XCTFail() }
        root = pulled.stack(travelling, intoSlot: s.id)
        _ = newSlot

        let found = root.findPane(travelling.id)
        XCTAssertEqual(found?.id, travelling.id)
        XCTAssertEqual(found?.connectionID, travelling.connectionID,
                       "the machine rides on the pane, not on where it sits")
        XCTAssertEqual(found?.label, "remotehost")
    }

    func testTheSlotHoldingAPaneCanBeFound() {
        let a = pane("a"), b = pane("b")
        let root = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal, first: oneSlot(a), second: oneSlot(b)))
        XCTAssertEqual(root.slot(containing: b.id)?.panes.map(\.label), ["b"])
        XCTAssertNil(root.slot(containing: UUID()))
    }
}
