import AppKit
import XCTest
@testable import Synapty

/// Where in a pane a dragged pane was released ([[WI-2026-08-17-028]]).
///
/// This is the whole of the drop's geometry, kept apart from AppKit so it
/// can be measured: the alternative is a rule that only a human with a
/// mouse can check, on the one code path where being a quarter of a pane
/// out means the pane lands somewhere else entirely.
final class PaneDropRegionTests: XCTestCase {

    private let size = CGSize(width: 400, height: 200)

    private func region(_ x: CGFloat, _ y: CGFloat) -> PaneDropRegion {
        PaneDropRegion.at(CGPoint(x: x * size.width, y: y * size.height), in: size)
    }

    func testTheCentreStacks() {
        XCTAssertEqual(region(0.5, 0.5), .stack)
        XCTAssertEqual(region(0.3, 0.7), .stack)
    }

    func testEachEdgeBandIsItsOwnSide() {
        XCTAssertEqual(region(0.05, 0.5), .left)
        XCTAssertEqual(region(0.95, 0.5), .right)
        XCTAssertEqual(region(0.5, 0.05), .top)
        XCTAssertEqual(region(0.5, 0.95), .bottom)
    }

    /// A CORNER BELONGS TO THE EDGE IT IS NEARER, in fractions of the
    /// pane rather than pixels — the bands are proportional, so a wide
    /// pane's left band is wider than its top band is tall and comparing
    /// distances in points would hand every corner to the short side.
    func testACornerGoesToTheNearerEdge() {
        XCTAssertEqual(region(0.04, 0.10), .left, "nearer the left edge")
        XCTAssertEqual(region(0.10, 0.04), .top, "nearer the top edge")
        XCTAssertEqual(region(0.97, 0.90), .right)
        XCTAssertEqual(region(0.90, 0.97), .bottom)
    }

    /// The diagonal itself is a tie, and a tie must always fall the same
    /// way: a boundary that picks by rounding luck makes the corner of
    /// every pane a coin toss.
    func testTheDiagonalFallsTheSameWayEveryTime() {
        XCTAssertEqual(region(0.1, 0.1), .left)
        XCTAssertEqual(region(0.9, 0.1), .right)
        XCTAssertEqual(region(0.1, 0.9), .left)
        XCTAssertEqual(region(0.9, 0.9), .right)
    }

    /// The band is a quarter, and the pane's own quarter-line is centre —
    /// so a drop that misses the band stacks rather than splitting.
    func testTheBandEndsWhereTheCentreBegins() {
        XCTAssertEqual(region(0.24, 0.5), .left)
        XCTAssertEqual(region(0.25, 0.5), .stack)
        XCTAssertEqual(region(0.76, 0.5), .right)
        XCTAssertEqual(region(0.75, 0.5), .stack)
    }

    /// A pane with no area has no regions. AppKit will not ask about one,
    /// but a division by its width is how that gets discovered.
    func testAPaneWithNoAreaStacks() {
        XCTAssertEqual(PaneDropRegion.at(.zero, in: .zero), .stack)
        XCTAssertEqual(PaneDropRegion.at(CGPoint(x: 0, y: 5),
                                         in: CGSize(width: 0, height: 10)), .stack)
    }

    /// AppKit reports a point outside the view during a drag that is
    /// leaving it. It is clamped, not refused: the last region the human
    /// saw highlighted is the one the release should mean.
    func testAPointOutsideThePaneClampsToItsEdge() {
        XCTAssertEqual(region(-0.5, 0.5), .left)
        XCTAssertEqual(region(1.5, 0.5), .right)
        XCTAssertEqual(region(0.5, -0.5), .top)
        XCTAssertEqual(region(0.5, 1.5), .bottom)
    }

    // MARK: - What each region means to the layout

    func testTheEdgesCarryTheirSplitAndTheirSide() {
        XCTAssertNil(PaneDropRegion.stack.direction)

        XCTAssertEqual(PaneDropRegion.left.direction, .horizontal)
        XCTAssertEqual(PaneDropRegion.right.direction, .horizontal)
        XCTAssertEqual(PaneDropRegion.top.direction, .vertical)
        XCTAssertEqual(PaneDropRegion.bottom.direction, .vertical)

        XCTAssertTrue(PaneDropRegion.left.placesMovedPaneFirst)
        XCTAssertTrue(PaneDropRegion.top.placesMovedPaneFirst)
        XCTAssertFalse(PaneDropRegion.right.placesMovedPaneFirst)
        XCTAssertFalse(PaneDropRegion.bottom.placesMovedPaneFirst)
    }

    // MARK: - What the human is shown before releasing

    /// THE HIGHLIGHT IS THE RESULT, NOT THE BAND. A block a quarter of
    /// the pane wide would promise a quarter of the space; an edge drop
    /// gives half, and the centre gives the whole position.
    func testTheHighlightIsTheShapeThePaneWillTake() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(PaneDragBoard.highlight(.stack, in: bounds), bounds)
        XCTAssertEqual(PaneDragBoard.highlight(.left, in: bounds),
                       CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(PaneDragBoard.highlight(.right, in: bounds),
                       CGRect(x: 200, y: 0, width: 200, height: 200))
    }

    /// And it is flipped for the same reason the point is: in a view
    /// whose origin is at the bottom, the TOP half is the high half. A
    /// highlight that ignored this would light up the opposite side of
    /// the pane from the one the drop lands in.
    func testTheHighlightIsFlippedForAViewWithOriginAtTheBottom() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(PaneDragBoard.highlight(.top, in: bounds, flipped: true),
                       CGRect(x: 0, y: 100, width: 400, height: 100))
        XCTAssertEqual(PaneDragBoard.highlight(.bottom, in: bounds, flipped: true),
                       CGRect(x: 0, y: 0, width: 400, height: 100))
        XCTAssertEqual(PaneDragBoard.highlight(.top, in: bounds),
                       CGRect(x: 0, y: 0, width: 400, height: 100))
        XCTAssertEqual(PaneDragBoard.highlight(.bottom, in: bounds),
                       CGRect(x: 0, y: 100, width: 400, height: 100))
    }

    /// Both ends of the gesture are ours, but they speak different APIs —
    /// a SwiftUI tab writes the board and an AppKit pane reads it — so
    /// the encoding is a contract between them rather than an internal
    /// detail ([[WI-2026-08-17-028]]).
    func testAPaneDragIsReadBackOffTheBoard() {
        let paneID = UUID()
        let board = NSPasteboard(name: .init(rawValue: "synapty.test.\(paneID)"))
        board.clearContents()
        board.setData(try! JSONEncoder().encode(TabDragPayload(paneID: paneID)),
                      forType: PaneDragBoard.type)

        XCTAssertEqual(PaneDragBoard.paneID(on: board), paneID)
    }

    func testABoardCarryingSomethingElseIsNotAPaneDrag() {
        let board = NSPasteboard(name: .init(rawValue: "synapty.test.files"))
        board.clearContents()
        board.setString("/tmp/a.txt", forType: .string)

        XCTAssertNil(PaneDragBoard.paneID(on: board), "a file drag is not a pane drag")
    }

    /// The AppKit surface's own coordinates are y-up; the layout's, and
    /// this type's, are y-down. Naming the flip once is what keeps a drop
    /// near the tab bar from splitting the pane downwards.
    func testAViewWithOriginAtTheBottomIsFlippedOnce() {
        let bottomLeftOrigin = CGPoint(x: 200, y: 190)  // near the TOP on screen
        XCTAssertEqual(
            PaneDropRegion.at(flippingY: bottomLeftOrigin, in: size), .top)
        XCTAssertEqual(
            PaneDropRegion.at(flippingY: CGPoint(x: 200, y: 10), in: size), .bottom)
    }
}
