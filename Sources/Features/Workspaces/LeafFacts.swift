import Foundation

/// EVERYTHING THE WORKBENCH KNOWS ABOUT ONE LEAF, in one value.
///
/// THESE WERE EIGHT SEPARATE TABLES, and the bug was not that any of them
/// was wrong — it was that forgetting a leaf meant remembering to write
/// eight removals, and three different close paths each remembered a
/// different subset:
///
///   - `leafDidClose` cleared five of them, and is reached ONLY when
///     ghostty asks to close a surface — that is, when the shell exits;
///   - the tab bar's ✕ and ⌘W go through `removePane`, which cleared one;
///   - `fileNavigation` was written in eight places and removed in none.
///
/// Measured on a closed pane: `nav=1 attention=1 titles=1` before, and the
/// same after. The visible half of that was a sidebar badge counting a
/// pane that no longer existed, and no way to make it stop — the leaf it
/// counted could never be looked at, so nothing could ever attend to it.
///
/// One dictionary makes forgetting one line, and a fact added later is
/// forgotten by that same line without anybody being reminded.
///
/// RUNTIME ONLY. None of this is persisted: the session snapshot walks the
/// layout tree and writes what each surviving pane needs, so a fact about a
/// leaf that is gone has nowhere to be written even in principle.
struct LeafFacts: Equatable {

    /// LAST OSC 7 CWD — WHAT THE CHILD ANNOUNCED, which is a string the
    /// child chose. It is the most current answer there is and the least
    /// attested: [[RFC-0015]] C-DERIVED treats it as session contents, so
    /// a reader that resolves untrusted text against a directory must use
    /// `attestedPwd` or the kernel instead.
    var announcedPwd: String?

    /// WHAT THE HOLDER ANSWERED for a remote pane, read from the process
    /// table on the far side rather than from the stream ([[RFC-0014]]
    /// C-PWD requires an answer that does not depend on the child having
    /// announced anything).
    ///
    /// SEPARATE FROM `announcedPwd` BECAUSE PROVENANCE IS THE QUESTION.
    /// These were one field, written by both sources, and a reader could
    /// not tell afterwards which had written it — which is fine for a
    /// drag hint and not fine for resolving a path an agent printed.
    var attestedPwd: String?

    /// Latest shell-emitted title (OSC 0/2).
    var title: String?

    /// The agent running in this leaf, if one is.
    var agent: String?

    /// THE OTHER NAME THIS LEAF MIGHT ANSWER TO, until one of them
    /// registers ([[RFC-0015]] C-PERSIST, [[WI-2026-08-19-006]]).
    ///
    /// A RECORDED AGENT ID IS A RECORD AND NOT A GRANT: it may re-associate
    /// a pane with a child that SURVIVED, and must not be conferred on one
    /// that is newly started — the name routes A2A mail, so a fresh child
    /// wearing it receives what was addressed to the one it replaced.
    ///
    /// On this machine the workbench can simply ask, before it builds the
    /// pane's command, whether a holder of that name is still running. On
    /// another machine it cannot: the answer is over there, and restore
    /// must not block on a connection ([[RFC-0015]] C-UNARCHIVE). So the
    /// far side is handed BOTH names — the one to return to and the one to
    /// start under — and picks. THE WORKBENCH DOES NOT NEED TO BE TOLD
    /// WHICH: it knows both, only one can ever exist, and the registration
    /// says which one did. Holding two candidates and letting the event
    /// decide is stronger than reading the script's account of itself.
    var candidateAgent: String?

    /// The exec record that owns this leaf, if it is an exec pane.
    var execOwner: String?

    /// The find bar's needle. `nil` means there is no bar — which is a
    /// different state from a bar with nothing typed in it yet
    /// ([[RFC-0016]] C-DISPATCH row 2 is defined over a bar that EXISTS).
    var find: String?

    /// How a file leaf is being looked at: where it has been, what it is
    /// filtered to, what it last saw.
    var navigation: WorkspaceManager.FileNavigation?

    /// WHICH EXPOSURE A SERVICES LEAF IS SHOWING.
    ///
    /// HERE AND NOT PERSISTED, and the distinction is the clause's:
    /// [[RFC-0015]] C-CONTENT gives a services leaf "none of its own" as
    /// durable state, "because what it shows belongs to the machine and is
    /// re-read on restore". An exposure id from a previous run names
    /// nothing — the offers are gone with the process that recorded them.
    ///
    /// Surviving a TAB SWITCH is a different question from surviving a
    /// RESTART, and only the second is what that cell answers. The view is
    /// destroyed every time the human looks at another tab, and losing the
    /// page they were reading is the same defect the file pane had when it
    /// came back at `~` every time ([[WI-2026-08-19-002]]).
    var viewing: UUID?

    /// WHETHER THIS PANE CAME BACK TO ITS WORK OR STARTED OVER
    /// ([[RFC-0015]] C-HONESTY). Set when the pane is rebuilt from a
    /// snapshot or taken back out of the archive, and — for a pane on
    /// another machine, whose answer is over there — settled by the
    /// registration. Cleared when the human has read it.
    var rejoining: Rejoining?

    /// WHAT THE OFFER ON THAT NOTICE MAY TYPE, fixed at the moment the
    /// notice went up and never refreshed ([[RFC-0006]] C-RESUME-RESTORE).
    ///
    /// A LIVE LOOKUP HERE IS THE HAZARD ITSELF. The plans a lookup would
    /// read are composed from `agent_registered`, so the only thing that
    /// can create one is a harness that is alive in this pane right now —
    /// and the registration that composes it is also what raises the
    /// notice on the candidate branch of `leafID(forAgent:)`. One event
    /// would put up "the session that was running here is gone" and arm a
    /// button offering the live session's own id. Holding the offer as a
    /// captured value, and nilling it on every registration, is what makes
    /// "there is a button" and "an agent registered here" unable to be
    /// true at once ([[RFC-0014]] C-LIVE-CHILD).
    var rejoinOffer: ResumePlan?

    /// ANOTHER CLIENT TOOK THIS SESSION, and this pane is the one that
    /// lost it ([[RFC-0014]] C-ONE-CLIENT).
    ///
    /// WHY IT IS A FACT AND NOT JUST A MESSAGE. The clause requires a
    /// displaced client to be TOLD, and the protocol tells it: the holder
    /// sends a `displaced` frame and the client writes the reason. But
    /// the client then exits, the child is gone, and the pane closes on
    /// top of the sentence — so what the human saw was a tab
    /// disappearing. The clause now names that: telling the process is
    /// not telling the human. Recorded here so the close can be refused
    /// and the pane left standing with the reason on it.
    var takenByAnother = false

    /// Wake delegation is armed on this leaf.
    var wakeArmed = false

    /// WHOSE OUTPUT PUT THIS LEAF HERE, when untrusted text did.
    ///
    /// [[RFC-0015]] C-DERIVED rule five: what opens inside the workbench
    /// because a pane's contents named it MUST say which pane and which
    /// agent, since nothing else on a file leaf distinguishes it from one
    /// the human navigated to themselves.
    ///
    /// RUNTIME ONLY, and correctly so: C-PERSIST gives a file leaf exactly
    /// one durable field, the directory it is showing. A restored pane is
    /// one the human left open, not one that just arrived.
    var openedFrom: OpenedFrom?

    struct OpenedFrom: Equatable {
        let pane: UUID
        let agent: String?
    }

    /// Something happened here that the human has not looked at yet.
    var needsAttention = false

    /// A PROGRAM'S OWN PROGRESS BAR (OSC 9;4, the ConEmu sequence that
    /// package managers and build tools emit). Drawn as a hairline under
    /// the tab so a pane that is not on screen still says how far along
    /// it is. nil = nothing reported or the program removed it.
    var progress: LeafProgress?
}

struct LeafProgress: Equatable {
    enum State: Equatable { case set, indeterminate, error, paused }
    var state: State
    /// 0–100, or nil when the program gave no figure.
    var percent: Int?
}

