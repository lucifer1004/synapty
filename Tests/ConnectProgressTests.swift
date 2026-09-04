import XCTest
@testable import Synapty

/// [[WI-2026-08-17-016]]. The rules that decide what a human looks at
/// while a connection is being made, and the moment they stop looking at
/// it.
///
/// DRIVEN THROUGH THE FILE, not through the object's own setters: the
/// account is written by another process entirely (`src/cli/progress.zig`
/// and `scripts/connect.sh`), so the format is the contract and a test
/// that bypassed it would agree with itself about a format nobody else
/// writes.
@MainActor
final class ConnectProgressTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-progress-\(UUID().uuidString)")
        ConfigPaths.rootOverride = root
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        ConfigPaths.rootOverride = nil
        super.tearDown()
    }

    /// Begin an account the way a dial does, then read it the way the
    /// workbench does.
    private func dial(_ agentID: String) -> ConnectProgress {
        ConnectProgress.begin(for: agentID)
        let p = ConnectProgress()
        p.start(agentID: agentID)
        return p
    }

    /// Append to the channel the way the connection does.
    private func append(_ agentID: String, _ lines: String...) {
        let url = ConnectProgress.channel(for: agentID)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = lines.map { "\(Int(Date().timeIntervalSince1970 * 1000)) \($0)\n" }.joined()
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(body.utf8))
            try? h.close()
        } else {
            try? Data(body.utf8).write(to: url)
        }
    }

    /// The reader polls; this waits for it rather than guessing.
    private func settle(_ p: ConnectProgress, until: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !until(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testTheStepsOfAConnectionAreShownAsItMakesThem() {
        let p = dial("host-1")
        append("host-1", "note reusing this host's open connection")
        append("host-1", "note ensuring a hub on this host")
        settle(p) { p.steps.count >= 2 }

        XCTAssertEqual(p.steps.count, 2)
        XCTAssertEqual(p.latest, "ensuring a hub on this host")
        // NOTHING IS SHOWN AS DONE THAT IS NOT. The pane is still empty.
        XCTAssertFalse(p.revealed)
    }

    func testThePaneIsGivenBackTheMomentTheSessionPaintsIt() {
        let p = dial("host-2")
        append("host-2", "note ensuring a hub on this host")
        settle(p) { !p.steps.isEmpty }
        XCTAssertFalse(p.revealed, "a step is not a screen")

        append("host-2", "paint ")
        settle(p) { p.revealed }
        XCTAssertTrue(p.revealed)
    }

    func testAResumedSessionCountsAsSomethingToShow() {
        // Nothing is painted when a client returns to a position it still
        // holds — what follows is live output, which is equally a reason
        // to stop showing progress in front of the pane.
        let p = dial("host-3")
        append("host-3", "live returned to the session where it was left")
        settle(p) { p.revealed }
        XCTAssertTrue(p.revealed)
    }

    func testAConnectionThatEndsWithoutPaintingKeepsItsReasonOnThePane() {
        let p = dial("host-4")
        append("host-4",
               "note could not start a session on this host (exit 1): the session did not come up")
        append("host-4", "end no_session")
        settle(p) { p.failure != nil }

        // THE REASON, NOT A SUMMARY. This is the sentence that used to
        // race past between two contradicting lines ([[WI-2026-08-17-015]]).
        XCTAssertEqual(
            p.failure,
            "could not start a session on this host (exit 1): the session did not come up")
        XCTAssertFalse(p.revealed)
    }

    func testASessionThatEndsAfterItPaintedIsNotAFailure() {
        // The human typed `exit`. That is a session ending, not a
        // connection failing, and a failure card over the pane would be a
        // lie about a thing that worked.
        let p = dial("host-5")
        append("host-5", "paint ")
        settle(p) { p.revealed }
        append("host-5", "end child_exited")
        settle(p) { p.failure != nil }
        XCTAssertNil(p.failure)
    }

    func testAnAccountFromAnEarlierAttemptIsNotReadAsThisOne() {
        // The channel is named after the agent, so an attempt inherits the
        // last one's file. A stale `paint` in it would hand the pane back
        // before this connection had done anything at all.
        append("host-6", "note from a connection that is over", "paint ")
        let p = dial("host-6")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(p.revealed)
        XCTAssertTrue(p.steps.isEmpty)
    }

    func testAHangIsNeverHiddenBehindAPromiseNobodyIsKeeping() {
        // A placeholder says something is happening. When nothing has
        // happened for long enough, that is no longer true, and the pane
        // — whatever is on it — is the honest thing to show.
        XCTAssertEqual(ConnectProgress.silenceDeadline, 8,
                       "the deadline is part of the behaviour, not an implementation detail")
    }

    func testAnAgentIdCannotNameAPathOutsideTheChannelDirectory() {
        // The id is built from a host label a human typed.
        let url = ConnectProgress.channel(for: "../../etc/passwd")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "connect")
        XCTAssertFalse(url.path.contains(".."))
    }
    // MARK: - A link lost mid-session ([[WI-2026-08-29-004]])

    /// THE CHANNEL OUTLIVES THE FIRST PAINT.
    ///
    /// It used to be closed the moment a pane had a screen, on the
    /// reasoning that progress is what a pane shows BEFORE it has one.
    /// True of the placeholder, not of the account: a transport dies
    /// mid-session and the client's `lost` then arrived at a reader that
    /// had stopped. Saying it anyway is why the client wrote a line into
    /// the session's own terminal, where a full-screen program owns every
    /// cell — and a resumed attach never repaints, so it stayed there.
    func testALinkLostAfterThePaintIsStillHeard() {
        let agent = "builder-9f01"
        let p = dial(agent)

        append(agent, "paint ")
        settle(p) { p.revealed }
        XCTAssertNil(p.lostSince, "nothing has been lost yet")

        append(agent, "lost the link died; dialling again")
        settle(p) { p.lostSince != nil }

        XCTAssertNotNil(p.lostSince,
                        "the account stopped being read at the first paint, which is when "
                        + "a mid-session loss can first happen")
    }

    /// AND THE MARK GOES WHEN THE LINK COMES BACK. `live` is what a
    /// resumed attach says, and it means the screen is moving again.
    func testComingBackClearsTheMark() {
        let agent = "builder-9f02"
        let p = dial(agent)
        append(agent, "paint ")
        settle(p) { p.revealed }
        append(agent, "lost the link died; dialling again")
        settle(p) { p.lostSince != nil }

        append(agent, "live returned to the session where it was left")
        settle(p) { p.lostSince == nil }

        XCTAssertNil(p.lostSince, "the pane is still marked as stale after it came back")
    }

    /// ONE LOSS, NOT ONE PER ATTEMPT. The client dials again every second,
    /// and the human wants to know how long it has been down — which is
    /// the FIRST loss, not the latest.
    func testTheClockRunsFromTheFirstLossNotTheLatestAttempt() {
        let agent = "builder-9f03"
        let p = dial(agent)
        append(agent, "paint ")
        settle(p) { p.revealed }

        append(agent, "lost the link died; dialling again")
        settle(p) { p.lostSince != nil }
        let first = p.lostSince

        append(agent, "lost the link died; dialling again")
        settle(p) { p.steps.filter { $0.kind == "lost" }.count >= 2 }

        XCTAssertEqual(p.lostSince, first,
                       "each retry restarted the clock, so a link down for a minute would "
                       + "always read as down for a second")
    }

}
