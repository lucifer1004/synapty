import Foundation

/// HOW A PANE IS STARTED, AND THE NAME OR NAMES IT MAY COME BACK UNDER.
///
/// A RECORDED AGENT ID IS A RECORD AND NOT A GRANT ([[RFC-0015]]
/// C-PERSIST): it returns a pane to a child that SURVIVED and must not be
/// conferred on one that is newly started, because the name routes A2A
/// mail. Which of the two happened can only be decided where the session
/// would be — and on another machine that is the far side, while restore
/// must not block on a connection ([[RFC-0015]] C-UNARCHIVE).
///
/// SO THE FAR SIDE IS HANDED BOTH NAMES AND PICKS, and the workbench holds
/// both until one of them registers. It does not need to be told which was
/// used: only one can exist, and the registration is the event that says
/// so — which is a stronger answer than the script's account of itself.
struct PaneLaunch {
    let command: String
    /// The name to return to, and the one recorded against the leaf.
    let agentID: String
    /// The name the pane will answer to if `agentID` named a session that
    /// is not there. `nil` where the question was already settled — on
    /// this machine the record can be read and the kernel asked before the
    /// command is built.
    var candidateID: String?
    /// WHAT THIS SIDE DECIDED, where it could decide. `nil` on the remote
    /// path, whose answer arrives with the registration.
    ///
    /// CARRIED RATHER THAN ASKED AGAIN. The caller used to put the same
    /// question a second time, and the two askings did not agree: this one
    /// consulted the durability opt-out and the id above was chosen
    /// without it, so a pane could be told a new shell had started while
    /// wearing the name of the old one ([[WI-2026-08-30-007]]).
    var rejoining: Rejoining?
}
