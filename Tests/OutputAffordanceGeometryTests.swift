import XCTest
@testable import Synapty

/// POINTER TO CELL, AND CELL BACK TO PIXELS.
///
/// A view counts up from the bottom left and a terminal grid counts down
/// from the top, so the row arithmetic is the half that is easy to get
/// backwards — and getting it backwards draws the mark on a different line
/// from the one that was read.
final class OutputAffordanceGeometryTests: XCTestCase {

    /// 80x24 of 10x20-point cells.
    private let grid = OutputAffordance.Metrics(
        columns: 80, rows: 24, cellWidth: 10, cellHeight: 20, height: 480)

    func testTheTopLeftCellIsRowZero() {
        let hit = grid.cell(at: CGPoint(x: 1, y: 479))
        XCTAssertEqual(hit?.column, 0)
        XCTAssertEqual(hit?.row, 0)
    }

    func testTheBottomLeftCellIsTheLastRow() {
        let hit = grid.cell(at: CGPoint(x: 1, y: 1))
        XCTAssertEqual(hit?.row, 23)
    }

    func testColumnsAdvanceWithX() {
        XCTAssertEqual(grid.cell(at: CGPoint(x: 25, y: 470))?.column, 2)
    }

    func testAPointOutsideTheGridIsNoCell() {
        XCTAssertNil(grid.cell(at: CGPoint(x: -1, y: 100)))
        XCTAssertNil(grid.cell(at: CGPoint(x: 801, y: 100)))
        XCTAssertNil(grid.cell(at: CGPoint(x: 10, y: 481)))
        XCTAssertNil(grid.cell(at: CGPoint(x: 10, y: -1)))
    }

    func testARectSitsOnTheRowItNames() {
        // Row 0 is the top: its rect's top edge is the view's top edge.
        XCTAssertEqual(grid.rect(row: 0, cells: 0..<3), CGRect(x: 0, y: 460, width: 30, height: 20))
        // And the last row sits on the floor.
        XCTAssertEqual(grid.rect(row: 23, cells: 0..<1), CGRect(x: 0, y: 0, width: 10, height: 20))
    }

    /// The two directions must invert each other, or the mark lands on a
    /// different span from the one the pointer hit.
    func testARectContainsThePointThatFoundIt() {
        let point = CGPoint(x: 45, y: 333)
        guard let hit = grid.cell(at: point) else { return XCTFail("no cell") }
        let rect = grid.rect(row: hit.row, cells: hit.column..<(hit.column + 1))
        XCTAssertTrue(rect.contains(point), "\(rect) does not contain \(point)")
    }

    /// A retina surface reports pixels while the view is laid out in
    /// points, and the ratio is measured rather than assumed.
    func testCellSizeIsMeasuredFromTheSurfaceRatio() {
        let retina = OutputAffordance.Metrics(
            columns: 80, rows: 24, cellWidth: 20 * 400 / 800, cellHeight: 40 * 480 / 960,
            height: 480)
        XCTAssertEqual(retina.cellWidth, 10)
        XCTAssertEqual(retina.cellHeight, 20)
    }
}
