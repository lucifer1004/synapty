import XCTest
@testable import Synapty

/// [[WorkspaceDestruction]] — what the human is told before a layout goes
/// ([[RFC-0015]] C-WORKSPACE, [[WI-2026-08-19-007]]).
final class WorkspaceDestructionTests: XCTestCase {

    /// IT NAMES THE ONE THAT IS GOING. A human with several open is told
    /// nothing by "are you sure".
    func testTheQuestionNamesTheWorkspace() {
        XCTAssertTrue(WorkspaceDestruction.question(name: "remotehost").contains("remotehost"))
    }

    /// AND SAYS WHAT IS DISCARDED, because the cost is the arrangement.
    func testTheDetailCountsWhatCloses() {
        XCTAssertEqual(WorkspaceDestruction.detail(panes: 1, machines: 1),
                       "1 pane closes with it.")
        XCTAssertEqual(WorkspaceDestruction.detail(panes: 6, machines: 3),
                       "6 panes on 3 machines close with it.")
    }

    /// ONE MACHINE IS NOT WORTH COUNTING — a sentence that says "on 1
    /// machines" is one nobody wrote for a human.
    func testASingleMachineIsNotCounted() {
        XCTAssertFalse(WorkspaceDestruction.detail(panes: 3, machines: 1).contains("1 machine"))
    }

    /// AN EMPTY WORKSPACE COSTS NOTHING TO CLOSE, and saying "0 panes
    /// close with it" would make a free act sound like a loss.
    func testAnEmptyWorkspaceSaysSoRatherThanCountingToZero() {
        let detail = WorkspaceDestruction.detail(panes: 0, machines: 0)
        XCTAssertFalse(detail.contains("0"))
        XCTAssertTrue(detail.contains("nothing open"))
    }

    /// THE DEFAULT IS THE SAFE ONE.
    func testTheSafeAnswerIsTheCancel() {
        XCTAssertEqual(WorkspaceDestruction.safeAnswer, "Cancel")
        XCTAssertNotEqual(WorkspaceDestruction.destructiveAnswer,
                          WorkspaceDestruction.safeAnswer)
    }
}

