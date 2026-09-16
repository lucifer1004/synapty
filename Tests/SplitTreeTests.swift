import XCTest
@testable import Synapty

/// The tree's geometry and navigation. The four layout operations —
/// stacking, splitting, removing, updating — live in [[LayoutTreeTests]].
final class SplitTreeTests: XCTestCase {

    private func pane(_ command: String? = nil) -> SplitNode.Pane {
        SplitNode.Pane(command: command, connectionID: UUID())
    }

    private func slot(_ p: SplitNode.Pane) -> SplitNode { .slot(SplitNode.Slot(pane: p)) }

    private func pair(_ a: SplitNode.Pane, _ b: SplitNode.Pane,
                      _ direction: SplitNode.SplitDirection = .horizontal,
                      ratio: CGFloat = 0.5) -> SplitNode {
        .split(SplitNode.SplitData(direction: direction,
                                   first: slot(a), second: slot(b), ratio: ratio))
    }

    // MARK: - Pane basics

    func testLeafHasUniqueID() {
        XCTAssertNotEqual(pane().id, pane().id)
    }

    func testLeafCommandStoredCorrectly() {
        XCTAssertEqual(pane("ssh user@host").content.terminalCommand, "ssh user@host")
    }

    func testLeafCommandDefaultsToNil() {
        XCTAssertNil(pane().content.terminalCommand)
    }

    // MARK: - A single position

    func testSingleSlotIDMatchesTheSlot() {
        let s = SplitNode.Slot(pane: pane())
        XCTAssertEqual(SplitNode.slot(s).id, s.id)
    }

    func testSingleSlotHasOnePaneID() {
        let p = pane()
        XCTAssertEqual(slot(p).paneIDs, [p.id])
    }

    func testFindPaneOnSingleSlot() {
        let p = pane()
        let node = slot(p)
        XCTAssertNotNil(node.findPane(p.id))
        XCTAssertNil(node.findPane(UUID()))
    }

    // MARK: - Navigation walks POSITIONS

    func testNextPaneCycles() {
        let a = pane(), b = pane()
        let node = pair(a, b)
        XCTAssertEqual(node.nextPane(after: a.id), b.id)
        XCTAssertEqual(node.nextPane(after: b.id), a.id) // wraps
    }

    func testPreviousPaneCycles() {
        let a = pane(), b = pane()
        let node = pair(a, b)
        XCTAssertEqual(node.previousPane(before: b.id), a.id)
        XCTAssertEqual(node.previousPane(before: a.id), b.id) // wraps
    }

    /// ONE POSITION HAS NOWHERE TO GO. The old tree answered with the leaf
    /// itself, so the shortcut "focus the next pane" re-focused the pane
    /// already focused and reported success.
    func testNextPaneWithOnlyOnePositionIsNil() {
        let p = pane()
        XCTAssertNil(slot(p).nextPane(after: p.id))
    }

    func testNextPaneWithUnknownIDReturnsNil() {
        XCTAssertNil(pair(pane(), pane()).nextPane(after: UUID()))
    }

    /// A stacked pane is reached from its POSITION, so stepping past a
    /// position lands on whatever that one is showing — never on a pane
    /// hidden behind a tab, which the human cannot see to know they have
    /// arrived at it.
    func testSteppingLandsOnWhatEachPositionIsShowing() {
        let a = pane(), behind = pane(), c = pane()
        var node = pair(a, c)
        guard let first = node.slots.first else { return XCTFail() }
        node = node.stack(behind, intoSlot: first.id)

        // `behind` is now in front of the first position.
        XCTAssertEqual(node.nextPane(after: c.id), behind.id)
        XCTAssertEqual(node.nextPane(after: behind.id), c.id)
        XCTAssertEqual(node.nextPane(after: a.id), c.id,
                       "stepping from a pane behind a tab still steps by position")
    }

    func testThreePositionNavigation() {
        let a = pane(), b = pane(), c = pane()
        let root = SplitNode.split(SplitNode.SplitData(
            direction: .vertical, first: pair(a, b), second: slot(c)))
        XCTAssertEqual(root.nextPane(after: a.id), b.id)
        XCTAssertEqual(root.nextPane(after: b.id), c.id)
        XCTAssertEqual(root.nextPane(after: c.id), a.id) // wraps
    }

    // MARK: - Ratio

    func testSetRatioClampsLow() {
        var node = pair(pane(), pane())
        node.setRatio(splitID: node.id, ratio: 0.0)
        guard case .split(let data) = node else { return XCTFail("Expected split node") }
        XCTAssertEqual(data.ratio, 0.1, accuracy: 0.001)
    }

    func testSetRatioClampsHigh() {
        var node = pair(pane(), pane())
        node.setRatio(splitID: node.id, ratio: 1.0)
        guard case .split(let data) = node else { return XCTFail("Expected split node") }
        XCTAssertEqual(data.ratio, 0.9, accuracy: 0.001)
    }

    func testSetRatioWithinRange() {
        var node = pair(pane(), pane())
        node.setRatio(splitID: node.id, ratio: 0.3)
        guard case .split(let data) = node else { return XCTFail("Expected split node") }
        XCTAssertEqual(data.ratio, 0.3, accuracy: 0.001)
    }

    func testSetRatioOnNestedSplitFindsCorrectNode() {
        let inner = SplitNode.SplitData(
            direction: .horizontal, first: slot(pane()), second: slot(pane()), ratio: 0.5)
        var root = SplitNode.split(SplitNode.SplitData(
            direction: .vertical, first: .split(inner), second: slot(pane()), ratio: 0.5))
        root.setRatio(splitID: inner.id, ratio: 0.7)
        guard case .split(let outerData) = root,
              case .split(let innerData) = outerData.first else {
            return XCTFail("Expected nested split structure")
        }
        XCTAssertEqual(innerData.ratio, 0.7, accuracy: 0.001)
        XCTAssertEqual(outerData.ratio, 0.5, accuracy: 0.001) // outer unchanged
    }

    func testDefaultRatioIsFifty() {
        let data = SplitNode.SplitData(
            direction: .horizontal, first: slot(pane()), second: slot(pane()))
        XCTAssertEqual(data.ratio, 0.5, accuracy: 0.001)
    }
}

// MARK: - Layout presets (WI-2026-08-09-012)

final class LayoutPresetTests: XCTestCase {

    private func makeSlots(_ n: Int) -> [SplitNode.Slot] {
        (0..<n).map { .init(pane: SplitNode.Pane(command: "cmd\($0)", connectionID: UUID())) }
    }

    /// Every preset must preserve POSITION identity AND order — surface
    /// views key on pane UUID; a changed or reordered id set would deinit
    /// surfaces (the PTY-killing class).
    func testPresetsPreserveLeafIdentityAndOrder() {
        let slots = makeSlots(4)
        for preset in SplitNode.LayoutPreset.allCases {
            let tree = SplitNode.arranged(slots: slots, preset: preset)
            XCTAssertEqual(tree.slots.map(\.id), slots.map(\.id), "\(preset) must keep IDs in order")
        }
    }

    /// A STACK RIDES WITH THE POSITION HOLDING IT. Presets fold positions,
    /// not panes — a rearrange that flattened stacks would silently turn
    /// every tab into a split.
    func testPresetsCarryWholeStacks() {
        let front = SplitNode.Pane(connectionID: UUID())
        let behind = SplitNode.Pane(connectionID: UUID())
        let slots: [SplitNode.Slot] = [.init(panes: [front, behind]), .init(pane: SplitNode.Pane(connectionID: UUID()))]

        let tree = SplitNode.arranged(slots: slots, preset: .columns)

        XCTAssertEqual(tree.slots.count, 2, "two positions, not three")
        XCTAssertEqual(tree.panes.count, 3)
        XCTAssertEqual(tree.slot(containing: behind.id)?.panes.map(\.id), [front.id, behind.id])
    }

    func testSingleSlotIsIdentity() {
        let slots = makeSlots(1)
        for preset in SplitNode.LayoutPreset.allCases {
            let tree = SplitNode.arranged(slots: slots, preset: preset)
            guard case .slot(let data) = tree else {
                return XCTFail("\(preset) with one position must be a bare position")
            }
            XCTAssertEqual(data.id, slots[0].id)
        }
    }

    func testColumnsShapeAndRatios() {
        let tree = SplitNode.arranged(slots: makeSlots(3), preset: .columns)
        guard case .split(let top) = tree else { return XCTFail("expected split") }
        XCTAssertEqual(top.direction, .horizontal)
        // First column gets 1/3 of the width.
        XCTAssertEqual(top.ratio, 1.0 / 3.0, accuracy: 0.001)
        guard case .split(let inner) = top.second else { return XCTFail("expected nested split") }
        XCTAssertEqual(inner.direction, .horizontal)
        // Remaining two share the rest evenly.
        XCTAssertEqual(inner.ratio, 0.5, accuracy: 0.001)
    }

    func testRowsShape() {
        let tree = SplitNode.arranged(slots: makeSlots(2), preset: .rows)
        guard case .split(let top) = tree else { return XCTFail("expected split") }
        XCTAssertEqual(top.direction, .vertical)
        XCTAssertEqual(top.ratio, 0.5, accuracy: 0.001)
    }

    /// Grid chunks rows of two; 4 positions = 2x2 (vertical root of two
    /// horizontal pairs).
    func testGridFourSlotsIsTwoByTwo() {
        let tree = SplitNode.arranged(slots: makeSlots(4), preset: .grid)
        guard case .split(let top) = tree else { return XCTFail("expected split") }
        XCTAssertEqual(top.direction, .vertical)
        guard case .split(let row1) = top.first, case .split(let row2) = top.second else {
            return XCTFail("expected two row splits")
        }
        XCTAssertEqual(row1.direction, .horizontal)
        XCTAssertEqual(row2.direction, .horizontal)
    }

    /// Odd count: the last row is a single full-width position.
    func testGridThreeSlotsLastRowFullWidth() {
        let slots = makeSlots(3)
        let tree = SplitNode.arranged(slots: slots, preset: .grid)
        guard case .split(let top) = tree else { return XCTFail("expected split") }
        XCTAssertEqual(top.direction, .vertical)
        guard case .split(let row1) = top.first else { return XCTFail("first row should be a pair") }
        XCTAssertEqual(row1.direction, .horizontal)
        guard case .slot(let last) = top.second else {
            return XCTFail("last row should be a bare position")
        }
        XCTAssertEqual(last.id, slots[2].id)
    }

    /// Main+Stack: the first position is the 0.65 main region; the rest
    /// stack vertically on the trailing side.
    func testMainStackShape() {
        let slots = makeSlots(3)
        let tree = SplitNode.arranged(slots: slots, preset: .mainStack)
        guard case .split(let top) = tree else { return XCTFail("expected split") }
        XCTAssertEqual(top.direction, .horizontal)
        XCTAssertEqual(top.ratio, 0.65, accuracy: 0.001)
        guard case .slot(let main) = top.first else { return XCTFail("main should be a position") }
        XCTAssertEqual(main.id, slots[0].id)
        guard case .split(let stack) = top.second else { return XCTFail("stack should be a split") }
        XCTAssertEqual(stack.direction, .vertical)
    }
}
