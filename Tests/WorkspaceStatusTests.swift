import XCTest
import SwiftUI
@testable import Synapty

/// [[WI-2026-09-07-003]]. The dot on a workspace row said which machine —
/// a question the row had already decided not to answer, since a workspace
/// may hold panes on three of them. It now says the one thing the
/// workspace itself knows, and the precedence between those things is the
/// part worth pinning: it is not the order it looks like it should be.
final class WorkspaceStatusTests: XCTestCase {

    func testAQuietWorkspaceIsQuiet() {
        XCTAssertEqual(WorkspaceStatus(archived: false, attention: false, failed: false), .quiet)
    }

    func testAFailedConnectionShows() {
        XCTAssertEqual(WorkspaceStatus(archived: false, attention: false, failed: true), .failed)
    }

    func testSomethingWaitingShows() {
        XCTAssertEqual(WorkspaceStatus(archived: false, attention: true, failed: false), .attention)
    }

    /// THE ORDER THAT LOOKS WRONG AND IS NOT. Broken is worse than
    /// waiting, so failure looks like it should take the dot. It must not:
    /// a failure ALSO writes its reason in red on the right of the row,
    /// and attention has no other channel at all now that the second dot
    /// is gone. Failure-wins would show the break twice and lose the wait.
    func testAttentionTakesTheDotFromAFailure() {
        XCTAssertEqual(WorkspaceStatus(archived: false, attention: true, failed: true), .attention,
                       "the failure still has its red reason on the right; the wait has nothing else")
    }

    /// PUT AWAY LOOKS PUT AWAY, whatever is true inside it. An archived
    /// row is not offering live work and must not draw a live row's mark.
    func testArchivedWinsOverEverything() {
        XCTAssertEqual(WorkspaceStatus(archived: true, attention: true, failed: true), .archived)
    }

    // MARK: - How it is drawn

    /// ONLY A STATE THAT WANTS SOMETHING MOVES. A failure has already
    /// happened and will not change while the human looks at it; motion is
    /// how "act on me" is said, and spending it on both says neither.
    func testOnlyAttentionPulses() {
        XCTAssertTrue(WorkspaceStatus.attention.pulses)
        XCTAssertFalse(WorkspaceStatus.failed.pulses)
        XCTAssertFalse(WorkspaceStatus.quiet.pulses)
        XCTAssertFalse(WorkspaceStatus.archived.pulses)
    }

    /// A COLUMN OF RUNNING WORKSPACES SHOULD READ AS A RAIL. The quiet dot
    /// is smaller so the one that is alerting is the one that is seen.
    func testAQuietDotIsSmallerThanOneWithSomethingToSay() {
        XCTAssertLessThan(WorkspaceStatus.quiet.dotSize, WorkspaceStatus.attention.dotSize)
        XCTAssertEqual(WorkspaceStatus.failed.dotSize, WorkspaceStatus.attention.dotSize,
                       "both have something to say and neither outranks the other in weight")
    }

    /// THE SEMANTIC COLOURS ARE THE ONLY SATURATED ONES WITH A MEANING,
    /// and the whole point of this change is that the dot stopped
    /// competing with three hundred and sixty arbitrary hues for them.
    func testTheAlertingStatesUseTheSemanticColours() {
        XCTAssertEqual(WorkspaceStatus.failed.color, DS.danger)
        XCTAssertEqual(WorkspaceStatus.attention.color, DS.warning)
        XCTAssertEqual(WorkspaceStatus.quiet.color, DS.textTertiary)
    }

    /// A COLOUR-ONLY SIGNAL HAS TO BE SAID OUT LOUD SOMEWHERE
    /// ([[WI-2026-08-09-020]]), and the row is an
    /// `accessibilityElement(children: .ignore)` — so a label on the glyph
    /// is discarded and this is the only place it can be said. The archive
    /// icon has carried `accessibilityLabel("Archived")` all along and
    /// nothing has ever read it out.
    ///
    /// A FAILURE IS THE EXCEPTION, because the row's description already
    /// appends its reason; saying "failed" here would say it twice.
    func testEveryStateWithNoOtherSpokenChannelIsSpoken() {
        XCTAssertEqual(WorkspaceStatus.attention.spoken, "needs attention")
        XCTAssertEqual(WorkspaceStatus.archived.spoken, "archived")
        XCTAssertNil(WorkspaceStatus.quiet.spoken)
        XCTAssertNil(WorkspaceStatus.failed.spoken, "the reason is already read out")
    }
}
