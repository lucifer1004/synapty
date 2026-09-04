import XCTest
@testable import Synapty

/// [[RFC-0015]] C-CONTENT: a pane is the layout's atom, and it is not
/// necessarily a terminal.
@MainActor
final class PaneContentTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    private func makeHost(_ label: String) -> HostEntry {
        HostEntry(label: label, address: "10.0.0.1", username: "u")
    }

    // MARK: - Content and connection are separate facts

    /// A file browser is a browser OF a machine: the binding answers for
    /// every kind, not only for terminals.
    func testAFilesPaneAnswersWhichMachineItIsOn() {
        let manager = WorkspaceManager()
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: makeHost("remotehost"),
                                 command: "bash connect.sh a 10.0.0.1 22 u 9000")
        guard let anchor = manager.workspaces[0].panes.first
        else { return XCTFail() }

        let files = manager.addPane(content: .files(directory: nil), toWorkspace: manager.workspaces[0].id)
        guard let files else { return XCTFail("a files pane can be opened") }

        XCTAssertEqual(manager.host(ofLeaf: files)?.label, "remotehost")
        XCTAssertEqual(manager.connectionID(ofLeaf: files), anchor.connectionID,
                       "it joins the machine the human is looking at, not a second link")
    }

    /// A command is meaningless for two kinds out of three and must not
    /// sit on every pane.
    func testOnlyATerminalHasACommand() {
        let terminal = SplitNode.Pane(command: "/bin/zsh", connectionID: UUID())
        let files = SplitNode.Pane(content: .files(directory: nil), connectionID: UUID())
        let web = SplitNode.Pane(content: .services, connectionID: UUID())

        XCTAssertEqual(terminal.content.terminalCommand, "/bin/zsh")
        XCTAssertNil(files.content.terminalCommand)
        XCTAssertNil(web.content.terminalCommand)
        XCTAssertTrue(terminal.content.isTerminal)
        XCTAssertFalse(files.content.isTerminal)
    }

    // MARK: - Every layout operation works on every kind

    func testAFilesPaneCanBeSplitMovedAndClosed() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let workspace = manager.workspaces[0].id
        guard let files = manager.addPane(content: .files(directory: nil), toWorkspace: workspace)
        else { return XCTFail() }

        // Split it. Splitting a file browser gives another file browser,
        // the way splitting a terminal gives another terminal.
        manager.focusLeaf(files)
        manager.splitFocusedLeaf(direction: .horizontal)
        let filesPanes = manager.workspaces[0].panes.filter { $0.content == .files(directory: nil) }
        XCTAssertEqual(filesPanes.count, 2,
                       "a split inherits the kind, not just the machine")

        // Move it onto the first position — the drop-on-centre.
        guard let first = manager.workspaces[0].slots.first?.id else { return XCTFail() }
        manager.stackPane(files, intoSlot: first)
        XCTAssertEqual(manager.workspaces[0].slots.first?.panes.map(\.id).contains(files), true)
        XCTAssertEqual(manager.leafContent(files), .files(directory: nil),
                       "moving a pane does not change what it is showing")

        // Close it.
        manager.leafDidClose(files)
        XCTAssertNil(manager.leafContent(files))
    }

    /// The arrangement docking exists to permit: a terminal and the file
    /// browser watching what it writes, sharing one position.
    func testATabCanHoldATerminalAndAFileBrowser() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let workspace = manager.workspaces[0].id
        guard let terminal = manager.workspaces[0].panes.first?.id,
              let files = manager.addPane(content: .files(directory: nil), toWorkspace: workspace)
        else { return XCTFail() }
        // `addPane` already stacked it onto the focused position; the two
        // are in one place and that place shows tabs.
        guard let slot = manager.workspaces[0].slots.first else { return XCTFail() }
        XCTAssertTrue(slot.isStacked)
        XCTAssertEqual(Set(slot.panes.map(\.id)), [terminal, files])

        let kinds = slot.panes.map(\.content)
        XCTAssertEqual(kinds.filter(\.isTerminal).count, 1)
        XCTAssertEqual(kinds.filter { $0 == .files(directory: nil) }.count, 1)
    }

    // MARK: - The kind survives a restart (C-PERSIST)

    /// A restored arrangement that came back as terminals where the human
    /// left a file browser has not been restored.
    func testAPanesKindSurvivesASnapshotRoundTrip() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let workspace = manager.workspaces[0].id
        _ = manager.addPane(content: .files(directory: nil), toWorkspace: workspace)
        _ = manager.addPane(content: .services, toWorkspace: workspace)

        let snapshot = manager.snapshot(planFor: { _ in nil })
        let restored = WorkspaceManager()
        _ = restored.restore(from: snapshot, hostStore: HostStore())

        // The KIND is durable; a restored terminal's command is minted
        // fresh, so `kindOnly` is what a round trip can be held to.
        let kinds = restored.workspaces.flatMap { $0.panes.map(\.content.kindOnly) }
        XCTAssertEqual(kinds, [.terminal(command: nil), .files(directory: nil), .services],
                       "each pane comes back showing what it was showing")
        // And the restored terminal really did get a command of its own.
        XCTAssertNotNil(restored.workspaces[0].panes[0].content.terminalCommand,
                        "a restored terminal spawns; a files pane has nothing to spawn")
        XCTAssertNil(restored.workspaces[0].panes[1].content.terminalCommand)
    }

    func testAFilesPaneSurvivesEncodingAndDecoding() throws {
        var snapshot = WorkspaceSnapshot()
        snapshot.workspaces = [
            .init(label: "release",
                  root: .slot(.init(panes: [.init(label: "files", content: .files(directory: nil))])))
        ]
        let back = try JSONDecoder().decode(
            WorkspaceSnapshot.self, from: try JSONEncoder().encode(snapshot))
        XCTAssertEqual(back, snapshot)
        XCTAssertEqual(back.workspaces[0].root?.paneEntries[0].content, .files(directory: nil))
    }

}

/// [[WI-2026-08-19-002]] / [[RFC-0015]] C-PERSIST: a file leaf's durable
/// state is the directory it is showing.
@MainActor
final class FileLeafDirectoryTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    private func makeFileLeaf() -> (WorkspaceManager, UUID) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let leaf = manager.addPane(content: .files(directory: nil),
                                   toWorkspace: manager.workspaces[0].id)!
        return (manager, leaf)
    }

    /// THE DEFECT THE HUMAN FELT: switching tabs destroyed the view, and
    /// the pane came back at home — five clicks of navigation on a remote
    /// machine undone by looking at something else. The directory is the
    /// LEAF's now, and a view is free to come and go.
    func testTheLeafRemembersWhereItNavigated() {
        let (manager, leaf) = makeFileLeaf()
        XCTAssertNil(manager.leafContent(leaf)?.fileDirectory, "it starts wherever the machine starts")

        manager.fileLeafDidNavigate(leaf, to: "/Users/operator/work/proj/src")

        XCTAssertEqual(manager.leafContent(leaf)?.fileDirectory, "/Users/operator/work/proj/src")
    }

    /// NAVIGATION CHANGES STATE AND NEVER KIND ([[RFC-0015]] C-CONTENT).
    func testNavigatingDoesNotChangeTheKind() {
        let (manager, leaf) = makeFileLeaf()
        manager.fileLeafDidNavigate(leaf, to: "/tmp")
        XCTAssertNotNil(manager.leafContent(leaf)?.fileDirectory)
        XCTAssertFalse(manager.leafContent(leaf)?.isTerminal ?? true)
    }

    /// A terminal leaf has no directory to move, and asking it to move is
    /// not an error — it is a no-op, because the kind is fixed.
    func testATerminalLeafIgnoresFileNavigation() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let terminal = manager.workspaces[0].panes[0].id
        manager.fileLeafDidNavigate(terminal, to: "/tmp")
        XCTAssertTrue(manager.leafContent(terminal)?.isTerminal ?? false)
    }

    /// AND IT SURVIVES A SNAPSHOT, which is what "durable" means — a file
    /// leaf that came back as a terminal, or at home, has not been
    /// restored ([[RFC-0015]] C-PERSIST).
    func testTheDirectorySurvivesASnapshot() throws {
        let (manager, leaf) = makeFileLeaf()
        manager.fileLeafDidNavigate(leaf, to: "/var/log")

        let data = try JSONEncoder().encode(manager.snapshot(planFor: { _ in nil }))
        let restored = WorkspaceManager()
        _ = restored.restore(from: try JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
                             hostStore: nil)

        let directories = restored.allLeaves.compactMap(\.content.fileDirectory)
        XCTAssertEqual(directories, ["/var/log"])
    }
}

/// [[WI-2026-08-19-002]]: a file pane can be walked back and forward, and
/// the trail survives the human looking at another tab.
@MainActor
final class FileNavigationTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    private func makeLeaf() -> (WorkspaceManager, UUID) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let leaf = manager.addPane(content: .files(directory: nil),
                                   toWorkspace: manager.workspaces[0].id)!
        return (manager, leaf)
    }

    func testBackReturnsToThePreviousDirectoryAndForwardReturnsFromIt() {
        let (manager, leaf) = makeLeaf()
        manager.fileLeafDidNavigate(leaf, to: "/a")
        manager.fileLeafDidNavigate(leaf, to: "/a/b")
        manager.fileLeafDidNavigate(leaf, to: "/a/b/c")

        XCTAssertEqual(manager.fileLeafGoBack(leaf), "/a/b")
        XCTAssertEqual(manager.leafContent(leaf)?.fileDirectory, "/a/b")
        XCTAssertEqual(manager.fileLeafGoForward(leaf), "/a/b/c")
        XCTAssertEqual(manager.leafContent(leaf)?.fileDirectory, "/a/b/c")
    }

    /// A NEW PLACE CLEARS THE FORWARD TRAIL, as it does in every browser.
    func testGoingSomewhereNewDropsTheForwardTrail() {
        let (manager, leaf) = makeLeaf()
        manager.fileLeafDidNavigate(leaf, to: "/a")
        manager.fileLeafDidNavigate(leaf, to: "/a/b")
        _ = manager.fileLeafGoBack(leaf)
        XCTAssertFalse(manager.navigation(ofFileLeaf: leaf).forward.isEmpty)

        manager.fileLeafDidNavigate(leaf, to: "/elsewhere")

        XCTAssertTrue(manager.navigation(ofFileLeaf: leaf).forward.isEmpty,
                     "the road not taken is not still on offer")
    }

    /// GOING BACK IS NOT A NEW PLACE — it must not push what it left onto
    /// the back trail, or back and forward walk in circles.
    func testGoingBackDoesNotRecordItselfAsAVisit() {
        let (manager, leaf) = makeLeaf()
        manager.fileLeafDidNavigate(leaf, to: "/a")
        manager.fileLeafDidNavigate(leaf, to: "/a/b")
        _ = manager.fileLeafGoBack(leaf)
        XCTAssertTrue(manager.navigation(ofFileLeaf: leaf).back.isEmpty,
                       "only /a was behind us, and we are standing on it")
    }

    func testThereIsNowhereToGoFromAFreshPane() {
        let (manager, leaf) = makeLeaf()
        XCTAssertNil(manager.fileLeafGoBack(leaf))
        XCTAssertNil(manager.fileLeafGoForward(leaf))
    }

    /// Picking the sorted column again reverses it — what a column header
    /// does everywhere.
    func testSortingByTheSameColumnTwiceReversesIt() {
        let (manager, leaf) = makeLeaf()
        manager.sortFileLeaf(leaf, by: .size)
        XCTAssertEqual(manager.navigation(ofFileLeaf: leaf).sort, .size)
        XCTAssertTrue(manager.navigation(ofFileLeaf: leaf).ascending)

        manager.sortFileLeaf(leaf, by: .size)
        XCTAssertFalse(manager.navigation(ofFileLeaf: leaf).ascending)

        manager.sortFileLeaf(leaf, by: .name)
        XCTAssertTrue(manager.navigation(ofFileLeaf: leaf).ascending,
                      "a different column starts ascending rather than inheriting")
    }

    /// The filter is per leaf, so two file panes filtered differently stay
    /// that way.
    func testTheFilterBelongsToTheLeaf() {
        let (manager, first) = makeLeaf()
        let second = manager.addPane(content: .files(directory: nil),
                                     toWorkspace: manager.workspaces[0].id)!
        manager.setFilter("swift", ofFileLeaf: first)
        XCTAssertEqual(manager.navigation(ofFileLeaf: first).filter, "swift")
        XCTAssertEqual(manager.navigation(ofFileLeaf: second).filter, "")
    }
}

/// The model half of back/forward moved a leaf that no view was watching.
/// These pin the invariant the view now depends on: after a step, the
/// leaf's directory IS the destination, so a pane that follows its leaf
/// lands there.
@MainActor
final class FileNavigationMovesTheLeafTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    private func makeLeaf() -> (WorkspaceManager, UUID) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let leaf = manager.addPane(content: .files(directory: nil),
                                   toWorkspace: manager.workspaces[0].id)!
        return (manager, leaf)
    }

    /// GOING BACK MOVES THE LEAF, not just the history. The buttons were
    /// wired to a manager that recorded the step and to a view that read
    /// the directory once, on appear — so the model walked and the pane
    /// stood still.
    func testGoingBackChangesTheLeafsDirectory() {
        let (manager, leaf) = makeLeaf()
        manager.fileLeafDidNavigate(leaf, to: "/a")
        manager.fileLeafDidNavigate(leaf, to: "/a/b")

        _ = manager.fileLeafGoBack(leaf)

        XCTAssertEqual(manager.leafContent(leaf)?.fileDirectory, "/a",
                       "the pane follows this value; if it does not move, nothing moves")
    }

    func testGoingForwardChangesItBack() {
        let (manager, leaf) = makeLeaf()
        manager.fileLeafDidNavigate(leaf, to: "/a")
        manager.fileLeafDidNavigate(leaf, to: "/a/b")
        _ = manager.fileLeafGoBack(leaf)

        _ = manager.fileLeafGoForward(leaf)

        XCTAssertEqual(manager.leafContent(leaf)?.fileDirectory, "/a/b")
    }

    /// AND THE STEP DOES NOT RECORD ITSELF. The view reports where it
    /// landed, which arrives back at the manager as a navigation — if that
    /// were recorded, every back would push a forward and the trail would
    /// grow with each press.
    func testLandingWhereTheStepSentUsAddsNoHistory() {
        let (manager, leaf) = makeLeaf()
        manager.fileLeafDidNavigate(leaf, to: "/a")
        manager.fileLeafDidNavigate(leaf, to: "/a/b")
        _ = manager.fileLeafGoBack(leaf)

        // What the view does when its listing succeeds.
        manager.fileLeafDidNavigate(leaf, to: "/a")

        XCTAssertEqual(manager.navigation(ofFileLeaf: leaf).forward.last, "/a/b",
                       "the forward trail survives the pane reporting where it is")
        XCTAssertTrue(manager.navigation(ofFileLeaf: leaf).back.isEmpty)
    }
}

/// Going back to a directory that was on screen a moment ago should not
/// cost three round trips of nothing to look at ([[WI-2026-08-19-002]]).
@MainActor
final class FileListingCacheTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    private func makeLeaf() -> (WorkspaceManager, UUID) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let leaf = manager.addPane(content: .files(directory: nil),
                                   toWorkspace: manager.workspaces[0].id)!
        return (manager, leaf)
    }

    private let listing = [BrowsedFile(name: "camp", size: nil, modified: nil, isDirectory: true)]

    /// KEYED BY PATH, not by leaf. Keyed by leaf it held one listing — the
    /// current one — which is exactly the listing a navigation leaves
    /// behind, so the place a human is most impatient had nothing cached.
    func testEachDirectoryKeepsItsOwnListing() {
        let (manager, leaf) = makeLeaf()
        manager.cacheListing(listing, for: "/a", ofFileLeaf: leaf)
        manager.cacheListing([], for: "/a/b", ofFileLeaf: leaf)

        XCTAssertEqual(manager.navigation(ofFileLeaf: leaf).cached["/a"], listing)
        XCTAssertEqual(manager.navigation(ofFileLeaf: leaf).cached["/a/b"], [])
        XCTAssertNil(manager.navigation(ofFileLeaf: leaf).cached["/elsewhere"])
    }

    /// A WRITE MAKES ITS DIRECTORY'S COPY A LIE, and the copy is DROPPED
    /// rather than patched: the listing is the machine's to state, and a
    /// cache amended with what this application believes it did is a
    /// second claim about a machine, made by the party least able to check
    /// it.
    func testAWriteDropsThatDirectorysCachedCopy() {
        let (manager, leaf) = makeLeaf()
        manager.cacheListing(listing, for: "/a", ofFileLeaf: leaf)
        manager.cacheListing(listing, for: "/b", ofFileLeaf: leaf)

        manager.invalidateCache(path: "/a", ofFileLeaf: leaf)

        XCTAssertNil(manager.navigation(ofFileLeaf: leaf).cached["/a"],
                     "a deleted file would otherwise still be on screen when the human comes back")
        XCTAssertNotNil(manager.navigation(ofFileLeaf: leaf).cached["/b"],
                        "and only that directory is dropped")
    }

    /// The cache is per leaf, so two file panes on two machines cannot
    /// show each other's directories — the paths would collide.
    func testTwoLeavesDoNotShareACache() {
        let (manager, first) = makeLeaf()
        let second = manager.addPane(content: .files(directory: nil),
                                     toWorkspace: manager.workspaces[0].id)!
        manager.cacheListing(listing, for: "/home/operator", ofFileLeaf: first)
        XCTAssertNil(manager.navigation(ofFileLeaf: second).cached["/home/operator"],
                     "same path, different machine — one listing must not answer for the other")
    }
}
