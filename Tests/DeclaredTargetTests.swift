import XCTest
@testable import Synapty

/// WHEN A DECLARED TARGET MAY BE FOLLOWED, AND WHEN THE HUMAN IS ASKED.
///
/// A hyperlink escape lets a child print one thing and mean another. Most
/// of the time that is abbreviation — `main.zig` standing for a full path —
/// and refusing it breaks every tool that uses the escape as intended.
/// The deception is narrower: displayed characters that THEMSELVES read as
/// a destination, naming somewhere other than where the link goes.
final class DeclaredTargetTests: XCTestCase {

    private func verdict(shown: String, target: String) -> DeclaredTarget.Verdict {
        DeclaredTarget.verdict(shown: shown, target: target)
    }

    // MARK: - Abbreviation: follow it

    func testANameThatClaimsNothingIsAnAbbreviation() {
        XCTAssertEqual(verdict(shown: "main.zig", target: "file:///w/src/main.zig"), .follow)
    }

    func testAWordIsAnAbbreviation() {
        XCTAssertEqual(verdict(shown: "the docs", target: "https://docs.test/x"), .follow)
    }

    func testAnIssueNumberIsAnAbbreviation() {
        XCTAssertEqual(verdict(shown: "#412", target: "https://github.test/o/r/issues/412"),
                       .follow)
    }

    // MARK: - Agreement: follow it

    func testTheSameAddressTwiceIsNoDeception() {
        XCTAssertEqual(verdict(shown: "https://a.test/x", target: "https://a.test/x"), .follow)
    }

    /// A matched url arrives as its own display text, which is the common
    /// case and must never ask.
    func testAHostThatAgreesIsFollowedEvenWhenThePathDiffers() {
        // The characters claim a HOST. Where the link goes to that same
        // host, nothing was misdescribed — a tracking path is not the
        // deception this rule is about.
        XCTAssertEqual(verdict(shown: "https://a.test", target: "https://a.test/deep/page"),
                       .follow)
    }

    func testASchemeUpgradeIsNotDeception() {
        XCTAssertEqual(verdict(shown: "http://a.test/x", target: "https://a.test/x"), .follow)
    }

    // MARK: - Deception: ask

    func testAnAddressPointingAtAnotherHostIsAsked() {
        XCTAssertEqual(
            verdict(shown: "https://docs.company.test", target: "https://evil.test/steal"),
            .ask)
    }

    func testABareHostPointingElsewhereIsAsked() {
        XCTAssertEqual(verdict(shown: "docs.company.test", target: "https://evil.test/"), .ask)
    }

    /// A LOOK-ALIKE HOST IS STILL ANOTHER HOST. Nothing here tries to judge
    /// how similar two names are — same or not is the whole test.
    func testASubdomainOfTheDisplayedHostIsAnotherHost() {
        XCTAssertEqual(
            verdict(shown: "https://company.test", target: "https://company.test.evil.test/"),
            .ask)
    }

    func testAPathShownWhileAnAddressOpensIsAsked() {
        XCTAssertEqual(verdict(shown: "/etc/hosts", target: "https://evil.test/"), .ask)
    }

    func testAnAddressShownWhileAFileOpensIsAsked() {
        XCTAssertEqual(verdict(shown: "https://a.test/x", target: "file:///etc/passwd"), .ask)
    }

    func testAPathShownWhileAnotherPathOpensIsAsked() {
        XCTAssertEqual(verdict(shown: "/tmp/safe.txt", target: "file:///etc/passwd"), .ask)
    }

    // MARK: - Containment is not agreement

    /// A TARGET THAT MERELY MENTIONS THE NAME IS NOT THE NAME. Appending
    /// the displayed host as a query parameter would otherwise buy an
    /// attacker a `follow`.
    func testTheDisplayedNameInAQueryIsNotAgreement() {
        XCTAssertEqual(
            verdict(shown: "docs.company.test", target: "https://evil.test/?r=docs.company.test"),
            .ask)
    }

    func testTheDisplayedNameInAFragmentIsNotAgreement() {
        XCTAssertEqual(
            verdict(shown: "docs.company.test", target: "https://evil.test/#docs.company.test"),
            .ask)
    }

    /// A displayed name that IS a path segment is the abbreviation the
    /// escape exists for, wherever the target lives.
    func testANameThatIsAPathSegmentIsAnAbbreviation() {
        XCTAssertEqual(verdict(shown: "main.zig", target: "https://gh.test/blob/main.zig"),
                       .follow)
    }

    func testANameThatIsTheHostIsAgreement() {
        XCTAssertEqual(verdict(shown: "docs.company.test", target: "https://docs.company.test/x"),
                       .follow)
    }

    /// A PATH IS AN ANCESTOR OR IT IS SOMEWHERE ELSE. `/tmp/a` appearing
    /// inside `/evil/tmp/a` is a different file wearing part of the name.
    func testAShownPathBuriedInsideAnotherIsNotAnAncestor() {
        XCTAssertEqual(verdict(shown: "/tmp/a", target: "file:///evil/tmp/a"), .ask)
    }

    func testAShownDirectoryAboveTheTargetIsAnAncestor() {
        XCTAssertEqual(verdict(shown: "/etc", target: "file:///etc/passwd"), .follow)
    }

    func testASiblingPrefixIsNotAnAncestor() {
        // `/etc` must not swallow `/etcetera/x`.
        XCTAssertEqual(verdict(shown: "/etc", target: "file:///etcetera/x"), .ask)
    }

    // MARK: - What the filesystem will do, not what the string looks like

    /// TRAVERSAL IS RESOLVED BY WHOEVER OPENS IT. A prefix test on the raw
    /// string sees `/tmp/safe/` and says yes; LaunchServices folds the
    /// `..` and opens something else entirely.
    func testTraversalOutOfTheShownDirectoryIsAsked() {
        XCTAssertEqual(
            verdict(shown: "/tmp/safe", target: "file:///tmp/safe/../../../etc/passwd"), .ask)
    }

    func testTraversalThatStaysInsideIsStillAnAncestor() {
        XCTAssertEqual(verdict(shown: "/tmp/safe", target: "file:///tmp/safe/a/../b"), .follow)
    }

    func testASingleDotIsFolded() {
        XCTAssertEqual(verdict(shown: "/tmp/safe", target: "file:///tmp/./safe/x"), .follow)
    }

    /// Foundation strips a query from a file url before opening it, so a
    /// comparison that keeps one is comparing a different file.
    func testAQueryOnAFileUrlIsNotPartOfThePath() {
        XCTAssertEqual(verdict(shown: "/innocent?file", target: "file:///innocent?file"), .ask)
    }

    // MARK: - The same host is the same host

    func testAnExplicitDefaultPortIsTheSameHost() {
        XCTAssertEqual(verdict(shown: "https://a.test", target: "https://a.test:443/x"), .follow)
    }

    func testAnyPortIsTheSameHost() {
        // A different port is a different service, not a different place —
        // and the preview shows it. Asking here would fire on every tool
        // that prints an explicit port.
        XCTAssertEqual(verdict(shown: "https://a.test", target: "https://a.test:8080/x"),
                       .follow)
    }

    func testAPortDoesNotSmuggleAnotherHost() {
        XCTAssertEqual(verdict(shown: "https://a.test", target: "https://a.test.evil.test:443/"),
                       .ask)
    }

    // MARK: - Nothing to compare

    func testAnUnparseableTargetIsAsked() {
        // If what would open cannot be read, it cannot be shown to agree
        // with anything.
        XCTAssertEqual(verdict(shown: "https://a.test", target: "not a url"), .ask)
    }
}
