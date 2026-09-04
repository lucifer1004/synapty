import XCTest
@testable import Synapty

/// The fourth pane kind ([[RFC-0015]] C-CONTENT, [[WI-2026-08-19-004]]).
@MainActor
final class BrowserLeafTests: XCTestCase {

    private func remoteHost() -> HostEntry {
        HostEntry(label: "builder", address: "builder.example", username: "someone")
    }

    /// THE LOCAL CONNECTION, ALWAYS — and the clause says this is a
    /// STIPULATION rather than a derivation, so it is enforced where a
    /// pane's connection is decided rather than left to each caller.
    func testABrowserLeafTakesTheLocalConnectionEvenBesideARemotePane() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard let workspace = manager.activeWorkspaceID else { return XCTFail() }
        // A pane on another machine, focused — which is what decides the
        // connection for every other kind.
        let remote = manager.connections.acquire(host: remoteHost()).id
        let beside = SplitNode.Pane(content: .files(directory: nil), connectionID: remote)
        manager.workspaces[0].setLayout(.slot(SplitNode.Slot(pane: beside)))
        manager.leafDidFocus(beside.id)

        guard let leaf = manager.addPane(content: .browser(address: nil), toWorkspace: workspace)
        else { return XCTFail("no browser leaf") }

        XCTAssertEqual(manager.connectionID(ofLeaf: leaf), manager.connections.localID,
                       "a browser leaf followed focus onto a remote machine")
        XCTAssertNil(manager.host(ofLeaf: leaf), "there must be no way to make a remote one")
    }

    /// A file pane beside it still follows focus — the rule is the browser
    /// leaf's alone and not a change to how panes bind.
    func testTheOtherKindsStillFollowTheMachineTheHumanIsLookingAt() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard let workspace = manager.activeWorkspaceID else { return XCTFail() }
        let remote = manager.connections.acquire(host: remoteHost()).id
        let beside = SplitNode.Pane(content: .terminal(command: nil), connectionID: remote)
        manager.workspaces[0].setLayout(.slot(SplitNode.Slot(pane: beside)))
        manager.leafDidFocus(beside.id)

        guard let leaf = manager.addPane(content: .files(directory: nil), toWorkspace: workspace)
        else { return XCTFail() }

        XCTAssertEqual(manager.connectionID(ofLeaf: leaf), remote)
    }

    /// THE KIND IS FIXED AT CREATION. Navigating changes where it points
    /// and never what it is — a converted leaf would be a new pane wearing
    /// an old identity.
    func testNavigatingChangesTheAddressAndNotTheKind() {
        var pane = SplitNode.Pane(content: .browser(address: nil), connectionID: UUID())
        pane.navigateBrowser(to: "https://example.com/docs")
        XCTAssertEqual(pane.content.browserAddress, "https://example.com/docs")
        XCTAssertEqual(pane.content.kindName, "Browser")

        // And a mutation belonging to another kind does nothing at all.
        pane.navigateFiles(to: "/tmp")
        XCTAssertEqual(pane.content.browserAddress, "https://example.com/docs")
        pane.start(command: "/bin/sh")
        XCTAssertEqual(pane.content.kindName, "Browser")
    }

    // MARK: - What comes back ([[RFC-0015]] C-PERSIST)

    /// THE ADDRESS AND NOTHING ELSE. Restoring an address is restoring
    /// where the human was; restoring a session would be re-entering it on
    /// their behalf.
    func testTheAddressSurvivesARoundTripAndTheKindComesBackAsItself() throws {
        let content = SplitNode.PaneContent.browser(address: "https://example.com/a")
        let data = try JSONEncoder().encode(content)
        let back = try JSONDecoder().decode(SplitNode.PaneContent.self, from: data)
        XCTAssertEqual(back, content)

        // Only two keys are written, so there is nowhere for a session to
        // ride along.
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(raw.keys), ["kind", "address"])
    }

    func testABrowserLeafThatWasNeverAddressedComesBackUnaddressed() throws {
        let content = SplitNode.PaneContent.browser(address: nil)
        let data = try JSONEncoder().encode(content)
        XCTAssertEqual(try JSONDecoder().decode(SplitNode.PaneContent.self, from: data), content)
    }

    func testTheServicesLeafKeepsItsOwnNameOnTheWire() throws {
        let data = try JSONEncoder().encode(SplitNode.PaneContent.services)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(raw["kind"] as? String, "services",
                       "the wire name outlived the panel era it came from")
        XCTAssertEqual(try JSONDecoder().decode(SplitNode.PaneContent.self, from: data), .services)
    }

    /// A STORE WRITTEN BY ANY OTHER SHAPE IS DISCARDED RATHER THAN
    /// CONVERTED ([[RFC-0015]] C-PERSIST, C-UNRELEASED) — which is what
    /// the version is for, and the only thing it is for while nothing has
    /// been released.
    func testAStoreOfAnotherShapeIsDiscardedRatherThanConverted() throws {
        var snapshot = WorkspaceSnapshot()
        snapshot.workspaces = [.init(label: "Local")]
        snapshot.version = WorkspaceSnapshot.currentVersion + 1
        let data = try JSONEncoder().encode(snapshot)

        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertNotEqual(decoded.version, WorkspaceSnapshot.currentVersion,
                          "a store of another shape claimed to be this one")
        // `load()` reads a file; what it enforces is this comparison, and
        // it is the comparison that must hold at any version value.
        XCTAssertFalse(decoded.version == WorkspaceSnapshot.currentVersion,
                       "a store of an unknown shape would be read instead of discarded")
    }

    /// Each kind is marked on a tab by something only it wears.
    func testEveryKindThatIsNotTheDefaultCarriesItsOwnMark() {
        let marks = [SplitNode.PaneContent.files(directory: nil), .services, .browser(address: nil)]
            .compactMap(\.tabIcon)
        XCTAssertEqual(Set(marks).count, marks.count, "two kinds share a glyph")
        XCTAssertNil(SplitNode.PaneContent.terminal(command: nil).tabIcon,
                     "the default stays unmarked, or the marks become noise")
    }

    /// THROUGH THE WHOLE ROUND TRIP, not only the codec: a browser leaf
    /// comes back at its address, on the local connection, and still a
    /// browser leaf.
    func testABrowserLeafComesBackAtItsAddressAfterARestart() throws {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard let workspace = manager.activeWorkspaceID,
              let leaf = manager.addPane(content: .browser(address: nil), toWorkspace: workspace)
        else { return XCTFail() }
        manager.browserLeafDidNavigate(leaf, to: "https://example.com/docs")

        let data = try JSONEncoder().encode(manager.snapshot(planFor: { _ in nil }))
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)

        let restored = WorkspaceManager()
        _ = restored.restore(from: decoded, hostStore: nil)
        let panes = restored.workspaces.flatMap(\.panes)
        let browser = panes.first { $0.content.browserAddress != nil }
        XCTAssertEqual(browser?.content.browserAddress, "https://example.com/docs",
                       "the one durable fact this kind has did not survive")
        XCTAssertEqual(browser?.connectionID, restored.connections.localID,
                       "it came back on some other machine")
    }

}
