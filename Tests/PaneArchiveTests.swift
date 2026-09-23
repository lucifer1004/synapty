import XCTest
@testable import Synapty

/// WHAT CLOSING AND ARCHIVING A PANE MEAN ([[RFC-0015]] C-PANE-ARCHIVE, [[ADR-0019]]).
///
/// RFC-0014 C-DETACH requires this question to be answered and names both
/// obvious answers as harmful. It had been answered twice at once: a
/// remote pane's agent was ended, a local pane's was not, and the gesture
/// showed neither.
@MainActor
final class PaneArchiveTests: XCTestCase {

    private var tunnelManager: TunnelManager!
    private var tmp: URL!
    /// HELD, BECAUSE `TunnelManager.hostStore` IS WEAK. A store made
    /// inside the helper below is deallocated when it returns, and the
    /// peer lookup then finds no hosts at all.
    private var hostStore: HostStore!

    override func setUpWithError() throws {
        // A HOST STORE HERE WOULD OTHERWISE BE THE REAL ONE. Some of
        // these tests put a host in a store so a peer name can resolve
        // to it, and a miss on this once clobbered real hosts.json.
        tmp = try setUpHostStoreStorage()
        // AND THE ACCOUNTS TOO. `accountSaying` writes a connect channel;
        // without this it writes into the real one beside the human's own
        // sessions ([[ConfigPaths]]).
        ConfigPaths.rootOverride = tmp
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
        hostStore = nil
        ConfigPaths.rootOverride = nil
        restoreStorageOverrides(tmp)
    }

    /// Give this manager's host a name the far side reported for itself,
    /// which is what `host(forPeer:)` joins on ([[RFC-0010]]
    /// C-PEER-IDENTITY mints it over there, so the human's label never
    /// matches it directly).
    private func peerNamed(_ peer: String, for host: HostEntry) {
        hostStore = HostStore()
        hostStore.addHost(host)
        tunnelManager.hostStore = hostStore
        tunnelManager.adoptExistingPeers([(peer: peer, port: 9310)])
    }

    private func makeManager() -> WorkspaceManager {
        let m = WorkspaceManager()
        m.addLocalWorkspace()
        return m
    }

    private func session(_ name: String) -> RemoteSessions.Session {
        .init(name: name, attached: false, everAttached: true, childExited: false,
              unattached: 30, command: "zsh", directory: "/srv", unreachable: false)
    }

    private func remoteManager() -> WorkspaceManager {
        let m = WorkspaceManager()
        m.addRemoteWorkspace(
            label: "remotehost",
            hostEntry: HostEntry(label: "remotehost", address: "10.0.0.1", username: "u"),
            command: "synapty connect --id a --host 10.0.0.1 --port 22 --user u")
        return m
    }

    // MARK: - One answer for every machine

    func testArchivingALocalTerminalKeepsItListed() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id

        manager.archivePane(pane)

        XCTAssertEqual(manager.archivedPanes.map(\.id), [pane])
        XCTAssertNil(manager.activeWorkspace?.layout?.findPane(pane),
                     "it left the layout")
    }

    /// THE DEFECT THIS CLAUSE EXISTS FOR. A remote pane was ended on close
    /// and a local one was not — two answers decided by which machine the
    /// pane was on, and visible from neither gesture.
    func testArchivingARemoteTerminalKeepsItListedToo() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        var ended: [String] = []
        manager.remoteAgentEnder = { _, id in ended.append(id); return Task { true } }

        manager.archivePane(pane)

        XCTAssertEqual(manager.archivedPanes.map(\.id), [pane])
        XCTAssertEqual(ended, [], "archiving a pane must not end what runs in it")
    }

    // MARK: - Which panes

    func testAFileLeafClosesRatherThanBeingArchived() {
        let manager = makeManager()
        let workspace = manager.activeWorkspaceID!
        let file = manager.addPane(content: .files(directory: "/tmp"), toWorkspace: workspace)!

        manager.archivePane(file)

        XCTAssertEqual(manager.archivedPanes, [],
                       "nothing runs in it, so there is nothing to return to")
    }

    /// A row offering to return to a child that has exited is the dead
    /// record this list exists to keep out.
    func testATerminalWhoseChildHasExitedCloses() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id

        manager.leafDidClose(pane)

        XCTAssertEqual(manager.archivedPanes, [])
    }

    // MARK: - What the list carries

    func testTheRowNamesTheAgentAndWhenItWasSetAside() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(pane, "claude-7")
        let before = Date()

        manager.archivePane(pane)

        let row = manager.archivedPanes.first
        XCTAssertEqual(row?.agent, "claude-7")
        XCTAssertNotNil(row?.at)
        XCTAssertGreaterThanOrEqual(row!.at, before)
    }

    func testTheRowNamesTheMachine() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.remoteAgentEnder = { _, _ in Task { true } }

        manager.archivePane(pane)

        XCTAssertEqual(manager.host(ofArchivedPane: pane)?.label, "remotehost")
    }

    // MARK: - Returning and ending

    func testReturningPutsItBackInTheWorkspaceItCameFrom() {
        let manager = makeManager()
        let workspace = manager.activeWorkspaceID!
        let pane = manager.activeWorkspace!.panes[0].id
        manager.archivePane(pane)

        manager.unarchivePane(pane)

        XCTAssertEqual(manager.archivedPanes, [])
        XCTAssertNotNil(manager.workspaces.first { $0.id == workspace }?
            .layout?.findPane(pane))
    }

    /// Ending is the act closing a pane no longer performs, so the list is
    /// where it lives — and it MUST be distinct from returning.
    func testEndingRemovesTheRowAndEndsTheAgent() async {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        // NAMED BEFORE THE CLOSE, and asserted against by name. Asking for
        // the agent before the pane is set aside answers nil, and an
        // assertion against nil passes whether or not anything was ended.
        manager.recordLeafAgent(pane, "claude-9")
        var ended: [String] = []
        manager.remoteAgentEnder = { _, id in ended.append(id); return Task { true } }
        manager.archivePane(pane)
        XCTAssertEqual(ended, [], "archiving is not ending")

        await manager.endArchivedPane(pane)

        XCTAssertEqual(manager.archivedPanes, [])
        XCTAssertEqual(ended, ["claude-9"])
    }

    /// THE TAB'S OWN LABEL, CAPTURED. It is what the human was looking at
    /// — a shell title naming the command, or the name they typed — and
    /// it says more than a folder does. Captured at the closing because
    /// the leaf's facts are forgotten when it leaves the tree, so reading
    /// it later would find nothing.
    func testTheRowKeepsTheLabelTheHumanWasLookingAt() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.leafDidUpdateTitle(pane, title: "cargo test")

        manager.archivePane(pane)

        XCTAssertEqual(manager.archivedPanes.first?.title, "cargo test")
    }

    /// A pane the human renamed keeps THEIR name, since that is what
    /// `displayLabel` resolves and what the tab was showing.
    func testAHumansOwnNameWins() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.leafDidUpdateTitle(pane, title: "zsh")
        manager.renamePane(pane, to: "the deploy one")

        manager.archivePane(pane)

        XCTAssertEqual(manager.archivedPanes.first?.title, "the deploy one")
    }

    /// WHERE THE WORK IS, CAPTURED AT THE CLOSING.
    ///
    /// THE SAME READING THE AGENT AND THE TITLE ALREADY GET. A leaf's
    /// facts are forgotten the moment it leaves the tree, and the
    /// directory it is standing in is one of them — so a row that asked
    /// afterwards got nil, and `pwd(ofLeaf:)`'s own fallback could not
    /// help because that reads the leaf out of the TREE the pane has
    /// just left.
    func testTheRowKeepsWhereTheWorkWas() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.leafDidUpdatePwd(pane, pwd: "/Users/z/proj/api")

        manager.archivePane(pane)

        XCTAssertEqual(manager.archivedPanes.first?.pane.workingDirectory,
                       "/Users/z/proj/api")
    }

    /// WHERE IT IS NOW, NOT WHERE IT WAS STARTED. A pane records the
    /// directory it was opened in and the shell then walks away from it;
    /// the row that says "cargo test in ~/proj/api" is naming the second.
    func testTheDirectoryItWalkedToWinsOverTheOneItStartedIn() {
        let manager = makeManager()
        let workspace = manager.activeWorkspaceID!
        let pane = manager.addPane(content: .terminal(command: nil),
                                   toWorkspace: workspace)!
        manager.renamePane(pane, to: "started at home")
        manager.leafDidUpdatePwd(pane, pwd: "/Users/z/proj/web")

        manager.archivePane(pane)

        XCTAssertEqual(manager.archivedPanes.first?.pane.workingDirectory,
                       "/Users/z/proj/web")
    }

    /// AND IT SURVIVES THE RESTART, because the snapshot reads the leaf's
    /// facts too and finds none for a pane that has left the tree. The
    /// pane VALUE is what still knows, and it is what is written.
    func testWhereTheWorkWasSurvivesARoundTrip() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.leafDidUpdatePwd(pane, pwd: "/Users/z/proj/api")
        manager.archivePane(pane)

        let restored = WorkspaceManager()
        _ = restored.restore(from: manager.snapshot(planFor: { _ in nil }), hostStore: nil)

        XCTAssertEqual(restored.archivedPanes.first?.pane.workingDirectory,
                       "/Users/z/proj/api")
    }

    /// RETURNING IT OPENS WHERE THE WORK IS. The pane goes back as the
    /// value that was set aside, so the directory rides back with it
    /// rather than the row knowing something the pane does not.
    func testReturningItBringsTheDirectoryBack() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.leafDidUpdatePwd(pane, pwd: "/Users/z/proj/api")
        manager.archivePane(pane)

        manager.unarchivePane(pane)

        XCTAssertEqual(manager.activeWorkspace?.layout?.findPane(pane)?.workingDirectory,
                       "/Users/z/proj/api")
    }

    // MARK: - One session, one row

    /// THE LIST IS FOR HOLDERS NO PANE HERE NAMES. A pane that is open is
    /// already a row — its own tab — and the host reports it all the
    /// same, so it arrived from both sides and was offered as something
    /// to open while the human was looking at it.
    func testAnOpenRemotePaneIsNotAlsoListedFromItsHost() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!
        manager.recordLeafAgent(pane, "gpu-4")

        manager.noteRemoteSessions(
            [session("gpu-4"), session("gpu-9")], for: host)

        XCTAssertEqual(manager.remoteSessions[host.id]?.map(\.name), ["gpu-9"])
    }

    /// PICKED UP, AND STILL OFFERED. The order here is the one that
    /// happens: the host reports its holders on a poll, and the human
    /// picks one up AFTERWARDS. Every other case in this file records the
    /// agent first, which is the order in which a subtraction done once at
    /// arrival cannot be wrong — so none of them could fail, and the row
    /// sat in the list for up to the sixty seconds until the next poll
    /// ([[WI-2026-09-07-002]]).
    func testASessionPickedUpAfterTheHostReportedItLeavesTheList() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!

        manager.noteRemoteSessions([session("gpu-4"), session("gpu-9")], for: host)
        XCTAssertEqual(manager.remoteSessions[host.id]?.map(\.name), ["gpu-4", "gpu-9"])

        manager.recordLeafAgent(pane, "gpu-4")

        XCTAssertEqual(manager.remoteSessions[host.id]?.map(\.name), ["gpu-9"],
                       "the pane is open and the list still offers it as somewhere to return to")
    }

    /// THE SAME, FOR A PANE STILL DECIDING WHICH NAME IT ANSWERS TO. A
    /// restored pane carries both until the far side registers, and the
    /// row has to go on either.
    func testACandidateNameRecordedAfterTheReportAlsoTakesTheRowAway() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!

        manager.noteRemoteSessions([session("gpu-4"), session("gpu-9")], for: host)
        manager.recordLeafCandidates(pane, settled: nil, candidate: "gpu-9")

        XCTAssertEqual(manager.remoteSessions[host.id]?.map(\.name), ["gpu-4"])
    }

    // MARK: - A marked row owes a reason

    /// [[RFC-0015]] C-FAILURE: "A failure MUST carry the reason it
    /// failed." The sidebar had ONE source for that reason and it walks
    /// CONNECTIONS, so when [[WI-2026-09-07-004]] widened the mark to fire
    /// on a PANE's link as well, a whole class of failure got a mark with
    /// nothing beside it — and, where something also wanted the human, the
    /// attention mark instead, which is indistinguishable from a workspace
    /// with nothing wrong ([[WI-2026-09-07-007]]).
    ///
    /// AND THERE IS ONE SOURCE NOW, which is the durable version of that
    /// lesson. The row spelled the mark out as its own disjunction while
    /// the reason beside it asked `failureReason`; both halves are the
    /// same question, so the row asks it once and the mark IS the reason
    /// being there ([[WI-2026-09-11-008]]). The two can no longer be
    /// widened apart, so this asks the one that decides.
    func testAWorkspaceMarkedForAPanesLinkHasAReasonToShow() {
        let manager = remoteManager()
        let workspace = manager.activeWorkspace!
        let pane = workspace.panes[0].id
        manager.recordLeafAgent(pane, "gpu-4")

        // Nothing wrong: nothing to say, and so nothing marked.
        XCTAssertNil(manager.failureReason(workspace))

        // THROUGH THE PATH THE WORKBENCH ACTUALLY USES. `leafChildExited`
        // is what the libghostty action calls; a non-zero code with
        // nothing else said is a link that died taking its transport with
        // it, which marks the row at once.
        manager.leafChildExited(pane, code: 255)

        let why = manager.failureReason(workspace)
        XCTAssertNotNil(why,
                        "a pane whose link died must mark the row, and C-FAILURE "
                            + "requires the mark to say why")
        XCTAssertEqual(why, manager.link(ofLeaf: pane).sentence(
            on: manager.machineLabel(ofLeaf: pane)),
            "the reason shown is the pane's own account of itself")
    }

    /// A NEW CHILD IS NOT THE OLD ONE'S EXIT. The exit code was written
    /// once and cleared nowhere, and `LinkState.from` consults it ahead of
    /// everything the account says — so a pane that lost its link once and
    /// was then re-dialled read as `dropped` for the rest of its life
    /// ([[WI-2026-09-07-009]]).
    func testARedialledPaneIsNotStillWearingItsLastExitCode() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(pane, "gpu-4")

        manager.leafChildExited(pane, code: 255)
        XCTAssertEqual(manager.link(ofLeaf: pane), .dropped)

        manager.paneDidConnect(pane, command: "synapty connect --id gpu-4 --host 10.0.0.1", agentID: "gpu-4")

        XCTAssertEqual(manager.link(ofLeaf: pane), .live,
                       "the dial returned; the pane has a new child and no exit to report")
    }

    /// THE CLOSE IS THE WORKBENCH'S DECISION, NOT LIBGHOSTTY'S. Taking
    /// `SHOW_CHILD_EXITED` means libghostty may never call `close()` — the
    /// branch it takes for a child that went within 250ms returns instead
    /// — so a pane that should go would be stranded with its armed bit set
    /// and its resume plan never dropped ([[WI-2026-09-07-009]]).
    func testAPaneWhoseChildSimplyFinishedIsClosedByTheWorkbench() {
        let manager = remoteManager()
        let workspace = manager.activeWorkspace!
        let pane = workspace.panes[0].id
        manager.remoteAgentEnder = { _, _ in Task { true } }
        XCTAssertNotNil(manager.activeWorkspace?.layout?.findPane(pane))

        // AN ORDINARY EXIT, SAID SO BY THE CLIENT. On a durable host the
        // work finishing is a fact the client writes down before it goes;
        // the death by itself does not carry it.
        accountSaying("1 paint -\n2 end child_exited\n", for: pane, agent: "gpu-fin", in: manager)
        manager.leafChildExited(pane, code: 0)

        XCTAssertNil(manager.activeWorkspace?.layout?.findPane(pane),
                     "an ordinary exit closes the pane, whether or not libghostty asks")
    }

    /// A CLIENT THAT DIED WITHOUT WRITING ANYTHING KEEPS ITS PANE.
    ///
    /// On a durable host the client retries rather than exiting, and when
    /// it does exit it writes an `end` first — so a death with no account
    /// is the client ITSELF dying, and the session it was carrying is
    /// still over there ([[RFC-0014]] C-EXIT-SIGNAL, [[WI-2026-09-09-001]]).
    func testARemoteClientThatDiedSayingNothingKeepsItsPane() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.remoteAgentEnder = { _, _ in Task { true } }

        manager.leafChildExited(pane, code: 0)

        XCTAssertNotNil(manager.activeWorkspace?.layout?.findPane(pane),
                        "a pane whose client vanished silently kept nothing to show for it")
        XCTAssertEqual(manager.link(ofLeaf: pane), .dropped)
    }

    /// AND A HOST THAT KEEPS NO SESSION IS LEFT AS IT WAS. There the
    /// transport IS the pane's child, so a dropped link and a human typing
    /// `exit` arrive identically — and the exit code that was supposed to
    /// tell them apart is `login`'s zero in every case. Guessing would
    /// leave a dead pane open every time somebody left a shell.
    func testAPaneOnAHostThatKeepsNoSessionStillClosesWhenItsTransportGoes() {
        let manager = WorkspaceManager()
        var host = HostEntry(label: "ephemeral", address: "10.0.0.2", username: "u")
        host.durableSessions = false
        manager.addRemoteWorkspace(label: "ephemeral", hostEntry: host,
                                   command: "ssh u@10.0.0.2")
        let pane = manager.activeWorkspace!.panes[0].id
        manager.remoteAgentEnder = { _, _ in Task { true } }

        manager.leafChildExited(pane, code: 0)

        XCTAssertNil(manager.activeWorkspace?.layout?.findPane(pane),
                     "nothing here can tell a drop from an exit, so the pane behaves as a "
                     + "terminal does")
    }

    /// AND A PANE WHOSE LINK DIED IS NOT CLOSED BY IT. [[RFC-0014]]
    /// C-EXIT-SIGNAL: a client MUST NOT close on the strength of a lost
    /// connection.
    func testAPaneWhoseLinkDiedIsKept() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.remoteAgentEnder = { _, _ in Task { true } }

        manager.leafChildExited(pane, code: 255)

        XCTAssertNotNil(manager.activeWorkspace?.layout?.findPane(pane),
                        "the screen is the last true thing the session said")
    }

    // MARK: - The decision arrives before the poll does

    /// THE CLOSE DECISION IS TAKEN AT THE INSTANT THE CLIENT EXITS, and
    /// the account is read by a reader that polls every quarter second. So
    /// a client that wrote `end no_session` and exited — which it does
    /// with exit status 0, because breaking out of its retry loop is a
    /// normal return — presented the workbench with `ended == nil` and a
    /// zero code, which reads as an ordinary exit, and the pane was closed
    /// on the one outcome the whole of [[WI-2026-09-07-004]] exists to
    /// report ([[WI-2026-09-07-011]]).
    ///
    /// The codebase already knew this shape: `accountEndsDisplaced` reads
    /// the FILE for exactly this reason and says so. The fix is to ask the
    /// same way about every ending, not only that one.
    func testASessionThatIsGoneKeepsItsPaneEvenBeforeTheAccountHasBeenPolled() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.remoteAgentEnder = { _, _ in Task { true } }
        accountSaying("1 paint -\n2 end no_session\n", for: pane, agent: "gpu-5", in: manager)

        // NOT AWAITED. The poll has not run and must not need to have.
        XCTAssertNil(manager.connectProgress.progress(for: pane)?.ended,
                     "precondition: this test is worthless if the poll already ran")

        manager.leafChildExited(pane, code: 0)

        XCTAssertNotNil(manager.activeWorkspace?.layout?.findPane(pane),
                        "a reconnect that found no session must not lose its pane to a race")
    }

    /// The same, for the ending the codebase already handled — so the two
    /// cannot drift apart again.
    ///
    /// AND THE PANE MUST SAY WHY IT IS STILL THERE. Surviving is half the
    /// obligation: `surface(of:)` draws the taken surface from
    /// `takenByAnother`, and that flag was set on ONE of the two paths
    /// into the decision — so a pane kept by the child-exited action
    /// survived as a pane with a dead process and no explanation, and the
    /// promise made to the other human in the displacement dialog ("they
    /// will be told who took it") held only when libghostty happened to
    /// call close as well ([[WI-2026-09-08-002]]).
    func testADisplacedPaneKeepsItsPaneAndSaysWhyBeforeThePollToo() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.remoteAgentEnder = { _, _ in Task { true } }
        accountSaying("1 paint -\n2 end displaced\n", for: pane, agent: "gpu-7", in: manager)

        manager.leafChildExited(pane, code: 0)

        XCTAssertNotNil(manager.activeWorkspace?.layout?.findPane(pane),
                        "[[RFC-0014]] C-ONE-CLIENT: the pane carries the reason")
        XCTAssertEqual(manager.surface(of: pane), .taken,
                       "a pane kept because somebody took its session must say so")
    }

    /// Write an account the way a connection does, and point the manager
    /// at it — without waiting for the reader that follows it.
    private func accountSaying(_ line: String, for leaf: UUID,
                               agent: String, in manager: WorkspaceManager) {
        let url = ConnectProgress.begin(for: agent)
        try? Data(line.utf8).write(to: url)
        manager.recordLeafAgent(leaf, agent)
        manager.connectProgress.begin(session: leaf, agentID: agent)
    }

    /// A SHELL ON THIS MAC EXITS NON-ZERO ALL THE TIME. A failing command
    /// and a Ctrl-D is the ordinary case, and fed to the rule that keeps a
    /// pane whose LINK died it meant `exit` stopped closing a terminal
    /// ([[WI-2026-09-08-016]]).
    func testALocalShellExitingNonZeroStillClosesItsPane() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id
        XCTAssertNil(manager.host(ofLeaf: pane), "precondition: this pane is on this Mac")

        manager.leafChildExited(pane, code: 2)

        XCTAssertNil(manager.activeWorkspace?.layout?.findPane(pane),
                     "a local shell that exited is a terminal behaving as one")
    }

    /// AND THE SAME CODE ON A REMOTE PANE STILL KEEPS IT, because there
    /// the child is the thing CARRYING the work rather than the work.
    func testTheSameExitCodeOnARemotePaneKeepsIt() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.remoteAgentEnder = { _, _ in Task { true } }
        XCTAssertNotNil(manager.host(ofLeaf: pane))

        manager.leafChildExited(pane, code: 2)

        XCTAssertNotNil(manager.activeWorkspace?.layout?.findPane(pane))
    }

    /// RETRY IS ADDRESSED TO THE CLIENT, WHICH ANSWERS TO ONE NAME.
    ///
    /// The marker is derived from the channel, and the channel was opened
    /// under the name the pane was DIALLED with. `facts[leaf].agent` is a
    /// different question — the hub renames it to the durable id
    /// ([[RFC-0008]] identity upgrade, `remapLeafAgent`) — so keying the
    /// marker off it wrote permission into a path nothing was polling, and
    /// pressing Retry did nothing at all ([[WI-2026-09-08-016]]).
    func testRetryReachesTheClientUnderTheNameItWasDialledWith() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        accountSaying("1 paint -\n2 paused for 30s\n", for: pane, agent: "gpu-dialled",
                      in: manager)
        manager.remapLeafAgent(from: "gpu-dialled", to: "gpu-durable")

        manager.retryLink(ofLeaf: pane)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: ConnectProgress.retryMarker(for: "gpu-dialled").path),
            "the paused client polls beside the account it is writing, and that is the "
            + "name it was dialled under")
    }

    /// AND WHEN THAT HOST'S SSH SAYS THE FAILURE WAS ITS OWN, THE PANE
    /// STAYS.
    ///
    /// The case above is the one nothing speaks for. This is the one
    /// something does: the connection sees ssh's exit status — 255 for ssh's
    /// own failures, the remote shell's own status otherwise — and writes
    /// it to the account, which is the channel the workbench already
    /// reads. The gap was called unclosable one signal too early
    /// ([[WI-2026-09-09-004]]).
    func testAHostThatKeepsNoSessionKeepsThePaneWhenItsLinkDropped() {
        let manager = WorkspaceManager()
        var host = HostEntry(label: "ephemeral", address: "10.0.0.2", username: "u")
        host.durableSessions = false
        manager.addRemoteWorkspace(label: "ephemeral", hostEntry: host,
                                   command: "synapty connect --id e --host 10.0.0.2 --port 22 --user u")
        let pane = manager.activeWorkspace!.panes[0].id
        manager.remoteAgentEnder = { _, _ in Task { true } }
        accountSaying("1 live -\n2 end link_severed\n", for: pane, agent: "eph-1", in: manager)

        manager.leafChildExited(pane, code: 0)

        XCTAssertNotNil(manager.activeWorkspace?.layout?.findPane(pane),
                        "the screen is the last true thing that session said")

        // AND THE STRIP SAYS SO ONCE THE ACCOUNT HAS BEEN READ. The close
        // above is decided from disk, because it happens at the instant
        // the client exits; what the human then looks at comes through the
        // reader, so this waits for it rather than assuming its timing.
        let deadline = Date().addingTimeInterval(3)
        while manager.link(ofLeaf: pane) != .severed, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(manager.link(ofLeaf: pane), .severed)
    }

    /// A HOST THAT COULD NOT BE DIALLED EXPLAINS EVERY PANE ON IT, so its
    /// reason leads. Reporting one of those panes instead would name a
    /// symptom over its cause.
    func testAFailedConnectionsReasonLeadsOverAPanes() {
        let manager = remoteManager()
        let workspace = manager.activeWorkspace!
        let pane = workspace.panes[0].id
        manager.recordLeafAgent(pane, "gpu-4")
        manager.leafChildExited(pane, code: 255)

        let connectionID = workspace.panes[0].connectionID
        manager.connections.markFailed(connectionID, "the host refused the key")

        XCTAssertEqual(manager.failureReason(workspace), "the host refused the key")
        XCTAssertNotNil(manager.link(ofLeaf: pane).sentence(on: "gc"),
                        "the pane still has its own account; it is simply not the one shown")
    }

    /// A HOST THAT HOLDS NOTHING CLEARS ITS ROWS.
    ///
    /// The step from one session to none is the transition a human is
    /// watching for, and it was the one the sidebar could not show: an
    /// empty listing was indistinguishable from a failed one, so the
    /// caller distrusted every empty answer and a host's last row stayed
    /// until the app was restarted ([[WI-2026-09-03-012]]).
    func testAHostThatHoldsNothingClearsItsRows() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!

        manager.noteRemoteSessions([session("gpu-4"), session("gpu-9")], for: host)
        XCTAssertEqual(manager.remoteSessions[host.id]?.count, 2)

        manager.noteRemoteSessions([], for: host)
        XCTAssertEqual(manager.remoteSessions[host.id], [],
                       "the host said it holds nothing and the rows stayed")
    }

    /// BOTH NAMES A RESTORED PANE MAY ANSWER TO. Restore hands a pane the
    /// name to return to and the name to start under; until the far side
    /// registers, either may be the one the host is reporting.
    func testAPaneStillDecidingItsNameCountsUnderEither() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!
        manager.recordLeafCandidates(pane, settled: "gpu-4", candidate: "gpu-5")

        manager.noteRemoteSessions(
            [session("gpu-4"), session("gpu-5"), session("gpu-9")], for: host)

        XCTAssertEqual(manager.remoteSessions[host.id]?.map(\.name), ["gpu-9"])
    }

    /// A NAMESAKE ON ANOTHER MACHINE IS A DIFFERENT SESSION. Names come
    /// from a four-hex namespace ([[RFC-0008]] C-IDENTITY), so matching
    /// on the string alone would hide one host's session because a pane
    /// on another host answers to the same one.
    func testANamesakeOnAnotherHostIsStillListed() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(pane, "gpu-4")
        manager.addRemoteWorkspace(
            label: "bluecloud",
            hostEntry: HostEntry(label: "bluecloud", address: "10.0.0.2", username: "u"),
            command: "synapty connect --id b --host 10.0.0.2 --port 22 --user u")
        let other = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!

        manager.noteRemoteSessions([session("gpu-4")], for: other)

        XCTAssertEqual(manager.remoteSessions[other.id]?.map(\.name), ["gpu-4"])
    }


    // MARK: - A session this side ended ([[WI-2026-09-21-002]])

    /// THE RACE. The end and the poll are both ssh round trips, so a poll
    /// issued before the end lands its answer after it — and that answer
    /// is the listing from BEFORE, assigned wholesale. The row came back.
    func testAPollThatLeftBeforeTheEndDoesNotBringTheRowBack() {
        let manager = remoteManager()
        let host = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!
        manager.noteRemoteSessions([session("gpu-4"), session("gpu-9")], for: host)

        manager.noteAgentEnded("gpu-4", onHost: host.id)
        XCTAssertEqual(manager.remoteSessions[host.id]?.map(\.name), ["gpu-9"])

        // The poll that was already in flight answers, still naming it.
        manager.noteRemoteSessions([session("gpu-4"), session("gpu-9")], for: host)

        XCTAssertEqual(manager.remoteSessions[host.id]?.map(\.name), ["gpu-9"],
                       "a listing from before the end put the ended session back in "
                       + "front of the human")
    }

    /// AND IT STAYS GONE WITH NO FURTHER POLL, which is what makes the
    /// difference between a minute and forever. `refreshRemoteSessions`
    /// iterates the CONNECTED hosts; once a host's connection is released
    /// nothing writes its key again, so a row put back by the race had
    /// nothing left that could take it away.
    func testAnEndedSessionStaysGoneWithoutAnotherPoll() {
        let manager = remoteManager()
        let host = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!
        manager.noteRemoteSessions([session("gpu-4")], for: host)

        manager.noteAgentEnded("gpu-4", onHost: host.id)

        XCTAssertEqual(manager.remoteSessions[host.id], [],
                       "nothing polls a host whose connection was released")
    }

    /// A NAMESAKE ON ANOTHER MACHINE IS A DIFFERENT SESSION, and ending
    /// one must not silence the other. The sets that record an end were
    /// keyed on the name alone while `shown` had been machine-scoped from
    /// the start.
    func testEndingOneMachinesSessionDoesNotHideItsNamesakeElsewhere() {
        let manager = remoteManager()
        let first = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!
        manager.addRemoteWorkspace(
            label: "bluecloud",
            hostEntry: HostEntry(label: "bluecloud", address: "10.0.0.2", username: "u"),
            command: "synapty connect --id b --host 10.0.0.2 --port 22 --user u")
        let second = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!
        manager.noteRemoteSessions([session("gpu-4")], for: first)
        manager.noteRemoteSessions([session("gpu-4")], for: second)

        manager.noteAgentEnded("gpu-4", onHost: first.id)

        XCTAssertEqual(manager.remoteSessions[first.id], [])
        XCTAssertEqual(manager.remoteSessions[second.id]?.map(\.name), ["gpu-4"],
                       "ending a session on one machine hid its namesake on another")
    }

    /// THE MARK IS A BRIDGE, NOT A GRAVESTONE. It exists to outlast a poll
    /// that was in flight; once a listing arrives without the name, the
    /// host and this side agree. Kept forever it would hide a NEW session
    /// that minted the same name — four hex digits is not many.
    func testAListingThatAgreesRetiresTheMarkSoANameCanBeUsedAgain() {
        let manager = remoteManager()
        let host = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!
        manager.noteRemoteSessions([session("gpu-4")], for: host)
        manager.noteAgentEnded("gpu-4", onHost: host.id)

        // The host agrees: it is gone.
        manager.noteRemoteSessions([], for: host)
        // Later, a new session mints the same name.
        manager.noteRemoteSessions([session("gpu-4")], for: host)

        XCTAssertEqual(manager.remoteSessions[host.id]?.map(\.name), ["gpu-4"],
                       "a new session was hidden by the mark left by an old namesake")
    }

    // MARK: - Ending an archived row waits for the answer ([[WI-2026-09-22-002]])

    /// THE TWO END BUTTONS IN ONE LIST KEPT DIFFERENT DISCIPLINE. The host
    /// row's waits for the far side and keeps its row on a no; this one
    /// fired and forgot and removed the row either way, so a failed end
    /// read as a successful one.
    func testAnArchivedRowSurvivesAnEndThatTheFarSideRefused() async {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!
        manager.recordLeafAgent(pane, "gpu-4")
        manager.remoteAgentEnder = { _, _ in Task { false } }
        manager.archivePane(pane)
        // The host still holds it, so the refusal means what it says.
        manager.noteRemoteSessions([session("gpu-4")], for: host)

        let ended = await manager.endArchivedPane(pane)

        XCTAssertFalse(ended)
        XCTAssertEqual(manager.archivedPanes.map(\.agent), ["gpu-4"],
                       "the end failed, the session is still running, and the row that "
                       + "knew its title went anyway")
    }

    /// BUT A REFUSAL IS TWO DIFFERENT FACTS. `synapty end` answers 2 for a
    /// name it does not hold, and 2 is also this CLI's universal usage
    /// error, so the code cannot say which. A session that was already
    /// gone must still take its row with it, or End becomes the one press
    /// that does nothing on the row a human most wants rid of.
    func testAnEndRefusedForASessionThatHasAlreadyGoneStillTakesTheRow() async {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!
        manager.recordLeafAgent(pane, "gpu-4")
        manager.remoteAgentEnder = { _, _ in Task { false } }
        manager.archivePane(pane)
        // The host has listed what it holds, and this is not among it.
        manager.noteRemoteSessions([session("gpu-9")], for: host,
                                   asOf: Date(timeIntervalSince1970: 0))

        let ended = await manager.endArchivedPane(pane)

        XCTAssertTrue(ended)
        XCTAssertEqual(manager.archivedPanes.map(\.agent), [])
    }

    /// IGNORANCE KEEPS THE ROW. A host nothing has ever listed cannot be
    /// read as a host holding nothing — the distinction this side has been
    /// careful about since [[WI-2026-09-03-012]].
    func testAnEndRefusedWithNoListingAtAllKeepsTheRow() async {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(pane, "gpu-4")
        manager.remoteAgentEnder = { _, _ in Task { false } }
        manager.archivePane(pane)

        let ended = await manager.endArchivedPane(pane)

        XCTAssertFalse(ended)
        XCTAssertEqual(manager.archivedPanes.map(\.agent), ["gpu-4"])
    }

    /// A ROW THAT NAMES NO AGENT HAS NOTHING TO CONFIRM. Requiring one
    /// would make it the only row End cannot remove.
    func testEndingARowWithNoAgentRemovesItWithoutAskingAnybody() async {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.remoteAgentEnder = { _, _ in
            XCTFail("a row with no agent asked the far side to end something")
            return Task { false }
        }
        manager.archivePane(pane)

        let ended = await manager.endArchivedPane(pane)

        XCTAssertTrue(ended)
        XCTAssertEqual(manager.archivedPanes, [])
    }

    // MARK: - An archived row against what the machine holds ([[WI-2026-09-22-001]])

    /// THE ROW NOBODY WAS CHECKING. An archived pane is the only row in
    /// Still Running made of purely local state — written when the human
    /// puts a pane away, read back from the workspace file — and nothing
    /// ever compared it with what the machine it names actually holds. A
    /// session that ended on the far side left a row offering to return
    /// to it, for the life of the app and across restarts.
    func testAnArchivedRowGoesWhenItsHostStopsReportingTheSession() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!
        manager.recordLeafAgent(pane, "gpu-4")
        manager.archivePane(pane)
        XCTAssertEqual(manager.archivedPanes.map(\.agent), ["gpu-4"])

        manager.noteRemoteSessions([session("gpu-9")], for: host)

        XCTAssertEqual(manager.archivedPanes.map(\.agent), [],
                       "the host answered and did not name it, and the row stayed")
    }

    /// A HOST STILL HOLDING IT KEEPS THE ROW, which is the whole point of
    /// the list.
    func testAnArchivedRowStaysWhileItsHostStillHoldsTheSession() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!
        manager.recordLeafAgent(pane, "gpu-4")
        manager.archivePane(pane)

        manager.noteRemoteSessions([session("gpu-4")], for: host)

        XCTAssertEqual(manager.archivedPanes.map(\.agent), ["gpu-4"])
    }

    /// A LISTING CAN ONLY SPEAK ABOUT WHAT EXISTED WHEN IT WAS TAKEN. A
    /// pane put away while a poll was out is not absent from that poll
    /// because it is gone — the same rule as [[WI-2026-09-21-002]],
    /// pointing the other way.
    func testAListingTakenBeforeTheArchivingDoesNotRemoveTheRow() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!
        let askedAt = Date()
        manager.recordLeafAgent(pane, "gpu-4")
        manager.archivePane(pane)

        manager.noteRemoteSessions([], for: host, asOf: askedAt)

        XCTAssertEqual(manager.archivedPanes.map(\.agent), ["gpu-4"],
                       "a poll issued before the pane was put away removed its row")
    }

    /// ANOTHER MACHINE'S ANSWER IS ABOUT ANOTHER MACHINE. A host answers
    /// only for itself, and a row on a different one is not absent from
    /// its listing in any meaningful sense.
    func testAnotherHostsListingLeavesThisHostsArchivedRowAlone() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(pane, "gpu-4")
        manager.archivePane(pane)
        manager.addRemoteWorkspace(
            label: "bluecloud",
            hostEntry: HostEntry(label: "bluecloud", address: "10.0.0.2", username: "u"),
            command: "synapty connect --id b --host 10.0.0.2 --port 22 --user u")
        let other = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!

        manager.noteRemoteSessions([], for: other)

        XCTAssertEqual(manager.archivedPanes.map(\.agent), ["gpu-4"])
    }

    /// A ROW THAT NAMES NO AGENT HAS NOTHING TO ASK ABOUT. A pane archived
    /// before its session registered carries no name, and a listing cannot
    /// be said to omit it.
    func testARowWithNoAgentSurvivesAnyListing() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!
        manager.archivePane(pane)
        XCTAssertEqual(manager.archivedPanes.count, 1)

        manager.noteRemoteSessions([], for: host)

        XCTAssertEqual(manager.archivedPanes.count, 1,
                       "a row with no name was removed by a listing that could not "
                       + "possibly have named it")
    }

    /// AND THIS MACHINE ANSWERS THE SAME QUESTION ABOUT ITS OWN.
    func testALocalArchivedRowGoesWhenItsSessionIsNoLongerHeld() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(pane, "local-1a2b")
        manager.archivePane(pane)
        XCTAssertEqual(manager.archivedPanes.map(\.agent), ["local-1a2b"])

        manager.noteLocalSessions([])

        XCTAssertEqual(manager.archivedPanes.map(\.agent), [])
    }

    /// A LOCAL ROW IS NOT REMOVED BY A HOST'S ANSWER, and a remote one is
    /// not removed by this machine's. They are different machines.
    func testAHostsListingDoesNotReachThisMachinesArchivedRows() {
        let manager = remoteManager()
        let host = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!
        manager.addLocalWorkspace()
        let localPane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(localPane, "local-1a2b")
        manager.archivePane(localPane)

        manager.noteRemoteSessions([], for: host)
        XCTAssertEqual(manager.archivedPanes.map(\.agent), ["local-1a2b"],
                       "a host's listing removed a row for a session on this Mac")

        manager.noteLocalSessions(["local-1a2b"])
        XCTAssertEqual(manager.archivedPanes.map(\.agent), ["local-1a2b"])
    }

    /// A REMOTE PANE SET ASIDE IS STILL HELD ON ITS HOST, so the host
    /// reports it too — and it appeared twice, once from each side. The
    /// set-aside row knows more (the title, the workspace it came from,
    /// that returning puts it back), so it is the one that stays.
    func testAnArchivedRemotePaneIsNotAlsoListedFromItsHost() {
        let manager = remoteManager()
        let host = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!
        let pane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(pane, "gpu-4")
        manager.remoteAgentEnder = { _, _ in Task { true } }
        manager.archivePane(pane)
        manager.noteRemoteSessions(
            [.init(name: "gpu-4", attached: false, everAttached: true, childExited: false,
                   unattached: 30, command: "zsh", directory: "/srv/app", unreachable: false),
             .init(name: "gpu-9", attached: false, everAttached: true, childExited: false,
                   unattached: 30, command: "zsh", directory: "/srv/web", unreachable: false)],
            for: host)

        XCTAssertEqual(manager.remoteSessions[host.id]?.map(\.name), ["gpu-9"],
                       "the one this workbench set aside is already a row")
    }

    /// ONE LIST, ONE ROW. Setting a pane aside forgets its leaf, so the
    /// agent in it stopped being "shown by a pane here" — and under one
    /// heading that put the same work in front of the human twice, once
    /// as the pane they closed and once as an agent nothing shows.
    func testAArchivedPanesAgentIsNotAlsoAnAgentRow() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!
        manager.recordLeafAgent(pane, "gpu-4")
        manager.remoteAgentEnder = { _, _ in Task { true } }
        manager.archivePane(pane)
        peerNamed("remotehost-2630", for: host)

        XCTAssertTrue(manager.stillRunningNames("gpu-4", onPeer: "remotehost-2630"))
        XCTAssertFalse(manager.stillRunningNames("gpu-9", onPeer: "remotehost-2630"))
    }

    /// A HOST'S OWN ROW COUNTS TOO: it knows where the work is and how
    /// long nobody has watched it, which a relayed registration does not.
    func testAHostReportedSessionIsNotAlsoAnAgentRow() {
        let manager = remoteManager()
        let host = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!
        manager.noteRemoteSessions(
            [.init(name: "gpu-7", attached: false, everAttached: true, childExited: false,
                   unattached: 30, command: "zsh", directory: "/srv", unreachable: false)],
            for: host)
        peerNamed("remotehost-2630", for: host)

        XCTAssertTrue(manager.stillRunningNames("gpu-7", onPeer: "remotehost-2630"))
    }

    /// A PEER THIS MAC HAS NEVER DIALLED HAS NO HOST, so no session row
    /// can exist for it and nothing is subtracted — the agent keeps its
    /// row, which is the only place that work is named at all.
    func testAnAgentOnAnUndialledMachineKeepsItsRow() {
        let manager = remoteManager()
        XCTAssertFalse(manager.stillRunningNames("gpu-4", onPeer: "deskmac-2630"))
    }

    // MARK: - Surviving a restart

    /// "THE SAME LEAK WITH A LONGER FUSE" ([[RFC-0015]] C-PANE-ARCHIVE). The
    /// holder outlives the process; a row that did not would leave a live
    /// session nothing names, which is the state this clause exists to end.
    func testAArchivedPaneSurvivesARoundTrip() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(pane, "gpu-7")
        manager.remoteAgentEnder = { _, _ in Task { true } }
        manager.archivePane(pane)

        let restored = WorkspaceManager()
        _ = restored.restore(from: manager.snapshot(planFor: { _ in nil }), hostStore: nil)

        let row = restored.archivedPanes.first
        XCTAssertEqual(restored.archivedPanes.count, 1)
        XCTAssertEqual(row?.agent, "gpu-7", "the name its work answers to")
        XCTAssertEqual(row?.pane.content.isTerminal, true)
    }

    /// RESTORE LISTS THEM RATHER THAN RECONNECTING THEM. A workbench that
    /// reattached every set-aside pane at launch would spend, at the moment
    /// a human is waiting for a window, the cost of work they had already
    /// put out of sight.
    func testRestoreDoesNotPutThemBackInTheLayout() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.archivePane(pane)

        let restored = WorkspaceManager()
        _ = restored.restore(from: manager.snapshot(planFor: { _ in nil }), hostStore: nil)

        XCTAssertEqual(restored.archivedPanes.count, 1)
        XCTAssertNil(restored.workspaces.first?.layout?.findPane(pane),
                     "listed, not connected")
    }

    func testEndingOneLeavesTheOthers() async {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let panes = manager.activeWorkspace!.panes.map(\.id)
        panes.forEach { manager.archivePane($0) }
        XCTAssertEqual(manager.archivedPanes.count, 2)

        await manager.endArchivedPane(panes[0])

        XCTAssertEqual(manager.archivedPanes.map(\.id), [panes[1]])
    }

    // MARK: - Closing ends ([[ADR-0019]])

    /// THE OTHER HALF OF THE GRAMMAR. Closing a pane ends its session and
    /// adds no row; a remote agent is ended through its host.
    func testClosingARemoteTerminalEndsItsAgentAndKeepsNoRow() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(pane, "claude-9")
        var ended: [String] = []
        manager.remoteAgentEnder = { _, id in ended.append(id); return Task { true } }

        manager.closePane(pane)

        XCTAssertEqual(ended, ["claude-9"])
        XCTAssertEqual(manager.archivedPanes, [], "closing keeps nothing")
        XCTAssertNil(manager.activeWorkspace?.layout?.findPane(pane))
    }

    /// ONE ANSWER FOR EVERY MACHINE: a local pane's holder is ended the
    /// same way, through `synapty end` run here.
    func testClosingALocalTerminalEndsItsAgentToo() {
        let manager = makeManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(pane, "local-1a2b")
        var ended: [String] = []
        manager.localAgentEnder = { ended.append($0); return Task { true } }

        manager.closePane(pane)

        XCTAssertEqual(ended, ["local-1a2b"])
        XCTAssertEqual(manager.archivedPanes, [])
    }

    /// THE QUESTION IS ASKED EXACTLY WHEN A FOREGROUND PROCESS WOULD DIE.
    func testOnlyATerminalWithAProcessInTheForegroundIsAskedAbout() {
        XCTAssertEqual(WorkspaceManager.closeDecision(isTerminal: true, foregroundIsProcess: true), .ask)
        XCTAssertEqual(WorkspaceManager.closeDecision(isTerminal: true, foregroundIsProcess: false), .close,
                       "a shell at its prompt closes without a word")
        XCTAssertEqual(WorkspaceManager.closeDecision(isTerminal: false, foregroundIsProcess: true), .close,
                       "a file or browser leaf runs no child")
    }

    /// RELEASE FOLLOWS THE ACT. Archiving is a stated decision and lets
    /// the connection nothing open still needs go at once; closing is
    /// churn and waits out the grace period.
    func testArchivingReleasesAtOnceAndClosingWaitsForTheGrace() {
        let archived = remoteManager()
        archived.connections.grace = 3600
        let remoteHost = archived.host(ofLeaf: archived.activeWorkspace!.panes[0].id)!
        archived.archivePane(archived.activeWorkspace!.panes[0].id)
        XCTAssertNil(archived.connections.connection(forHost: remoteHost.id),
                     "an archive that left the link open would have hidden the work, not put it away")

        let closed = remoteManager()
        closed.connections.grace = 3600
        closed.remoteAgentEnder = { _, _ in Task { true } }
        let host = closed.host(ofLeaf: closed.activeWorkspace!.panes[0].id)!
        closed.closePane(closed.activeWorkspace!.panes[0].id)
        XCTAssertNotNil(closed.connections.connection(forHost: host.id),
                        "closing is the churn the grace period exists to absorb")
    }
}
