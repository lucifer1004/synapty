import XCTest
@testable import Synapty

/// WHAT TAKING AN OFFER DOES.
///
/// [[RFC-0015]] C-DERIVED bounds it to opening a FILE LEAF, on the machine
/// the source pane is bound to, showing the directory that holds what the
/// text named. Not a terminal leaf, not a browser leaf, and never an
/// address.
@MainActor
final class TakenActionTests: XCTestCase {

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

    func testItOpensTheDirectoryThatHoldsTheFile() {
        let manager = makeManager()
        let source = manager.activeWorkspace!.panes[0].id

        let opened = manager.showWhereItLives("/w/Sources/App.swift", from: source)

        XCTAssertNotNil(opened)
        let pane = manager.activeWorkspace!.panes.first { $0.id == opened }
        XCTAssertEqual(pane?.content.fileDirectory, "/w/Sources")
    }

    func testATrailingSlashIsAlreadyADirectory() {
        let manager = makeManager()
        let source = manager.activeWorkspace!.panes[0].id

        let opened = manager.showWhereItLives("/w/Sources/", from: source)

        let pane = manager.activeWorkspace!.panes.first { $0.id == opened }
        XCTAssertEqual(pane?.content.fileDirectory, "/w/Sources")
    }

    func testAPathAtTheRootOpensTheRoot() {
        let manager = makeManager()
        let source = manager.activeWorkspace!.panes[0].id

        let opened = manager.showWhereItLives("/passwd", from: source)

        let pane = manager.activeWorkspace!.panes.first { $0.id == opened }
        XCTAssertEqual(pane?.content.fileDirectory, "/")
    }

    /// A PATH PRINTED BY A REMOTE PANE IS A PATH ON THAT MACHINE. Opening
    /// it here would show a different file wearing the same name.
    func testItOpensOnTheMachineThePaneIsBoundTo() {
        let manager = WorkspaceManager()
        let host = HostEntry(label: "remotehost", address: "10.0.0.1", username: "u")
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: host,
                                   command: "bash connect.sh a 10.0.0.1 22 u 9000")
        let source = manager.activeWorkspace!.panes[0].id

        let opened = manager.showWhereItLives("/srv/app/main.zig", from: source)

        XCTAssertNotNil(opened)
        XCTAssertEqual(manager.host(ofLeaf: opened!)?.label, "remotehost")
    }

    func testALocalPaneOpensLocally() {
        let manager = makeManager()
        let source = manager.activeWorkspace!.panes[0].id

        let opened = manager.showWhereItLives("/tmp/a.txt", from: source)

        XCTAssertTrue(manager.isLocalLeaf(opened!))
    }

    /// The pane it opens is a FILE leaf, which is the only surface the
    /// clause admits — never a terminal, which is the kind that runs a
    /// child, and never a browser.
    func testWhatOpensIsAFileLeaf() {
        let manager = makeManager()
        let source = manager.activeWorkspace!.panes[0].id

        let opened = manager.showWhereItLives("/tmp/a.txt", from: source)
        let pane = manager.activeWorkspace!.panes.first { $0.id == opened }

        XCTAssertNotNil(pane?.content.fileDirectory)
        XCTAssertFalse(pane!.content.isTerminal)
    }

    /// A PATH THAT IS ITSELF A DIRECTORY OPENS AS ITSELF. Asking the
    /// filesystem is allowed on the pane's own machine — it tells an agent
    /// nothing it could not read itself — and this is what it buys.
    func testADirectoryOpensAsItself() {
        let manager = makeManager()
        manager.pathIsDirectory = { $0 == "/w/src" }
        let source = manager.activeWorkspace!.panes[0].id

        let opened = manager.showWhereItLives("/w/src", from: source)
        let pane = manager.activeWorkspace!.panes.first { $0.id == opened }
        XCTAssertEqual(pane?.content.fileDirectory, "/w/src")
    }

    func testAFileStillOpensTheDirectoryThatHoldsIt() {
        let manager = makeManager()
        manager.pathIsDirectory = { _ in false }
        let source = manager.activeWorkspace!.panes[0].id

        let opened = manager.showWhereItLives("/w/src/main.zig", from: source)
        let pane = manager.activeWorkspace!.panes.first { $0.id == opened }
        XCTAssertEqual(pane?.content.fileDirectory, "/w/src")
    }

    /// A REMOTE ANSWER COSTS A ROUND TRIP, and the clause lets an
    /// implementation decline it. Declining means the directory, which is
    /// never wrong — only less specific.
    func testARemotePathIsNotProbed() {
        let manager = WorkspaceManager()
        let host = HostEntry(label: "remotehost", address: "10.0.0.1", username: "u")
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: host,
                                   command: "bash connect.sh a 10.0.0.1 22 u 9000")
        var asked: [String] = []
        manager.pathIsDirectory = { asked.append($0); return true }
        let source = manager.activeWorkspace!.panes[0].id

        let opened = manager.showWhereItLives("/srv/app", from: source)
        let pane = manager.activeWorkspace!.panes.first { $0.id == opened }
        XCTAssertEqual(pane?.content.fileDirectory, "/srv")
        XCTAssertEqual(asked, [], "a remote path must not be probed from here")
    }

    // MARK: - Attribution

    /// WHAT OPENS INSIDE THE WORKBENCH MUST SAY WHOSE OUTPUT IT CAME FROM
    /// ([[RFC-0015]] C-DERIVED rule five). A file leaf that appeared
    /// because untrusted text named a path is not one the human navigated
    /// to, and nothing else on it says so.
    func testTheOpenedLeafNamesThePaneItCameFrom() {
        let manager = makeManager()
        let source = manager.activeWorkspace!.panes[0].id
        manager.recordLeafAgent(source, "claude-1")

        let opened = manager.showWhereItLives("/tmp/a.txt", from: source)

        let from = manager.openedFrom(leaf: opened!)
        XCTAssertEqual(from?.pane, source)
        XCTAssertEqual(from?.agent, "claude-1")
    }

    /// THE SOURCE PANE CAN BE CLOSED WHILE THIS ONE STAYS, and the
    /// attribution still has to say something rather than vanish — a
    /// silent strip would leave a pane the human never navigated to
    /// looking like one they did.
    func testAClosedSourcePaneIsStillNamed() {
        let manager = makeManager()
        let source = manager.activeWorkspace!.panes[0].id
        let opened = manager.showWhereItLives("/tmp/a.txt", from: source)!

        manager.archivePane(source)

        XCTAssertNotNil(manager.openedFrom(leaf: opened))
        let said = manager.openedFromDescription(leaf: opened)
        XCTAssertEqual(said?.contains("closed"), true, "got: \(said ?? "nil")")
    }

    /// A LEAF THE HUMAN OPENED THEMSELVES OWES NOTHING. Attribution is for
    /// what arrived because text said so.
    func testAnOrdinaryFileLeafHasNoAttribution() {
        let manager = makeManager()
        let workspace = manager.activeWorkspaceID!
        let opened = manager.addPane(content: .files(directory: "/tmp"), toWorkspace: workspace)
        XCTAssertNil(manager.openedFrom(leaf: opened!))
    }

    func testARelativePathIsRefused() {
        // Resolution happens before this is reached; anything still
        // relative here is a caller that skipped it.
        let manager = makeManager()
        let source = manager.activeWorkspace!.panes[0].id

        XCTAssertNil(manager.showWhereItLives("Sources/App.swift", from: source))
    }

    func testAPaneThatIsGoneOpensNothing() {
        let manager = makeManager()
        XCTAssertNil(manager.showWhereItLives("/tmp/a", from: UUID()))
    }
}
