import XCTest
@testable import Synapty

/// WHAT HAPPENS TO THE PANE WHOSE SEAT WAS TAKEN ([[RFC-0014]]
/// C-ONE-CLIENT).
///
/// The clause always required a displaced client to be told rather than
/// left to infer a transport failure from silence, and the protocol
/// always told it: the holder sends a `displaced` frame and the client
/// writes the reason. Then the client exits — and that exit IS the pane's
/// close, so the sentence was destroyed by the same event that produced
/// it. What the human saw was a tab disappearing.
///
/// The clause now names that: telling the process is not telling the
/// human.
@MainActor
final class DisplacedClientTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        ConfigPaths.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-displaced-\(UUID().uuidString)")
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
        if let root = ConfigPaths.rootOverride {
            try? FileManager.default.removeItem(at: root)
        }
        ConfigPaths.rootOverride = nil
    }

    // MARK: - Reading the account

    /// A LINE IS `<milliseconds> <kind> <text>`, and the client writes
    /// this one with a single unbuffered write before it exits.
    func testAnAccountEndingInDisplacementIsRecognised() {
        XCTAssertTrue(ConnectProgress.endsDisplaced(
            "1 start ssh\n2 paint -\n3 end displaced\n"))
    }

    func testAnOrdinaryEndIsNotADisplacement() {
        XCTAssertFalse(ConnectProgress.endsDisplaced(
            "1 start ssh\n2 paint -\n3 end child_exited\n"))
        XCTAssertFalse(ConnectProgress.endsDisplaced("1 start ssh\n"))
        XCTAssertFalse(ConnectProgress.endsDisplaced(""))
    }

    /// THE LAST THING SAID, NOT THE LAST `end` SAID. One account holds
    /// every dial a pane has made, so a displacement with a later dial
    /// after it describes a session that has already been replaced —
    /// reading it as current would refuse to close a pane whose shell
    /// simply exited.
    func testADisplacementWithADialAfterItIsOver() {
        XCTAssertFalse(ConnectProgress.endsDisplaced(
            "1 end displaced\n2 start ssh\n3 paint -\n"))
    }

    // MARK: - What the pane does

    private func remoteManager() -> WorkspaceManager {
        let m = WorkspaceManager()
        m.addRemoteWorkspace(
            label: "remotehost",
            hostEntry: HostEntry(label: "remotehost", address: "10.0.0.1", username: "u"),
            command: "bash connect.sh a 10.0.0.1 22 u 9000")
        return m
    }

    /// Put a real account on disk under the test root and follow it, the
    /// way a dial does — the mechanism under test is that the close reads
    /// this file, so a test that set the flag directly would test nothing.
    private func accountSaying(_ line: String, for leaf: UUID,
                               agent: String, in manager: WorkspaceManager) {
        let url = ConnectProgress.begin(for: agent)
        try? Data(line.utf8).write(to: url)
        manager.connectProgress.begin(session: leaf, agentID: agent)
    }

    /// THE DEFECT. The pane closed on top of the only sentence that said
    /// why, leaving the human with the silence the clause forbids —
    /// reached the long way round, through a protocol that satisfied it.
    func testAPaneWhoseSessionWasTakenStaysAndSaysSo() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        accountSaying("1 end displaced\n", for: pane, agent: "gpu-4", in: manager)

        manager.leafDidClose(pane)

        XCTAssertNotNil(manager.activeWorkspace?.layout?.findPane(pane),
                        "the pane is what carries the reason")
        XCTAssertEqual(manager.surface(of: pane), .taken)
    }

    /// AND ONLY THEN. A shell that exited is a pane that is finished, and
    /// keeping it would put a dead rectangle in every layout.
    func testAPaneWhoseChildSimplyExitedStillCloses() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        accountSaying("1 end child_exited\n", for: pane, agent: "gpu-4", in: manager)

        manager.leafDidClose(pane)

        XCTAssertNil(manager.activeWorkspace?.layout?.findPane(pane))
    }

    /// A LEAF-LEVEL FACT, READ BEFORE THE LINK. Displacement leaves the
    /// host perfectly reachable — every other pane on it keeps working —
    /// so a surface derived from the connection would find `connected`
    /// and hand a dead pane a terminal.
    func testTheOtherPanesOnThatHostAreUnaffected() {
        let manager = remoteManager()
        let workspace = manager.activeWorkspaceID!
        let taken = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: taken)!
        let other = manager.addRemotePane(
            toWorkspace: workspace, label: "remotehost", hostEntry: host)
        accountSaying("1 end displaced\n", for: taken, agent: "gpu-4", in: manager)

        manager.leafDidClose(taken)

        XCTAssertEqual(manager.surface(of: taken), .taken)
        XCTAssertNotEqual(manager.surface(of: other), .taken)
    }

    /// A DIAL SUPERSEDES THE LOSS IT ANSWERS: taking the session back is
    /// the offer on that notice, and from the moment it is accepted the
    /// pane is dialling rather than displaced.
    func testTakingItBackClearsTheNotice() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        accountSaying("1 end displaced\n", for: pane, agent: "gpu-4", in: manager)
        manager.leafDidClose(pane)

        manager.markLeafConnecting(pane)

        XCTAssertNotEqual(manager.surface(of: pane), .taken)
    }

    /// CLOSING IT CLOSES IT. A displaced pane has no client left to set
    /// aside — its child exited, which is the same ground on which a pane
    /// whose shell exited closes rather than becoming a row. The session
    /// is not lost with it: somebody else is attached, and its host lists
    /// it ([[RFC-0014]] C-END).
    func testClosingADisplacedPaneDoesNotSetItAside() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        manager.remoteAgentEnder = { _, _ in Task { true } }
        accountSaying("1 end displaced\n", for: pane, agent: "gpu-4", in: manager)
        manager.leafDidClose(pane)

        manager.archivePane(pane)

        XCTAssertEqual(manager.archivedPanes, [])
    }

    // MARK: - The other side of the same act

    private func session(_ name: String, attached: Bool) -> RemoteSessions.Session {
        .init(name: name, attached: attached, everAttached: true, childExited: false,
              unattached: attached ? 0 : 30, command: "zsh", directory: "/srv",
              unreachable: false)
    }

    /// WHAT THE OFFER COSTS, ASKED BEFORE IT IS ACCEPTED. A row listing a
    /// session as somewhere to return to describes the ordinary case,
    /// where nobody is there.
    func testOpeningAnOccupiedSessionIsKnownToDisplace() {
        let manager = remoteManager()
        let host = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!
        manager.noteRemoteSessions(
            [session("gpu-8", attached: true), session("gpu-9", attached: false)],
            for: host)

        XCTAssertTrue(manager.attachWouldDisplace("gpu-8", on: host))
        XCTAssertFalse(manager.attachWouldDisplace("gpu-9", on: host))
    }

    /// ANSWERABLE ONLY BECAUSE THE LIST SUBTRACTS OUR OWN. A session a
    /// pane here names is not in this table at all, so an entry saying
    /// `attached` is attached to somebody who is not us — which is what
    /// makes the question worth asking rather than a dialog in front of
    /// every reopen.
    func testOurOwnOpenPaneIsNotSomebodyToDisplace() {
        let manager = remoteManager()
        let pane = manager.activeWorkspace!.panes[0].id
        let host = manager.host(ofLeaf: pane)!
        manager.recordLeafAgent(pane, "gpu-4")
        manager.noteRemoteSessions([session("gpu-4", attached: true)], for: host)

        XCTAssertFalse(manager.attachWouldDisplace("gpu-4", on: host))
    }

    func testAHostThatHasNotBeenAskedDisplacesNobody() {
        let manager = remoteManager()
        let host = manager.host(ofLeaf: manager.activeWorkspace!.panes[0].id)!
        XCTAssertFalse(manager.attachWouldDisplace("gpu-8", on: host))
    }
}
