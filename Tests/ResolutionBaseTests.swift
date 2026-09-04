import XCTest
@testable import Synapty

/// WHERE A RELATIVE NAME IN A PANE'S OUTPUT IS RESOLVED FROM.
///
/// [[RFC-0015]] C-DERIVED requires this directory to be one the holder
/// reported. The same fact ANNOUNCED by the child in its own output is a
/// string the child chose — [[RFC-0014]] C-PWD requires an answer that
/// does not depend on the child having announced anything — so OSC 7 is
/// session contents here, not process metadata.
@MainActor
final class ResolutionBaseTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    private func makeManager() -> WorkspaceManager {
        let m = WorkspaceManager()
        m.addLocalWorkspace()
        return m
    }

    func testTheKernelAnswersAndTheChildDoesNot() {
        let manager = makeManager()
        let leaf = manager.activeWorkspace!.panes[0].id
        manager.leafDidUpdatePwd(leaf, pwd: "/tmp/announced")
        manager.observedPwd = { _ in "/tmp/kernel" }

        XCTAssertEqual(manager.resolutionBase(ofLeaf: leaf), "/tmp/kernel")
    }

    func testAChildsWordAloneIsNoBaseAtAll() {
        let manager = makeManager()
        let leaf = manager.activeWorkspace!.panes[0].id
        manager.leafDidUpdatePwd(leaf, pwd: "/tmp/announced")
        manager.observedPwd = { _ in nil }

        XCTAssertNil(manager.resolutionBase(ofLeaf: leaf),
                     "an announced directory is a string the child chose")
    }

    /// A REMOTE PANE'S KERNEL IS THE WRONG KERNEL. Its foreground process
    /// on this Mac is an ssh client, so reading it would answer with a
    /// local path for a remote shell — confidently, and wrongly.
    func testARemotePaneIsNotAnsweredByThisMachinesKernel() {
        let manager = WorkspaceManager()
        let host = HostEntry(label: "remotehost", address: "10.0.0.1", username: "u")
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: host,
                                   command: "bash connect.sh a 10.0.0.1 22 u 9000")
        let leaf = manager.activeWorkspace!.panes[0].id
        manager.observedPwd = { _ in "/Users/z/on-this-mac" }

        XCTAssertNil(manager.resolutionBase(ofLeaf: leaf))
    }

    func testTheHolderAnswersForARemotePane() {
        let manager = WorkspaceManager()
        let host = HostEntry(label: "remotehost", address: "10.0.0.1", username: "u")
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: host,
                                   command: "bash connect.sh a 10.0.0.1 22 u 9000")
        let leaf = manager.activeWorkspace!.panes[0].id
        manager.leafDidLearnAttestedPwd(leaf, pwd: "/srv/work")
        manager.leafDidUpdatePwd(leaf, pwd: "/tmp/announced")

        XCTAssertEqual(manager.resolutionBase(ofLeaf: leaf), "/srv/work",
                       "the holder's answer, not the child's")
    }

    // MARK: - What must not change

    /// Every existing reader of `pwd(ofLeaf:)` keeps the answer it had.
    /// The provenance split is additive: it tells the two sources apart
    /// for the one reader that must, and moves nothing else.
    func testTheShellsWordStillWinsForEverybodyElse() {
        let manager = makeManager()
        let leaf = manager.activeWorkspace!.panes[0].id
        manager.leafDidUpdatePwd(leaf, pwd: "/tmp/announced")
        manager.observedPwd = { _ in "/tmp/kernel" }

        XCTAssertEqual(manager.pwd(ofLeaf: leaf), "/tmp/announced")
        XCTAssertEqual(manager.reportedPwd(ofLeaf: leaf), "/tmp/announced")
    }

    func testAHoldersAnswerStillSatisfiesTheOldReader() {
        // `refreshRemotePwd` used to write the same field OSC 7 does, and
        // `reportedPwd` answered for both. Splitting the storage must not
        // make a holder-answered pane look like one that has said nothing.
        let manager = makeManager()
        let leaf = manager.activeWorkspace!.panes[0].id
        manager.leafDidLearnAttestedPwd(leaf, pwd: "/srv/work")

        XCTAssertEqual(manager.reportedPwd(ofLeaf: leaf), "/srv/work")
    }
}
