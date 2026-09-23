import XCTest
@testable import Synapty

/// A drag is a line the human moves; the split tree hears about it once
/// (WI-2026-08-17-002).
@MainActor
final class DividerDragTests: XCTestCase {

    private let parent = CGRect(x: 100, y: 50, width: 400, height: 200)

    private func divider(_ direction: SplitNode.SplitDirection) -> SplitLayout.DividerInfo {
        SplitLayout.DividerInfo(
            id: UUID(),
            rect: .zero,       // where it is COMMITTED; irrelevant to the preview
            direction: direction,
            parentRect: parent)
    }

    // MARK: - The state machine

    func testNothingIsInFlightUntilADragStarts() {
        let drag = DividerDrag()
        XCTAssertNil(drag.active)
        XCTAssertNil(drag.ratio(for: UUID()))
    }

    func testUpdateHoldsTheRatioForItsOwnDividerOnly() {
        let drag = DividerDrag()
        let info = divider(.horizontal)
        drag.update(info, ratio: 0.7)
        XCTAssertEqual(drag.ratio(for: info.id) ?? 0, 0.7, accuracy: 0.001)
        XCTAssertNil(drag.ratio(for: UUID()))
    }

    /// The whole point: the tree is written once, at the end.
    func testCommitReturnsTheFinalRatioAndClears() {
        let drag = DividerDrag()
        let info = divider(.horizontal)
        drag.update(info, ratio: 0.3)
        drag.update(info, ratio: 0.45)
        drag.update(info, ratio: 0.62)

        let committed = drag.commit()
        XCTAssertEqual(committed?.id, info.id)
        XCTAssertEqual(committed?.ratio ?? 0, 0.62, accuracy: 0.001)
        XCTAssertNil(drag.active, "a committed drag is over")
    }

    /// A release with nothing in flight must not write a ratio — SwiftUI
    /// delivers gesture callbacks more than once.
    func testCommitTwiceWritesOnce() {
        let drag = DividerDrag()
        let info = divider(.vertical)
        drag.update(info, ratio: 0.4)
        XCTAssertNotNil(drag.commit())
        XCTAssertNil(drag.commit())
    }

    /// Grabbing a second divider replaces the first rather than stacking.
    func testASecondDividerTakesOver() {
        let drag = DividerDrag()
        let first = divider(.horizontal)
        let second = divider(.vertical)
        drag.update(first, ratio: 0.2)
        drag.update(second, ratio: 0.8)
        XCTAssertNil(drag.ratio(for: first.id))
        XCTAssertEqual(drag.ratio(for: second.id) ?? 0, 0.8, accuracy: 0.001)
    }

    /// A split can close from a keystroke or a process exit while the human
    /// is mid-drag; SwiftUI has no `onEnded` for that, so the ghost would
    /// outlive its divider.
    func testADividerThatVanishedDropsTheDrag() {
        let drag = DividerDrag()
        let info = divider(.horizontal)
        drag.update(info, ratio: 0.4)

        drag.dropIfGone(dividerIDs: [info.id, UUID()])
        XCTAssertNotNil(drag.active, "still there — keep dragging")

        drag.dropIfGone(dividerIDs: [UUID()])
        XCTAssertNil(drag.active)
        XCTAssertNil(drag.info)
    }

    // MARK: - The clamp

    /// THE GHOST MAY NOT PROMISE AN EDGE THAT CANNOT HAPPEN. `setRatio`
    /// clamps to [0.1, 0.9]; a preview drawn past that would slide under
    /// the cursor and then jump back on release.
    func testPreviewClampsWhereACommittedRatioClamps() {
        let drag = DividerDrag()
        let info = divider(.horizontal)
        drag.update(info, ratio: -0.5)
        XCTAssertEqual(drag.ratio(for: info.id) ?? 0, SplitNode.ratioRange.lowerBound, accuracy: 0.001)
        drag.update(info, ratio: 2.0)
        XCTAssertEqual(drag.ratio(for: info.id) ?? 0, SplitNode.ratioRange.upperBound, accuracy: 0.001)
    }

    func testCommittedRatioUsesTheSameRange() {
        var node = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal,
            first: .slot(SplitNode.Slot(pane: SplitNode.Pane(connectionID: UUID()))),
            second: .slot(SplitNode.Slot(pane: SplitNode.Pane(connectionID: UUID()))),
            ratio: 0.5))
        node.setRatio(splitID: node.id, ratio: 5.0)
        guard case .split(let data) = node else { return XCTFail("expected split") }
        XCTAssertEqual(data.ratio, SplitNode.ratioRange.upperBound, accuracy: 0.001)
    }

    // MARK: - Where the line is drawn

    /// At the ratio the tree already holds, the preview sits exactly where
    /// the real divider does — otherwise the line would jump the moment a
    /// drag begins.
    func testPreviewAtTheCommittedRatioMatchesTheRealDivider() {
        let slotA = SplitNode.Slot(pane: SplitNode.Pane(connectionID: UUID()))
        let slotB = SplitNode.Slot(pane: SplitNode.Pane(connectionID: UUID()))
        let node = SplitNode.split(SplitNode.SplitData(
            direction: .horizontal, first: .slot(slotA), second: .slot(slotB), ratio: 0.35))
        let real = SplitLayout.computeDividers(node: node, in: parent)[0]

        let preview = SplitLayout.previewRect(for: real, ratio: 0.35)
        XCTAssertEqual(preview.minX, real.rect.minX, accuracy: 0.5)
        XCTAssertEqual(preview.minY, real.rect.minY, accuracy: 0.5)
        XCTAssertEqual(preview.height, real.rect.height, accuracy: 0.5)
    }

    func testPreviewMovesWithTheRatioHorizontally() {
        let info = divider(.horizontal)
        let left = SplitLayout.previewRect(for: info, ratio: 0.25)
        let right = SplitLayout.previewRect(for: info, ratio: 0.75)
        XCTAssertLessThan(left.minX, right.minX)
        // Spans the parent's full height, and stays inside it.
        XCTAssertEqual(left.height, parent.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(left.minX, parent.minX)
        XCTAssertLessThanOrEqual(right.maxX, parent.maxX)
    }

    func testPreviewMovesWithTheRatioVertically() {
        let info = divider(.vertical)
        let top = SplitLayout.previewRect(for: info, ratio: 0.25)
        let bottom = SplitLayout.previewRect(for: info, ratio: 0.75)
        XCTAssertLessThan(top.minY, bottom.minY)
        XCTAssertEqual(top.width, parent.width, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(top.minY, parent.minY)
        XCTAssertLessThanOrEqual(bottom.maxY, parent.maxY)
    }
}
