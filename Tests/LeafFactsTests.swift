import XCTest
@testable import Synapty

/// A LEAF THAT IS GONE IS FORGOTTEN ([[LeafFacts]]).
///
/// Eight tables, three close paths, each clearing a different subset — and
/// the one path that cleared five of them was reached only when a SHELL
/// EXITED. Closing a pane the way a human closes a pane cleared one.
///
/// Measured before the fold, on a pane closed with the tab bar's ✕:
///
///     PROBE before: nav=1 attention=1 titles=1
///     PROBE after:  nav=1 attention=1 titles=1
///
/// The visible half was a sidebar badge counting a pane that no longer
/// existed — and it could never come down, because attending to a leaf
/// means looking at it and there was nothing left to look at.
@MainActor
final class LeafFactsTests: XCTestCase {

    private func makeManager() -> (WorkspaceManager, UUID, UUID) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard let workspace = manager.activeWorkspaceID,
              let leaf = manager.addPane(content: .files(directory: nil), toWorkspace: workspace),
              let other = manager.addPane(content: .files(directory: nil), toWorkspace: workspace)
        else { fatalError("the manager would not make two panes") }
        // Attention is refused on the leaf being looked at, so the second
        // pane holds focus throughout.
        manager.leafDidFocus(other)
        return (manager, leaf, other)
    }

    func testClosingAPaneForgetsEverythingKnownAboutIt() {
        let (manager, leaf, _) = makeManager()
        manager.fileLeafDidNavigate(leaf, to: "/tmp/somewhere", recordingHistory: true)
        manager.cacheListing([], for: "/tmp/somewhere", ofFileLeaf: leaf)
        manager.leafDidUpdateTitle(leaf, title: "a title")
        manager.leafDidUpdatePwd(leaf, pwd: "/tmp/somewhere")
        manager.markLeafAttention(leaf)
        XCTAssertNotNil(manager.facts[leaf], "nothing was recorded, so nothing is being tested")

        manager.archivePane(leaf)

        XCTAssertNil(manager.facts[leaf],
                     "the workbench still knows things about a pane that no longer exists")
    }

    /// THE VISIBLE HALF. `attentionCount` drives the sidebar badge and the
    /// window's notification; a dead leaf in it is a number that never
    /// comes down.
    func testTheAttentionBadgeDoesNotCountPanesThatAreGone() {
        let (manager, leaf, _) = makeManager()
        manager.markLeafAttention(leaf)
        XCTAssertEqual(manager.attentionCount, 1)

        manager.archivePane(leaf)

        XCTAssertEqual(manager.attentionCount, 0,
                       "the badge counts a closed pane, and nothing can ever attend to it")
    }

    /// ⌘W reaches the same place as the ✕, and a pane closed because its
    /// shell exited reaches it through `leafDidClose`. All three end in
    /// `detach`, which is the point of putting the removal there.
    func testEveryCloseRouteForgets() {
        for close in [("closePane", { (m: WorkspaceManager, l: UUID) in m.archivePane(l) }),
                      ("shell exited", { (m: WorkspaceManager, l: UUID) in m.leafDidClose(l) })] {
            let (manager, leaf, _) = makeManager()
            manager.leafDidUpdateTitle(leaf, title: "t")
            manager.markLeafAttention(leaf)

            close.1(manager, leaf)

            XCTAssertNil(manager.facts[leaf], "closing by \(close.0) left the leaf remembered")
            XCTAssertEqual(manager.attentionCount, 0, "closing by \(close.0) left the badge lit")
        }
    }

    /// MOVING IS NOT CLOSING. A pane dragged to another workspace is the
    /// same pane, and forgetting it there would lose its directory, its
    /// title and its agent — which is why the removal lives in `detach`
    /// and not in every path that takes a pane out of a tree.
    func testMovingAPaneBetweenWorkspacesKeepsWhatIsKnownAboutIt() {
        let (manager, leaf, _) = makeManager()
        manager.leafDidUpdateTitle(leaf, title: "keep me")
        manager.addLocalWorkspace()
        guard let destination = manager.activeWorkspaceID else { return XCTFail() }

        manager.movePane(leaf, toWorkspace: destination)

        XCTAssertEqual(manager.facts[leaf]?.title, "keep me",
                       "a pane that moved was treated as a pane that died")
    }

    /// A SERVICES LEAF REMEMBERS WHAT IT IS SHOWING ACROSS A TAB SWITCH,
    /// and forgets it across a restart.
    ///
    /// The two are different questions and only the second is what
    /// [[RFC-0015]] C-CONTENT answers with "none of its own": an exposure
    /// id from a previous run names nothing, because the offers died with
    /// the process. Held only in the view, though, looking at another tab
    /// put the human back at the list with no sign anything was lost.
    func testAServicesLeafRemembersWhatItIsShowing() {
        let (manager, leaf, _) = makeManager()
        let exposure = UUID()

        manager.servicesLeaf(leaf, isShowing: exposure)

        XCTAssertEqual(manager.viewing(ofServicesLeaf: leaf), exposure,
                       "the leaf did not keep what its view was showing")
    }

    /// An agent that withdrew its view leaves the leaf showing nothing,
    /// and the record goes with it — otherwise coming back would restore a
    /// page nobody is offering.
    func testDismissingClearsWhatTheLeafRemembers() {
        let (manager, leaf, _) = makeManager()
        manager.servicesLeaf(leaf, isShowing: UUID())

        manager.servicesLeaf(leaf, isShowing: nil)

        XCTAssertNil(manager.viewing(ofServicesLeaf: leaf))
    }

    /// And it is forgotten with the leaf, like everything else about it.
    func testClosingAServicesPaneForgetsWhatItWasShowing() {
        let (manager, leaf, _) = makeManager()
        manager.servicesLeaf(leaf, isShowing: UUID())

        manager.archivePane(leaf)

        XCTAssertNil(manager.viewing(ofServicesLeaf: leaf))
    }

    /// THE ARRANGEMENT'S SIGNATURE CHANGES WHEN A RESTORE WOULD NOTICE
    /// ([[RFC-0015]] C-PERSIST: written on change, not on a timer).
    ///
    /// The periodic write left a window a `kill` fitted through: a pane
    /// opened and the workbench gone before the next tick came back as an
    /// empty workspace.
    func testOpeningAPaneChangesTheArrangementSignature() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard let workspace = manager.activeWorkspaceID else { return XCTFail() }
        let before = manager.arrangementSignature

        _ = manager.addPane(content: .files(directory: nil), toWorkspace: workspace)

        XCTAssertNotEqual(manager.arrangementSignature, before,
                          "a new pane did not register as a change, so nothing would be written")
    }

    /// AND WHERE A PANE IS LOOKING IS PART OF IT — a file leaf that came
    /// back somewhere else has not been restored.
    func testNavigatingAFileLeafChangesTheSignature() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard let workspace = manager.activeWorkspaceID,
              let leaf = manager.addPane(content: .files(directory: nil), toWorkspace: workspace)
        else { return XCTFail() }
        let before = manager.arrangementSignature

        manager.fileLeafDidNavigate(leaf, to: "/tmp/elsewhere")

        XCTAssertNotEqual(manager.arrangementSignature, before)
    }

    /// A SHELL'S TITLE IS NOT AN ARRANGEMENT. Rewriting the file for every
    /// title a busy terminal emits is how a snapshot becomes a hot loop.
    func testAShellTitleDoesNotChangeTheSignature() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard let workspace = manager.activeWorkspaceID,
              let leaf = manager.addPane(content: .files(directory: nil), toWorkspace: workspace)
        else { return XCTFail() }
        let before = manager.arrangementSignature

        manager.leafDidUpdateTitle(leaf, title: "make -j8")

        XCTAssertEqual(manager.arrangementSignature, before,
                       "a title from a shell would rewrite the snapshot")
    }

}
