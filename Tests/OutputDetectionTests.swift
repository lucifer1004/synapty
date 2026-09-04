import XCTest
@testable import Synapty

/// What the workbench may recognise in a pane's output, and what it may
/// resolve it to ([[RFC-0015]] C-DERIVED).
final class OutputDetectionTests: XCTestCase {

    // MARK: - Paths

    func testAbsolutePathIsRecognised() {
        let found = OutputDetector.detect(in: "wrote /tmp/out.txt ok", base: nil)
        XCTAssertEqual(found.map(\.text), ["/tmp/out.txt"])
        XCTAssertEqual(found.first?.kind, .path("/tmp/out.txt"))
    }

    func testAbsolutePathNeedsNoBase() {
        // "where that is unknown, there is no offer" bounds RELATIVE names
        // only; an absolute one names its own place.
        let found = OutputDetector.detect(in: "see /var/log/system.log", base: nil)
        XCTAssertEqual(found.first?.kind, .path("/var/log/system.log"))
    }

    func testRelativePathResolvesAgainstTheBase() {
        let found = OutputDetector.detect(in: "edit src/main.zig now", base: "/home/z/proj")
        XCTAssertEqual(found.first?.kind, .path("/home/z/proj/src/main.zig"))
        XCTAssertEqual(found.first?.text, "src/main.zig")
    }

    func testRelativePathWithoutABaseIsNotOffered() {
        let found = OutputDetector.detect(in: "edit src/main.zig now", base: nil)
        XCTAssertTrue(found.isEmpty)
    }

    func testAbsolutePathSurvivesAMissingBase() {
        // The two rules meet on one line: the relative name is dropped, the
        // absolute one is not.
        let found = OutputDetector.detect(in: "src/a.zig -> /tmp/a.o", base: nil)
        XCTAssertEqual(found.map(\.text), ["/tmp/a.o"])
    }

    func testLineAndColumnSuffixIsNotPartOfThePath() {
        // `file:42:7` is how every compiler in this repository points at a
        // line, and the path is what opens.
        let found = OutputDetector.detect(in: "Sources/App.swift:42:7: error", base: "/w")
        XCTAssertEqual(found.first?.kind, .path("/w/Sources/App.swift"))
        XCTAssertEqual(found.first?.text, "Sources/App.swift")
    }

    func testTrailingPunctuationIsNotPartOfThePath() {
        let found = OutputDetector.detect(in: "created /tmp/a.txt, then /tmp/b.txt.", base: nil)
        XCTAssertEqual(found.map(\.text), ["/tmp/a.txt", "/tmp/b.txt"])
    }

    func testParentTraversalResolves() {
        let found = OutputDetector.detect(in: "../sibling/x.txt", base: "/w/proj")
        XCTAssertEqual(found.first?.kind, .path("/w/sibling/x.txt"))
    }

    func testTraversalAboveTheRootIsNotOffered() {
        // A resolution that walks off the top has no answer to give.
        let found = OutputDetector.detect(in: "../../../../x", base: "/w")
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - Addresses

    func testAddressIsRecognisedButNotAPath() {
        let found = OutputDetector.detect(in: "serving on https://example.com/x", base: nil)
        XCTAssertEqual(found.first?.kind, .address("https://example.com/x"))
    }

    func testAddressIsNeverResolvedAsARelativeName() {
        // `https://h/p` must not become `<base>/https:/h/p`.
        let found = OutputDetector.detect(in: "http://localhost:3000/a", base: "/w")
        XCTAssertEqual(found.first?.kind, .address("http://localhost:3000/a"))
    }

    func testFileSchemeIsNotAnAddressAndNotAPath() {
        // A `file:` URL names a path while wearing an address's clothes;
        // admitting it either way would let text pick which rule applies.
        let found = OutputDetector.detect(in: "file:///etc/hosts", base: nil)
        XCTAssertTrue(found.allSatisfy { $0.kind != .address("file:///etc/hosts") })
    }

    // MARK: - Ambiguity

    func testTwoCandidatesOnOneLineAreBothOffered() {
        let found = OutputDetector.detect(in: "/tmp/a and /tmp/b", base: nil)
        XCTAssertEqual(found.map(\.text), ["/tmp/a", "/tmp/b"])
    }

    // MARK: - Inertness

    /// RESOLUTION IS SYNTACTIC. Contact is unrepresentable rather than
    /// merely absent — `detect` is a pure function of a string and has no
    /// way to reach a filesystem — so what is worth testing is the
    /// observable half: an existence filter added later would drop this.
    func testAPathThatCannotExistResolvesLikeOneThatDoes() {
        let absent = "/nonexistent-\(UUID().uuidString)/x.txt"
        let found = OutputDetector.detect(in: "wrote \(absent)", base: nil)
        XCTAssertEqual(found.first?.kind, .path(absent))
    }
}
