import XCTest
@testable import Synapty

/// [[WI-2026-09-02-001]] — the scrollbar's arithmetic. The overlay is
/// pixels; this is the part that can silently lie.
final class ScrollbarMathTests: XCTestCase {

    /// CONTENT THAT FITS DRAWS NOTHING — a scrollbar for no overflow is
    /// noise pretending to be information.
    func testNoOverflowNoThumb() {
        XCTAssertNil(ScrollbarMath.thumb(total: 40, offset: 0, len: 40, track: 400))
        XCTAssertNil(ScrollbarMath.thumb(total: 30, offset: 0, len: 40, track: 400))
        XCTAssertNil(ScrollbarMath.thumb(total: 0, offset: 0, len: 0, track: 400))
    }

    /// The thumb's SIZE is the viewport's share of the whole.
    func testThumbSizeIsProportional() throws {
        let thumb = try XCTUnwrap(
            ScrollbarMath.thumb(total: 400, offset: 0, len: 40, track: 400))
        XCTAssertEqual(thumb.height, 40, accuracy: 0.5, "40 of 400 rows on a 400pt track")
    }

    /// BOTH EXTREMES ARE REACHABLE: offset 0 puts the thumb at the very
    /// top, and the maximum offset puts its bottom edge at the very end —
    /// a mapping over the full track instead of the travel never gets
    /// there, and the thumb reads as stuck.
    func testExtremesTouchTheEnds() throws {
        let top = try XCTUnwrap(
            ScrollbarMath.thumb(total: 1000, offset: 0, len: 50, track: 500))
        XCTAssertEqual(top.y, 0)
        let bottom = try XCTUnwrap(
            ScrollbarMath.thumb(total: 1000, offset: 950, len: 50, track: 500))
        XCTAssertEqual(bottom.y + bottom.height, 500, accuracy: 0.5)
    }

    /// TEN THOUSAND LINES MUST STILL BE GRABBABLE. Proportional sizing
    /// alone would draw a 2pt thumb over a long build log.
    func testTheThumbNeverShrinksPastAFinger() throws {
        let thumb = try XCTUnwrap(
            ScrollbarMath.thumb(total: 10_000, offset: 0, len: 40, track: 400))
        XCTAssertEqual(thumb.height, ScrollbarMath.minThumb)
    }

    /// THE DRAG IS THE RENDERING'S INVERSE. Written any other way the
    /// thumb jumps on grab — the row under the thumb's top must map back
    /// to the same thumb position.
    func testDragInvertsRendering() throws {
        let (total, len, track) = (5_000, 60, CGFloat(700))
        for offset in [0, 1, 500, 2_470, 4_939, 4_940] {
            let thumb = try XCTUnwrap(
                ScrollbarMath.thumb(total: total, offset: offset, len: len, track: track))
            XCTAssertEqual(
                ScrollbarMath.row(forThumbY: thumb.y, total: total, len: len, track: track),
                offset, "offset \(offset) did not survive the round trip")
        }
    }

    /// Drags past either end clamp instead of asking for rows that do
    /// not exist.
    func testDragClampsAtTheEnds() {
        XCTAssertEqual(ScrollbarMath.row(forThumbY: -50, total: 1000, len: 50, track: 500), 0)
        XCTAssertEqual(ScrollbarMath.row(forThumbY: 9_999, total: 1000, len: 50, track: 500), 950)
    }

    /// Following the output is the resting state.
    func testAtBottom() {
        XCTAssertTrue(ScrollbarMath.isAtBottom(total: 100, offset: 60, len: 40))
        XCTAssertFalse(ScrollbarMath.isAtBottom(total: 100, offset: 59, len: 40))
        XCTAssertTrue(ScrollbarMath.isAtBottom(total: 40, offset: 0, len: 40))
    }
}
