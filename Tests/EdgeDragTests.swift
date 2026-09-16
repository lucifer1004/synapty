import XCTest
@testable import Synapty

/// [[EdgeDrag]] — the anchor and the live width as one value.
final class EdgeDragTests: XCTestCase {

    /// EVERY FRAME MEASURES FROM THE START. The divider reports the
    /// translation since the gesture began, so a drag that accumulated
    /// would apply the whole gesture again on every tick.
    func testTheDragAlwaysMeasuresFromWhereItBegan() {
        var drag = EdgeDrag(from: 200)
        drag.slide(by: 30, within: 100...300)
        XCTAssertEqual(drag.width, 230)
        drag.slide(by: 60, within: 100...300)
        XCTAssertEqual(drag.width, 260, "the second report was added to the first")
        XCTAssertEqual(drag.anchor, 200, "the anchor moved during the drag")
    }

    func testTheWidthStaysWithinItsLimits() {
        var drag = EdgeDrag(from: 200)
        drag.slide(by: -500, within: 180...320)
        XCTAssertEqual(drag.width, 180)
        drag.slide(by: 500, within: 180...320)
        XCTAssertEqual(drag.width, 320)
    }

    /// A drag that has not moved is the width it started at, so the
    /// divider does not jump on the first frame.
    func testADragThatHasNotMovedIsWhereItStarted() {
        XCTAssertEqual(EdgeDrag(from: 240).width, 240)
    }
}
