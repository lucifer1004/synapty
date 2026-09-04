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
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
        hostStore = nil
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
            command: "bash connect.sh a 10.0.0.1 22 u 9000")
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
    func testEndingRemovesTheRowAndEndsTheAgent() {
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

        manager.endArchivedPane(pane)

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
            command: "bash connect.sh b 10.0.0.2 22 u 9000")
        let other = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!

        manager.noteRemoteSessions([session("gpu-4")], for: other)

        XCTAssertEqual(manager.remoteSessions[other.id]?.map(\.name), ["gpu-4"])
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

    func testEndingOneLeavesTheOthers() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let panes = manager.activeWorkspace!.panes.map(\.id)
        panes.forEach { manager.archivePane($0) }
        XCTAssertEqual(manager.archivedPanes.count, 2)

        manager.endArchivedPane(panes[0])

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
