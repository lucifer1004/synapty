import XCTest
@testable import Synapty

/// [[WI-2026-08-15-011]]. An agent chooses where on its service to point;
/// the workbench chooses which machine that is. These pin the seam, which
/// is the kind that fails silently — a URL that goes somewhere else still
/// loads, and looks like it worked.
final class ExposedPathTests: XCTestCase {

    private let port = 39000

    // MARK: - What an agent is for

    /// The ordinary cases, which are most of them: a service worth showing
    /// is usually not at the root.
    func testAnOrdinaryPathSurvivesIntact() {
        XCTAssertEqual(ExposedPath.url(localPort: port, path: "/d/abc123")?.absoluteString,
                       "http://127.0.0.1:39000/d/abc123")
        XCTAssertEqual(ExposedPath.url(localPort: port, path: "/reports/2026-08-16.html")?.absoluteString,
                       "http://127.0.0.1:39000/reports/2026-08-16.html")
    }

    /// A QUERY IS NOT DECORATION. Jupyter without its token is a login
    /// page, so dropping the query would turn "look at this" into "log in
    /// to something".
    func testAQueryIsCarried() {
        XCTAssertEqual(ExposedPath.url(localPort: port, path: "/lab?token=abc123")?.absoluteString,
                       "http://127.0.0.1:39000/lab?token=abc123")
        XCTAssertEqual(ExposedPath.url(localPort: port, path: "/x#section-2")?.absoluteString,
                       "http://127.0.0.1:39000/x#section-2")
    }

    /// Nothing given is the root, not a failure. Most exposures say nothing
    /// about a path and must keep working.
    func testNoPathIsTheRoot() {
        for empty in [nil, ""] {
            XCTAssertEqual(ExposedPath.url(localPort: port, path: empty)?.absoluteString,
                           "http://127.0.0.1:39000/")
        }
    }

    // MARK: - The authority is not the agent's

    /// THE ONE THAT MAKES THIS A TYPE. Appending to a string would put the
    /// loopback address in the USERINFO field and hand the host to somebody
    /// else — the whole address still parses, still loads, and is not our
    /// machine.
    func testAPathCannotTurnIntoAnotherHost() {
        for escape in ["@evil.example/", "//evil.example/x", "https://evil.example/",
                       "/\\evil.example/x", "\\\\evil.example"] {
            let url = ExposedPath.url(localPort: port, path: escape)
            if let url {
                XCTAssertEqual(url.host, "127.0.0.1", "\(escape) reached \(url)")
                XCTAssertEqual(url.port, port, "\(escape) reached \(url)")
            }
            XCTAssertNil(url, "\(escape) should be refused outright, not normalised")
        }
    }

    /// A relative path is refused rather than quietly made absolute:
    /// "relative to what" has no answer here, and guessing would make the
    /// agent's mistake invisible.
    func testARelativePathIsRefused() {
        XCTAssertEqual(ExposedPath.parse("docs/index.html"), .failure(.notAbsolute))
        XCTAssertEqual(ExposedPath.parse("../etc/passwd"), .failure(.notAbsolute))
    }

    /// The refusal NAMES WHAT WAS WRONG, because its reader is an agent
    /// that has to fix its own call.
    func testARefusalTellsTheAgentWhatToChange() {
        // A whole URL fails the leading-slash rule before anything looks at
        // its scheme, and that message is the right diagnosis anyway.
        guard case .failure(let asURL) = ExposedPath.parse("https://evil.example/") else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(asURL, .notAbsolute)
        XCTAssertTrue(asURL.message.contains("not a URL"), asURL.message)

        // The authority message is for the case the slash rule lets past.
        guard case .failure(let authority) = ExposedPath.parse("//evil.example/x") else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(authority, .carriesAuthority)
        XCTAssertTrue(authority.message.contains("host"), authority.message)
    }

    /// Control characters are refused. They have no meaning in a path and
    /// every meaning in whatever the string is later pasted into.
    func testControlCharactersAreRefused() {
        XCTAssertEqual(ExposedPath.parse("/x\nHost: evil.example"), .failure(.malformed))
        XCTAssertEqual(ExposedPath.parse("/x\u{0}y"), .failure(.malformed))
    }

    /// Whatever is thrown at it, the destination is this machine — the
    /// property the split exists to guarantee, stated once directly.
    func testTheDestinationIsAlwaysLoopback() {
        let attempts = ["/", "/a/b", "/a?b=c", "@evil.example", "//evil.example",
                        "http://evil.example", "/..%2F..%2Fetc", "/x#y", "docs"]
        for attempt in attempts {
            guard let url = ExposedPath.url(localPort: port, path: attempt) else { continue }
            XCTAssertEqual(url.host, "127.0.0.1", attempt)
            XCTAssertEqual(url.port, port, attempt)
            XCTAssertEqual(url.scheme, "http", attempt)
        }
    }

    // MARK: - What the human is shown

    /// The whole address, because the point of showing it is that they can
    /// see where the click goes.
    func testTheDisplayIsTheWholeAddress() {
        XCTAssertEqual(ExposedPath.display(localPort: port, path: "/lab?token=abc"),
                       "http://127.0.0.1:39000/lab?token=abc")
    }
}
