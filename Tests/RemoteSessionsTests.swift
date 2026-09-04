import XCTest
@testable import Synapty

/// WHAT A HOST SAYS IT IS HOLDING.
///
/// [[RFC-0014]] C-END requires every holder on a host to be enumerable on
/// that host, reporting its name, whether a client is attached, whether it
/// was ever attached, how long it has been unattached, and whether its
/// child has exited. The far side already answers all of that; nothing on
/// this side had ever asked, so a holder no workspace named was invisible
/// here — found in its dozens twice, on remotehost and on this Mac.
final class RemoteSessionsTests: XCTestCase {

    private func parse(_ text: String) -> [RemoteSessions.Session] {
        RemoteSessions.parse(stdout: text, exitCode: 0) ?? []
    }

    /// THE TWO TRAILING COLUMNS ([[RFC-0014]] C-CLIENT-LABEL,
    /// C-SESSION-NAME): who is attached, and what the human calls it.
    func testWhoIsAttachedAndTheNameAreRead() {
        let rows = parse("gpu-1\tattached\tseen\trunning\t0\t/srv\tclaude\t/srv\tgui@deskmac:41\tthe deploy one\n")
        XCTAssertEqual(rows.first?.attachedBy, "gui@deskmac:41")
        XCTAssertEqual(rows.first?.humanName, "the deploy one")
    }

    /// An older far side writes eight columns and both stay nil — the
    /// dash is "none", not a name.
    func testAnEightColumnRowStillReadsWithNeither() {
        let rows = parse("gpu-1\tdetached\tseen\trunning\t3600\t/srv/app\tclaude\t/srv\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.attachedBy)
        XCTAssertNil(rows.first?.humanName)
        let dashed = parse("gpu-1\tdetached\tseen\trunning\t0\t-\t-\t-\t-\t-\n")
        XCTAssertNil(dashed.first?.attachedBy)
        XCTAssertNil(dashed.first?.humanName)
    }

    func testAnOrdinaryRowIsRead() {
        let rows = parse("gpu-1\tdetached\tseen\trunning\t3600\t/srv/app\tclaude\t/srv\n")
        XCTAssertEqual(rows.count, 1)
        let s = rows[0]
        XCTAssertEqual(s.name, "gpu-1")
        XCTAssertFalse(s.attached)
        XCTAssertTrue(s.everAttached)
        XCTAssertFalse(s.childExited)
        XCTAssertEqual(s.unattached, 3600)
        XCTAssertEqual(s.command, "claude")
    }

    /// WHAT TELLS TWO SESSIONS APART. Every one of them is named
    /// `local-XXXX` — the namespace [[RFC-0008]] C-IDENTITY reserves, and
    /// deliberately not the host label, since that spelling broke
    /// identity scoping. So the id distinguishes nothing a human can use,
    /// and the directory is what does: `~/proj/api` against `~/proj/web`.
    func testTheDirectoryIsRead() {
        let rows = parse("gpu-1\tdetached\tseen\trunning\t60\t/srv/build\tzsh\t/srv/app\n")
        XCTAssertEqual(rows[0].directory, "/srv/app")
    }

    /// THE SHELL'S, NOT THE FOREGROUND GROUP'S. They differ whenever the
    /// session is running anything that has `cd`d — [[RemotePwd]] records
    /// `jenv rehash` living in `~/.jenv/shims` — and what identifies a
    /// session to a human is where they are working, not where a build
    /// script went.
    func testTheShellDirectoryWinsOverTheForegroundOne() {
        let rows = parse("gpu-1\tdetached\tseen\trunning\t60\t/home/z/.jenv/shims\tjenv\t/home/z/proj\n")
        XCTAssertEqual(rows[0].directory, "/home/z/proj")
    }

    func testAnAbsentDirectoryIsNil() {
        let rows = parse("gpu-1\tdetached\tseen\trunning\t60\t-\t-\t-\n")
        XCTAssertNil(rows[0].directory)
    }

    /// The host writes "-" where it could not say, and a row falls back to
    /// the foreground group's rather than showing nothing.
    func testTheForegroundDirectoryIsUsedWhenTheShellHasNone() {
        let rows = parse("gpu-1\tdetached\tseen\trunning\t60\t/srv/build\tzsh\t-\n")
        XCTAssertEqual(rows[0].directory, "/srv/build")
    }

    func testAnAttachedSessionSaysSo() {
        let rows = parse("gpu-1\tattached\tseen\trunning\t0\t/srv\tzsh\t/srv\n")
        XCTAssertTrue(rows[0].attached)
        XCTAssertEqual(rows[0].unattached, 0)
    }

    /// THE POLICY LINE IS NOT A SESSION. It is the sentence C-END requires
    /// the listing to carry, and reading it as a row would put a session
    /// called "policy" in front of the human.
    func testThePolicyLineIsNotASession() {
        let rows = parse("""
        gpu-1\tdetached\tseen\trunning\t5\t/srv\tzsh\t/srv
        policy\tsessions are never ended except by you
        """)
        XCTAssertEqual(rows.map(\.name), ["gpu-1"])
    }

    func testNoSessionsIsNoRows() {
        XCTAssertEqual(parse("no sessions\n"), [])
    }

    /// ALIVE AND UNREACHABLE ARE COMPATIBLE, and the far side says so in a
    /// row of its own. C-END requires such a holder to still be listed and
    /// to be distinguishable — it can be ended but not attached, and a
    /// human shown a problem and denied the remedy has been told nothing.
    func testAnUnreachableHolderIsStillListed() {
        let rows = parse("gpu-2\tunreachable\t-\t-\t-\tpid 4211\t-\t-\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "gpu-2")
        XCTAssertTrue(rows[0].unreachable)
        XCTAssertFalse(rows[0].attached, "it cannot be attached; that is the point")
    }

    func testAFailedCallIsNoRowsRatherThanAnEmptyHost() {
        // A host that could not be asked has not answered "nothing" — and
        // this used to assert `== []`, which is precisely the value an
        // empty host produces. The listing could not tell the caller
        // which had happened, so the caller could not act on either, and
        // a host's last row stayed on screen for the life of the app
        // ([[WI-2026-09-03-012]]).
        XCTAssertNil(RemoteSessions.parse(stdout: "", exitCode: 255))
        XCTAssertNil(RemoteSessions.parse(stdout: "", exitCode: nil))
    }

    /// AND THE OTHER HALF, WHICH IS THE ONE A HUMAN WATCHES FOR. A host
    /// answering that it holds nothing is an answer, not a failure to
    /// answer.
    func testAHostThatHoldsNothingSaysSo() {
        XCTAssertEqual(RemoteSessions.parse(stdout: "", exitCode: 0), [])
        // The policy sentence is all a host with no sessions writes.
        XCTAssertEqual(
            RemoteSessions.parse(stdout: "policy\tsessions are never ended except by you\n",
                                 exitCode: 0),
            [])
    }

    func testARowWithTooFewColumnsIsSkippedRatherThanGuessed() {
        let rows = parse("gpu-1\tdetached\n")
        XCTAssertEqual(rows, [])
    }

    func testRowsComeBackInTheOrderTheHostGaveThem() {
        let rows = parse("""
        b\tdetached\tseen\trunning\t1\t-\t-\t-
        a\tdetached\tseen\trunning\t2\t-\t-\t-
        """)
        XCTAssertEqual(rows.map(\.name), ["b", "a"],
                       "the host has already decided; a second ordering here is a second answer")
    }
}
