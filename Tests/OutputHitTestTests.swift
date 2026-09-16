import XCTest
@testable import Synapty

/// WHICH DETECTION THE POINTER IS OVER, in terminal cells.
///
/// A cell is not a character: a CJK glyph occupies two. The underline and
/// the resolved target have to name the same characters — a mark drawn
/// over one span while another opens is the display-versus-target mismatch
/// [[RFC-0015]] C-DERIVED exists to close — so both come from this map.
final class OutputHitTestTests: XCTestCase {

    func testCellsAreCharactersInAsciiText() {
        let line = "see /tmp/a now"
        let hit = OutputDetector.detection(in: line, base: nil, atCell: 5)
        XCTAssertEqual(hit?.text, "/tmp/a")
    }

    func testAPointerBeforeTheSpanHitsNothing() {
        XCTAssertNil(OutputDetector.detection(in: "see /tmp/a", base: nil, atCell: 1))
    }

    func testAPointerAfterTheSpanHitsNothing() {
        XCTAssertNil(OutputDetector.detection(in: "/tmp/a  x", base: nil, atCell: 8))
    }

    func testTheFirstAndLastCellOfASpanBothHit() {
        let line = "/tmp/a"
        XCTAssertEqual(OutputDetector.detection(in: line, base: nil, atCell: 0)?.text, "/tmp/a")
        XCTAssertEqual(OutputDetector.detection(in: line, base: nil, atCell: 5)?.text, "/tmp/a")
        XCTAssertNil(OutputDetector.detection(in: line, base: nil, atCell: 6))
    }

    /// Six characters of Chinese prose occupy TWELVE cells, so a path
    /// after them starts six cells further right than its character index.
    func testAWideGlyphOccupiesTwoCells() {
        let line = "写入了文件到 /tmp/a"
        // "写入了文件到" is 6 wide chars = 12 cells, then a space = 13.
        XCTAssertNil(OutputDetector.detection(in: line, base: nil, atCell: 6),
                     "cell 6 is still inside the prose")
        XCTAssertEqual(OutputDetector.detection(in: line, base: nil, atCell: 13)?.text, "/tmp/a")
    }

    func testCellRangeOfADetectionAccountsForWideGlyphs() {
        let line = "写入 /tmp/a"
        let found = OutputDetector.detect(in: line, base: nil)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(OutputDetector.cells(of: found[0], in: line), 5..<11)
    }

    func testAddressesAreHitTestedToo() {
        // They are hit-tested because they are SHOWN on hover; taking one
        // is what the caller must refuse, not finding one.
        let hit = OutputDetector.detection(in: "at https://x.test/y", base: nil, atCell: 5)
        XCTAssertEqual(hit?.kind, .address("https://x.test/y"))
    }

    func testACellBeyondTheLineHitsNothing() {
        XCTAssertNil(OutputDetector.detection(in: "/tmp/a", base: nil, atCell: 999))
    }
}
