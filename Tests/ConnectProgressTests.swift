import XCTest
@testable import Synapty

/// [[WI-2026-08-17-016]]. The rules that decide what a human looks at
/// while a connection is being made, and the moment they stop looking at
/// it.
///
/// DRIVEN THROUGH THE FILE, not through the object's own setters: the
/// account is written by another process entirely (`src/cli/progress.zig`
/// and the holder), so the format is the contract and a test
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

    /// AN END AFTER A PAINT WAS DISCARDED, and that is the whole of why a
    /// reconnect that found no session left libghostty's "Process exited"
    /// as everything the human was told. `failure` is guarded by
    /// `if !revealed` for a good reason — a failure card over a working
    /// pane would be a lie — and the reason WHY was read off the same
    /// guard, so it went with it ([[WI-2026-09-07-004]]).
    func testWhyASessionEndedIsHeardEvenAfterItPainted() {
        let p = dial("host-gone")
        append("host-gone", "paint ")
        settle(p) { p.revealed }
        append("host-gone", "end no_session")
        settle(p) { p.ended != nil }

        // THE FACT, NOT A SECOND DERIVATION OF IT. What this type owns is
        // what the account said; turning that into a [[LinkState]] is
        // `LinkState.from`'s job and [[LinkStateTests]] pins it
        // ([[WI-2026-09-11-011]]).
        XCTAssertEqual(p.ended, .noSession)
        XCTAssertNil(p.failure, "a session that painted did not fail to connect")
    }

    /// STOPPED DIALLING IS NOT ENDED, and the two must not collapse: one
    /// leaves a pane that can still come back with a press, the other has
    /// nothing to come back to.
    func testAPauseIsHeardAndIsUndoneByResuming() {
        let p = dial("host-paused")
        append("host-paused", "paint ")
        settle(p) { p.revealed }
        append("host-paused", "lost the link died; dialling again")
        settle(p) { p.lostSince != nil }
        append("host-paused", "paused stopped dialling after 30 minutes down")
        settle(p) { p.pausedSince != nil }

        XCTAssertNotNil(p.pausedSince, "the pause was not recorded")
        XCTAssertNotNil(p.lostSince, "a pause does not undo the loss that preceded it")

        append("host-paused", "resumed dialling again")
        settle(p) { p.pausedSince == nil }
        XCTAssertNil(p.pausedSince)
        XCTAssertNotNil(p.lostSince,
                        "resuming leaves the link down until something paints")
    }

    /// COMING BACK CLEARS EVERYTHING THE OUTAGE LEFT. A pane that repaints
    /// is a pane whose link works, whatever was recorded before.
    func testARepaintClearsTheLossThePauseAndTheEnd() {
        let p = dial("host-back")
        append("host-back", "paint ")
        settle(p) { p.revealed }
        append("host-back", "lost gone", "paused gave up")
        settle(p) { p.pausedSince != nil }

        append("host-back", "paint ")
        settle(p) { p.pausedSince == nil }

        XCTAssertNil(p.lostSince)
        XCTAssertNil(p.ended)
        XCTAssertNil(p.pausedSince)
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

    /// THE MARKER IS DERIVED FROM THE CHANNEL ON BOTH SIDES, and neither
    /// side can import the other's. `progress.RetrySignal` appends
    /// ".retry" to `SYNAPTY_CONNECT_LOG`; this appends it to the same
    /// path. A second deriver of one name is how two copies come to
    /// disagree, so the shape is pinned here ([[WI-2026-09-07-004]]).
    func testTheRetryMarkerSitsBesideTheAccountUnderTheSameName() {
        // NOT `marker.path == channel.path + ".retry"` — that restates the
        // body and would be green with the Zig side spelling it any other
        // way. The agreement between the two derivations is UNVERIFIED,
        // and saying so is better than a test that looks like it checks it
        // ([[WI-2026-09-08-003]]).
        let marker = ConnectProgress.retryMarker(for: "host-r")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        ConnectProgress.requestRetry(for: "host-r")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "a paused client polls for this file and takes it")
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

    // MARK: - A gap in what the pane can show ([[WI-2026-09-16-002]])

    /// THE CASE THAT REACHED NOBODY. The far side says the scrollback has
    /// a hole in it on a pane that is painting, and the only reader of
    /// the account's steps is the dialling placeholder that is already
    /// gone.
    func testAHoleOnAPaintedPaneIsCarriedSomewhereItCanBeShown() {
        let agent = "builder-9fa0"
        let p = dial(agent)
        append(agent, "paint ")
        settle(p) { p.revealed }
        XCTAssertNil(p.hole, "nothing has been lost yet")

        append(agent, "hole output was lost while this client was away")
        settle(p) { p.hole != nil }

        XCTAssertEqual(p.hole?.text, "output was lost while this client was away")
        XCTAssertEqual(p.hole?.afterPaint, true,
                       "the pane was already showing a screen when the far side said this")
        // AND IT IS NOT A LOST LINK. The link is up; saying it there wore
        // "Link lost — reconnecting" for the rest of the attach
        // ([[WI-2026-09-11-020]]).
        XCTAssertNil(p.lostSince)
    }

    /// AND THE TWO SIDES OF THE PAINT ARE TOLD APART. Before it there is
    /// a placeholder reading `latest`; after it there is not, which is
    /// the whole reason this value exists.
    func testAHoleBeforeThePaintIsTheSameFactFromADifferentMoment() {
        let agent = "builder-9fa1"
        let p = dial(agent)
        append(agent, "hole too much happened to continue; showing the screen as it is now")
        settle(p) { p.hole != nil }

        XCTAssertEqual(p.hole?.afterPaint, false)
        XCTAssertFalse(p.revealed)
        // NOT ONE OF THE DIAL'S STEPS. The placeholder narrates what the
        // connection is doing; this outlives the placeholder and must not
        // be mistaken for the last thing it was up to.
        XCTAssertNil(p.latest, "a hole is not a step of the dial")
        XCTAssertTrue(p.steps.isEmpty)
    }

    /// NOTHING FILLS A GAP BACK IN. `lostSince` clears on a repaint
    /// because the link coming back ends the loss; this does not, because
    /// the output is gone whatever the pane does next.
    func testAHoleOutlivesTheNextPaintAndGoesOnlyWhenDismissed() {
        let agent = "builder-9fa2"
        let p = dial(agent)
        append(agent, "paint ")
        settle(p) { p.revealed }
        append(agent, "hole output was lost while this client was away")
        settle(p) { p.hole != nil }

        append(agent, "lost the link died; dialling again")
        settle(p) { p.lostSince != nil }
        append(agent, "live returned to the session where it was left")
        settle(p) { p.lostSince == nil }
        XCTAssertNotNil(p.hole, "coming back does not put the missing output back")

        p.dismissHole()
        XCTAssertNil(p.hole)
    }

    /// A NEW DIAL IS A NEW ACCOUNT. The gap belonged to the connection
    /// that had it, and carrying it across is how a pane came to show the
    /// previous attempt's reasons ([[WI-2026-09-08-016]]).
    func testAReDialDoesNotInheritTheLastOnesHole() {
        let agent = "builder-9fa3"
        let p = dial(agent)
        append(agent, "paint ")
        settle(p) { p.revealed }
        append(agent, "hole output was lost while this client was away")
        settle(p) { p.hole != nil }

        ConnectProgress.begin(for: agent)
        append(agent, "note opening a connection to this host")
        settle(p) { p.hole == nil }

        XCTAssertNil(p.hole)
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

    // MARK: - Joining an account rather than starting one

    /// A DIAL THAT NAMES AN EXISTING SESSION IS NOT A FIRST INSTANT.
    ///
    /// Opening a Still Running row, or a status-bar agent row, dials with
    /// the name the HOST reported — a session whose client is alive and
    /// writing this very file. Emptying the channel there unlinks the
    /// inode that client holds an fd on, so everything it says next,
    /// including the `end displaced` that a taken session depends on,
    /// goes to a file nothing can open by path. `accountEnd()` reads by
    /// path, sees the new dial's empty file, and the displaced pane closes
    /// in silence with no notice and no `taken` surface — which is the
    /// outcome [[RFC-0014]] C-ONE-CLIENT exists to prevent
    /// ([[WI-2026-09-09-002]]).
    func testJoiningAnAccountLeavesWhatItsClientIsStillWriting() {
        let agent = "builder-9f08"
        let url = ConnectProgress.begin(for: agent)
        append(agent, "paint ")
        // A LIVE CLIENT'S HANDLE, held across the dial exactly as the
        // client's own is.
        let live = try? FileHandle(forWritingTo: url)
        defer { try? live?.close() }

        ConnectProgress.beginDial(for: agent, joining: true)

        live?.seekToEndOfFile()
        live?.write(Data(ConnectProgress.line("end", "displaced").utf8))
        let text = (try? String(contentsOf: ConnectProgress.channel(for: agent),
                                encoding: .utf8)) ?? ""
        XCTAssertEqual(ConnectProgress.endReason(text), .displaced,
                       "the client that is being displaced can no longer say so by path")
    }

    /// AND A FRESH DIAL STILL EMPTIES IT, which is what gives each dial an
    /// identity to be told apart by.
    func testAFreshDialStillReplacesTheChannel() {
        let agent = "builder-9f09"
        ConnectProgress.begin(for: agent)
        append(agent, "note the last dial")
        ConnectProgress.beginDial(for: agent, joining: false)
        let text = (try? String(contentsOf: ConnectProgress.channel(for: agent),
                                encoding: .utf8)) ?? "x"
        XCTAssertEqual(text, "", "a dial that mints its own name starts from nothing")
    }

    /// PERMISSION IS GIVEN TO A DIAL, NOT TO A NAME. A marker left by a
    /// press the client never lived to take would otherwise sit there, and
    /// the next connection under that name would resume itself the first
    /// time it paused — without anybody asking ([[WI-2026-09-08-016]]).
    func testANewDialDoesNotInheritPermissionGivenToTheLastOne() {
        let agent = "builder-9f07"
        ConnectProgress.requestRetry(for: agent)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ConnectProgress.retryMarker(for: agent).path))

        ConnectProgress.begin(for: agent)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ConnectProgress.retryMarker(for: agent).path),
            "this dial would take a retry meant for the last one")
    }

    /// AND A JOINING DIAL OWES THE SAME, though it replaces nothing.
    /// Clearing permission and replacing the channel are two obligations
    /// that happened to be discharged by one line ([[WI-2026-09-09-002]]).
    func testAJoiningDialAlsoInheritsNoPermission() {
        let agent = "builder-9f0a"
        ConnectProgress.requestRetry(for: agent)

        ConnectProgress.beginDial(for: agent, joining: true)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ConnectProgress.retryMarker(for: agent).path))
    }

    /// GIVING THE PANE BACK IS NOT THE END OF THE ACCOUNT.
    ///
    /// A dial that says nothing for the silence deadline has its pane
    /// handed back — the promise that something is happening is no longer
    /// being kept, so whatever is really there becomes visible. That is
    /// right. Cancelling the READER with it was not: every `lost`,
    /// `paused` and `end` the client wrote afterwards went to a file
    /// nothing was reading, so the pane answered `live` for the rest of
    /// its life — no scrim, no notice, no mark in the sidebar — while the
    /// session was gone ([[RFC-0015]] C-FAILURE, [[WI-2026-09-10-001]]).
    ///
    /// THE CODE HAD ALREADY FIXED THIS ONCE, on the other path: `paint`
    /// used to close the channel too, until a transport died mid-session
    /// and the client's `lost` arrived at a reader that had stopped. Only
    /// `end` has earned the right to stop, because only `end` means
    /// nothing further will happen.
    func testGivingThePaneBackDoesNotStopListening() {
        let agent = "builder-9f0b"
        let p = dial(agent)
        p.reveal()
        XCTAssertTrue(p.revealed)

        append(agent, "lost the link died; dialling again")
        settle(p) { p.lostSince != nil }
        XCTAssertNotNil(p.lostSince, "the pane went deaf the moment it was handed back")

        append(agent, "end no_session")
        settle(p) { p.ended != nil }
        XCTAssertEqual(p.ended, .noSession,
                       "a session that is gone left the pane looking healthy")
    }

    // MARK: - A second dial on the same pane ([[WI-2026-09-08-016]])

    /// RETRY IS OFFERED EXACTLY WHERE THE OLD GUARD FIRED.
    ///
    /// `Center.begin` was idempotent on "this account has not revealed a
    /// screen yet" — which is the description of every account a Retry
    /// follows. So pressing Retry left the reader on the PREVIOUS dial's
    /// file, and since a dial empties the channel by making a new one,
    /// that handle pointed at an inode nothing would ever write to again.
    /// The pane sat frozen on the dead dial's reason.
    func testASecondDialOnAPaneThatNeverPaintedIsHeard() {
        let agent = "builder-9f04"
        let center = ConnectProgress.Center()
        let session = UUID()

        ConnectProgress.begin(for: agent)
        center.begin(session: session, agentID: agent)
        let first = center.progress(for: session)
        XCTAssertNotNil(first)
        append(agent, "attach dialling", "end no_session")
        settle(first!) { first!.ended != nil }
        XCTAssertEqual(first!.ended, .noSession)

        // Retry: the dial empties the channel, then the pane asks to
        // watch it again.
        ConnectProgress.begin(for: agent)
        center.begin(session: session, agentID: agent)
        let second = center.progress(for: session)!

        append(agent, "attach dialling", "paint ")
        settle(second) { second.revealed }
        XCTAssertTrue(second.revealed,
                      "the second dial's account was never read: the reader was still on the "
                      + "file the first dial left behind")
        XCTAssertNil(second.ended, "the pane is still showing why the PREVIOUS dial ended")
    }

    /// THE SAME DIAL, ASKED FOR TWICE. Both the dial and the pane reach
    /// `Center.begin`, and the second must not throw away what the first
    /// has already read.
    func testWatchingTheSameDialTwiceKeepsTheAccountAlreadyRead() {
        let agent = "builder-9f05"
        let center = ConnectProgress.Center()
        let session = UUID()

        ConnectProgress.begin(for: agent)
        center.begin(session: session, agentID: agent)
        let p = center.progress(for: session)!
        append(agent, "note uploading the binary")
        settle(p) { !p.steps.isEmpty }

        center.begin(session: session, agentID: agent)
        XCTAssertTrue(center.progress(for: session) === p,
                      "the same dial was restarted, which loses the steps read so far")
    }

    /// A HANDLE OUTLIVES THE FILE IT WAS OPENED ON. Nothing about a
    /// `FileHandle` fails when the file underneath it is replaced — reads
    /// simply return nothing, forever, and a reader that only reopens
    /// `if handle == nil` never notices.
    func testAReaderFollowsTheChannelRatherThanTheInodeItFirstOpened() {
        let agent = "builder-9f06"
        let p = dial(agent)
        append(agent, "note uploading the binary")
        settle(p) { !p.steps.isEmpty }

        // What a dial does, without going through the pane at all.
        ConnectProgress.begin(for: agent)
        append(agent, "note dialling the new session")
        settle(p) { p.steps.contains { $0.text.contains("new session") } }

        XCTAssertTrue(p.steps.contains { $0.text.contains("new session") },
                      "the reader was deaf to everything written after the channel was replaced")
        XCTAssertFalse(p.steps.contains { $0.text.contains("uploading") },
                       "the replaced dial's steps are still on the pane")
    }

}
