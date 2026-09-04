import XCTest
@testable import Synapty

/// [[BrowserAddress]] — what a browser leaf will load ([[WI-2026-08-19-004]]).
///
/// THE ALLOW-LIST IS A SECURITY OBLIGATION AND NOT POLISH. A browser leaf
/// draws content that is better able to imitate this window than anything
/// else the workbench shows ([[ADR-0010]] rule d), and what it may fetch
/// "cannot be retrofitted once content sits somewhere it appears to
/// belong".
final class BrowserAddressTests: XCTestCase {

    private func url(_ typed: String, file: StaticString = #filePath, line: UInt = #line) -> URL? {
        guard case .success(let u) = BrowserAddress.parse(typed) else { return nil }
        return u
    }

    private func refusal(_ typed: String) -> BrowserAddress.Rejection? {
        guard case .failure(let why) = BrowserAddress.parse(typed) else { return nil }
        return why
    }

    // MARK: - What it takes

    func testItTakesTheTwoSchemesOnTheList() {
        XCTAssertEqual(url("https://example.com/docs")?.absoluteString, "https://example.com/docs")
        XCTAssertEqual(url("http://example.com")?.absoluteString, "http://example.com")
    }

    /// A human types a hostname, not a URL.
    func testABareHostnameBecomesHttps() {
        XCTAssertEqual(url("example.com/a/b")?.scheme, "https")
        XCTAssertEqual(url("example.com/a/b")?.host, "example.com")
    }

    /// THE COMMONEST ADDRESS A WORKBENCH IS POINTED AT. `localhost:3000`
    /// parses as scheme `localhost` under RFC 3986; refusing it as an
    /// unknown scheme would be nonsense to the human typing it.
    func testLoopbackWithAPortIsAHostAndAPortAndSpeaksHttp() {
        XCTAssertEqual(url("localhost:3000")?.scheme, "http")
        XCTAssertEqual(url("localhost:3000")?.host, "localhost")
        XCTAssertEqual(url("localhost:3000")?.port, 3000)
        XCTAssertEqual(url("127.0.0.1:8080/admin")?.scheme, "http")
        XCTAssertEqual(url("127.0.0.1:8080/admin")?.port, 8080)
    }

    /// And a real site keeps its transport — defaulting a public host to
    /// http would be downgrading something that is not ours to downgrade.
    func testARealHostWithAPortStillGetsHttps() {
        XCTAssertEqual(url("example.com:8443")?.scheme, "https")
    }

    // MARK: - What it refuses, and why it says so

    func testItRefusesLocalFilesByName() {
        XCTAssertEqual(refusal("file:///etc/passwd"), .localFile)
        XCTAssertEqual(refusal("file:///Users/someone/notes.md"), .localFile)
        // The message sends them somewhere rather than just saying no.
        XCTAssertTrue(BrowserAddress.Rejection.localFile.message.contains("file pane"),
                      "a refusal that does not say what to do gets worked around")
    }

    func testItRefusesEverySchemeThatIsNotOnTheList() {
        for (typed, scheme) in [("javascript:alert(1)", "javascript"),
                                ("data:text/html,<b>x", "data"),
                                ("ftp://example.com/f", "ftp"),
                                ("about:blank", "about"),
                                ("ws://example.com/s", "ws")] {
            XCTAssertEqual(refusal(typed), .refusedScheme(scheme),
                           "\(typed) was not refused as \(scheme)")
        }
    }

    /// THE UNKNOWN FALLS OUT, which is the whole difference between a list
    /// of what is allowed and a list of what is not.
    func testASchemeNobodyThoughtOfIsRefusedRatherThanAdmitted() {
        XCTAssertEqual(refusal("synapty-agent://take-over"), .refusedScheme("synapty-agent"))
    }

    func testNothingTypedIsItsOwnAnswer() {
        XCTAssertEqual(refusal(""), .empty)
        XCTAssertEqual(refusal("   "), .empty)
    }

    func testSomethingThatNamesNoSiteIsRefused() {
        XCTAssertEqual(refusal("/just/a/path"), .noHost)
    }

    /// The list is two entries and the message says which two, so a human
    /// reading the refusal learns the rule rather than only this instance.
    func testTheRefusalNamesWhatIsAllowed() {
        let message = BrowserAddress.Rejection.refusedScheme("ftp").message
        XCTAssertTrue(message.contains("http") && message.contains("https"))
    }
}
