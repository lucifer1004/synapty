import XCTest
@testable import Synapty

/// [[WI-2026-09-07-004]]. A network drop separates three subjects — the
/// host's link, this pane's transport, and the session on the far side —
/// and the workbench had no way to say that the third was gone. Every fact
/// needed to say it was already in the account; what was missing was a
/// reader and somewhere to put them together.
final class LinkStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - What the account is saying

    func testNothingSaidIsALiveLink() {
        XCTAssertEqual(LinkState.from(ended: nil, lostSince: nil, pausedSince: nil), .live)
    }

    func testALostTransportIsLost() {
        XCTAssertEqual(LinkState.from(ended: nil, lostSince: t0, pausedSince: nil),
                       .lost(since: t0))
    }

    /// PAUSED OUTRANKS LOST, because it comes after it: the client loses
    /// the link, retries, and gives up. Reading the pair as `lost` would
    /// tell the human the workbench is still dialling when it stopped.
    func testAPauseOutranksTheLossThatPrecededIt() {
        XCTAssertEqual(
            LinkState.from(ended: nil, lostSince: t0, pausedSince: t0.addingTimeInterval(1800)),
            .paused(since: t0.addingTimeInterval(1800)))
    }

    /// AN END IS THE LAST WORD. It was said after whatever losing and
    /// pausing came before it, so it outranks both.
    func testAnEndOutranksBoth() {
        XCTAssertEqual(
            LinkState.from(ended: .noSession, lostSince: t0, pausedSince: t0), .gone)
        XCTAssertEqual(
            LinkState.from(ended: .childExited, lostSince: t0, pausedSince: nil), .ended)
        XCTAssertEqual(LinkState.from(ended: .displaced, lostSince: nil, pausedSince: nil), .taken)
        XCTAssertEqual(
            LinkState.from(ended: .versionMismatch, lostSince: nil, pausedSince: nil), .mismatch)
    }

    /// `stopped` IS THE HUMAN LEAVING, and leaving is not a state of
    /// anything. It must not be read as a failure, and it must not mask a
    /// loss that is still true.
    func testDetachingIsNotAFailure() {
        XCTAssertEqual(LinkState.from(ended: .stopped, lostSince: nil, pausedSince: nil), .live)
        XCTAssertEqual(LinkState.from(ended: .stopped, lostSince: t0, pausedSince: nil),
                       .lost(since: t0))
    }

    /// THIS SIDE OF A CROSS-PROCESS CONTRACT, AND ONLY THIS SIDE. The Zig
    /// client spells these with its own `@tagName`, and nothing here can
    /// see that — renaming `no_session` over there leaves this green.
    ///
    /// What DOES check the two together is `scripts/test-reconnect-e2e.sh`,
    /// which drives a real client against a real holder and reads the
    /// account it writes; it reaches `no_session` and nothing else. The
    /// other four spellings are unverified in both directions and this
    /// test does not pretend otherwise ([[WI-2026-09-08-003]]).
    func testTheseAreTheSpellingsThisSideExpects() {
        XCTAssertEqual(AccountEnd(rawValue: "child_exited"), .childExited)
        XCTAssertEqual(AccountEnd(rawValue: "no_session"), .noSession)
        XCTAssertEqual(AccountEnd(rawValue: "version_mismatch"), .versionMismatch)
        XCTAssertEqual(AccountEnd(rawValue: "displaced"), .displaced)
        XCTAssertEqual(AccountEnd(rawValue: "stopped"), .stopped)
        // THE ONE NO CLIENT WRITES. On a host that keeps no session ssh IS
        // the pane's child, so there is no client to have an outcome and
        // the connection classifies its own exit status instead
        // ([[WI-2026-09-09-004]]).
        XCTAssertEqual(AccountEnd(rawValue: "link_severed"), .linkSevered)
        XCTAssertNil(AccountEnd(rawValue: "something a newer client says"))
    }

    // MARK: - What follows from it

    /// [[RFC-0014]] C-EXIT-SIGNAL, and the failure its rationale names:
    /// "the safe guess — treat every drop as a death — is the behaviour
    /// that makes a network blip destroy a pane".
    ///
    /// THE QUESTION IS NARROWER THAN IT FIRST LOOKED, and this test was
    /// written before the answer was available. `keepsPane` is asked only
    /// where the pane's process HAS exited, so it is not "may this pane
    /// close" in general — it is "was that exit the end of the human's
    /// work, or the end of the thing carrying it". Phase 2 answered `true`
    /// for `live`, `lost` and `paused` on the prose alone, which would have
    /// refused to close a pane whose shell the human had just exited.
    func testNoTransportFailureMayCostThePane() {
        XCTAssertTrue(LinkState.gone.keepsPane, "the screen is the last true thing it said")
        XCTAssertTrue(LinkState.mismatch.keepsPane)
        XCTAssertTrue(LinkState.taken.keepsPane)
        XCTAssertTrue(LinkState.dropped.keepsPane,
                      "a link that died taking its transport with it explains itself here "
                      + "or nowhere")
    }

    /// A child that exited is the one case where nothing was lost: the
    /// work finished, and the pane closing is the terminal behaving as a
    /// terminal.
    func testOnlyARealChildExitReleasesThePane() {
        XCTAssertFalse(LinkState.ended.keepsPane)
    }

    /// AND AN ORDINARY EXIT CLOSES AN ORDINARY PANE. A human typing `exit`
    /// in a local shell leaves nothing to keep, and a workbench that
    /// refused to close it would be unusable.
    func testAnOrdinaryExitStillClosesThePane() {
        XCTAssertFalse(LinkState.live.keepsPane)
        XCTAssertFalse(LinkState.from(ended: nil, lostSince: nil, pausedSince: nil,
                                      childDied: false).keepsPane)
    }

    // MARK: - The one case nothing else speaks for

    /// A HOST THAT KEEPS NO SESSION BETWEEN CONNECTIONS ([[RFC-0014]]
    /// C-OPT-OUT) has no client in front of its transport, so ssh IS the
    /// pane's child and a dropped link kills it outright, with no account
    /// to say anything. That the child is GONE is then the only evidence
    /// there is, and the alternative to using it is libghostty's
    /// "Process exited" and a pane that vanishes.
    ///
    /// THE EVIDENCE IS THE DEATH, NOT A NUMBER. This used to key off a
    /// non-zero exit code, which made the state unreachable on the only
    /// platform this app runs on: libghostty spawns every pane through
    /// `/usr/bin/login`, and `login` reports 0 for a child that exits 42,
    /// is killed, or does not exist ([[LinkState]] `dropped` carries the
    /// measurements). So the panes this state exists to keep were closed
    /// ([[WI-2026-09-09-001]]).
    func testAnUnexplainedDeathIsAState() {
        let state = LinkState.from(ended: nil, lostSince: nil, pausedSince: nil, childDied: true)
        XCTAssertEqual(state, .dropped)
        XCTAssertTrue(state.isTerminal)
        XCTAssertTrue(state.needsSidebarMark(now: t0))
        XCTAssertEqual(state.sentence(now: t0, on: "greencloud"),
                       "The connection to greencloud ended — nothing said why")
    }

    /// A HOST THAT KEEPS NO SESSION CAN SAY SO AFTER ALL.
    ///
    /// The gap was called unclosable — a dropped link and a human typing
    /// `exit` arriving as one event, with the exit code that was supposed
    /// to separate them turning out not to exist. That was one signal
    /// short of the truth. ssh(1): "ssh exits with the exit status of the
    /// remote command or with 255 if an error occurred" — so ssh itself
    /// knows which of the two happened, and the process that ran it is
    /// standing right there when it exits. It could not SAY so only because
    /// it `exec`ed, replacing the one process that could have looked
    /// ([[WI-2026-09-09-004]]).
    func testALinkThatDroppedIsToldApartFromAShellThatEnded() {
        let severed = LinkState.from(ended: .linkSevered, lostSince: nil, pausedSince: nil)
        XCTAssertEqual(severed, .severed)
        XCTAssertTrue(severed.keepsPane,
                      "the screen is the last true thing that session said")
        XCTAssertTrue(severed.isTerminal, "there is nothing on this host to come back to")
        XCTAssertTrue(severed.needsSidebarMark(now: t0))

        // AND THE OTHER HALF, which must still close: the human ended
        // their own shell.
        let ended = LinkState.from(ended: .childExited, lostSince: nil, pausedSince: nil)
        XCTAssertEqual(ended, .ended)
        XCTAssertFalse(ended.keepsPane)
    }

    /// TWO STATES OFFER "TRY AGAIN" AND THEY MEAN OPPOSITE THINGS.
    ///
    /// A PAUSED client is alive and still holds the pane's pseudoterminal:
    /// the screen and the scrollback the human was reading are there, and
    /// what the press owes is a nudge — a marker the client polls for —
    /// so a resumed attach repaints over them. Dialling again there would
    /// destroy exactly what the pause preserved.
    ///
    /// A SEVERED link has no client at all: the host keeps no session, the
    /// transport WAS ssh, and it is dead. A marker would be written to a
    /// path nothing polls, and the button would do nothing — which is what
    /// it did, while a comment beside it claimed "connecting again is one
    /// press" ([[WI-2026-09-09-014]]).
    func testTryAgainMeansDifferentThingsInTheStatesThatOfferIt() {
        XCTAssertEqual(LinkNoticeView.retryMeans(.paused(since: t0)), .wakeTheClient)
        XCTAssertEqual(LinkNoticeView.retryMeans(.severed), .dialAgain)
        // AND A DROPPED PANE IS THE SEVERED ONE WITHOUT A WITNESS. Nothing
        // local is alive in either, so the same act helps: dial the host
        // and put a session back in this pane. Only this state was refused
        // it ([[WI-2026-09-10-006]]).
        XCTAssertEqual(LinkNoticeView.retryMeans(.dropped), .dialAgain)
        // AND THE HELP PROMISES THE ACT THAT WILL HAPPEN. One sentence
        // covered both, and it was the dialling one — told to a human
        // whose paused session was about to be woken onto the screen it
        // had kept.
        XCTAssertTrue(LinkNoticeView.retryHelp(.wakeTheClient, machine: "greencloud")
            .contains("scrollback"))
        XCTAssertFalse(LinkNoticeView.retryHelp(.wakeTheClient, machine: "greencloud")
            .contains("Dials"))
        XCTAssertTrue(LinkNoticeView.retryHelp(.dialAgain, machine: "greencloud")
            .contains("Dials greencloud"))
        // AND NOTHING ELSE OFFERS IT, so nothing else needs an answer.
        for state: LinkState in [.live, .lost(since: t0), .gone, .ended, .mismatch, .taken] {
            XCTAssertNil(LinkNoticeView.retryMeans(state),
                           "\(state) offers a retry with no meaning attached")
        }
    }

    /// AND IT SAYS WHAT HAPPENED, rather than the "nothing said why" that
    /// belongs to the state next to it. Something did say why.
    func testTheSeveredSentenceNamesTheCause() {
        XCTAssertEqual(
            LinkState.severed.sentence(now: t0, on: "greencloud"),
            "The link to greencloud dropped, and it keeps no session to return to")
        XCTAssertTrue(LinkNoticeView.offersClose(.severed),
                      "there is nothing to wait for")
        XCTAssertNotNil(LinkNoticeView.retryMeans(.severed),
                      "connecting again is one press, and it starts a fresh session")
    }

    /// AND IT NAMES NO CODE, because there is none to name. A sentence
    /// quoting `login`'s zero would be a fabricated fact dressed as the
    /// only real one.
    func testTheSentenceInventsNoExitCode() {
        let said = LinkState.dropped.sentence(now: t0, on: "gc")
        XCTAssertEqual(said, "The connection to gc ended — nothing said why")
        XCTAssertFalse(said?.contains("exit") ?? true, "there is no exit code on this platform")
    }

    /// THE ACCOUNT OUTRANKS THE CODE. A client that said why it stopped
    /// knows more than the number it exited with, and reading the number
    /// instead would turn "the session is gone" into "exit 1".
    func testWhatTheClientSaidBeatsWhatItExitedWith() {
        XCTAssertEqual(
            LinkState.from(ended: .noSession, lostSince: nil, pausedSince: nil, childDied: true),
            .gone)
        XCTAssertEqual(
            LinkState.from(ended: .childExited, lostSince: nil, pausedSince: nil, childDied: true),
            .ended)
    }

    func testWhatIsStillHappeningIsNotTerminal() {
        XCTAssertFalse(LinkState.live.isTerminal)
        XCTAssertFalse(LinkState.lost(since: t0).isTerminal)
        XCTAssertFalse(LinkState.paused(since: t0).isTerminal)
        XCTAssertTrue(LinkState.gone.isTerminal)
        XCTAssertTrue(LinkState.mismatch.isTerminal)
    }

    // MARK: - The sidebar

    /// A BLIP IS NOT A FAILURE. [[RFC-0015]] C-FAILURE requires a
    /// workspace holding something broken to be distinguishable without
    /// opening it — and a mark that appears several times a day for
    /// something that fixes itself in seconds is one nobody reads.
    func testAMomentaryDropDoesNotMarkTheSidebar() {
        let state = LinkState.lost(since: t0)
        XCTAssertFalse(state.needsSidebarMark(now: t0.addingTimeInterval(5)))
        XCTAssertFalse(state.needsSidebarMark(now: t0.addingTimeInterval(59)))
        XCTAssertTrue(state.needsSidebarMark(now: t0.addingTimeInterval(60)))
    }

    func testEverythingSettledAndBrokenMarksItAtOnce() {
        XCTAssertTrue(LinkState.gone.needsSidebarMark(now: t0))
        XCTAssertTrue(LinkState.paused(since: t0).needsSidebarMark(now: t0))
        XCTAssertTrue(LinkState.mismatch.needsSidebarMark(now: t0))
        XCTAssertFalse(LinkState.live.needsSidebarMark(now: t0))
        XCTAssertFalse(LinkState.ended.needsSidebarMark(now: t0),
                       "work that finished is not something that failed")
    }

    // MARK: - What it says

    func testALiveLinkSaysNothing() {
        XCTAssertNil(LinkState.live.sentence(now: t0, on: "greencloud"))
    }

    /// THE SENTENCE ESCALATES WITH THE CLOCK, and names the machine once
    /// it does: "reconnecting" is enough for a blip, and useless once the
    /// human is deciding whether to go and look at the host.
    func testTheSentenceEscalatesAndThenNamesTheMachine() {
        let state = LinkState.lost(since: t0)
        let early = state.sentence(now: t0.addingTimeInterval(12), on: "greencloud")
        XCTAssertEqual(early, "Link lost — reconnecting · 12s")
        let late = state.sentence(now: t0.addingTimeInterval(134), on: "greencloud")
        XCTAssertEqual(late, "greencloud has not answered for 2m — still trying")
    }

    /// The one a human most needs and could least be told before this.
    func testAReconnectThatFoundNoSessionSaysSo() {
        XCTAssertEqual(LinkState.gone.sentence(now: t0, on: "greencloud"),
                       "The session is gone — greencloud came back without it")
    }

    func testAPauseSaysHowLongItTriedFor() {
        XCTAssertEqual(
            LinkState.paused(since: t0).sentence(now: t0.addingTimeInterval(1800), on: "gc"),
            "Stopped reconnecting · gc was unreachable for 30m")
    }

    /// SECONDS WHILE A HUMAN IS WATCHING, and not after. Below a minute
    /// the seconds are the whole information; past an hour so are the
    /// minutes.
    func testTheDurationIsSpeltAtThePrecisionItIsReadAt() {
        XCTAssertEqual(LinkState.spell(0), "0s")
        XCTAssertEqual(LinkState.spell(59), "59s")
        XCTAssertEqual(LinkState.spell(60), "1m")
        XCTAssertEqual(LinkState.spell(3599), "59m")
        XCTAssertEqual(LinkState.spell(3600), "1h")
        XCTAssertEqual(LinkState.spell(-5), "0s", "a clock that stepped back is not a negative age")
    }

    // MARK: - What the notice offers

    /// A WAY BACK THAT COSTS ONE PRESS EXISTS ONLY WHERE THERE IS ONE. A
    /// client that is still dialling needs no permission, and a session
    /// that is gone will not be found by dialling harder.
    func testOnlyAPausedClientIsOfferedARetry() {
        XCTAssertNotNil(LinkNoticeView.retryMeans(.paused(since: t0)))
        XCTAssertNotNil(LinkNoticeView.retryMeans(.dropped))
        XCTAssertNil(LinkNoticeView.retryMeans(.lost(since: t0)))
        XCTAssertNil(LinkNoticeView.retryMeans(.gone))
        XCTAssertNil(LinkNoticeView.retryMeans(.live))
    }

    /// CLOSING IS OFFERED WHERE IT IS THE USEFUL ACT. A link still being
    /// dialled is not something to tidy away; one that will not come back
    /// is. And it is offered rather than taken: [[RFC-0014]]
    /// C-EXIT-SIGNAL forbids the workbench closing a pane on the strength
    /// of a lost connection, so the press has to be the human's.
    func testClosingIsOfferedOnlyWhereNothingWillComeBack() {
        XCTAssertTrue(LinkNoticeView.offersClose(.gone))
        XCTAssertTrue(LinkNoticeView.offersClose(.mismatch))
        // THE CASE THE STATE EXISTS FOR. A link that died taking its
        // transport with it is the one place a blip could still take a
        // pane down in silence, so it must be closable by hand — and it
        // was the one of the eight this test did not ask about.
        XCTAssertTrue(LinkNoticeView.offersClose(.dropped))
        XCTAssertFalse(LinkNoticeView.offersClose(.lost(since: t0)))
        XCTAssertFalse(LinkNoticeView.offersClose(.paused(since: t0)))
        XCTAssertFalse(LinkNoticeView.offersClose(.live))
        XCTAssertFalse(LinkNoticeView.offersClose(.ended),
                       "work that finished closes its own pane; there is nothing to tidy")
        XCTAssertFalse(LinkNoticeView.offersClose(.taken),
                       "a displaced pane has its own surface and its own account")
    }

}
