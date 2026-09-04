import Foundation
import AppKit
import Observation

/// Manages a two-level hierarchy: Workspaces (sidebar) → one split tree of
/// pane stacks ([[RFC-0015]] C-LAYOUT).
///
/// A WORKSPACE IS NOT CONNECTED TO ANYTHING ([[RFC-0015]] C-WORKSPACE). It
/// is the human's container for a piece of work: resident, named, and
/// surviving the closing of everything inside it. The machine belongs to
/// each pane, which references a shared `Connection` — so one position can
/// hold panes on two hosts, and a pane moved between positions keeps
/// answering for its own.
///
/// A PANE IS THE ONLY LAYOUT TYPE, and it is not necessarily a terminal
/// ([[RFC-0015]] C-CONTENT). There were two container species: a workspace
/// held tabs and every tab held a split tree of its own, so "these two
/// panes share a position" — the arrangement docking exists for — had no
/// operation to write it against. A tab is what a position with more than
/// one pane SHOWS.
@MainActor @Observable final class WorkspaceManager: TerminalCoordinator {

    // MARK: - TerminalCoordinator

    func requestSplit(direction: SplitNode.SplitDirection) {
        splitFocusedLeaf(direction: direction)
    }

    func requestCloseSplit() {
        guard let sIdx = activeWorkspaceIndex,
              let focused = workspaces[sIdx].focusedPaneID else { return }
        closePaneAsking(focused)
    }

    func requestArchivePane() {
        guard let sIdx = activeWorkspaceIndex,
              let focused = workspaces[sIdx].focusedPaneID else { return }
        archivePane(focused)
    }

    func requestFocusNextSlot() {
        focusNextLeaf()
    }

    func requestFocusPreviousSlot() {
        focusPreviousLeaf()
    }

    func requestResizeFocused(_ edge: SplitNode.Edge) { resizeFocusedPosition(edge) }
    func requestEqualizePositions() { equalizePositions() }

    func requestNewPane() {
        addPaneToActiveWorkspace()
    }

    func requestNextPane() {
        activateNextPane()
    }

    func requestPreviousPane() {
        activatePreviousPane()
    }

    func requestSwitchWorkspace(index: Int) {
        activateWorkspaceByIndex(index)
    }

    func requestSelectPane(index: Int) {
        selectPane(index: index)
    }

    func requestFocusSlot(index: Int) {
        focusSlot(index: index)
    }

    func leafDidFocus(_ leafID: UUID) {
        focusLeaf(leafID)
    }

    func leafDidClose(_ leafID: UUID) {
        // ANOTHER CLIENT TOOK IT, so this pane did not finish — it lost
        // ([[RFC-0014]] C-ONE-CLIENT). The client was told, and wrote the
        // reason; then it exited, and the exit is this call, which would
        // destroy the surface the reason was written on. Telling the
        // process is not telling the human, so the pane stays and says
        // so, and closing it is the human's own act.
        if connectProgress.progress(for: leafID)?.accountEndsDisplaced() == true {
            facts[leafID, default: .init()].takenByAnother = true
            return
        }
        // BEFORE FORGETTING IT, because disarming tells the coordinator
        // which agent was delegated to and that answer lives in the facts.
        setWakeArmed(leafID, false)
        // RFC-0006 C-RESUME-PLAN: pane close is an OBSERVABLE drop trigger.
        onLeafClosed?(leafID)
        closeLeaf(leafID)
    }

    /// RFC-0006: resume-plan owners hook this to drop plans on the
    /// observable pane-close trigger.
    var onLeafClosed: ((UUID) -> Void)?

    func leafDidUpdatePwd(_ leafID: UUID, pwd: String) {
        facts[leafID, default: .init()].announcedPwd = pwd
    }

    /// WHAT IS KNOWN ABOUT EACH LEAF ([[LeafFacts]]), keyed by the leaf it
    /// is about — one table, so forgetting a leaf is one line that cannot
    /// forget half of it.
    private(set) var facts: [UUID: LeafFacts] = [:]

    /// A LEAF THAT IS GONE IS FORGOTTEN. Called from `detach`, which is the
    /// single place a pane is destroyed — a MOVE between workspaces goes
    /// through `takeForMove` instead and keeps everything, because the pane
    /// is the same pane.
    /// EVERY PANE OF A WORKSPACE THAT IS ENDING, forgotten together.
    ///
    /// A workspace ends two ways — archived and closed — and they are the
    /// same end state for its panes. One wrote this loop inline and the
    /// other did not, so closing a workspace held its pool tenants and
    /// kept per-leaf state for panes that no longer existed
    /// ([[WI-2026-08-30-007]]).
    ///
    /// BEFORE THE WORKSPACE LEAVES THE TREE. `forget` finds a leaf's
    /// machine by searching `workspaces`, so a pane already removed from
    /// the list is a pane it cannot place.
    /// A LEAF THAT HAS JUST BEEN REBUILT FROM A PERSISTED ENTRY: recorded,
    /// and given back the state the entry carries.
    ///
    /// ONE STATEMENT, because these were two. Recording the entry happened
    /// at both exits of `rebuildPane`; re-arming the pane happened in a
    /// loop that only `restore` runs. Unarchiving rebuilds through the
    /// same code and does not run that loop, so a workspace put away with
    /// a pane armed for wake came back disarmed — the arm was in the
    /// archived tree the whole time, collected into `leafMeta` and dropped
    /// on the floor ([[WI-2026-08-30-007]]).
    ///
    /// Here rather than in a helper the callers must remember: any future
    /// rebuilder gets it by rebuilding.
    private func recordRebuilt(_ leafID: UUID, from entry: WorkspaceSnapshot.PaneEntry,
                               into meta: inout [UUID: WorkspaceSnapshot.PaneEntry]) {
        meta[leafID] = entry
        if entry.wakeArmed { setWakeArmed(leafID, true) }
    }

    private func forgetPanes(of session: Workspace) {
        for pane in session.panes { forget(pane.id) }
    }

    private func forget(_ leafID: UUID) {
        // THE PANE'S SLOT GOES BACK HERE, because this is the one place
        // every close reaches and no move does. It was moved out to
        // `leafDidClose` on the belief that `forget` also ran on a move;
        // it does not — a move goes through `takeForMove`, which removes
        // the pane from the tree directly and keeps everything, because it
        // is the same pane. `forget` has two callers, `detach` and
        // `archiveWorkspace`, and both mean the pane is finished with.
        //
        // Moving it out lost the release on the ordinary routes — the
        // tab's ✕, Close Tab, ⌘W — leaving a record on disk that outlives
        // the process and keeps a connection looking busy forever
        // ([[RFC-0013]] C-BROKER).
        if let agent = facts[leafID]?.agent {
            TunnelManager.shared?.paneClosed(hostID: host(ofLeaf: leafID)?.id, agentID: agent)
        }
        facts.removeValue(forKey: leafID)
        // AND WHAT THE TERMINAL LAYER KNEW ABOUT IT. Its record is keyed
        // by leaf and outlived every closed pane for the life of the
        // process ([[WI-2026-08-28-018]]).
        GhosttyApp.shared?.forgetLeaf(leafID)
        // AND THE ACCOUNT OF ITS CONNECTION. `forget` had no caller while
        // the reader stopped at the first paint and only a dictionary
        // entry was left behind; the reader now outlives the paint so it
        // can report a link lost mid-session, and an unpruned entry is a
        // live timer per closed pane ([[WI-2026-08-29-004]]).
        connectProgress.forget(session: leafID)
    }

    /// WHAT THE SHELL ITSELF SAID, and nothing inferred.
    ///
    /// OSC 7 is the shell volunteering its own directory — for a remote
    /// pane too, since the far side's OSC 7 rides the same stream the
    /// screen does. nil means it has not said, which is a different state
    /// from "at home" and callers that cannot act on a guess want to know
    /// the difference.
    func reportedPwd(ofLeaf leafID: UUID) -> String? {
        // BOTH SOURCES, ANNOUNCED FIRST, which is what this answered when
        // they shared one field: OSC 7 wrote unconditionally and the
        // holder's answer was taken only where nothing was known.
        let reported = facts[leafID]?.announcedPwd ?? facts[leafID]?.attestedPwd
        guard let reported, !reported.isEmpty else { return nil }
        return reported
    }

    /// WHERE A RELATIVE NAME IN THIS PANE'S OUTPUT RESOLVES FROM, and the
    /// only directory [[RFC-0015]] C-DERIVED lets one resolve against.
    ///
    /// NOT `pwd(ofLeaf:)`, WHICH IS A LOOSER READER. That one prefers what
    /// the child announced, because a drag hint would rather say somewhere
    /// plausible than nothing. Here the input is untrusted text, and a
    /// directory the child chose would let it decide where its own paths
    /// point — and a file leaf opened there persists what it is showing,
    /// so the child's string would reach the workspace snapshot.
    ///
    /// Nil is an ordinary answer and means there is no offer for a
    /// relative name. An absolute one needs no base and is unaffected.
    func resolutionBase(ofLeaf leafID: UUID) -> String? {
        // THE KERNEL FOR A LOCAL PANE, THE HOLDER FOR A REMOTE ONE. A
        // remote pane's foreground process on this Mac is an ssh client,
        // so reading this machine's process table would answer with a
        // local path for a shell that is somewhere else ([[ProcessCwd]]).
        let attested = isLocalLeaf(leafID) ? observedPwd(leafID) : facts[leafID]?.attestedPwd
        guard let attested, attested.hasPrefix("/") else { return nil }
        return attested
    }

    /// A holder's answer about where a remote pane is standing.
    func leafDidLearnAttestedPwd(_ leafID: UUID, pwd: String) {
        facts[leafID, default: .init()].attestedPwd = pwd
    }

    /// SHOW WHERE A RECOGNISED PATH LIVES — the whole of what taking an
    /// offer may do ([[RFC-0015]] C-DERIVED).
    ///
    /// A FILE LEAF AND NOTHING ELSE. Not a terminal leaf, which is the
    /// kind defined by running a child; not a browser leaf, whose
    /// connection is stipulated local and so could not carry the binding
    /// below. What opens is an ORDINARY file leaf — it creates, renames
    /// and deletes ([[RFC-0015]] C-PANE-WRITES) — because the bound is on
    /// what the workbench opens, never on what the human may then do in
    /// what they opened.
    ///
    /// ON THE SOURCE PANE'S MACHINE. A path printed by a remote pane is a
    /// path over there, and resolving it against this one would open a
    /// different file wearing the same name ([[RFC-0015]] C-LEAF-BINDING).
    ///
    /// The DIRECTORY, because nothing here may ask whether the path names
    /// a file or a folder — that question needs a probe, and a probe is
    /// what an agent would trigger by printing a string.
    @discardableResult
    func showWhereItLives(_ path: String, from leafID: UUID) -> UUID? {
        guard path.hasPrefix("/") else { return nil }
        guard let workspace = workspaces.first(where: { $0.panes.contains { $0.id == leafID } })
        else { return nil }
        let host = host(ofLeaf: leafID)
        // A PATH THAT IS ITSELF A DIRECTORY OPENS AS ITSELF. Asking is
        // allowed on the pane's own machine — it tells an agent nothing it
        // could not read itself at no cost — and declining it would open
        // the level above every directory the human clicked.
        //
        // NOT ASKED ACROSS A CONNECTION, which is where the answer costs a
        // round trip and the clause lets an implementation decline. The
        // directory is never wrong there, only less specific.
        let directory = host == nil && pathIsDirectory(path)
            ? path : containingDirectory(of: path)
        guard let opened = addPane(
            content: .files(directory: directory),
            toWorkspace: workspace.id, on: .machine(host))
        else { return nil }
        // WHOSE OUTPUT PUT IT THERE. Nothing else on a file leaf tells the
        // human this one arrived because text in another pane named a path
        // ([[RFC-0015]] C-DERIVED rule five).
        facts[opened, default: .init()].openedFrom =
            .init(pane: leafID, agent: facts[leafID]?.agent)
        return opened
    }

    /// Whose output opened this leaf, if text did rather than the human.
    func openedFrom(leaf leafID: UUID) -> LeafFacts.OpenedFrom? {
        facts[leafID]?.openedFrom
    }

    /// SAID TO A HUMAN. Names the pane, and the agent when one is running
    /// there — the clause asks for both and one of them may not exist.
    func openedFromDescription(leaf leafID: UUID) -> String? {
        guard let from = openedFrom(leaf: leafID) else { return nil }
        let pane = leafData(from.pane)?.label ?? "a pane that has closed"
        guard let agent = from.agent else { return "Opened from a path printed in \(pane)" }
        return "Opened from a path \(agent) printed in \(pane)"
    }

    /// WHETHER A PATH ON THIS MACHINE NAMES A DIRECTORY.
    ///
    /// A closure for the reason `observedPwd` is one: what needs testing
    /// is not the syscall but which readers are allowed to make it.
    var pathIsDirectory: (String) -> Bool = { path in
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// The directory that holds a path, or the path itself when it already
    /// names one by ending in a separator.
    private func containingDirectory(of path: String) -> String {
        var parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if !path.hasSuffix("/"), !parts.isEmpty { parts.removeLast() }
        return "/" + parts.joined(separator: "/")
    }

    /// WHAT THE KERNEL CAN SEE: the directory of the SHELL above this
    /// pane's foreground process, which is as close as a process table
    /// gets to "where the human is".
    ///
    /// A closure for the reason `remoteAgentEnder` is one: a real read
    /// needs a live ghostty surface, and what needs testing is not the
    /// syscall — it is WHICH readers are allowed to believe this.
    ///
    /// LOCAL PANES ONLY, and the caller enforces it. A pane running `ssh`
    /// has a foreground process on THIS Mac, so the kernel would answer
    /// with a local path for a remote shell — confidently, and wrong
    /// ([[ProcessCwd]]).
    var observedPwd: (UUID) -> String? = { leafID in
        guard let surface = GhosttyApp.shared?.surface(forLeaf: leafID) else { return nil }
        // THE SHELL ABOVE THE FOREGROUND PROCESS, not the foreground
        // process ([[WI-2026-08-18-004]]). ghostty names what the human
        // last typed; a command that `cd`d would otherwise hand us its
        // own directory as the pane's.
        return ProcessCwd.ofShell(foregroundPID: pid_t(ghostty_surface_foreground_pid(surface)))
    }

    /// WHERE A LEAF IS ACTUALLY STANDING, which is not the same question as
    /// what its shell has volunteered.
    ///
    /// The shell's own word first; the kernel behind it, because a plain
    /// login emits no OSC 7 at all and every reader of this had a shrug
    /// for the ordinary case — a drop that said "working directory
    /// unknown", a restored session that reopened at home, an agent told
    /// nothing about where it was.
    ///
    /// THE KERNEL'S ANSWER IS NOT THE SHELL'S ([[RFC-0015]] C-LAYOUT).
    /// It reports whatever is in FRONT of the shell, and a command that
    /// `cd`s takes the answer with it — `jenv rehash`, which every zsh
    /// here runs from `.zshrc`, spends its life in `~/.jenv/shims`. Found
    /// by duplicating a pane during its own startup: the copy opened in
    /// the shim directory, confidently. Readers that place something on
    /// the strength of this must use `reportedPwd` instead.
    func pwd(ofLeaf leafID: UUID) -> String? {
        if let reported = reportedPwd(ofLeaf: leafID) { return reported }
        if isLocalLeaf(leafID), let observed = observedPwd(leafID) { return observed }
        // WHERE IT WAS STARTED, when nothing has said where it is now.
        // A shell that never emitted OSC 7 is not a leaf with no
        // directory: it is one standing where it was put. Without this a
        // restored pane lost its directory on the NEXT restart — the
        // snapshot recorded nothing, so the restore after it had nothing
        // to place the pane with ([[RFC-0015]] C-PERSIST).
        return leafData(leafID)?.workingDirectory
    }

    /// Every connection the workbench holds ([[RFC-0015]] C-CONNECTION).
    let connections = ConnectionRegistry()

    /// How often the registry is asked whether anything has been idle long
    /// enough to release. Shorter than the grace period, so a connection
    /// goes at roughly the moment it becomes eligible rather than up to a
    /// whole period late.
    static let releaseSweepInterval: TimeInterval = 10

    private var releaseSweep: Timer?

    /// RELEASING IS SOMETHING SOMEBODY HAS TO ASK FOR. The registry knows
    /// when a connection is eligible and hangs up nothing on its own — it
    /// owns what a connection IS, not the transport. Without this timer and
    /// this closure the whole release path is unreachable: connections
    /// accumulate, tunnels stay open, and the leak C-RELEASE exists to
    /// prevent happens quietly on the host.
    func startReleasingIdleConnections() {
        connections.onRelease = { connection in
            guard let host = connection.host else { return }
            TunnelManager.shared?.disconnectTunnel(for: host)
        }
        releaseSweep?.invalidate()
        releaseSweep = Timer.scheduledTimer(
            withTimeInterval: Self.releaseSweepInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.connections.sweep() }
        }
    }

    /// Quitting is an explicit act and does not wait out the grace period.
    func releaseAllConnections() {
        releaseSweep?.invalidate()
        releaseSweep = nil
        connections.updateReferences([])
        for connection in connections.remoteConnections {
            connections.releaseNow(connection.id)
        }
    }

    /// WHICH MACHINE A LEAF IS ON, READ DOWNWARD.
    ///
    /// This used to walk UP — find the session containing the leaf, ask
    /// it for its host — and was correct only because a session could
    /// contain leaves from one machine. It cannot any more: a leaf may
    /// sit in a position whose other panes are on a different host, and
    /// the container's answer would be somebody else's machine. Two files
    /// went to the wrong host through a subtler version of that
    /// ([[RFC-0015]] C-LEAF-BINDING).
    ///
    /// nil is THIS machine, which is the local connection rather than an
    /// absence — the leaf is bound either way.
    func host(ofLeaf leafID: UUID) -> HostEntry? {
        guard let id = connectionID(ofLeaf: leafID) else { return nil }
        return connections.connection(id)?.host
    }

    func connectionID(ofLeaf leafID: UUID) -> UUID? {
        leafData(leafID)?.connectionID
    }

    func isLocalLeaf(_ leafID: UUID) -> Bool {
        host(ofLeaf: leafID) == nil
    }

    /// The connection a NEW pane in this workspace should join.
    ///
    /// Taken from the pane the human is looking at rather than from the
    /// workspace, which no longer has a machine: opening a pane beside a
    /// remotehost pane means another remotehost pane, and a workspace
    /// holding two machines has no single answer to give.
    private func connectionForNewPane(in session: Workspace) -> UUID {
        session.focusedPane?.connectionID
            ?? session.panes.first?.connectionID
            ?? connections.localID
    }

    /// Focus the pane running this agent, wherever it is.
    ///
    /// This looked up the SESSION whose agent id matched, which only ever
    /// found the pane a workspace had been dialled with. The agent is a
    /// pane's own ([[RFC-0015]] C-LEAF-BINDING), so the pane holding it is
    /// found directly and brought to the front of its own position.
    func focusAgent(_ agentID: String) {
        guard let leafID = leafID(forAgent: agentID) else { return }
        revealLeaf(leafID)
    }

    /// BRING A PANE TO THE HUMAN, wherever it is: switch to its workspace,
    /// front it in its position, and focus it — the go-to-pane palette's
    /// verb ([[WI-2026-09-02-007]]), and what focusing an agent already
    /// did. Attention is cleared the way `focusLeaf` clears it: the human
    /// has now looked.
    func revealLeaf(_ leafID: UUID) {
        guard let sIdx = workspaceIndex(containing: leafID) else { return }
        activeWorkspaceID = workspaces[sIdx].id
        facts[leafID]?.needsAttention = false
        bringToFront(leafID, in: sIdx)
    }

    /// Every open pane as the palette sees it, in workspace order
    /// ([[PaneSearch]]).
    var paneSearchCandidates: [PaneSearch.Candidate] {
        workspaces.flatMap { ws in
            ws.panes.map { pane in
                PaneSearch.Candidate(
                    id: pane.id,
                    label: displayLabel(for: pane),
                    title: tabTooltip(for: pane),
                    host: host(ofLeaf: pane.id)?.label ?? "",
                    agent: agentID(forLeaf: pane.id) ?? "",
                    workspace: ws.label)
            }
        }
    }

    /// The connections a workspace's panes reference. DERIVED — a
    /// workspace holds no connection of its own ([[RFC-0015]]
    /// C-WORKSPACE).
    func connections(ofWorkspace session: Workspace) -> [Connection] {
        var seen: Set<UUID> = []
        // EVERY CONNECTION IS NAMED BY A PANE. There used to be a
        // pending one to add here, because a workspace mid-dial had no
        // pane to read a connection from; it has one now ([[RFC-0015]]
        // C-DIAL), so there is nothing left that only the container knows.
        let ids = session.panes.map(\.connectionID)
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return connections.connection(id)
        }
    }

    /// Every machine a workspace has work on.
    func hosts(ofWorkspace session: Workspace) -> [HostEntry] {
        connections(ofWorkspace: session).compactMap(\.host)
    }

    /// HOW MANY MACHINES CLOSE WITH IT, this Mac included. The sidebar
    /// counts HOSTS, because a local workspace has no host record and a
    /// count of hosts is what "how many machines is this workspace
    /// spread over" reads as there. This is a different question — what
    /// a human is about to discard — and the machine they are sitting at
    /// is one of the answers ([[WorkspaceDestruction]]).
    func machineCount(ofWorkspace session: Workspace) -> Int {
        connections(ofWorkspace: session).count
    }

    /// WHETHER WORK PUT ASIDE HAS BROKEN ([[RFC-0015]] C-FAILURE): a
    /// workspace containing a failed connection must be distinguishable
    /// without opening it, or a failure inside one the human is not
    /// looking at is discovered only on return.
    /// WHY, and not merely that. A row that says something has broken
    /// without saying what sends the human into the workspace to find out
    /// — which is the trip [[RFC-0015]] C-FAILURE exists to save them.
    func firstFailure(_ session: Workspace) -> String? {
        for connection in connections(ofWorkspace: session) {
            if case .failed(let why) = connection.state { return why }
        }
        return nil
    }

    func hasFailedConnection(_ session: Workspace) -> Bool {
        connections(ofWorkspace: session).contains {
            if case .failed = $0.state { return true }
            return false
        }
    }

    /// The worst state among a workspace's connections, for surfaces that
    /// still summarise a whole container. Derived rather than stored —
    /// the per-pane account C-FAILURE actually requires is the sidebar's
    /// own rework ([[WI-2026-08-17-026]]).
    /// WHAT ONE LEAF SHOWS, and the rule that keeps a spurious shell
    /// unrepresentable ([[RFC-0015]] C-DIAL, C-FAILURE).
    ///
    /// A pane bound to a host now exists and is drawn while its dial is
    /// still in flight, which C-DIAL requires — a pane that appears only
    /// after a multi-second dial gives the human nothing to look at and
    /// nowhere to see progress. That reintroduces the hazard the old
    /// placeholder model was built around: a terminal with no command,
    /// handed a surface, spawns ghostty's DEFAULT shell — a LOCAL one —
    /// on a pane the human asked to be on another machine
    /// (WI-2026-03-31-003).
    ///
    /// So the surface is gated on BOTH: the leaf's connection must be up
    /// AND the leaf must have something to run. The connection alone was
    /// the first attempt and is not sufficient — a host already reached
    /// hands back a `connected` connection at once, which opened the gate
    /// on a pane whose command had not arrived. The local connection is
    /// never dialled ([[RFC-0015]] C-CONNECTION), so a local pane turns
    /// on the second half of the gate alone: it opens when it has its
    /// command, which it is given at creation.
    enum LeafSurface: Equatable {
        /// The connection is up: give it a terminal.
        case terminal
        /// Bound, waiting, drawn in its place in the layout.
        case dialling
        /// The dial failed. The leaf stays, with its binding, and says why.
        case failed(String)
        /// Another client took the session this leaf was attached to
        /// ([[RFC-0014]] C-ONE-CLIENT). The link to the host is fine and
        /// the session is alive; what this pane lost is its seat.
        case taken
    }

    func surface(of leafID: UUID) -> LeafSurface {
        guard let pane = leafData(leafID) else { return .terminal }
        // A FACT ABOUT THIS LEAF, ASKED BEFORE THE LINK. Displacement
        // leaves the host perfectly reachable — every other pane on it
        // keeps working — so reading this off the connection would find
        // `connected` and hand a dead surface a terminal.
        if facts[leafID]?.takenByAnother == true { return .taken }
        switch connections.connection(pane.connectionID)?.state {
        case .failed(let reason): return .failed(reason)
        case .connecting: return .dialling
        case .connected, nil:
            // AND ASKED OF THE PANE, not only of its link. The connection
            // being up is a fact about the HOST; whether this leaf has
            // anything to run is a fact about the LEAF, and reading the
            // second off the first is what let the old bug back in.
            //
            // A host already reached — a second pane on it, or one opened
            // after an earlier pane brought the link up — is `connected`
            // the instant `acquire` hands its connection back, while the
            // new leaf's command is still a dial away. The gate opened on
            // a leaf with nothing to run, and ghostty's default shell is
            // a LOCAL one: the human asked for a pane on another machine
            // and got a shell on this one (WI-2026-03-31-003, again).
            if pane.content.isTerminal, pane.content.terminalCommand == nil { return .dialling }
            return .terminal
        }
    }

    /// WHAT THE PANE AREA SHOWS FOR A WORKSPACE. Two outcomes, because
    /// there are only two things a container can be: holding a layout, or
    /// holding nothing ([[RFC-0015]] C-EMPTY).
    ///
    /// IT USED TO HAVE A THIRD, and losing it is the point. A workspace
    /// could be "connecting", which put a full-frame card over the whole
    /// layout — so a workspace with a connected local pane and one remote
    /// pane still dialling hid BOTH, and two hosts dialling at once could
    /// not be shown separately ([[RFC-0015]] C-FAILURE forbids exactly
    /// this). Dialling is a fact about a CONNECTION, and a connection is
    /// named by a leaf, so it is reported on the leaf: `surface(of:)`.
    enum PaneArea: Equatable {
        case layout
        case empty
    }

    func paneArea(of session: Workspace) -> PaneArea {
        session.layout == nil ? .empty : .layout
    }


    /// Test seam: the app calls this from every mutation path, and a test
    /// that builds a layout by hand has to say when it is done.
    func syncReferencesForTest() { syncConnectionReferences() }

    /// Which connections the live panes name. The registry derives its
    /// reference count from this rather than from balanced retain/release
    /// calls, so a pane that goes away by any route is accounted for.
    private func syncConnectionReferences() {
        connections.updateReferences(allLeaves.map(\.connectionID))
    }

    // MARK: - Locating things

    private func leafData(_ leafID: UUID) -> SplitNode.Pane? {
        for session in workspaces {
            if let pane = session.layout?.findPane(leafID) { return pane }
        }
        return nil
    }

    private func workspaceIndex(containing leafID: UUID) -> Int? {
        workspaces.firstIndex { $0.layout?.findPane(leafID) != nil }
    }

    private func workspaceIndex(withSlot slotID: UUID) -> Int? {
        workspaces.firstIndex { $0.layout?.slot(slotID) != nil }
    }

    private var activeWorkspaceIndex: Int? {
        workspaces.firstIndex { $0.id == activeWorkspaceID }
    }

    // MARK: - Moving a pane ([[RFC-0015]] C-LAYOUT)

    /// Put an EXISTING pane into a position's stack, keeping its identity.
    ///
    /// THE DROP-ON-CENTRE, and one operation on one type — which is what
    /// the old shape could not express: a tab and a split leaf lived at
    /// different levels of a hierarchy, so there was no destination type
    /// at the source's level. The gesture that drives this is separate
    /// work ([[WI-2026-08-17-028]]); what this delivers is that the
    /// arrangement it would produce — one position holding panes from two
    /// machines — is expressible and answers correctly, because the
    /// machine rides on the pane ([[RFC-0015]] C-LEAF-BINDING).
    func stackPane(_ leafID: UUID, intoSlot slotID: UUID) {
        guard let moved = takeForMove(leafID, towardsSlot: slotID),
              let tIdx = workspaceIndex(withSlot: slotID),
              let layout = workspaces[tIdx].layout else { return }
        workspaces[tIdx].setLayout(layout.stack(moved, intoSlot: slotID))
        workspaces[tIdx].focus(moved.id)
        syncConnectionReferences()
    }

    /// Drop onto a tab: the moved pane lands in the target's place in that
    /// position's stack.
    func movePane(_ leafID: UUID, before targetID: UUID) {
        guard leafID != targetID,
              let slot = slot(containing: targetID),
              let moved = takeForMove(leafID, towardsSlot: slot.id),
              let tIdx = workspaceIndex(withSlot: slot.id),
              let layout = workspaces[tIdx].layout,
              // RE-DERIVED AFTER THE REMOVAL, not before: taking the pane
              // out shifts every index after it, and a move rightwards
              // computed on the old positions lands one short.
              let index = layout.slot(slot.id)?.panes.firstIndex(where: { $0.id == targetID })
        else { return }
        workspaces[tIdx].setLayout(layout.stack(moved, intoSlot: slot.id, at: index))
        workspaces[tIdx].focus(moved.id)
        syncConnectionReferences()
    }

    /// Drop past the last tab of a position → append.
    func movePane(_ leafID: UUID, toEndOfSlot slotID: UUID) {
        stackPane(leafID, intoSlot: slotID)
    }

    /// Move an existing pane into a NEW position beside the given one.
    /// The drop-on-edge half of docking: `before` is the near side, so a
    /// pane released on the left edge arrives on the left
    /// ([[WI-2026-08-17-028]]).
    func movePane(_ leafID: UUID, besideSlot slotID: UUID,
                  direction: SplitNode.SplitDirection, before: Bool = false) {
        guard let moved = takeForMove(leafID, towardsSlot: slotID),
              let tIdx = workspaceIndex(withSlot: slotID),
              let layout = workspaces[tIdx].layout else { return }
        let (node, created) = layout.splitSlot(slotID, direction: direction,
                                               newPane: moved, before: before)
        guard created != nil else { return }
        workspaces[tIdx].setLayout(node)
        workspaces[tIdx].focus(moved.id)
        syncConnectionReferences()
    }

    /// A PANE RELEASED ON ANOTHER PANE ([[WI-2026-08-17-028]]).
    ///
    /// The one place a region becomes an operation, so the two
    /// destinations that report one — the terminal's AppKit surface and
    /// the SwiftUI view a files or web pane draws — cannot come to
    /// different conclusions about the same gesture.
    func dockPane(_ leafID: UUID, onto targetLeafID: UUID, region: PaneDropRegion) {
        guard let slot = slot(containing: targetLeafID) else { return }
        if let direction = region.direction {
            movePane(leafID, besideSlot: slot.id, direction: direction,
                     before: region.placesMovedPaneFirst)
        } else {
            stackPane(leafID, intoSlot: slot.id)
        }
    }

    /// Move a pane into ANOTHER WORKSPACE, which is what its row in the
    /// sidebar means when a pane is dropped on it ([[WI-2026-08-17-028]]).
    ///
    /// THE ROW NAMES A WORKSPACE AND NOT A POSITION, so the pane joins the
    /// position that workspace is focused on and comes to the front there.
    /// It is visible the moment the human follows it, rather than behind a
    /// tab or squeezing a layout nobody is looking at; and a workspace with
    /// no tree at all receives it as one ([[RFC-0015]] C-EMPTY).
    ///
    /// The human is NOT taken there. Sending a pane away is not a request
    /// to go with it, and the sidebar switching under a drag would move the
    /// layout out from under the next one.
    func movePane(_ leafID: UUID, toWorkspace workspaceID: UUID) {
        guard let tIdx = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let sIdx = workspaceIndex(containing: leafID),
              // ALREADY THERE IS NOT A MOVE. The row names a destination,
              // and reading it as one anyway would rearrange the layout
              // the human is holding a pane over rather than pointing at.
              sIdx != tIdx,
              let moved = takeForMove(leafID, towardsSlot: nil) else { return }
        if let layout = workspaces[tIdx].layout, let slot = workspaces[tIdx].focusedSlot {
            workspaces[tIdx].setLayout(layout.stack(moved, intoSlot: slot.id))
        } else {
            workspaces[tIdx].setLayout(.slot(SplitNode.Slot(pane: moved)))
        }
        workspaces[tIdx].focus(moved.id)
        syncConnectionReferences()
    }

    /// Take a pane out of the tree it is in WITHOUT ending it — the pane
    /// is going somewhere else, so none of `closeLeaf`'s teardown applies.
    ///
    /// A MOVE THAT WOULD DESTROY ITS OWN DESTINATION IS REFUSED HERE. A
    /// position holding one pane collapses when that pane leaves, so
    /// dropping a lone pane back onto its own position would take the
    /// slot the drop names out of the tree before the drop landed. A nil
    /// slot is a destination that is not one — another workspace — and
    /// nothing there can be taken away by this removal.
    private func takeForMove(_ leafID: UUID, towardsSlot slotID: UUID?) -> SplitNode.Pane? {
        guard let sIdx = workspaceIndex(containing: leafID),
              let layout = workspaces[sIdx].layout,
              let pane = layout.findPane(leafID),
              let source = layout.slot(containing: leafID)
        else { return nil }
        if source.id == slotID, source.panes.count == 1 { return nil }
        guard case .removed(let node) = layout.removePane(leafID) else { return nil }
        workspaces[sIdx].setLayout(node)
        return pane
    }

    private func slot(containing leafID: UUID) -> SplitNode.Slot? {
        for session in workspaces {
            if let slot = session.layout?.slot(containing: leafID) { return slot }
        }
        return nil
    }

    private func bringToFront(_ leafID: UUID, in sIdx: Int) {
        workspaces[sIdx].bringToFront(leafID)
    }

    /// Leaves with a remote query in flight, so hovering does not stack up
    /// round trips behind one answer.
    private var pwdQueriesInFlight: Set<UUID> = []

    /// ASKED WHEN SOMEBODY WANTS TO KNOW, not on a timer.
    ///
    /// A poll would spend an ssh round trip per remote pane per interval to
    /// keep an answer nobody is reading current. The only moments this is
    /// read are a drag arriving over a pane and the drop that follows, and
    /// both are the human telling us exactly which pane they mean.
    ///
    /// The result lands in the leaf's facts — where OSC 7 puts it too — so every
    /// reader gets it and a second drag over the same pane is instant. The
    /// caller is not made to wait: a drag hint must be answered in the same
    /// turn AppKit asks, and this cannot be. It updates when it arrives.
    /// Is an answer on its way? The difference between "we cannot know
    /// this" and "we are finding out" is the whole content of what the
    /// drag hint says while it waits.
    func isAskingPwd(ofLeaf leafID: UUID) -> Bool { pwdQueriesInFlight.contains(leafID) }

    func refreshRemotePwd(ofLeaf leafID: UUID) {
        guard !pwdQueriesInFlight.contains(leafID),
              let host = host(ofLeaf: leafID),
              // THE LEAF'S OWN AGENT, not the container's. Every leaf runs
              // its own child under its own id, so the one the session was
              // dialled with answers for a different pane.
              let agentID = facts[leafID]?.agent,
              // The same weak singleton [[PortForwardService]] reaches for:
              // this object outlives no connection and owns none.
              let connection = TunnelManager.shared?.connection(for: host)
        else { return }
        pwdQueriesInFlight.insert(leafID)
        Task.detached(priority: .userInitiated) {
            let pwd = RemotePwd.query(connection: connection, agentID: agentID)
            await MainActor.run {
                self.pwdQueriesInFlight.remove(leafID)
                guard let pwd else { return }
                // THE SHELL'S OWN WORD IS NEVER OVERWRITTEN BY OUR
                // INFERENCE ABOUT IT. This lands a round trip later than
                // it was asked for, and OSC 7 can arrive in between — from
                // a shell the human started INSIDE the pane, which the
                // holder cannot see: it answers for the child it spawned,
                // and a `bash` typed at that child's prompt is a different
                // process standing somewhere else.
                //
                // The caller only asks when nothing is known, so this
                // guards the race rather than the call.
                guard self.reportedPwd(ofLeaf: leafID) == nil else { return }
                self.leafDidLearnAttestedPwd(leafID, pwd: pwd)
            }
        }
    }

    func leafNeedsAttention(_ leafID: UUID) {
        markLeafAttention(leafID)
    }

    // MARK: - What the core reports about a pane ([[WI-2026-09-02-002]])

    /// A LONG COMMAND ENDING IN A PANE NOBODY IS WATCHING IS A BELL — the
    /// signal this application already has for "look here", and nothing
    /// more ([[WI-2026-09-02-002]]).
    ///
    /// This was a toast with a tone chosen by exit code, and Occam took
    /// it apart: the toast was a second voice for an event the pane
    /// itself shows; a nonzero exit is what grep, diff and test return by
    /// design, so "failed" was a false alarm; and a human who watched the
    /// command finish does not need telling. What is left is the two
    /// gates ghostty's own app applies — unfocused, and long enough to
    /// have looked away — routed through the bell path: a badge in the
    /// app, a system notification when the human is in another app.
    func leafCommandFinished(_ leafID: UUID, exitCode _: Int, duration: TimeInterval) {
        guard leafID != visibleFocusedLeafID,
              duration >= TerminalSignals.commandFinishBell else { return }
        markLeafAttention(leafID)
        if NotificationForwarder.shouldForward(appActive: NSApp.isActive, hasPayload: true) {
            NotificationForwarder.forward(
                title: "Finished in \(leafData(leafID)?.label ?? "a pane")",
                body: TerminalSignals.durationText(duration))
        }
    }

    func leafProgress(_ leafID: UUID, _ progress: LeafProgress?) {
        guard facts[leafID]?.progress != progress else { return }
        facts[leafID, default: .init()].progress = progress
    }

    func progress(ofLeaf leafID: UUID) -> LeafProgress? { facts[leafID]?.progress }

    /// WHAT THE CLOSE GESTURE DOES BEFORE ANYTHING IS ENDED
    /// ([[RFC-0015]] C-PANE-ARCHIVE): a terminal with a process in the
    /// foreground earns the question; a terminal whose foreground is its
    /// own shell, and every other kind, closes without one — the rule every
    /// terminal has taught its users.
    enum CloseDecision: Equatable { case close, ask }

    static func closeDecision(isTerminal: Bool, foregroundIsProcess: Bool) -> CloseDecision {
        (isTerminal && foregroundIsProcess) ? .ask : .close
    }

    /// CLOSE, ASKING FIRST EXACTLY WHEN A FOREGROUND PROCESS WOULD DIE.
    ///
    /// THE QUESTION OFFERS THE OTHER ACT. Archive is its default button,
    /// so the human who meant "put it away" is one Return from it and the
    /// one who meant "I am done" is one click; that is what makes ending
    /// on ✕ not the silent harm [[RFC-0014]] C-DETACH warns of
    /// ([[ADR-0019]]).
    func closePaneAsking(_ paneID: UUID) {
        guard Self.closeDecision(isTerminal: leafData(paneID)?.content.isTerminal == true,
                                 foregroundIsProcess: isBusy(paneID)) == .ask else {
            closePane(paneID)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        alert.informativeText = "A process is still running in it. Archive keeps it running and puts the pane away; Close ends it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        let act: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.archivePane(paneID)
            case .alertSecondButtonReturn: self?.closePane(paneID)
            default: break
            }
        }
        // A SHEET, LIKE askBeforeDisplacing ([[WI-2026-09-02-022]]): runModal
        // stops the run loop, and with it every terminal's ticks, for as
        // long as the question stands. The window's own sheet asks the same
        // question and lets the rest of the workbench go on.
        guard let window = NSApp.keyWindow else {
            act(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: act)
    }

    // MARK: - File pane navigation ([[WI-2026-08-19-002]])

    /// HOW A FILE LEAF IS BEING LOOKED AT — where it has been, what it is
    /// filtered to, how it is sorted.
    ///
    /// RUNTIME ONLY, and deliberately not persisted: [[RFC-0015]]
    /// C-PERSIST enumerates a file leaf's durable state as the directory
    /// it is showing and permits nothing else. A history restored from
    /// disk would offer to go "back" to a place this session never was.
    ///
    /// BUT NOT VIEW STATE EITHER. It lives here because a pane's view is
    /// destroyed whenever the human looks at another tab, and a back
    /// button that empties itself for that reason is not a back button.
    struct FileNavigation: Equatable {
        enum Sort: String, CaseIterable { case name, size, modified }

        var back: [String] = []
        var forward: [String] = []
        var filter: String = ""
        var sort: Sort = .name
        var ascending = true

        /// WHAT THE PANE LAST SAW, so coming back to it shows something
        /// rather than a spinner.
        ///
        /// The directory is durable and this is not: a listing is a claim
        /// about a machine AT A MOMENT, and one restored from disk would
        /// be a claim about a machine as it was before the computer was
        /// turned off. Held for the life of the process and no longer.
        ///
        /// SHOWN WHILE IT IS CHECKED, NEVER INSTEAD OF CHECKING. The pane
        /// refetches every time; what the cache buys is that the human
        /// sees the directory while that happens ([[RFC-0015]]
        /// C-PANE-WRITES: the contents are a claim, and a stale claim that
        /// never gets corrected is the thing to avoid).
        ///
        /// KEYED BY PATH, because the place a human is most impatient is
        /// the one they have already been: going back re-fetched a
        /// directory that was on screen a moment ago, and on a host 247ms
        /// away that is three round trips of nothing to look at. Keyed by
        /// the leaf alone it held one listing — the current one — which is
        /// exactly the listing a navigation is leaving.
        var cached: [String: [BrowsedFile]] = [:]
    }

    /// A BROWSER LEAF WENT SOMEWHERE, and the leaf records it — this is
    /// the one durable fact that kind has ([[RFC-0015]] C-PERSIST), so it
    /// lives on the pane and rides the snapshot rather than sitting in a
    /// view that a tab switch destroys.
    func browserLeafDidNavigate(_ leafID: UUID, to address: String) {
        guard let sIdx = workspaceIndex(containing: leafID),
              let layout = workspaces[sIdx].layout else { return }
        workspaces[sIdx].setLayout(layout.updating(leafID) { $0.navigateBrowser(to: address) })
    }

    /// What a services leaf is showing, and its record of it. Runtime
    /// only — see [[LeafFacts]] `viewing` for why that is the clause's
    /// answer rather than a shortcut.
    func viewing(ofServicesLeaf leafID: UUID) -> UUID? {
        facts[leafID]?.viewing
    }

    func servicesLeaf(_ leafID: UUID, isShowing exposureID: UUID?) {
        facts[leafID, default: .init()].viewing = exposureID
    }

    func navigation(ofFileLeaf leafID: UUID) -> FileNavigation {
        facts[leafID]?.navigation ?? FileNavigation()
    }

    func cacheListing(_ files: [BrowsedFile], for path: String, ofFileLeaf leafID: UUID) {
        var nav = navigation(ofFileLeaf: leafID)
        nav.cached[path] = files
        facts[leafID, default: .init()].navigation = nav
    }

    /// A WRITE MAKES ITS DIRECTORY'S COPY A LIE. Dropped rather than
    /// amended: the listing is the machine's to state, and a cache patched
    /// with what this application believes it did is a second claim about
    /// a machine, made by the party least able to check it.
    func invalidateCache(path: String, ofFileLeaf leafID: UUID) {
        var nav = navigation(ofFileLeaf: leafID)
        nav.cached.removeValue(forKey: path)
        facts[leafID, default: .init()].navigation = nav
    }

    func setFilter(_ text: String, ofFileLeaf leafID: UUID) {
        var nav = navigation(ofFileLeaf: leafID)
        nav.filter = text
        facts[leafID, default: .init()].navigation = nav
    }

    /// Picking the column that is already sorted reverses it, which is
    /// what a column header does everywhere.
    func sortFileLeaf(_ leafID: UUID, by sort: FileNavigation.Sort) {
        var nav = navigation(ofFileLeaf: leafID)
        if nav.sort == sort { nav.ascending.toggle() } else { nav.sort = sort; nav.ascending = true }
        facts[leafID, default: .init()].navigation = nav
    }

    /// A NEW PLACE CLEARS THE FORWARD TRAIL, as it does in every browser:
    /// going somewhere new from the middle of a history makes the rest of
    /// that history a road not taken.
    func fileLeafDidNavigate(_ leafID: UUID, to directory: String, recordingHistory: Bool = true) {
        guard let sIdx = workspaceIndex(containing: leafID),
              let layout = workspaces[sIdx].layout,
              let previous = layout.findPane(leafID)?.content.fileDirectory ?? Optional("")
        else { return }
        guard previous != directory else { return }
        if recordingHistory {
            var nav = navigation(ofFileLeaf: leafID)
            if !previous.isEmpty { nav.back.append(previous) }
            nav.forward.removeAll()
            facts[leafID, default: .init()].navigation = nav
        }
        workspaces[sIdx].setLayout(layout.updating(leafID) { $0.navigateFiles(to: directory) })
    }

    @discardableResult
    func fileLeafGoBack(_ leafID: UUID) -> String? {
        var nav = navigation(ofFileLeaf: leafID)
        guard let destination = nav.back.popLast() else { return nil }
        if let here = leafContent(leafID)?.fileDirectory { nav.forward.append(here) }
        facts[leafID, default: .init()].navigation = nav
        fileLeafDidNavigate(leafID, to: destination, recordingHistory: false)
        return destination
    }

    @discardableResult
    func fileLeafGoForward(_ leafID: UUID) -> String? {
        var nav = navigation(ofFileLeaf: leafID)
        guard let destination = nav.forward.popLast() else { return nil }
        if let here = leafContent(leafID)?.fileDirectory { nav.back.append(here) }
        facts[leafID, default: .init()].navigation = nav
        fileLeafDidNavigate(leafID, to: destination, recordingHistory: false)
        return destination
    }

    /// A FILE LEAF REMEMBERS WHERE IT IS ([[RFC-0015]] C-PERSIST).
    ///
    /// Written to the leaf's own content, which is what the snapshot
    /// carries — so a pane comes back showing the directory it was
    /// showing, and a duplicate of one opens beside it on the same
    /// directory rather than at home.
    ///
    /// ONLY THE DIRECTORY, and only for a file leaf. C-PERSIST enumerates
    /// what a leaf of each kind persists and permits nothing else.
    // MARK: - Find in scrollback ([[WI-2026-08-20-001]])

    /// WHICH LEAVES HAVE A FIND BAR OPEN, and what is typed in each.
    ///
    /// PER LEAF, AND THAT IS THE POINT. It used to be two `@State` values
    /// on the whole window, so there was one bar for however many
    /// terminals were on screen and no fact saying which one it searched.
    /// [[RFC-0016]] C-DISPATCH's second row is defined over "a text-entry
    /// surface BELONGING TO A TERMINAL LEAF" — a bar owned by the window
    /// satisfies no such predicate, and the clause says such a surface
    /// falls to row 4, where a terminal command reaches no terminal.
    /// Ownership is what makes the row decidable.
    func isFinding(_ leafID: UUID) -> Bool { facts[leafID]?.find != nil }
    func findQuery(_ leafID: UUID) -> String { facts[leafID]?.find ?? "" }

    /// Opens only on a TERMINAL leaf. A file or browser leaf has no
    /// scrollback to search, and a bar there would belong to no terminal —
    /// which is the state this per-leaf model exists to make impossible.
    @discardableResult
    func beginFinding(_ leafID: UUID) -> Bool {
        guard leafData(leafID)?.content.isTerminal == true else { return false }
        facts[leafID, default: .init()].find = facts[leafID]?.find ?? ""
        return true
    }

    func setFindQuery(_ leafID: UUID, _ text: String) {
        guard facts[leafID]?.find != nil else { return }
        facts[leafID]?.find = text
    }

    func endFinding(_ leafID: UUID) {
        facts[leafID]?.find = nil
    }

    /// [[RFC-0016]] C-DISPATCH: a command whose object does not exist is
    /// unavailable, not silent.
    /// WHAT AN ARRANGEMENT IS, compressed to something cheap to compare.
    ///
    /// [[RFC-0015]] C-PERSIST requires the arrangement to be written ON
    /// CHANGE and not only at termination — "a workspace's arrangement
    /// MUST be recoverable after a crash". A periodic write satisfies the
    /// letter and not the requirement: a pane opened and a workbench
    /// killed ten seconds later leaves nothing on disk, which is the loss
    /// the clause names.
    ///
    /// A SIGNATURE RATHER THAN THE TREE ITSELF, because `Workspace` is
    /// not Equatable and making it so would put "did this change" on the
    /// same footing as "is this the same workspace". What has to be
    /// caught is any change a RESTORE would notice: which workspaces
    /// exist, which panes are in them, what kind each is, where it is
    /// bound, and what it is showing.
    var arrangementSignature: String {
        var parts: [String] = []
        for workspace in workspaces {
            parts.append("\(workspace.id)|\(workspace.label)")
            for pane in workspace.panes {
                // `kindOnly` CARRIES THE STATE ALREADY: it strips a
                // terminal's command — which is minted fresh and durable
                // in nothing — and passes every other kind through whole,
                // so a file leaf's directory and a browser leaf's address
                // are in here without being named twice.
                parts.append("\(pane.id)|\(pane.connectionID)|\(pane.label)|\(pane.content.kindOnly)")
            }
        }
        return parts.joined(separator: ";")
    }

    var hasFocusedPane: Bool { activeWorkspace?.focusedPane != nil }
    var slotCount: Int { activeWorkspace?.slots.count ?? 0 }

    /// THE HUMAN'S CONTAINER FOR THEIR WORK, and nothing about a machine
    /// ([[RFC-0015]] C-WORKSPACE).
    ///
    /// It held a host, an agent id and a connection state, which was
    /// coherent only while it could contain leaves from one machine. Each
    /// of the three now lives where it can answer honestly: the host and
    /// the dial state on the shared `Connection`, the agent id on the pane
    /// running that agent.
    /// ONE PANE ARCHIVED WITH ITS WORK STILL RUNNING ([[RFC-0015]]
    /// C-PANE-ARCHIVE).
    ///
    /// The pane itself, so unarchiving is putting it back rather than
    /// building something like it, plus the two facts the list must show
    /// that the pane does not carry: which agent was running in it (the
    /// leaf's facts are forgotten when it leaves the tree) and when the
    /// human archived it.
    struct ArchivedPane: Identifiable, Equatable {
        let pane: SplitNode.Pane
        let agent: String?
        /// WHICH MACHINE IT IS ON, kept on the row because archiving
        /// releases the connection the pane pointed at — a row that
        /// looked its host up through a released connection named no
        /// machine, could not end its agent, and could not be told apart
        /// from the host's own listing of the same session. nil = this Mac.
        var host: HostEntry? = nil
        /// WHAT THE TAB WAS SHOWING, captured at the closing.
        ///
        /// `displayLabel` resolves the human's own name over the shell's
        /// OSC title over the default, and that resolution reads the
        /// leaf's facts — which `forget` clears when the pane leaves the
        /// tree. Read later it would answer with the default for every
        /// row, so it is taken while it is still true.
        ///
        /// BETTER THAN A DIRECTORY where there is one: it is what the
        /// human was actually looking at, and a shell that titles itself
        /// names the command rather than the folder. A host's own listing
        /// cannot offer this — the holder "carries no notion of a window
        /// title at all" ([[RFC-0011]] C-HEADLESS-GATE) — which is why
        /// those rows lead with where they are instead.
        let title: String?
        let at: Date
        var id: UUID { pane.id }
    }

    struct Workspace: Identifiable {
        let id: UUID
        var label: String

        /// ORDERING AND PROMINENCE, AND NOTHING ELSE ([[RFC-0015]]
        /// C-ARCHIVE's smaller half). Pin must not touch lifetime,
        /// persistence or connections, or it becomes a second lifetime
        /// rule to reason about beside archive.
        var isPinned = false

        /// THE ARRANGEMENT WHILE IT IS PUT AWAY, unbuilt.
        ///
        /// An archived workspace keeps its name and its shape and holds
        /// no panes, which is what lets it hold no connections either:
        /// archiving that leaves the links open has not put the work
        /// away, it has hidden it, and the resources the human meant to
        /// reclaim are still spent ([[RFC-0015]] C-ARCHIVE).
        ///
        /// THE SAME SHAPE THE SNAPSHOT WRITES, deliberately. Archive is
        /// "write it all down, then let go", so it writes down what a
        /// restart would and comes back the same way — a round trip that
        /// loses something is then a bug in one path rather than two.
        var archivedTree: WorkspaceSnapshot.Node?

        /// AND WHERE THE HUMAN WAS WORKING IN IT. A round trip that puts
        /// the focus back on the first pane has not returned the
        /// arrangement — it has returned a picture of it
        /// ([[RFC-0015]] C-ARCHIVE).
        var archivedFocusSlot: Int?

        /// PANES CLOSED OUT OF THIS WORKSPACE THAT ARE STILL RUNNING
        /// ([[RFC-0015]] C-PANE-ARCHIVE).
        ///
        /// Archiving a pane detaches; the holder keeps the child. What made
        /// that a leak rather than a feature was that nothing named the
        /// session afterwards — measured at five live holders against one
        /// pane, the oldest just under three days. These rows are what
        /// name them.
        var archivedPanes: [ArchivedPane] = []
        var isArchived: Bool { archivedTree != nil }
        let createdAt: Date

        /// THE ONE TREE ([[RFC-0015]] C-LAYOUT). nil means the workspace
        /// holds nothing — a placeholder still dialling, or one whose last
        /// pane was closed. A slot may not be empty, so there is no husk
        /// of a tree to keep for that case, and a workspace with none is a
        /// resting state rather than an error ([[RFC-0015]] C-EMPTY).
        private(set) var layout: SplitNode?

        /// The pane the human is working in.
        private(set) var focusedPaneID: UUID?

        /// Every pane, across every position and every stack.
        var panes: [SplitNode.Pane] { layout?.panes ?? [] }

        /// Every position, in order.
        var slots: [SplitNode.Slot] { layout?.slots ?? [] }

        var focusedPane: SplitNode.Pane? {
            focusedPaneID.flatMap { layout?.findPane($0) }
        }

        /// The position the human is working in — the one holding the
        /// focused pane, or the first if focus has not landed anywhere.
        var focusedSlot: SplitNode.Slot? {
            if let id = focusedPaneID, let slot = layout?.slot(containing: id) { return slot }
            return layout?.slots.first
        }

        // MARK: Zoom ([[WI-2026-09-02-006]])

        /// THE ONE POSITION SHOWN ALONE, when the human asked for it. A
        /// viewing mode over the layout, never an edit of it: the tree
        /// and its ratios are untouched while this is set, which is what
        /// lets the toggle give the layout back exactly.
        private(set) var zoomedSlotID: UUID?

        // MARK: Broadcast ([[WI-2026-09-02-010]])

        /// THE PANES A KEYSTROKE IS COPIED TO. Never persisted: a standing
        /// "keys go to many machines" that came back after a relaunch
        /// would be armed by nobody present. Pruned against the layout on
        /// read, so a closed pane leaves the set with the tree.
        var broadcastPaneIDs: Set<UUID> = []

        var armedBroadcastPanes: [UUID] {
            panes.map(\.id).filter { broadcastPaneIDs.contains($0) }
        }

        var zoomedSlot: SplitNode.Slot? {
            guard let zoomedSlotID else { return nil }
            return slots.first { $0.id == zoomedSlotID }
        }

        var isZoomed: Bool { zoomedSlot != nil }

        /// What the split area draws: every position, or the zoomed one.
        var visibleSlots: [SplitNode.Slot] {
            zoomedSlot.map { [$0] } ?? slots
        }

        /// Zoom the focused position, or restore. One position cannot
        /// zoom — there is nothing to take the area from.
        mutating func toggleZoom() {
            if zoomedSlotID != nil { zoomedSlotID = nil; return }
            guard slots.count > 1, let slot = focusedSlot else { return }
            zoomedSlotID = slot.id
        }

        /// Restore-time: zoom the position at this index, if it exists.
        mutating func zoom(slotAt index: Int) {
            guard slots.count > 1, index >= 0, index < slots.count else { return }
            zoomedSlotID = slots[index].id
        }

        /// WHAT ENDS A ZOOM: the arrangement of positions changing, or
        /// focus leaving the zoomed position. Tab switches and reorders
        /// inside it change what the position shows, not where it is,
        /// and keep it — so the test is on the SET of position ids, not
        /// on the tree.
        private mutating func unzoomIfLeaving(_ paneID: UUID) {
            guard let zoomedSlotID,
                  layout?.slot(containing: paneID)?.id != zoomedSlotID else { return }
            self.zoomedSlotID = nil
        }

        /// THE ONE PLACE A TREE IS WRITTEN, so the two invariants that
        /// hold it together cannot be forgotten at a call site: an empty
        /// tree is no tree, and focus names a pane that exists. And the
        /// zoom's own rule: a change to the set of positions ends it.
        mutating func setLayout(_ node: SplitNode?) {
            let positionsBefore = Set(layout?.slots.map(\.id) ?? [])
            layout = (node?.panes.isEmpty ?? true) ? nil : node
            if focusedPaneID == nil || layout?.findPane(focusedPaneID!) == nil {
                focusedPaneID = layout?.slots.first?.activePaneID
            }
            if zoomedSlotID != nil, Set(layout?.slots.map(\.id) ?? []) != positionsBefore {
                zoomedSlotID = nil
            }
        }

        /// Focus a pane that is already in the tree. Anything else is
        /// ignored — focus on a pane that is not there is the shape of
        /// bug WI-2026-08-08-033 was.
        mutating func focus(_ paneID: UUID) {
            guard layout?.findPane(paneID) != nil else { return }
            unzoomIfLeaving(paneID)
            focusedPaneID = paneID
        }

        /// Bring a pane to the front of its own position and focus it.
        mutating func bringToFront(_ paneID: UUID) {
            guard layout?.findPane(paneID) != nil else { return }
            unzoomIfLeaving(paneID)
            layout = layout?.focusing(paneID)
            focusedPaneID = paneID
        }

        /// Ratios are the one mutation that moves no pane, so it goes
        /// straight to the tree rather than through `setLayout`'s focus
        /// and emptiness checks.
        mutating func resizeSplit(splitID: UUID, ratio: CGFloat) {
            layout?.setRatio(splitID: splitID, ratio: ratio)
        }

        /// `id` RESTORES AN IDENTITY RATHER THAN MINTING ONE
        /// ([[RFC-0015]] C-WORKSPACE: a workspace's identity "outlives
        /// every terminal it has ever contained" — which it cannot do if
        /// it does not outlive the process). The workbench hands this
        /// value to agents as `workspace_id`, so one written into a task
        /// or a message resolved to nothing after the next relaunch.
        init(id: UUID = UUID(), label: String, initialCommand: String? = nil, connectionID: UUID) {
            self.id = id
            self.label = label
            self.createdAt = Date()
            if let initialCommand, !initialCommand.isEmpty {
                // A real command launches the session shell (local or remote).
                let pane = SplitNode.Pane(command: initialCommand, connectionID: connectionID)
                self.layout = .slot(SplitNode.Slot(pane: pane))
                self.focusedPaneID = pane.id
            } else {
                // No command yet (e.g. remote placeholder while the tunnel is
                // being established): no pane, no ghostty surface. Creating a
                // surface with a nil command would spawn a spurious local
                // shell (WI-2026-03-31-003).
                self.layout = nil
                self.focusedPaneID = nil
            }
        }
    }

    var workspaces: [Workspace] = []
    var activeWorkspaceID: UUID?

    var activeWorkspace: Workspace? {
        guard let id = activeWorkspaceID else { return workspaces.first }
        return workspaces.first { $0.id == id }
    }

    /// The pane the human is working in, in the workspace they are looking
    /// at.
    var activePane: SplitNode.Pane? {
        activeWorkspace?.focusedPane
    }

    var allLeaves: [SplitNode.Pane] {
        workspaces.flatMap(\.panes)
    }

    /// The panes actually on screen: the one in front of each position of
    /// the active workspace. Panes behind them in a stack are alive but
    /// not shown.
    var visibleLeafIDs: [UUID] {
        activeWorkspace?.visibleSlots.compactMap { $0.activePane?.id } ?? []
    }

    /// Zoom the focused position of the active workspace, or restore
    /// ([[WI-2026-09-02-006]]). Visibility follows through
    /// `visibleLeafIDs`, so hidden positions lose their surfaces' key
    /// eligibility and occlusion state the same way stacked tabs do.
    func toggleZoom() {
        guard let idx = activeWorkspaceIndex else { return }
        workspaces[idx].toggleZoom()
    }

    var isZoomed: Bool { activeWorkspace?.isZoomed ?? false }

    // MARK: - Broadcast ([[WI-2026-09-02-010]])

    /// ARM EVERY VISIBLE PANE, OR DISARM EVERY PANE — one act each way.
    /// Arming takes the panes on screen at that moment and no others: a
    /// pane opened later joins only by being asked. One pane cannot
    /// broadcast; the switch stays off.
    func toggleBroadcast() {
        guard let idx = activeWorkspaceIndex else { return }
        if !workspaces[idx].armedBroadcastPanes.isEmpty {
            workspaces[idx].broadcastPaneIDs = []
            return
        }
        let visible = workspaces[idx].visibleSlots.compactMap { $0.activePane?.id }
        guard visible.count > 1 else { return }
        workspaces[idx].broadcastPaneIDs = Set(visible)
    }

    var isBroadcasting: Bool { !(activeWorkspace?.armedBroadcastPanes.isEmpty ?? true) }

    func isBroadcastArmed(_ leafID: UUID) -> Bool {
        guard let idx = workspaceIndex(containing: leafID) else { return false }
        return workspaces[idx].armedBroadcastPanes.contains(leafID)
    }

    func setBroadcastArmed(_ leafID: UUID, _ armed: Bool) {
        guard let idx = workspaceIndex(containing: leafID) else { return }
        if armed { workspaces[idx].broadcastPaneIDs.insert(leafID) }
        else { workspaces[idx].broadcastPaneIDs.remove(leafID) }
    }

    /// WHERE A KEYSTROKE IN `leafID` IS COPIED: the other armed panes of
    /// its workspace, and nothing if the source itself is not armed —
    /// the human left it out on purpose. Never another workspace's.
    func broadcastTargets(from leafID: UUID) -> [UUID] {
        guard let idx = workspaceIndex(containing: leafID) else { return [] }
        let armed = workspaces[idx].armedBroadcastPanes
        guard armed.contains(leafID) else { return [] }
        return armed.filter { $0 != leafID }
    }

    func requestToggleBroadcast() { toggleBroadcast() }

    /// A KEYBOARD STEP OF THE FOCUSED POSITION'S EDGE
    /// ([[WI-2026-09-02-008]]), through the same ratio the divider drag
    /// writes. One twentieth of the split per press: fine enough to land
    /// where the eye wants, coarse enough that four presses is a visible
    /// change.
    static let resizeStep: CGFloat = 0.05

    func resizeFocusedPosition(_ edge: SplitNode.Edge) {
        guard let idx = activeWorkspaceIndex,
              let layout = workspaces[idx].layout,
              let slot = workspaces[idx].focusedSlot else { return }
        let pushed = layout.pushingEdge(edge, ofSlot: slot.id, by: Self.resizeStep)
        guard pushed != layout else { return }
        workspaces[idx].setLayout(pushed)
    }

    /// Even shares for every position of the active workspace.
    func equalizePositions() {
        guard let idx = activeWorkspaceIndex, let layout = workspaces[idx].layout else { return }
        workspaces[idx].setLayout(layout.equalised())
    }

    func requestToggleZoom() { toggleZoom() }

    var visibleLeafID: UUID? {
        activeWorkspace?.focusedPaneID
    }

    init() {}

    // MARK: - Label generation

    /// Generate an auto-incrementing label: "Local", "Local 2", "Local 3", etc.
    /// A name nothing else is called ([[WI-2026-08-17-019]]).
    ///
    /// ASKED OF THE SESSIONS, NOT OF A COUNTER. This kept a per-prefix
    /// count in memory and handed out the bare prefix while that count was
    /// one — but workspaces a restore brings back never pass through here,
    /// their names coming from the snapshot, so the count was zero with
    /// three of them already on screen. The first `remotehost` opened by
    /// hand then took the name of the `remotehost` sitting above it, and
    /// only the second one got a number.
    ///
    /// A number freed by closing a session is used again. That is the
    /// behaviour of a name that means "the one that is not taken", which
    /// is what this is; a monotonic counter would leave gaps that mean
    /// nothing to the human reading the list.
    private func nextLabel(for prefix: String) -> String {
        var candidate = prefix
        var n = 1
        while workspaces.contains(where: { $0.label == candidate }) {
            n += 1
            candidate = "\(prefix) \(n)"
        }
        return candidate
    }

    // MARK: - Session management

    func addLocalWorkspace() {
        let result = TunnelManager.shared?.localCommand()
        let label = nextLabel(for: "Local")
        let session = Workspace(label: label, initialCommand: result?.command,
                              connectionID: connections.localID)
        workspaces.append(session)
        activeWorkspaceID = session.id
        recordLeafAgent(session.panes.first?.id, result?.agentID)
        syncConnectionReferences()
    }

    /// WHICH CONNECTION A WORKSPACE IS WAITING ON, for the window between
    /// dialling and having a pane.
    ///
    /// A placeholder has no pane to read the connection from, and giving
    /// it one before the command exists would spawn a spurious local shell
    /// (WI-2026-03-31-003). This holds the answer for exactly that gap and
    /// is dropped the moment the pane arrives.

    /// CONNECT TO A HOST BY PUTTING A PANE THERE, not by making a
    /// container and waiting ([[RFC-0015]] C-DIAL, C-WORKSPACE).
    ///
    /// The workspace this creates is a workspace like any other — it
    /// happens to contain a pane on that host, does not belong to it, and
    /// does not end when the connection does. The pane exists from this
    /// moment: bound, in the layout, drawn where the human put it, and
    /// showing its own dial rather than replacing the workspace with a
    /// card.
    @discardableResult
    func addRemoteWorkspace(label: String, hostEntry: HostEntry) -> UUID {
        let session = Workspace(label: nextLabel(for: label), connectionID: connections.localID)
        workspaces.append(session)
        activeWorkspaceID = session.id
        addRemotePane(toWorkspace: session.id, label: label, hostEntry: hostEntry)
        return session.id
    }

    /// A GROUP AS A WALL OF TERMINALS ([[WI-2026-09-02-009]]): one pane
    /// per member, each in its own position, arranged as the grid preset
    /// arranges positions, in a new workspace named after the group. The
    /// panes are placeholders until each dial answers, exactly as a single
    /// remote pane is; the caller dials them. Returns each pane with its
    /// host so it can. An empty group opens nothing.
    @discardableResult
    func addRemoteGrid(label: String, hosts: [HostEntry]) -> [(paneID: UUID, host: HostEntry)] {
        guard !hosts.isEmpty else { return [] }
        var session = Workspace(label: nextLabel(for: label), connectionID: connections.localID)
        let panes = hosts.map { host in
            SplitNode.Pane(label: host.label, command: nil,
                           connectionID: connections.acquire(host: host).id)
        }
        session.setLayout(SplitNode.arranged(slots: panes.map { SplitNode.Slot(pane: $0) }, preset: .grid))
        session.focus(panes[0].id)
        workspaces.append(session)
        activeWorkspaceID = session.id
        syncConnectionReferences()
        return zip(panes, hosts).map { (paneID: $0.id, host: $1) }
    }

    @discardableResult
    func addRemotePane(toWorkspace workspaceID: UUID,
                       label: String, hostEntry: HostEntry) -> UUID {
        let connectionID = connections.acquire(host: hostEntry).id
        // NO COMMAND YET, AND THAT IS SAFE HERE. `surface(of:)` refuses a
        // terminal to a leaf whose connection is not up, so nothing spawns
        // until the dial returns with the wrapper invocation.
        let pane = SplitNode.Pane(label: label, command: nil, connectionID: connectionID)
        if let idx = workspaces.firstIndex(where: { $0.id == workspaceID }) {
            place(pane, in: idx)
        }
        syncConnectionReferences()
        return pane.id
    }

    /// The dial returned. The pane that has been waiting takes its command
    /// and its agent id, and keeps its identity — it is the same pane the
    /// human has been looking at, not a replacement for it.
    func paneDidConnect(_ leafID: UUID, command: String, agentID: String?) {
        guard let sIdx = workspaceIndex(containing: leafID),
              let layout = workspaces[sIdx].layout,
              let pane = layout.findPane(leafID) else { return }
        connections.markConnected(pane.connectionID)
        workspaces[sIdx].setLayout(layout.updating(leafID) { $0.start(command: command) })
        recordLeafAgent(leafID, agentID)
        syncConnectionReferences()
    }

    /// The account each connecting session is writing.
    let connectProgress = ConnectProgress.Center()

    func addRemoteWorkspace(label: String, hostEntry: HostEntry, command: String, agentID: String? = nil) {
        let sessionLabel = nextLabel(for: label)
        let connectionID = connections.acquire(host: hostEntry).id
        let session = Workspace(label: sessionLabel, initialCommand: command, connectionID: connectionID)
        workspaces.append(session)
        activeWorkspaceID = session.id
        recordLeafAgent(session.panes.first?.id, agentID)
        syncConnectionReferences()
    }

    // MARK: - Rename

    func renameWorkspace(_ workspaceID: UUID, to newLabel: String) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[idx].label = newLabel
    }

    func renamePane(_ paneID: UUID, to newLabel: String) {
        guard let sIdx = workspaceIndex(containing: paneID),
              let layout = workspaces[sIdx].layout else { return }
        workspaces[sIdx].setLayout(layout.updating(paneID) {
            $0.label = newLabel
            // Manual name wins over shell titles from now on (WI-2026-08-09-017).
            $0.userRenamed = true
        })
        // AND THE HOLDER HEARS IT ([[RFC-0014]] C-SESSION-NAME): a durable
        // session is called one thing on both sides of the workbench.
        if let agentID = agentID(forLeaf: paneID), leafIsDurable(paneID) {
            TunnelManager.shared?.nameSession(agentID: agentID, on: host(ofLeaf: paneID), name: newLabel)
        }
    }

    /// Whether this leaf's session outlives its client — the same reading
    /// `paneWouldLoseAProcess` makes, without asking the surface.
    private func leafIsDurable(_ paneID: UUID) -> Bool {
        guard leafData(paneID)?.content.isTerminal == true else { return false }
        if isLocalLeaf(paneID) { return SynaptySettings.shared.localDurableSessions }
        return host(ofLeaf: paneID)?.durableSessions != false
    }

    // MARK: - Leaf ↔ agent identity (WI-2026-08-09-022)

    /// Every leaf's spawn command runs under a `synapty run` wrapper with
    /// a unique agent id — recorded here at the four spawn sites so hub
    /// agent status can be routed to the exact pane. Runtime-only.


    /// Internal rather than private: the four spawn sites are the only
    /// production callers, but a test that needs an agent in a pane has no
    /// other way to put one there, and going through a real spawn would
    /// make it a test of `synapty run`.
    func recordLeafAgent(_ leafID: UUID?, _ agentID: String?) {
        guard let leafID, let agentID else { return }
        facts[leafID, default: .init()].agent = agentID
    }

    /// Whether this leaf runs on the machine a qualified name points at.
    /// True for a bare name, which points at none.
    private func leafIsOn(machineIn qualified: String, leaf: UUID) -> Bool {
        guard let at = qualified.firstIndex(of: "@") else { return true }
        let machine = String(qualified[qualified.index(after: at)...])
        guard let host = host(ofLeaf: leaf) else {
            // A leaf on THIS Mac cannot be the one a qualified name means:
            // a qualifier is minted at the relay boundary and this machine
            // is never on the far side of its own.
            return false
        }
        // By the name that machine reported for itself where it has one,
        // and by the human's label otherwise — the second is what a
        // machine that has not spoken yet can be matched on at all.
        if let reported = TunnelManager.shared?.reportedPeer(forHost: host) {
            return reported == machine
        }
        return (host.label.isEmpty ? host.address : host.label).lowercased()
            == machine.lowercased()
    }

    /// EITHER NAME FINDS THE LEAF, and the one that registers becomes the
    /// only one ([[LeafFacts]] `candidateAgent`). A remote pane is handed
    /// two names and picks over there; this is how the workbench learns
    /// which without being told.
    /// AND WHERE THE NAME CARRIES A MACHINE, THE LEAF MUST BE ON IT. A
    /// fallback id is unique within ONE machine and never promised more
    /// ([[RFC-0009]] C-IDENTITY-SCOPE qualifies it for exactly that
    /// reason), so two panes on two hosts can draw the same four hex
    /// digits — and this table is keyed by leaf, not by machine, so the
    /// first match won. The symptom was `FileToolServer.origin(of:)`
    /// answering "this Mac" for a remote agent's request, and reading the
    /// wrong filesystem.
    ///
    /// The qualifier is the machine, so the case where it matters is the
    /// case where the answer is already in hand. A BARE name is matched as
    /// before: it can only come from a caller that has not been through
    /// the relay boundary, and tightening it here would refuse the local
    /// panes this is mostly asked about.
    /// WHICH LEAF SHOWS THIS AGENT, asked and nothing more.
    ///
    /// `leafID(forAgent:)` below is the funnel a REGISTRATION passes
    /// through, and it RECORDS a rejoin decision on the way past. A view
    /// asking "is this agent one of mine?" is not a registration, and
    /// answering it must not write: `facts` is observable, a body that
    /// mutates it invalidates every view that read it, and those include
    /// the body doing the mutating. The sidebar's list of agents
    /// elsewhere asked the funnel, and the workbench spun in a view
    /// update that could not settle ([[WI-2026-08-29-001]]).
    ///
    /// A DICTIONARY WRITE CANNOT BE ELIDED THE WAY A SCALAR CAN. `facts`
    /// is reached through `_modify`, so Observation has no old value to
    /// compare and fires whether or not anything changed — which is why
    /// `facts[x]?.rejoinOffer = nil`, a no-op on all but the first call,
    /// was enough to keep the loop turning.
    func leafShowing(agent agentID: String) -> UUID? {
        matchedLeaf(forAgent: agentID)
    }

    /// The match, without the recording. Both the query above and the
    /// funnel below start here, so they cannot disagree about which leaf
    /// an agent is on.
    private func matchedLeaf(forAgent agentID: String) -> UUID? {
        if let settled = facts.first(where: {
            guard let a = $0.value.agent,
                  AgentMonitor.namesSameAgent(agentID, a) else { return false }
            return leafIsOn(machineIn: agentID, leaf: $0.key)
        })?.key {
            return settled
        }
        return facts.first(where: { $0.value.candidateAgent == agentID })?.key
    }

    func leafID(forAgent agentID: String) -> UUID? {
        if let settled = facts.first(where: {
            guard let a = $0.value.agent,
                  AgentMonitor.namesSameAgent(agentID, a) else { return false }
            return leafIsOn(machineIn: agentID, leaf: $0.key)
        })?.key {
            // IT CAME BACK UNDER THE NAME IT LEFT UNDER, which is the far
            // side saying the session was still there.
            if facts[settled]?.rejoining == .undecided { facts[settled]?.rejoining = .rejoined }
            facts[settled]?.rejoinOffer = nil
            return settled
        }
        guard let candidate = facts.first(where: { $0.value.candidateAgent == agentID })?.key
        else { return nil }
        // IT REGISTERED, SO IT IS THE ONE. The other name named a session
        // that turned out not to be there, and keeping it would leave a
        // leaf answering to a name nothing is running under.
        facts[candidate]?.agent = agentID
        facts[candidate]?.candidateAgent = nil
        if facts[candidate]?.rejoining == .undecided {
            facts[candidate]?.rejoining = .restarted(.sessionGone)
        }
        // AND THAT NOTICE GETS NO OFFER. This branch is reached because a
        // name just registered against this leaf, which is a live child in
        // it; the plan the caller is about to compose describes the
        // session that is running here now, not one that is gone. Nilling
        // is done HERE rather than at the composing site because this is
        // the funnel every registration passes through, including the
        // `tool == "-"` and `"human"` ones the resume coordinator filters
        // out and which are live children all the same.
        facts[candidate]?.rejoinOffer = nil
        return candidate
    }

    /// Both names a pane may come back under, before either has spoken.
    func recordLeafCandidates(_ leafID: UUID?, settled: String?, candidate: String?) {
        guard let leafID else { return }
        facts[leafID, default: .init()].agent = settled
        facts[leafID, default: .init()].candidateAgent = candidate
    }

    func agentID(forLeaf leafID: UUID) -> String? {
        facts[leafID]?.agent
    }

    /// RFC-0008 identity upgrade: the hub renamed a pane's agent
    /// (pane id -> durable id); follow it so detection and badges stay
    /// attached to the same leaf.
    func remapLeafAgent(from oldID: String, to newID: String) {
        for (leaf, existing) in facts where existing.agent == oldID {
            facts[leaf]?.agent = newID
        }
    }

    /// Workbench gaze hook (RFC-0004 C-OWNERSHIP): fires when the human
    /// focuses a leaf that hosts an agent. The receiver (ContentView)
    /// decides whether a done→idle transition should be emitted — the
    /// hub's conditional acceptance bounds what the signal can do.
    var onAgentGaze: ((String) -> Void)?

    /// Agent hosted by the leaf the user is currently looking at, if any
    /// — for the app-activation gaze check (returning to the app while a
    /// done pane is already focused counts as seeing it).
    func visibleAgentID() -> String? {
        guard let leafID = visibleFocusedLeafID else { return nil }
        return facts[leafID]?.agent
    }

    // MARK: - Wake arming (RFC-0005 C-AUTHORITY)

    /// Leaves the human has armed for peer wake. Default OFF; arming is
    /// the human's act in the workbench UI — no hub message, CLI call,
    /// or traffic-derived configuration may set it. Kept as pane state
    /// so it rides the session snapshot when RFC-0006 restore lands
    /// (WI-2026-08-11-014).


    /// Disarm must cancel pending wake candidates immediately — the
    /// WakeCoordinator hooks this with the disarmed leaf's agent id.
    var onWakeDisarmed: ((String) -> Void)?

    func isWakeArmed(_ leafID: UUID) -> Bool {
        facts[leafID]?.wakeArmed == true
    }

    func setWakeArmed(_ leafID: UUID, _ armed: Bool) {
        if armed {
            facts[leafID, default: .init()].wakeArmed = true
        } else {
            guard facts[leafID]?.wakeArmed == true else { return }
            facts[leafID]?.wakeArmed = false
            if let agentID = facts[leafID]?.agent { onWakeDisarmed?(agentID) }
        }
    }

    // MARK: - Session snapshot (RFC-0006)

    /// Capture restorable state: layout, per-leaf host and cwd, armed
    /// bits, and resume plans (supplied by the owner — plans live outside
    /// the manager).
    ///
    /// EVERY WORKSPACE, LOCAL OR NOT. This wrote a full arrangement for
    /// local workspaces and a bare label+host for remote ones, which was
    /// right while nothing on the far side outlived the client: a restored
    /// remote layout would have pointed at dead ptys. The pty holder
    /// removes that premise ([[RFC-0015]] C-PERSIST), and the host is now
    /// a per-leaf fact so a mixed position persists as one.
    func snapshot(planFor: (UUID) -> ResumePlan?) -> WorkspaceSnapshot {
        var snap = WorkspaceSnapshot()
        for session in workspaces {
            var entry = WorkspaceSnapshot.SessionEntry(id: session.id, label: session.label)
            entry.isPinned = session.isPinned
            entry.isArchived = session.isArchived
            // AN ARCHIVED WORKSPACE'S TREE IS ALREADY WRITTEN DOWN — it is
            // what it was put away holding, and it has no live panes to
            // read one from.
            if let put = session.archivedTree {
                entry.root = put
                entry.focusedSlotIndex = session.archivedFocusSlot
            } else if let layout = session.layout {
                entry.root = snapshotNode(layout, planFor: planFor)
                entry.zoomedSlotIndex = zoomedSlotIndex(of: session)
                // The focused POSITION, counted over the positions that
                // survive the exec filter below — an index into the tree
                // as written, not as it stood.
                entry.focusedSlotIndex = focusedSlotIndex(of: session)
            }
            // AND THE PANES CLOSED OUT OF IT THAT ARE STILL RUNNING
            // ([[RFC-0015]] C-PANE-ARCHIVE). Not in the tree, so not reached
            // by the walk above — a store that stopped at the tree would
            // lose every one of them, and each is a live session nothing
            // would then name.
            entry.archivedPanes = session.archivedPanes.map {
                snapshotPane($0.pane, agentID: $0.agent, host: $0.host, planFor: planFor)
            }
            // AN EMPTY WORKSPACE IS STILL WRITTEN ([[RFC-0015]] C-EMPTY):
            // emptiness is a resting state, not a signal that the human
            // has finished with the place they keep their work.
            snap.workspaces.append(entry)
        }
        return snap
    }

    /// nil when nothing in the subtree survives — see the exec note.
    private func snapshotNode(_ node: SplitNode,
                              planFor: (UUID) -> ResumePlan?) -> WorkspaceSnapshot.Node? {
        switch node {
        case .slot(let slot):
            // RFC-0007 exec panes are machine scratch space whose owning
            // registration is definitively dead after a restart —
            // restoring one produces an unowned pane the human never
            // created, stripped of its machine-operated marker (found
            // live: a restored exec pane came back looking like an
            // ordinary shell). PER PANE now rather than per tab: an exec
            // pane stacked beside the human's own must not take theirs
            // with it.
            let kept = slot.panes.filter { !isExecLeaf($0.id) }
            guard !kept.isEmpty else { return nil }
            let active = kept.firstIndex { $0.id == slot.activePaneID } ?? 0
            return .slot(WorkspaceSnapshot.SlotEntry(
                panes: kept.map { snapshotPane($0, planFor: planFor) },
                activeIndex: active))
        case .split(let data):
            let first = snapshotNode(data.first, planFor: planFor)
            let second = snapshotNode(data.second, planFor: planFor)
            // A split with one surviving side collapses to it, exactly as
            // removing the last pane of a position would.
            guard let first else { return second }
            guard let second else { return first }
            return .split(
                direction: data.direction == .horizontal ? "horizontal" : "vertical",
                ratio: Double(data.ratio),
                first: first,
                second: second)
        }
    }

    /// `agentID` IS SUPPLIED FOR A PANE THAT HAS LEFT THE TREE. A leaf's
    /// facts are forgotten when it does, so a archived pane's name would
    /// be read as nil here and written as nil — and a row that comes back
    /// naming no agent is a live session nothing can address, which is the
    /// leak [[RFC-0015]] C-PANE-ARCHIVE exists to close. The row carries the
    /// name for exactly this reason.
    private func snapshotPane(_ pane: SplitNode.Pane,
                              agentID: String? = nil,
                              host: HostEntry? = nil,
                              planFor: (UUID) -> ResumePlan?) -> WorkspaceSnapshot.PaneEntry {
        WorkspaceSnapshot.PaneEntry(
            label: pane.label,
            userRenamed: pane.userRenamed,
            // AND THE PANE'S OWN ANSWER WHERE THE LEAF HAS NONE. Every
            // branch of `pwd(ofLeaf:)` asks about a leaf in the TREE, so
            // a pane that has left it — an archived one — reads as nil
            // here and is written as nil, and the directory is gone at
            // the next launch. The value still knows: it was written
            // when the pane was archived, for exactly this reason.
            pwd: pwd(ofLeaf: pane.id) ?? pane.workingDirectory,
            wakeArmed: isWakeArmed(pane.id),
            resumePlan: planFor(pane.id),
            // THE HOST, NOT THE CONNECTION. A connection is a live
            // object that does not survive a restart; the host is the
            // durable fact a restore re-acquires one from.
            hostID: host?.id ?? connections.connection(pane.connectionID)?.host?.id,
            // THE NAME THIS PANE'S HOLDER ANSWERS TO, so a reattach finds
            // the work instead of starting a second copy beside it — on
            // this machine as much as on any other ([[RFC-0014]] C-SCOPE).
            // It was kept for remote panes only, on the premise that a
            // local child does not survive; the holder is what made that
            // premise false, and a pane that comes back under a fresh name
            // leaves the session it had unreachable by the only client
            // that wanted it.
            agentID: agentID ?? facts[pane.id]?.agent,
            content: pane.content.kindOnly)
    }

    /// Workspaces whose remote panes have a connection nobody has dialled,
    /// for the caller to dial.
    ///
    /// RETURNED RATHER THAN DIALLED HERE: this type owns panes, not
    /// tunnels, and reaching for TunnelManager from inside it would put
    /// the connection logic in two places.
    ///
    /// NOT ONLY RESTORE'S. It was `restoredRemoteWorkspaces` while launch
    /// was the only way a workspace came back with released connections;
    /// unarchiving is the other, and it named none of the three functions
    /// that exist to dial — so a reopened remote workspace showed the dial
    /// spinner and never built a terminal ([[RFC-0015]] C-UNARCHIVE).
    private(set) var workspacesAwaitingDial: [UUID] = []

    /// TAKEN, NOT READ, so dialling twice is the same as dialling once.
    /// Both producers append and the consumer is a view that may run more
    /// than once.
    func takeWorkspacesAwaitingDial() -> [UUID] {
        defer { workspacesAwaitingDial = [] }
        return workspacesAwaitingDial
    }

    /// Whether any pane of this workspace is bound to a remote connection
    /// that is worth dialling. A FAILED connection is not: it has already
    /// said what happened and carries its own Reconnect.
    private func awaitsDial(_ workspace: Workspace) -> Bool {
        workspace.panes.contains { pane in
            guard let connection = connections.connection(pane.connectionID) else { return false }
            if case .failed = connection.state { return false }
            return !connection.isLocal
        }
    }

    /// Rebuild workspaces from a snapshot (fresh launch only). Every
    /// restored pane gets a FRESH run-wrapper command and agent id —
    /// restore resurrects layout and cwd, never presence (RFC-0006:
    /// registration remains the agent's act). Returns newPaneID →
    /// restored entry so the resume engine can run plans.
    @discardableResult
    func restore(from snap: WorkspaceSnapshot, hostStore: HostStore?) -> [UUID: WorkspaceSnapshot.PaneEntry] {
        guard workspaces.isEmpty else { return [:] }
        workspacesAwaitingDial = []
        var leafMeta: [UUID: WorkspaceSnapshot.PaneEntry] = [:]
        // RECONNECTING IS NOT RESUMING. C-RESUME-RESTORE governs what may
        // be TYPED into a restored pane — re-attach, never prompt — and
        // this code once cited it to justify not opening the connection at
        // all, which the clause does not say. Reopening a host the human
        // had open is the same authority class as restoring the window it
        // was in; running their agent's incantation is not, and that half
        // stays gated exactly as before.
        for sessionEntry in snap.workspaces {
            var session = Workspace(id: sessionEntry.id ?? UUID(),
                                    label: sessionEntry.label,
                                    connectionID: connections.localID)
            session.isPinned = sessionEntry.isPinned
            // PUT AWAY STAYS PUT AWAY. Building its panes would dial every
            // host it names, which is what archiving reclaimed.
            // LISTED, NOT CONNECTED ([[RFC-0015]] C-PANE-ARCHIVE). These are
            // rebuilt as VALUES and never launched: a workbench that
            // reattached every archived pane at launch would spend, at
            // the moment a human is waiting for a window, the cost of work
            // they had already put out of sight.
            session.archivedPanes = sessionEntry.archivedPanes.map { entry in
                var pane = SplitNode.Pane(
                    label: entry.label,
                    content: entry.content,
                    // THE DIRECTORY IT WAS IN, so returning it opens where
                    // the work is rather than at home.
                    workingDirectory: entry.pwd,
                    connectionID: connections.localID)
                pane.userRenamed = entry.userRenamed
                return ArchivedPane(
                    pane: pane,
                    agent: entry.agentID,
                    host: entry.hostID.flatMap { id in hostStore?.hosts.first { $0.id == id } },
                    // THE LABEL SURVIVES, because C-PERSIST already carries
                    // it: a pane's own name and whether the human set it
                    // are the pane's durable state.
                    title: entry.label,
                    // WHEN IT WAS SET ASIDE IS NOT WRITTEN, so a restored
                    // row reads as archived at the restart. The list
                    // orders by it and nothing else turns on it; recording
                    // the true moment is a field this store does not have
                    // and the ordering it would buy is worth less than a
                    // second shape to keep in step.
                    at: Date())
            }
            if sessionEntry.isArchived {
                session.archivedTree = sessionEntry.root ?? .slot(.init(panes: []))
                session.archivedFocusSlot = sessionEntry.focusedSlotIndex
                workspaces.append(session)
                continue
            }
            if let root = sessionEntry.root {
                // A WORKSPACE THAT WAS SAVED EMPTY COMES BACK EMPTY
                // ([[RFC-0015]] C-EMPTY), but one whose whole tree could
                // not be rebuilt is dropped rather than resurrected as a
                // blank container the human cannot account for. C-RESTORE
                // wants the panes kept and REPORTED instead, and that is
                // [[WI-2026-08-17-025]]'s to deliver.
                guard let node = rebuildNode(root, hostStore: hostStore, into: &leafMeta)
                else { continue }
                session.setLayout(node)
            }
            if let idx = sessionEntry.focusedSlotIndex, idx < session.slots.count {
                session.focus(session.slots[idx].activePaneID)
            }
            // AFTER FOCUS: focusing a pane outside the zoomed position
            // would end the zoom, so the order here is the rule's order.
            if let idx = sessionEntry.zoomedSlotIndex { session.zoom(slotAt: idx) }
            // ONE DIAL PER HOST, however many panes name it — the
            // connection is already shared by the time this is read.
            // A HOST THAT IS GONE IS NOT DIALLED. Its pane comes back and
            // says so, but there is nothing to dial towards: the snapshot
            // records a host's identity, not its address.
            if awaitsDial(session) { workspacesAwaitingDial.append(session.id) }
            workspaces.append(session)
        }
        // SOMEWHERE TO WORK, whatever was on disk. A store with no
        // workspaces in it — a first run, or one whose file was discarded
        // as an unknown shape — must not leave the human looking at
        // nothing at all ([[RFC-0015]] C-EMPTY: an empty workspace is a
        // resting state, and a workbench with no workspace is not).
        if workspaces.isEmpty {
            workspaces.append(Workspace(label: "Local", connectionID: connections.localID))
        }
        activeWorkspaceID = workspaces.first?.id
        syncConnectionReferences()
        // Re-arm restored leaves (RFC-0005 C-AUTHORITY persistence), and
        // hand each notice the offer the snapshot recorded for it. THE
        // RESTORE IS THE ONLY WRITER: a restart the workbench reported is
        // the one state C-RESUME-RESTORE offers in, and this is where it
        // is reported. Every restored leaf gets a fresh id (SplitTree),
        // so nothing in memory could have carried the plan across.
        // THE REJOIN OFFER ONLY. The armed bit used to be re-applied here
        // as well, which meant unarchiving — which rebuilds through the
        // same code and does not run this loop — brought a pane back
        // disarmed ([[recordRebuilt]]).
        for (leafID, meta) in leafMeta {
            if facts[leafID]?.rejoining?.isWorthSaying == true {
                facts[leafID]?.rejoinOffer = meta.resumePlan
            }
        }
        return leafMeta
    }

    /// Rebuild one workspace's tree, binding each pane to the connection
    /// for the host it was persisted with. nil when nothing in the subtree
    /// could be rebuilt.
    ///
    /// A PANE WHOSE HOST IS GONE FROM THE STORE IS KEPT AND REPORTED —
    /// bound to a connection that says the machine is no longer configured
    /// ([[ConnectionRegistry]] `acquireLost`). Deleting a host is not an
    /// instruction to discard the layouts that referenced it, and
    /// that is [[WI-2026-08-17-025]]'s to deliver rather than something
    /// this quietly half-does.
    private func rebuildNode(_ node: WorkspaceSnapshot.Node, hostStore: HostStore?,
                             into leafMeta: inout [UUID: WorkspaceSnapshot.PaneEntry]) -> SplitNode? {
        switch node {
        case .slot(let entry):
            // THE ACTIVE INDEX COUNTS OVER WHAT CAME BACK. A pane whose
            // host is gone from the store is dropped, and an index read
            // against the stored stack would then put its neighbour in
            // front — silently, and only for the human who deleted a host.
            var panes: [SplitNode.Pane] = []
            var active: UUID?
            for (i, paneEntry) in entry.panes.enumerated() {
                guard let pane = rebuildPane(paneEntry, hostStore: hostStore, into: &leafMeta)
                else { continue }
                if i == entry.activeIndex { active = pane.id }
                panes.append(pane)
            }
            guard !panes.isEmpty else { return nil }
            return .slot(SplitNode.Slot(panes: panes, activePaneID: active))
        case .split(let direction, let ratio, let first, let second):
            let first = rebuildNode(first, hostStore: hostStore, into: &leafMeta)
            let second = rebuildNode(second, hostStore: hostStore, into: &leafMeta)
            // A split with one surviving side collapses to it, exactly as
            // removing a pane would.
            guard let first else { return second }
            guard let second else { return first }
            return .split(SplitNode.SplitData(
                direction: direction == "vertical" ? .vertical : .horizontal,
                first: first, second: second, ratio: CGFloat(ratio)))
        }
    }

    /// THE FOCUSED POSITION, counted over the positions that survive the
    /// exec filter — an index into the tree AS WRITTEN, not as it stands.
    /// Archive writes the same tree the snapshot does, so it counts the
    /// same way ([[RFC-0015]] C-ARCHIVE).
    private func focusedSlotIndex(of session: Workspace) -> Int? {
        guard let focused = session.focusedPaneID else { return nil }
        return session.slots
            .filter { $0.panes.contains { !isExecLeaf($0.id) } }
            .firstIndex { $0.panes.contains { $0.id == focused } }
    }

    /// The zoomed POSITION, counted the same way as the focused one.
    private func zoomedSlotIndex(of session: Workspace) -> Int? {
        guard let zoomed = session.zoomedSlotID else { return nil }
        return session.slots
            .filter { $0.panes.contains { !isExecLeaf($0.id) } }
            .firstIndex { $0.id == zoomed }
    }

    private func rebuildPane(_ entry: WorkspaceSnapshot.PaneEntry, hostStore: HostStore?,
                             into leafMeta: inout [UUID: WorkspaceSnapshot.PaneEntry]) -> SplitNode.Pane? {
        // A NON-TERMINAL PANE HAS NO CHILD TO SPAWN. It comes back
        // showing what it was showing, on the machine it was on; a
        // restore that turned a file browser into a terminal has not
        // restored the arrangement ([[RFC-0015]] C-CONTENT).
        let result: PaneLaunch?
        let connectionID: UUID
        var rejoining: Rejoining?
        if let hostID = entry.hostID {
            guard let host = hostStore?.hosts.first(where: { $0.id == hostID }) else {
                // KEPT WITH ITS BINDING, NOT DROPPED. Deleting a host is
                // not an instruction to discard the arrangements that
                // named it, and a pane that silently failed to come back
                // is one the human cannot act on ([[WI-2026-08-17-025]]).
                connectionID = connections.acquireLost(
                    hostID: hostID, reason: "this machine is no longer in your hosts")
                var lost = SplitNode.Pane(
                    label: entry.label, content: entry.content.kindOnly,
                    workingDirectory: entry.pwd, connectionID: connectionID)
                lost.userRenamed = entry.userRenamed
                recordRebuilt(lost.id, from: entry, into: &leafMeta)
                return lost
            }
            connectionID = connections.acquire(host: host).id
            // REATTACH TO WHAT THIS PANE WAS, rather than opening a
            // second holder beside it.
            result = TunnelManager.shared?.connectCommand(for: host, agentID: entry.agentID)
            // ONLY THE OPT-OUT IS KNOWN ON THIS SIDE; the rest of the
            // answer is on the far side and arrives with the registration.
            rejoining = Rejoining.remote(recorded: entry.agentID, machine: host.label,
                                         durable: host.durableSessions)
        } else {
            connectionID = connections.localID
            // THE NAME IT PERSISTED, not a fresh one — the local half of
            // the reattach the remote branch above already does.
            result = TunnelManager.shared?.localCommand(agentID: entry.agentID)
            // THE ANSWER THE COMMAND WAS BUILT FROM, not a second asking.
            // Asked again here, this consulted the durability opt-out
            // while the name on that command line had been chosen without
            // it, so the notice and the name could disagree about the
            // same pane ([[PaneLaunch.rejoining]]).
            rejoining = result?.rejoining ?? .restarted(.nothingRecorded)
        }
        // The agent id is the far side's ADDRESS, not its presence:
        // restore resurrects layout and cwd and never registration,
        // which remains the agent's own act (RFC-0006).
        let content: SplitNode.PaneContent = entry.content.isTerminal
            ? .terminal(command: result?.command) : entry.content
        var pane = SplitNode.Pane(
            label: entry.label, content: content, workingDirectory: entry.pwd,
            connectionID: connectionID)
        pane.userRenamed = entry.userRenamed
        if content.isTerminal, let launch = result {
            // BOTH NAMES, until one of them registers ([[PaneLaunch]]).
            // A remote pane is handed the name to return to and the name
            // to start under, and picks over there; this leaf answers to
            // either until the registration says which.
            recordLeafCandidates(pane.id, settled: launch.agentID,
                                 candidate: launch.candidateID)
            facts[pane.id]?.rejoining = rejoining
        }
        recordRebuilt(pane.id, from: entry, into: &leafMeta)
        return pane
    }

    // MARK: - Attention (WI-2026-08-09-021)

    /// Leaves whose agent/process asked for human attention (bell, OSC
    /// notification, or a semantic agent_status). Cleared by focusing the
    /// leaf. Runtime-only.


    /// THE ORDER THE SIDEBAR LISTS THEM IN ([[RFC-0015]] C-ARCHIVE).
    ///
    /// PINNED FIRST, PUT AWAY LAST, and everything else in the order the
    /// human dragged it into. That is the WHOLE of what pinning does: it
    /// is not a second lifetime rule, so a pinned workspace holds and
    /// releases exactly what an unpinned one does.
    var orderedWorkspaces: [Workspace] {
        let open = workspaces.filter { !$0.isArchived }
        return open.filter(\.isPinned) + open.filter { !$0.isPinned }
            + workspaces.filter(\.isArchived)
    }

    /// WHAT IS INSIDE A WORKSPACE THAT IS PUT AWAY — read from the
    /// arrangement it was archived holding, since it has no live panes to
    /// count ([[RFC-0015]] C-ARCHIVE: it can be reopened "without the
    /// human remembering what was in it").
    func archivedSummary(_ workspace: Workspace) -> String {
        guard let tree = workspace.archivedTree else { return "" }
        var slots = 0, panes = 0
        var stack = [tree]
        while let node = stack.popLast() {
            switch node {
            case .slot(let slot):
                slots += 1
                panes += slot.panes.count
            case .split(let split):
                stack.append(split.first)
                stack.append(split.second)
            }
        }
        // A PANE IS A TAB and a slot is a split, which is what the tab
        // strip draws: every position wears a bar, and the panes stacked
        // in one are its tabs.
        let tabs = "\(panes) tab" + (panes == 1 ? "" : "s")
        return slots > 1 ? "\(tabs) · \(slots) splits" : tabs
    }

    /// WHAT TO TELL THE HUMAN ABOUT THIS PANE'S RETURN, if anything
    /// ([[RFC-0015]] C-HONESTY). A pane that rejoined got what it was
    /// promised, and a notice saying so is the noise that teaches people
    /// to dismiss notices unread.
    func rejoinNotice(_ leafID: UUID) -> Rejoining? {
        guard let told = facts[leafID]?.rejoining, told.isWorthSaying else { return nil }
        return told
    }

    /// Read. It is not said twice.
    /// What the notice on this leaf may offer to type, if anything.
    ///
    /// The offer is gated on the notice as well as on its own presence: a
    /// notice the human has dismissed takes its offer with it, so the two
    /// cannot be observed apart.
    func rejoinOffer(_ leafID: UUID) -> ResumePlan? {
        guard rejoinNotice(leafID) != nil else { return nil }
        return facts[leafID]?.rejoinOffer
    }

    func dismissRejoinNotice(_ leafID: UUID) {
        facts[leafID]?.rejoining = nil
        facts[leafID]?.rejoinOffer = nil
    }

    var attentionCount: Int { facts.values.filter(\.needsAttention).count }

    /// Whether one leaf is waiting to be looked at.
    func isAwaitingAttention(_ leafID: UUID) -> Bool {
        facts[leafID]?.needsAttention == true
    }

    /// The leaf the user is CURRENTLY looking at: the focused pane of the
    /// active workspace.
    var visibleFocusedLeafID: UUID? {
        activeWorkspace?.focusedPaneID
    }

    /// Mark a leaf as needing attention. A signal on the leaf the user is
    /// already looking at is ignored — bells fire for output the user is
    /// watching happen.
    func markLeafAttention(_ leafID: UUID) {
        guard leafID != visibleFocusedLeafID else { return }
        facts[leafID, default: .init()].needsAttention = true
    }

    func clearLeafAttention(_ leafID: UUID) {
        facts[leafID]?.needsAttention = false
    }

    func workspaceNeedsAttention(_ session: Workspace) -> Bool {
        session.panes.contains { isAwaitingAttention($0.id) }
    }

    // MARK: - Shell-driven titles (WI-2026-08-09-017)

    /// What the shell called itself, if it said.
    func reportedTitle(ofLeaf leafID: UUID) -> String? { facts[leafID]?.title }

    /// Record a shell title for a leaf; empty/whitespace clears it.
    func leafDidUpdateTitle(_ leafID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            facts[leafID]?.title = nil
        } else {
            facts[leafID, default: .init()].title = String(trimmed.prefix(80))
        }
    }

    /// Tab label resolution: manual rename wins; else this pane's own
    /// shell title; else the stored default ("Shell N").
    ///
    /// ITS OWN, not the focused one's. The label belonged to a tab, which
    /// had to pick a leaf to speak for it; a pane speaks for itself.
    func displayLabel(for pane: SplitNode.Pane) -> String {
        if pane.userRenamed { return pane.label }
        return facts[pane.id]?.title ?? pane.label
    }

    /// THE OTHER HALF. A tab shows identity (the human's name) or state
    /// (the shell's live title), never both — so whichever it is not
    /// showing goes in the tooltip. For a renamed pane that is the live
    /// title, which the rename otherwise hides entirely; for the rest it
    /// is the full title, which equal-width tabs truncate
    /// ([[WI-2026-09-02-002]]).
    func tabTooltip(for pane: SplitNode.Pane) -> String {
        let name: String
        if pane.userRenamed, let live = facts[pane.id]?.title, live != pane.label { name = live }
        else { name = displayLabel(for: pane) }
        // BOTH ACTS, NAMED BEFORE EITHER HAPPENS ([[RFC-0015]]
        // C-PANE-ARCHIVE): the ✕ on a terminal ends its session, and the
        // same ✕ with Option puts it away still running.
        guard pane.content.isTerminal else { return name }
        return name + "\n✕ closes and ends the session · ⌥✕ archives it, still running"
    }

    /// IS A COMMAND RUNNING HERE — the shell's cursor is not at a prompt.
    /// Answered by the core from its OSC 133 marks, which is what
    /// `needs_confirm_quit` means underneath; no process tree is walked.
    func isBusy(_ leafID: UUID) -> Bool {
        guard let surface = GhosttyApp.shared?.surface(forLeaf: leafID) else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func removeWorkspace(_ session: Workspace) {
        // ENDING THE AGENTS FIRST, because it reads `facts[leaf.id]?.agent`
        // and `forgetPanes` is what removes those facts.
        endRemoteWorkspace(session)
        // AND THE PANES ARE FORGOTTEN, which closing a workspace did not
        // do. Archiving one did — the same panes, the same end state — so
        // a closed workspace left its pool tenants held and its per-leaf
        // state behind, where an archived one did not
        // ([[WI-2026-08-30-007]]).
        forgetPanes(of: session)
        workspaces.removeAll { $0.id == session.id }
        // COUNTED AFTER IT IS OUT OF THE LIST, the way a pane close counts
        // after its pane is out of the tree.
        syncConnectionReferences()
        if activeWorkspaceID == session.id {
            activeWorkspaceID = workspaces.last?.id
        }
    }

    // MARK: - Ending remote agents (WI-2026-08-17-001)

    /// How a remote agent's session is ended.
    ///
    /// A closure because the ssh is not observable from a test, and what
    /// needs testing here is not the kill — it is WHICH agents a given
    /// close ends, which was the whole defect.
    /// WHETHER THE FAR SIDE ENDED IT, because an end nobody can tell
    /// failed is an end nobody can retry ([[WI-2026-09-03-010]]). This
    /// returned nothing and the caller recorded success either way, so a
    /// press that reached no connection at all looked exactly like one
    /// that worked.
    /// STARTED HERE, ANSWERED LATER. Returning the task rather than a
    /// bare `Void` is what lets the caller learn whether the far side
    /// ended it — an end nobody can tell failed is an end nobody can
    /// retry ([[WI-2026-09-03-010]]) — while the STARTING stays
    /// synchronous, which is what a press is.
    var remoteAgentEnder: (HostEntry, String) -> Task<Bool, Never> = { host, agentID in
        guard let connection = TunnelManager.shared?.connection(for: host)
        else { return Task { false } }
        return Task.detached(priority: .utility) {
            RemoteAgentSession.kill(connection: connection, agentID: agentID)
        }
    }

    /// How a LOCAL agent's session is ended — the same `synapty end` a
    /// remote one gets, run here ([[ADR-0019]]: one answer for every
    /// machine). A closure for the same reason `remoteAgentEnder` is one.
    var localAgentEnder: (String) -> Task<Bool, Never> = { agentID in
        guard let binary = SynaptyBinary.resolve() else { return Task { false } }
        return Task.detached(priority: .utility) {
            // `runQuiet` HAS ALWAYS ANSWERED THIS. The answer was
            // discarded with `_ =`.
            SubprocessRunner.runQuiet(executable: binary, arguments: ["end", "--id", agentID], timeout: 10)
        }
    }

    /// End one agent wherever it runs: on a host through its connection,
    /// on this Mac directly. Fire-and-forget, for the close cascades that
    /// cannot wait on it; `endAgentAwaiting` is the same work with the
    /// answer kept.
    private func endAgent(_ agentID: String, host: HostEntry?) {
        guard let started = startEnding(agentID, host: host) else { return }
        Task { await settleEnding(agentID, host: host, started) }
    }

    /// ASKED ONCE WHILE IT IS IN FLIGHT, AND AGAIN IF IT FAILED.
    ///
    /// The dedupe used to be a single set recorded BEFORE the attempt, so
    /// it did two jobs badly: it stopped the cascade from spending a
    /// second ssh, and it also stopped every later attempt after a first
    /// one that had reached nothing at all. A holder wedged in its own
    /// teardown answers `sessions` while refusing to die
    /// ([[WI-2026-09-03-007]]), so the row came back from every poll and
    /// pressing End again did nothing for the rest of the run
    /// ([[WI-2026-09-03-010]]). Two sets: one for what is in flight, one
    /// for what the far side confirmed.
    @discardableResult
    private func endAgentAwaiting(_ agentID: String, host: HostEntry?) async -> Bool {
        guard let started = startEnding(agentID, host: host) else {
            return endedAgents.contains(agentID)
        }
        return await settleEnding(agentID, host: host, started)
    }

    /// Ask, unless this agent is already ended or already being asked.
    /// nil means nothing was started and nothing is owed an answer.
    private func startEnding(_ agentID: String, host: HostEntry?) -> Task<Bool, Never>? {
        if endedAgents.contains(agentID) { return nil }
        guard endingAgents.insert(agentID).inserted else { return nil }
        return host.map { remoteAgentEnder($0, agentID) } ?? localAgentEnder(agentID)
    }

    @discardableResult
    private func settleEnding(_ agentID: String, host: HostEntry?,
                              _ started: Task<Bool, Never>) async -> Bool {
        let ended = await started.value
        endingAgents.remove(agentID)
        guard ended else { return false }
        endedAgents.insert(agentID)
        // THE ROW GOES WHEN THE SESSION DOES, and not a moment before.
        // Removing it on the way out made a failed end look like a
        // successful one until the next poll put the row back.
        if let host { remoteSessions[host.id]?.removeAll { $0.name == agentID } }
        return true
    }

    private func endAgent(ofLeaf leaf: SplitNode.Pane) {
        guard let agentID = facts[leaf.id]?.agent else { return }
        endAgent(agentID, host: connections.connection(leaf.connectionID)?.host)
    }

    /// Agents the far side CONFIRMED it ended. Closing the last pane
    /// closes nothing else, but a workspace close and a pane close can
    /// both name the same agent; without this the cascade spends a second
    /// ssh saying what the first one said.
    private var endedAgents: Set<String> = []

    /// Agents an end has been asked for and not yet answered. The other
    /// half of that dedupe, and the half that CLEARS ([[endAgentAwaiting]]).
    private var endingAgents: Set<String> = []

    private func endRemoteAgents(_ agentIDs: [String], host: HostEntry) {
        for id in agentIDs { endAgent(id, host: host) }
    }

    /// EVERY PANE IS ITS OWN REMOTE SHELL. A second pane, and every split,
    /// calls `connectCommand` again and gets a fresh agent id — so each
    /// holds a holder of its own, under its own id. The ids live only
    /// in the leaves' facts; the session carried just the one it was dialled
    /// with, which is why ending that one left the rest detached and
    /// unaddressable.
    private func endRemoteAgents(ofLeaves leaves: [SplitNode.Pane]) {
        for leaf in leaves {
            guard let host = connections.connection(leaf.connectionID)?.host,
                  let agentID = facts[leaf.id]?.agent else { continue }
            endRemoteAgents([agentID], host: host)
        }
    }

    /// A remote session the human has closed does not outlive the closing.
    ///
    /// Every caller is a human's own act — the sidebar's Close Session,
    /// and closing a pane. Everything the holder is there for is what the
    /// human did NOT choose: a quit, a dropped link, a crash. Those still
    /// reattach, now that the id survives a restart.
    private func endRemoteWorkspace(_ session: Workspace) {
        // EACH PANE WITH ITS OWN MACHINE. A workspace may hold panes on
        // several hosts, so there is no one host to end them all against
        // — the pane names both the agent and where it runs.
        endRemoteAgents(ofLeaves: session.panes)
    }

    /// Switch to session by 1-based index (for Cmd+1–9).
    func activateWorkspaceByIndex(_ index: Int) {
        guard index >= 1, index <= workspaces.count else { return }
        activeWorkspaceID = workspaces[index - 1].id
    }

    // MARK: - Moving through a position's stack

    /// Bring the next pane of the focused position to the front — what
    /// "next tab" means when a tab is what a position with several panes
    /// shows.
    func activateNextPane() {
        stepThroughStack(by: 1)
    }

    func activatePreviousPane() {
        stepThroughStack(by: -1)
    }

    private func stepThroughStack(by delta: Int) {
        guard let sIdx = activeWorkspaceIndex,
              let slot = workspaces[sIdx].focusedSlot,
              slot.panes.count > 1,
              let here = slot.panes.firstIndex(where: { $0.id == slot.activePaneID })
        else { return }
        let next = (here + delta + slot.panes.count) % slot.panes.count
        bringToFront(slot.panes[next].id, in: sIdx)
    }

    // MARK: - Pane management

    func addPaneToActiveWorkspace() {
        guard let sIdx = activeWorkspaceIndex else { return }
        // A NEW PANE JOINS THE MACHINE THE HUMAN IS LOOKING AT, because a
        // workspace no longer has one of its own.
        let connectionID = connectionForNewPane(in: workspaces[sIdx])
        // Generate a new command with unique agent ID for every pane.
        let r = connections.connection(connectionID)?.host.map {
            TunnelManager.shared?.connectCommand(for: $0)
        } ?? TunnelManager.shared?.localCommand()
        let pane = SplitNode.Pane(label: "Shell \(workspaces[sIdx].panes.count + 1)",
                                  command: r?.command, connectionID: connectionID)
        place(pane, in: sIdx)
        recordLeafAgent(pane.id, r?.agentID)
        syncConnectionReferences()
    }

    /// Put a new pane where the human is looking: into the focused
    /// position's stack — which is what a new tab IS — or as the
    /// workspace's first position when there is nothing there yet.
    private func place(_ pane: SplitNode.Pane, in sIdx: Int) {
        if let layout = workspaces[sIdx].layout, let slot = workspaces[sIdx].focusedSlot {
            workspaces[sIdx].setLayout(layout.stack(pane, intoSlot: slot.id))
        } else {
            workspaces[sIdx].setLayout(.slot(SplitNode.Slot(pane: pane)))
        }
        workspaces[sIdx].focus(pane.id)
    }

    /// What a leaf is showing, or nil if there is no such leaf.
    func leafContent(_ leafID: UUID) -> SplitNode.PaneContent? {
        leafData(leafID)?.content
    }

    /// Open a pane of any kind in a workspace, on the machine the human is
    /// looking at ([[RFC-0015]] C-CONTENT).
    ///
    /// A file pane and a services pane are views OF a machine, so they
    /// join the connection the focused pane is on rather than opening one
    /// or defaulting to local.
    ///
    /// A BROWSER LEAF IS THE EXCEPTION AND TAKES THE LOCAL CONNECTION
    /// WHEREVER IT IS OPENED. C-CONTENT's table gives that row "the local
    /// connection, ALWAYS", and says in its own text that this is a
    /// stipulation rather than a derivation — so it is enforced here,
    /// where a pane's connection is decided, rather than left to each
    /// caller to remember.
    /// WHICH MACHINE A NEW PANE LOOKS AT.
    ///
    /// The default is the one the human is looking at, which is what a new
    /// pane has always meant. A caller that KNOWS the machine names it:
    /// the status bar's globe counts exposures everywhere and must be able
    /// to take the human to the one it counted ([[WI-2026-08-28-009]]).
    /// `.machine(nil)` is this Mac, and is not the same as not saying.
    ///
    /// It carries the HOST and not its id: this type is handed a store per
    /// call rather than holding one, so an id here would be a lookup it
    /// cannot do.
    enum PaneMachine: Equatable {
        case whereTheHumanIsLooking
        case machine(HostEntry?)
    }

    @discardableResult
    func addPane(content: SplitNode.PaneContent, toWorkspace workspaceID: UUID,
                 on machine: PaneMachine = .whereTheHumanIsLooking) -> UUID? {
        guard let sIdx = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let connectionID: UUID
        if content.demandsLocalConnection {
            connectionID = connections.localID
        } else {
            switch machine {
            case .whereTheHumanIsLooking:
                connectionID = connectionForNewPane(in: workspaces[sIdx])
            case .machine(nil):
                connectionID = connections.localID
            case .machine(let host?):
                connectionID = connections.acquire(host: host).id
            }
        }
        // A terminal needs a command minted for it; the other kinds need
        // nothing but the machine they are looking at.
        var content = content
        var agentID: String?
        if content.isTerminal {
            let r = connections.connection(connectionID)?.host.map {
                TunnelManager.shared?.connectCommand(for: $0)
            } ?? TunnelManager.shared?.localCommand()
            content = .terminal(command: r?.command)
            agentID = r?.agentID
        }
        let label: String
        switch content {
        case .terminal: label = "Shell \(workspaces[sIdx].panes.count + 1)"
        case .files: label = "Files"
        case .services: label = "Services"
        case .browser: label = "Browser"
        }
        let pane = SplitNode.Pane(label: label, content: content, connectionID: connectionID)
        place(pane, in: sIdx)
        recordLeafAgent(pane.id, agentID)
        syncConnectionReferences()
        return pane.id
    }

    /// Exec panes (RFC-0007 C-EXEC-SCOPE): leaf ids that are machine-
    /// operated exec panes → the owning agent id, for the UI marker.
    /// Runtime-only; exec panes do not persist (they are scratch).
    func isExecLeaf(_ leafID: UUID) -> Bool { facts[leafID]?.execOwner != nil }
    func execOwner(_ leafID: UUID) -> String? { facts[leafID]?.execOwner }

    /// Open an exec pane (RFC-0007): a new pane in the active workspace
    /// running a plain LOCAL shell, marked machine-operated + owner.
    /// Returns the leaf id, nil when there is no workspace to host it.
    func newExecTab(handle: String, owner: String, cwd: String?) -> UUID? {
        // ON THE LOCAL CONNECTION, in whichever workspace is active. This
        // required the workspace itself to be "local", which is no longer
        // a property one has — an exec pane is local because RFC-0007
        // makes it machine scratch space, not because of its neighbours.
        guard let sIdx = activeWorkspaceIndex,
              let r = TunnelManager.shared?.localCommand()
        else { return nil }
        let pane = SplitNode.Pane(
            label: "exec:\(owner)", command: r.command,
            workingDirectory: (cwd?.isEmpty == false) ? cwd : nil,
            connectionID: connections.localID)
        place(pane, in: sIdx)
        recordLeafAgent(pane.id, r.agentID)
        facts[pane.id, default: .init()].execOwner = owner
        syncConnectionReferences()
        return pane.id
    }

    func closeExecPane(leafID: UUID) {
        leafDidClose(leafID)
    }


    /// Close a pane the human closed. Its agent ends with it — against the
    /// machine ITS pane names.
    ///
    /// A WORKSPACE SURVIVES BECOMING EMPTY ([[RFC-0015]] C-WORKSPACE).
    /// Closing the last pane used to delete the container, so finishing
    /// the work destroyed the place it was kept. Its death is the human's
    /// explicit act and nothing else.
    /// CLOSING A PANE SETS IT ASIDE ([[RFC-0015]] C-PANE-ARCHIVE).
    ///
    /// IT USED TO END A REMOTE AGENT AND NOT A LOCAL ONE — two answers to
    /// the question [[RFC-0014]] C-DETACH requires one answer to, decided
    /// by which machine the pane was on and visible from neither gesture.
    /// The local half leaked: five live holders against one pane, oldest
    /// just under three days, each holding a login shell nothing named.
    ///
    /// Neither answer now. The child keeps running, the client detaches,
    /// and the pane is listed until the human returns to it or ends it.
    /// CLOSE A PANE: end what runs in it, and take it out of the layout
    /// ([[RFC-0015]] C-PANE-ARCHIVE, [[ADR-0019]]). ONE ANSWER FOR EVERY
    /// MACHINE — a local pane's holder is ended the same way a remote
    /// one's is, because the gesture cannot show which machine a pane is
    /// on. The connection reference goes with the pane and C-RELEASE's
    /// grace period decides the rest: closing is the churn that period
    /// exists to absorb.
    func closePane(_ paneID: UUID) {
        guard let sIdx = workspaceIndex(containing: paneID),
              let pane = workspaces[sIdx].layout?.findPane(paneID) else { return }
        if pane.content.isTerminal, facts[paneID]?.takenByAnother != true {
            endAgent(ofLeaf: pane)
        }
        detach(paneID, in: sIdx)
        syncConnectionReferences()
    }

    /// ARCHIVE A PANE: it leaves the layout, what runs in it keeps
    /// running, and it stays listed under this workspace until it is
    /// unarchived or ended ([[RFC-0015]] C-PANE-ARCHIVE).
    func archivePane(_ paneID: UUID) {
        guard let sIdx = workspaceIndex(containing: paneID),
              let pane = workspaces[sIdx].layout?.findPane(paneID) else { return }
        // ONLY WHAT HAS SOMETHING TO KEEP. Every other kind holds nothing
        // that outlives the closing, and a list full of rows that cost
        // nothing to make again is one a human stops reading.
        // A DISPLACED PANE HAS NO CLIENT LEFT TO ARCHIVE. Its child
        // exited when another client took the session, which is the same
        // ground on which a pane whose shell exited closes rather than
        // becoming a row. The session itself is not lost: it is attached
        // to whoever took it, and its host lists it ([[RFC-0014]] C-END).
        if pane.content.isTerminal, facts[paneID]?.takenByAnother != true {
            // WHERE THE WORK IS, TAKEN WHILE IT IS STILL KNOWN — the same
            // reading the agent and the title get on the two lines below,
            // and for the same reason. `detach` forgets this leaf's facts
            // a moment from now, and `pwd(ofLeaf:)`'s own fallback cannot
            // stand in: it reads the leaf out of the TREE, which is what
            // the pane is about to leave.
            var put = pane
            put.willReopen(in: pwd(ofLeaf: paneID) ?? pane.workingDirectory)
            workspaces[sIdx].archivedPanes.append(
                .init(pane: put, agent: facts[paneID]?.agent,
                      host: connections.connection(pane.connectionID)?.host,
                      title: displayLabel(for: pane), at: Date()))
        }
        detach(paneID, in: sIdx)
        // A DECISION THE HUMAN STATED releases at once, as archiving a
        // workspace does ([[RFC-0015]] C-RELEASE); only what nothing open
        // still references goes.
        let before = connections.connections.map(\.id)
        syncConnectionReferences()
        for id in before { connections.releaseNow(id) }
    }

    /// Every archived pane, newest first — what the human put away last
    /// is what they are likeliest to want back.
    var archivedPanes: [ArchivedPane] {
        workspaces.flatMap(\.archivedPanes).sorted { $0.at > $1.at }
    }

    /// WHAT EACH CONNECTED HOST SAYS IT IS HOLDING, keyed by host id.
    ///
    /// [[RFC-0014]] C-END requires every holder on a host to be
    /// enumerable there, and the far side already answers; nothing here
    /// had ever asked, so a holder no workspace named was invisible from
    /// this side while running perfectly well over there.
    ///
    /// KEPT UNTIL A BETTER ANSWER ARRIVES. A host that could not be
    /// reached has not said it holds nothing, and blanking its rows would
    /// turn a dropped link into a claim about that machine.
    private(set) var remoteSessions: [UUID: [RemoteSessions.Session]] = [:]

    private var sessionQueriesInFlight: Set<UUID> = []

    /// Ask every host something is open on. One round trip each, over the
    /// master already dialled.
    func refreshRemoteSessions() {
        for connection in connections.connections {
            guard let host = connection.host,
                  !sessionQueriesInFlight.contains(host.id),
                  let live = TunnelManager.shared?.connection(for: host)
            else { continue }
            sessionQueriesInFlight.insert(host.id)
            Task.detached(priority: .utility) {
                let rows = RemoteSessions.query(connection: live)
                await MainActor.run {
                    self.sessionQueriesInFlight.remove(host.id)
                    // KEPT ONLY WHEN THE HOST DID NOT ANSWER. An empty
                    // answer is an answer — the transition a human is
                    // watching for — and distrusting it left a host's
                    // last row on screen for the life of the app
                    // ([[WI-2026-09-03-012]]).
                    guard let rows else { return }
                    self.noteRemoteSessions(rows, for: host)
                }
            }
        }
    }

    /// WHETHER EACH CONNECTED HOST RUNS THE BINARY THIS BUILD DEPLOYS.
    ///
    /// ONLY THE CONNECTED ONES. Asking an unconnected host means dialling
    /// it — an ssh, an authentication, a wait — for a machine the human is
    /// not using; on a live master the question is one round trip over a
    /// link already open. So the answer for a host nobody is connected to
    /// is simply absent, which is what it should be.
    private(set) var hostBinary: [UUID: HostBinary.Verdict] = [:]
    private var binaryQueriesInFlight: Set<UUID> = []

    /// Hosts currently uploading, so a second press does not start a
    /// second scp over the same link.
    private(set) var hostsUpdating: Set<UUID> = []

    func refreshHostBinaries() {
        for connection in connections.connections {
            guard let host = connection.host,
                  let live = TunnelManager.shared?.connection(for: host),
                  HostBinary.worthAsking(
                      connected: true,
                      alreadyAsking: binaryQueriesInFlight.contains(host.id))
            else { continue }
            binaryQueriesInFlight.insert(host.id)
            let expected = HubManager.expectedBuild
            Task.detached(priority: .utility) {
                let theirs = HostBinary.query(connection: live)
                let verdict = HostBinary.verdict(remote: theirs, local: expected)
                await MainActor.run {
                    self.binaryQueriesInFlight.remove(host.id)
                    self.hostBinary[host.id] = verdict
                }
            }
        }
    }

    /// PUT THE CURRENT BINARY ON THIS HOST, because the human asked.
    ///
    /// EXPLICIT, BECAUSE NOTHING ELSE WILL. `setup-host.sh` compares and
    /// uploads, but [[TunnelManager]]'s fast path does not run it for a
    /// host that is already connected, and ControlPersist keeps that
    /// master alive as long as the host is peered — so a host dialled
    /// before a rebuild stays on the old binary until it is disconnected,
    /// which is a thing a human has no reason to do and no sign to do it
    /// for.
    func updateHostBinary(_ host: HostEntry) {
        guard !hostsUpdating.contains(host.id),
              let live = TunnelManager.shared?.connection(for: host)
        else { return }
        hostsUpdating.insert(host.id)
        let expected = HubManager.expectedBuild
        Task.detached(priority: .userInitiated) {
            var ok = false
            // WHAT THE MACHINE IS, ASKED RATHER THAN REMEMBERED. A host
            // entry records where to reach a machine, not its
            // architecture, and sending the wrong binary is a failure
            // that only appears the next time something runs there.
            if let uname = HostBinary.platform(connection: live),
               let target = HostBinary.deployTarget(unameSM: uname),
               let local = HostBinary.bundled(target: target) {
                ok = HostBinary.upload(local: local, connection: live)
            }
            let theirs = ok ? HostBinary.query(connection: live) : nil
            await MainActor.run {
                self.hostsUpdating.remove(host.id)
                // ASKED AGAIN RATHER THAN ASSUMED. An upload that returned
                // success and left the old binary would otherwise show as
                // current for the rest of the session.
                if ok {
                    self.hostBinary[host.id] =
                        HostBinary.verdict(remote: theirs, local: expected)
                }
            }
        }
    }

    /// RECORD WHAT A HOST ANSWERED, MINUS WHAT THIS WORKBENCH SHOWS.
    ///
    /// This list is for holders no pane here names — a crashed run,
    /// another Mac's work, a session from before a reinstall. Everything
    /// a workspace is holding is reported by its host as well, so it
    /// arrives from both sides, and the row here is the one that stays:
    /// an open pane is its own tab and a archived pane is a row that
    /// knows the title, the workspace it came from and that returning
    /// puts it back, where the host's row knows only a name.
    func noteRemoteSessions(_ rows: [RemoteSessions.Session], for host: HostEntry) {
        remoteSessions[host.id] = rows.filter { !shown($0.name, on: host) }
    }

    /// Whether a name this host reported already has a row in this
    /// workbench, open or archived.
    ///
    /// SCOPED TO THE MACHINE, NOT MATCHED ON THE NAME ALONE. Sessions are
    /// named from a four-hex namespace ([[RFC-0008]] C-IDENTITY), so two
    /// machines can hold namesakes, and an unscoped match would hide one
    /// host's session because a pane on another host answers to the same
    /// string.
    ///
    /// BOTH NAMES A RESTORED PANE MAY ANSWER TO. Restore hands a pane the
    /// name to return to and the name to start under and the far side
    /// picks ([[PaneLaunch]]); until the registration says which, either
    /// may be the one the host is reporting.
    private func shown(_ agent: String, on host: HostEntry) -> Bool {
        let open = workspaces.flatMap(\.panes).contains { pane in
            guard self.host(ofLeaf: pane.id)?.id == host.id else { return false }
            let f = facts[pane.id]
            return f?.agent == agent || f?.candidateAgent == agent
        }
        if open { return true }
        return workspaces.flatMap(\.archivedPanes).contains { row in
            row.agent == agent && row.host?.id == host.id
        }
    }

    /// WHETHER A SESSION ROW ALREADY NAMES THIS AGENT.
    ///
    /// The Still Running list is fed from three places, and two of them
    /// can describe one thing: an agent running in a pane the human
    /// archived is an archived-pane row here AND, because archiving a pane
    /// forgets its leaf, an agent that no pane here shows. The row that
    /// stays is the session one — it knows where the work is, how long
    /// nobody has watched it, and how to get back to it, where a relayed
    /// registration knows a name, a peer and a status.
    ///
    /// SCOPED TO THE MACHINE, for the reason [[RFC-0008]] C-IDENTITY
    /// makes unavoidable: names come from a four-hex namespace, so two
    /// machines can hold namesakes and an unscoped match would hide one.
    /// A peer this Mac has never dialled resolves to no host, and no
    /// session row can exist for it — so nothing is subtracted.
    func stillRunningNames(_ agentID: String, onPeer machine: String) -> Bool {
        guard let host = TunnelManager.shared?.host(forPeer: machine) else { return false }
        if remoteSessions[host.id]?.contains(where: { $0.name == agentID }) == true {
            return true
        }
        return workspaces.flatMap(\.archivedPanes).contains { row in
            row.agent == agentID && row.host?.id == host.id
        }
    }

    /// WHETHER ATTACHING TO THIS NAME WOULD TAKE IT FROM SOMEBODY
    /// ([[RFC-0014]] C-ONE-CLIENT).
    ///
    /// READ OFF WHAT THE HOST LAST SAID, and answerable only because
    /// `remoteSessions` has already subtracted this workbench's own rows:
    /// a session a pane here names is not in this table at all, so an
    /// entry that says `attached` is attached to a client that is not us
    /// — another Mac, or a `synapty attach` somebody ran on the host.
    ///
    /// A STALE ANSWER ERRS TOWARDS ASKING. The listing is a poll, so this
    /// can be a few seconds old; the cost of asking about a seat that has
    /// since been vacated is a dialog, and the cost of not asking is
    /// somebody else's session taken without their knowledge or ours.
    func attachWouldDisplace(_ agentID: String, on host: HostEntry) -> Bool {
        remoteSessions[host.id]?.contains { $0.name == agentID && $0.attached } == true
    }

    /// WHO would be displaced, as their client said ([[RFC-0014]]
    /// C-CLIENT-LABEL); nil when the far side did not say.
    func attachedClient(_ agentID: String, on host: HostEntry) -> String? {
        remoteSessions[host.id]?.first { $0.name == agentID && $0.attached }?.attachedBy
    }

    /// End one of them, by the name the host gave.
    /// AWAITED, because this one has a human watching it. The sidebar's
    /// End is a press with an outcome; the close cascades are not, and
    /// they keep the fire-and-forget path.
    @discardableResult
    func endRemoteSession(_ name: String, on host: HostEntry) async -> Bool {
        await endAgentAwaiting(name, host: host)
    }

    /// The agent that was running in an archived pane, for the row that
    /// names it — the leaf's facts are forgotten when it leaves the tree.
    func archivedPaneAgent(of paneID: UUID) -> String? {
        workspaces.flatMap(\.archivedPanes).first { $0.id == paneID }?.agent
    }

    /// The machine a archived pane was on, for the row that names it.
    func host(ofArchivedPane paneID: UUID) -> HostEntry? {
        workspaces.flatMap(\.archivedPanes).first { $0.id == paneID }?.host
    }

    /// PUT IT BACK where it was closed from, attached to the same child.
    func unarchivePane(_ paneID: UUID) {
        guard let sIdx = workspaces.firstIndex(where: {
            $0.archivedPanes.contains { $0.id == paneID }
        }) else { return }
        let row = workspaces[sIdx].archivedPanes.first { $0.id == paneID }!
        workspaces[sIdx].archivedPanes.removeAll { $0.id == paneID }
        recordLeafAgent(paneID, row.agent)
        // ARCHIVING RELEASED ITS CONNECTION, so coming back acquires one
        // by host, as unarchiving a workspace does ([[RFC-0015]]
        // C-UNARCHIVE); a fresh dial is then the caller's to make.
        let pane = row.host.map { row.pane.rebound(to: connections.acquire(host: $0).id) } ?? row.pane
        place(pane, in: sIdx)
        syncConnectionReferences()
        if awaitsDial(workspaces[sIdx]) { workspacesAwaitingDial.append(workspaces[sIdx].id) }
    }

    /// END AN ARCHIVED PANE'S SESSION, the distinct act [[RFC-0014]]
    /// C-DETACH requires beside leaving. The row goes with the session.
    func endArchivedPane(_ paneID: UUID) {
        guard let sIdx = workspaces.firstIndex(where: {
            $0.archivedPanes.contains { $0.id == paneID }
        }) else { return }
        let row = workspaces[sIdx].archivedPanes.first { $0.id == paneID }!
        if let agent = row.agent { endAgent(agent, host: row.host) }
        workspaces[sIdx].archivedPanes.removeAll { $0.id == paneID }
        syncConnectionReferences()
    }

    // MARK: - Putting work away ([[RFC-0015]] C-ARCHIVE)

    /// PUT THIS WORKSPACE AWAY: write the arrangement down, drop the
    /// panes, and let go of every connection nothing open still needs.
    ///
    /// IMMEDIATELY, WITHOUT THE GRACE PERIOD. The grace absorbs accidental
    /// churn — a pane closed and reopened, a workspace passed through. This
    /// is a decision the human has stated, and waiting thirty seconds to
    /// honour it would mean the resources they asked for back are still
    /// spent while they watch.
    ///
    /// WHAT RUNS ON THE FAR SIDE KEEPS RUNNING. Archiving is the client
    /// leaving; the holder keeps the child ([[RFC-0014]] C-HOLDER), which
    /// is the whole reason coming back is possible.
    func archiveWorkspace(_ workspaceID: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceID }),
              !workspaces[idx].isArchived else { return }
        workspaces[idx].archivedTree = workspaces[idx].layout.map {
            snapshotNode($0, planFor: { _ in nil })
        } ?? .slot(.init(panes: []))
        workspaces[idx].archivedFocusSlot = focusedSlotIndex(of: workspaces[idx])
        forgetPanes(of: workspaces[idx])
        workspaces[idx].setLayout(nil)

        // WHAT NOTHING OPEN STILL NAMES, and nothing more: a connection
        // another workspace is using MUST NOT be disturbed by this one
        // being put away.
        let before = connections.connections.map(\.id)
        syncConnectionReferences()
        for id in before { connections.releaseNow(id) }

        if activeWorkspaceID == workspaceID {
            activeWorkspaceID = workspaces.first(where: { !$0.isArchived })?.id
        }
    }

    /// TAKE IT BACK OUT. The arrangement is rebuilt the way a restart
    /// rebuilds one, so what comes back is what a restart would give.
    @discardableResult
    func unarchiveWorkspace(_ workspaceID: UUID, hostStore: HostStore?) -> Bool {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let tree = workspaces[idx].archivedTree else { return false }
        var leafMeta: [UUID: WorkspaceSnapshot.PaneEntry] = [:]
        let layout = rebuildNode(tree, hostStore: hostStore, into: &leafMeta)
        workspaces[idx].setLayout(layout)
        workspaces[idx].archivedTree = nil
        let slots = workspaces[idx].slots
        if let put = workspaces[idx].archivedFocusSlot, put < slots.count {
            workspaces[idx].focus(slots[put].activePaneID)
        } else if let first = workspaces[idx].panes.first {
            workspaces[idx].focus(first.id)
        }
        workspaces[idx].archivedFocusSlot = nil
        activeWorkspaceID = workspaceID
        syncConnectionReferences()
        // THE SAME OBLIGATION RESTORE HAS ([[RFC-0015]] C-UNARCHIVE:
        // unarchiving MUST reconstruct the workspace exactly as C-RESTORE
        // does and MUST acquire connections by host under C-DIAL).
        // `archiveWorkspace` released the connections, so `acquire` above
        // has just minted fresh ones in `.connecting` that nothing marks
        // — and a leaf whose connection is not up refuses to build a
        // terminal at all, with no Try Again, which renders only for
        // `.failed`.
        if let reopened = workspaces.first(where: { $0.id == workspaceID }),
           awaitsDial(reopened) {
            workspacesAwaitingDial.append(workspaceID)
        }
        return true
    }

    /// Ordering and prominence. Nothing else.
    func setPinned(_ workspaceID: UUID, _ pinned: Bool) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[idx].isPinned = pinned
    }

    /// Take a pane out of its workspace's tree. The position it leaves
    /// empty collapses into its sibling; a workspace left with none keeps
    /// its place with no tree at all.
    ///
    /// THE ONE PLACE A PANE IS DESTROYED, which is why forgetting what was
    /// known about it belongs here and not in each of the three callers
    /// that used to do it differently.
    @discardableResult
    private func detach(_ paneID: UUID, in sIdx: Int) -> Bool {
        guard let layout = workspaces[sIdx].layout,
              case .removed(let node) = layout.removePane(paneID) else { return false }
        // BEFORE THE TREE IS REPLACED. `removePane` is pure — it returns a
        // new node and mutates nothing — so the leaf is still findable
        // here, and `forget` needs it findable to know which machine the
        // pane was on. Installing the new tree first left it looking up a
        // leaf that no longer existed.
        forget(paneID)
        workspaces[sIdx].setLayout(node)
        return true
    }

    func activatePane(_ paneID: UUID) {
        guard let sIdx = workspaceIndex(containing: paneID) else { return }
        bringToFront(paneID, in: sIdx)
    }

    // MARK: - Reordering (WI-2026-08-09-018)

    /// Session drag-reorder: the dragged session lands in the target's slot
    /// ([[WI-2026-08-17-023]]).
    ///
    /// THE SAME SHAPE AS `movePane`, because the sidebar now drags the same
    /// way the tab bar does — `.draggable` to a `.dropDestination` rather
    /// than a list's own `.onMove`, which carried this for months and never
    /// produced a drag anyone could start.
    func moveWorkspace(_ workspaceID: UUID, before targetID: UUID) {
        guard workspaceID != targetID,
              let from = workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }
        let session = workspaces.remove(at: from)
        guard let to = workspaces.firstIndex(where: { $0.id == targetID }) else {
            // Target vanished mid-drag — restore.
            workspaces.insert(session, at: from)
            return
        }
        workspaces.insert(session, at: to)
    }

    /// Drop past the last session → append.
    func moveWorkspaceToEnd(_ workspaceID: UUID) {
        guard let from = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let session = workspaces.remove(at: from)
        workspaces.append(session)
    }

    // MARK: - Three-tier switching (WI-2026-08-09-015)

    /// Bring the Nth pane of the focused position to the front (1-based;
    /// out of range = no-op).
    func selectPane(index: Int) {
        guard let sIdx = activeWorkspaceIndex,
              let slot = workspaces[sIdx].focusedSlot,
              index >= 1, index <= slot.panes.count else { return }
        bringToFront(slot.panes[index - 1].id, in: sIdx)
    }

    /// FOCUS THE Nth SLOT of the active workspace, landing on whichever
    /// pane that slot has in front. 1-based; out of range is a no-op.
    ///
    /// A SLOT IS A POSITION IN THE SPLIT TREE and a pane is one of the
    /// things stacked in it ([[RFC-0015]] C-PERSIST names both). This was
    /// called `focusPane` and bound to a command reading "Pane N", which
    /// did nothing at all on the commonest layout there is — one slot, a
    /// stack of panes — because the index it takes was never a pane's.
    func focusSlot(index: Int) {
        guard let sIdx = activeWorkspaceIndex else { return }
        let slots = workspaces[sIdx].slots
        guard index >= 1, index <= slots.count else { return }
        workspaces[sIdx].focus(slots[index - 1].activePaneID)
    }

    // MARK: - Split management

    /// SPLITTING IS COPYING THE PANE and cutting its position in two.
    ///
    /// It is not a terminal operation and never was one of ghostty's: the
    /// tree is ours, and what a split produces is a DUPLICATE of the pane
    /// the human is in — same machine, same kind, same place — set beside
    /// it. A split that opened a blank shell at home was a new pane
    /// wearing the gesture's name.
    ///
    /// WHAT "DUPLICATE" MEANS PER KIND. A file browser and a web view have
    /// nothing running behind them, so the copy is the value itself. A
    /// terminal has a child, and a child cannot be forked — so it is
    /// REOPENED: a fresh shell on the same connection, in the same
    /// directory, under an agent id of its own.
    func splitFocusedLeaf(direction: SplitNode.SplitDirection) {
        guard let sIdx = activeWorkspaceIndex,
              let layout = workspaces[sIdx].layout,
              let focused = workspaces[sIdx].focusedPane,
              let slot = layout.slot(containing: focused.id) else { return }

        // ON THE FOCUSED PANE'S MACHINE, not the workspace's — duplicating
        // a remotehost pane gives another remotehost pane even when the
        // pane beside it is local. Nothing else in the tree knows which
        // host this pane is on ([[RFC-0015]] C-LEAF-BINDING).
        //
        // AND WHERE IT IS STANDING, TAKEN FROM THE SHELL AND NOT FROM
        // THE KERNEL. Both can answer, and only one of them is answering
        // the question: the kernel reports the FOREGROUND process, so a
        // pane duplicated while its shell is running anything that `cd`s
        // opens wherever that command went. It is not a corner —
        // `jenv rehash` runs from `.zshrc` and lives in `~/.jenv/shims`,
        // and a copy made before the first prompt landed there.
        //
        // A pane that has not said gets no directory rather than a guess:
        // opening at the default is a thing the human can see and correct,
        // and opening in a build script's scratch directory is not.
        //
        // The reported answer covers a remote pane too — the far side's
        // OSC 7 rides the same stream the screen does. The local surface
        // ignores a path that is not on this Mac, so the remote copy is
        // placed by the connect command instead: two halves of one answer.
        let cwd = reportedPwd(ofLeaf: focused.id)
        var r: PaneLaunch?
        if focused.content.isTerminal {
            r = host(ofLeaf: focused.id).map {
                TunnelManager.shared?.connectCommand(for: $0, cwd: cwd)
            } ?? TunnelManager.shared?.localCommand()
        }
        let content: SplitNode.PaneContent = focused.content.isTerminal
            ? .terminal(command: r?.command) : focused.content
        // The NAME rides along but not the human's claim to it: a copy of
        // a renamed pane starts out following its own shell again.
        let newPane = SplitNode.Pane(label: focused.label, content: content,
                                     workingDirectory: cwd,
                                     connectionID: focused.connectionID)

        let (newRoot, newSlotID) = layout.splitSlot(slot.id, direction: direction, newPane: newPane)
        guard newSlotID != nil else { return }
        workspaces[sIdx].setLayout(newRoot)
        workspaces[sIdx].focus(newPane.id)
        recordLeafAgent(newPane.id, r?.agentID)
        syncConnectionReferences()
    }

    /// One-click layout preset for the active workspace (WI-2026-08-09-012):
    /// folds the existing POSITIONS into the preset's shape. Slots are
    /// reused verbatim, so every pane keeps its id — and with it its
    /// ghostty surface and pty — and any stack rides along with the
    /// position holding it. Focus is untouched.
    func applyLayout(_ preset: SplitNode.LayoutPreset) {
        guard let sIdx = activeWorkspaceIndex else { return }
        let slots = workspaces[sIdx].slots
        guard slots.count > 1 else { return }
        workspaces[sIdx].setLayout(SplitNode.arranged(slots: slots, preset: preset))
    }

    /// A dial to this host did not answer (WI-2026-03-31-003).
    ///
    /// ADDRESSED BY HOST, and it always was — the caller knows which dial
    /// failed, not which container was watching. Now that the state lives
    /// on the connection, every workspace with a pane on that host learns
    /// about it at once instead of only the one that opened it.
    /// THE LINK TO A HOST IS UP, told by the party that opened it.
    ///
    /// Every leaf bound to that host follows, because they share the one
    /// connection ([[RFC-0015]] C-CONNECTION). This exists because a
    /// RESTORED pane never passes through `paneDidConnect`: restore mints
    /// its command itself and only asks for the tunnel, so nothing marked
    /// the connection up — and a leaf whose connection is not up shows the
    /// dial forever, however complete it otherwise is.
    func markConnected(hostID: UUID) {
        guard let connection = connections.connection(forHost: hostID),
              connection.state == .connecting else { return }
        connections.markConnected(connection.id)
    }

    func markWorkspaceFailed(hostID: UUID, message: String) {
        guard let connection = connections.connection(forHost: hostID),
              connection.state == .connecting else { return }
        connections.markFailed(connection.id, message)
    }

    /// Re-dial the connection ONE LEAF is bound to (WI-2026-08-07-004,
    /// now per leaf under [[RFC-0015]] C-DIAL). It re-dials the shared
    /// connection rather than opening a second one, so every other leaf
    /// on that host follows it back up.
    func markLeafConnecting(_ leafID: UUID) {
        // A DIAL SUPERSEDES THE LOSS IT ANSWERS: this leaf is on its way
        // back to the session another client took, so what it shows from
        // here is the dial.
        facts[leafID]?.takenByAnother = false
        guard let pane = leafData(leafID),
              case .failed = connections.connection(pane.connectionID)?.state else { return }
        connections.redial(pane.connectionID)
    }

    /// Close a specific leaf by ID (called when its process exits).
    ///
    /// ENDS NOTHING REMOTE, deliberately. This runs from ghostty's
    /// close_surface callback — the LOCAL ssh has gone, and from here a
    /// dropped link and a shell that typed `exit` are the same event. A
    /// kill on this path would reach across on the first network blip and
    /// destroy the session the holder is there to keep ([[ADR-0008]]
    /// stage 3a).
    /// The kill belongs to the human's own close and nowhere else.
    ///
    /// AND ENDS NO WORKSPACE. This used to remove the workspace once its
    /// last pane went, which is the structural violation of
    /// [[RFC-0015]] C-WORKSPACE: a shell exiting destroyed the place the
    /// human kept their work.
    func closeLeaf(_ leafID: UUID) {
        guard let sIdx = workspaceIndex(containing: leafID) else { return }
        detach(leafID, in: sIdx)
        syncConnectionReferences()
    }

    /// Navigate focus to the next/previous POSITION.
    ///
    /// Positions, not panes: cycling through every pane of every stack
    /// would make the shortcut visit panes the human cannot see.
    func focusNextLeaf() {
        stepThroughSlots { $0.nextPane(after: $1) }
    }

    func focusPreviousLeaf() {
        stepThroughSlots { $0.previousPane(before: $1) }
    }

    private func stepThroughSlots(_ step: (SplitNode, UUID) -> UUID?) {
        guard let sIdx = activeWorkspaceIndex,
              let layout = workspaces[sIdx].layout,
              let focused = workspaces[sIdx].focusedPaneID,
              let next = step(layout, focused) else { return }
        workspaces[sIdx].focus(next)
    }

    /// Update the split ratio for a split node.
    func resizeSplit(splitID: UUID, ratio: CGFloat) {
        guard let sIdx = activeWorkspaceIndex else { return }
        workspaces[sIdx].resizeSplit(splitID: splitID, ratio: ratio)
    }

    /// Set focus to a specific leaf (called from surface becomeFirstResponder).
    /// Updates the workspace-level focus only — it must NOT switch the
    /// active workspace: a background connection's new surface becoming
    /// first responder would otherwise yank the user away from the
    /// workspace they are working in.
    func focusLeaf(_ leafID: UUID) {
        // Looking at it = attended (WI-2026-08-09-021).
        facts[leafID]?.needsAttention = false
        // Gaze evidence for the hub-side done→idle transition (RFC-0004).
        if let agentID = facts[leafID]?.agent {
            onAgentGaze?(agentID)
        }
        guard let sIdx = workspaceIndex(containing: leafID) else { return }
        bringToFront(leafID, in: sIdx)
    }
}
