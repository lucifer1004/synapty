import Foundation

/// WHAT IS BEING DISCARDED WHEN A WORKSPACE IS CLOSED, and what the human
/// is asked before it happens ([[RFC-0015]] C-WORKSPACE,
/// [[WI-2026-08-19-007]]).
///
/// The clause requires the act to be "confirmable or reversible — it
/// discards a layout the human may have arranged over days". It was
/// neither: a hover-revealed ×, a context-menu item and an accessibility
/// action each destroyed a workspace outright, and nothing recorded what
/// went, so nothing could put it back.
///
/// CONFIRMATION RATHER THAN UNDO, and the choice is recorded because the
/// clause allows either and undo is the better one. Undo means keeping a
/// copy of a destroyed layout somewhere with a lifetime and a size — where
/// it lives, how long it survives, whether it comes back after a restart,
/// what happens to the connections it named. That is a design; this is a
/// dialog. Taking the cheaper half now is a decision rather than an
/// oversight, and it is written down so a later reader does not mistake it
/// for the only option considered.
///
/// THE RULES ARE VALUES SO A TEST CAN PUT A CASE TO THEM, the same reason
/// [[PaneWrites]] is: a question is exactly the kind of obligation that
/// gets quietly dropped by one of three call sites drawing its own dialog.
enum WorkspaceDestruction {

    /// "ARE YOU SURE" TELLS A HUMAN WITH SIX WORKSPACES OPEN NOTHING. The
    /// question names the one that is about to go.
    static func question(name: String) -> String {
        "Close \"\(name)\"?"
    }

    /// AND SAYS WHAT IS BEING DISCARDED, because the cost of the act is
    /// the arrangement rather than the container. A workspace with nothing
    /// in it is a resting state ([[RFC-0015]] C-EMPTY) and costs nothing
    /// to close, so it says that instead of counting to zero.
    static func detail(panes: Int, machines: Int) -> String {
        guard panes > 0 else { return "It has nothing open in it." }
        let paneText = panes == 1 ? "1 pane" : "\(panes) panes"
        guard machines > 1 else { return "\(paneText) closes with it." }
        return "\(paneText) on \(machines) machines close with it."
    }

    /// THE SAFE OUTCOME IS THE DEFAULT — the cancel role, which is what
    /// Escape and Return both reach.
    static let safeAnswer = "Cancel"
    static let destructiveAnswer = "Close Workspace"
}
