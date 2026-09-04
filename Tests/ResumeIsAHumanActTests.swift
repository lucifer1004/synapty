import XCTest
@testable import Synapty

/// A RESUME IS A HUMAN'S ACT, ON A PANE THAT DEMONSTRABLY RESTARTED
/// ([[RFC-0006]] C-RESUME-RESTORE as amended, [[RFC-0014]] C-LIVE-CHILD,
/// [[WI-2026-08-24-001]]).
final class ResumeOfferTests: XCTestCase {

    private func plan(_ ref: String?) -> ResumePlan {
        ResumePlan(tool: "claude", cwd: "/tmp", host: nil, resumeRef: ref,
                   incantation: ref.map { "claude --resume \($0)" })
    }

    /// THE OFFER NAMES WHAT IT WOULD DO. A button reading "Resume" types
    /// an incantation the human cannot see into a shell they did not
    /// choose.
    func testTheOfferNamesTheToolAndTheSession() {
        XCTAssertEqual(RejoinNoticeView.offerLabel(plan("abc123def456")),
                       "Resume claude session def456")
    }

    func testAPlanWithNoSessionReferenceStillNamesTheTool() {
        var p = plan(nil)
        p.incantation = "claude --continue"
        XCTAssertEqual(RejoinNoticeView.offerLabel(p), "Resume claude")
    }

    /// NOTHING TO TYPE IS NOTHING TO OFFER — a plan that degraded to
    /// launch-fresh has no incantation, and a button that typed nothing
    /// would be a promise of continuity there is none of.
    func testAPlanWithNothingToTypeOffersNothing() {
        XCTAssertNil(RejoinNoticeView.offerLabel(plan(nil)))
        XCTAssertNil(RejoinNoticeView.offerLabel(nil))
    }
    // MARK: - A resume must not splice into what the human is typing

    /// [[RFC-0006]] C-RESUME-RESTORE, [[WI-2026-08-27-001]] item 7.
    ///
    /// The offer's EXISTENCE settles whether this pane may be resumed at
    /// all. It does not settle whether this MOMENT is safe: the human can
    /// have half a command on the line when they click, and the
    /// incantation lands in the middle of it — `make bui` becomes
    /// `make buiclaude --resume <id>`. Both neighbours that type into a
    /// pane consult a recency window first; this path did not.
    func testAResumeIsRefusedWhileTheHumanIsMidCommand() {
        XCTAssertFalse(ResumeGate.mayType(secondsSinceHumanInput: 0.2),
                       "a keystroke two tenths of a second ago is a line being composed")
        XCTAssertFalse(ResumeGate.mayType(secondsSinceHumanInput: 2.9))
    }

    func testAResumeProceedsOnAQuietPane() {
        XCTAssertTrue(ResumeGate.mayType(secondsSinceHumanInput: 3.1))
        XCTAssertTrue(ResumeGate.mayType(secondsSinceHumanInput: 600))
    }

    /// NEVER TYPED IS NOT RECENTLY TYPED. A restored pane the human has
    /// not touched is the ordinary case for this offer, and reading its
    /// absent timestamp as "just now" would refuse every one of them.
    func testAPaneTheHumanNeverTypedIntoIsNotTreatedAsBusy() {
        XCTAssertTrue(ResumeGate.mayType(secondsSinceHumanInput: nil))
    }

    /// The window is the one C-STATE-GATE already asked for, not a second
    /// number: two paths typing into the same pane with two different
    /// ideas of "recently" is how one of them becomes wrong quietly.
    func testTheWindowIsTheONEThisProjectAlreadyUses() {
        XCTAssertEqual(ResumeGate.humanBackoff, WakeGate.humanBackoff)
    }

}

