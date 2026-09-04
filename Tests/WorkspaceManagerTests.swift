import XCTest
@testable import Synapty

@MainActor
final class TerminalPaneManagerTests: XCTestCase {

    /// Established explicitly — addLocalWorkspace() consults
    /// TunnelManager.shared for the local command; riding the hosted
    /// app's ContentView.onAppear made these tests pass by accident
    /// (WI-2026-08-08-020).
    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    /// Helper: creates a manager with one local session (mimics ContentView.onAppear).
    private func makeManager() -> WorkspaceManager {
        let m = WorkspaceManager()
        m.addLocalWorkspace()
        return m
    }

    // MARK: - Initialization

    func testInitStartsEmpty() {
        let manager = WorkspaceManager()
        XCTAssertTrue(manager.workspaces.isEmpty)
        XCTAssertNil(manager.activeWorkspaceID)
    }

    func testAddLocalSessionCreatesSession() {
        let manager = makeManager()
        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertNil(manager.host(ofLeaf: manager.allLeaves[0].id))
        XCTAssertEqual(manager.workspaces.first!.label, "Local")
        XCTAssertNotNil(manager.activeWorkspaceID)
        let session = manager.workspaces.first!
        XCTAssertEqual(session.panes.count, 1)
        XCTAssertEqual(session.panes.first!.label, "Shell")
    }

    // MARK: - Session Management

    func testAddLocalSessionIncreasesCount() {
        let manager = makeManager()
        manager.addLocalWorkspace()
        XCTAssertEqual(manager.workspaces.count, 2)
    }

    func testAddLocalSessionSetsActive() {
        let manager = makeManager()
        let firstID = manager.activeWorkspaceID
        manager.addLocalWorkspace()
        XCTAssertNotEqual(manager.activeWorkspaceID, firstID)
        XCTAssertEqual(manager.activeWorkspaceID, manager.workspaces.last?.id)
    }

    func testAddRemoteSession() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = makeManager()
        manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host, command: "bash connect.sh agent-1 10.0.1.5 22 user 9000")
        let session = manager.workspaces.last!
        XCTAssertEqual(session.label, "GPU Box")
        XCTAssertEqual(manager.hosts(ofWorkspace: session).map(\.label), ["GPU Box"])
        XCTAssertEqual(manager.activeWorkspaceID, session.id)
    }

    func testRemoveSession() {
        let manager = makeManager()
        manager.addLocalWorkspace()
        let count = manager.workspaces.count
        let session = manager.workspaces.last!
        manager.removeWorkspace(session)
        XCTAssertEqual(manager.workspaces.count, count - 1)
    }

    func testRemoveActiveSessionSwitchesToAnother() {
        let manager = makeManager()
        manager.addLocalWorkspace()
        let second = manager.workspaces.last!
        manager.removeWorkspace(second)
        XCTAssertNotNil(manager.activeWorkspaceID)
        XCTAssertNotEqual(manager.activeWorkspaceID, second.id)
    }

    func testRemoveAllSessionsSetsActiveNil() {
        let manager = makeManager()
        let session = manager.workspaces.first!
        manager.removeWorkspace(session)
        XCTAssertTrue(manager.workspaces.isEmpty)
        XCTAssertNil(manager.activeWorkspaceID)
    }

    // MARK: - Remote Placeholder (WI-2026-03-31-003)

    /// Completing a dial must NOT steal focus: the human may have moved
    /// to another workspace while this one was connecting.
    func testCompletingADialDoesNotSwitchTheActiveWorkspace() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let localID = manager.activeWorkspaceID
        let remoteID = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        let paneID = manager.workspaces.first { $0.id == remoteID }!.panes[0].id
        // The human moves back while it dials.
        manager.activeWorkspaceID = localID

        manager.paneDidConnect(paneID, command: "bash connect.sh a 10.0.1.5 22 user 9000", agentID: "a")

        XCTAssertEqual(manager.activeWorkspaceID, localID)
        XCTAssertEqual(manager.surface(of: paneID), .terminal)
    }

    // MARK: - Pane Management

    /// A NEW PANE JOINS THE POSITION THE HUMAN IS IN, which is what a new
    /// tab now is: the position it lands in shows tabs because two panes
    /// occupy it ([[RFC-0015]] C-LAYOUT).
    func testAddPaneToActiveSession() {
        let manager = makeManager()
        let initialCount = manager.workspaces.first!.panes.count
        manager.addPaneToActiveWorkspace()
        XCTAssertEqual(manager.workspaces.first!.panes.count, initialCount + 1)
        XCTAssertEqual(manager.workspaces.first!.slots.count, 1, "no new position")
        XCTAssertEqual(manager.workspaces.first!.slots[0].isStacked, true)
    }

    /// CLOSING A PANE GIVES ITS CONNECTION SLOT BACK, on the routes a
    /// human actually uses — the tab's ✕, Close Tab, ⌘W — all of which
    /// reach `removePane`.
    ///
    /// This release was briefly moved to `leafDidClose` on the belief that
    /// `forget` also ran when a pane was MOVED between workspaces. It does
    /// not: a move goes through `takeForMove`. The move never happened and
    /// the release stopped happening, leaving a record on disk that
    /// outlives the process and keeps a connection looking busy forever
    /// ([[RFC-0013]] C-BROKER).
    @MainActor
    func testClosingAPaneReleasesItsConnectionSlot() throws {
        let tmp = try TestTempStorage.makeDir()
        MasterPool.tenantDirectoryOverride = tmp
        defer { MasterPool.tenantDirectoryOverride = nil; TestTempStorage.removeDir(tmp) }
        let tunnels = TunnelManager()
        TunnelManager.shared = tunnels
        defer { TunnelManager.shared = nil }

        let manager = makeManager()
        let pane = manager.workspaces.first!.panes.first!.id
        manager.recordLeafAgent(pane, "local-1a2b")
        let tenant = TunnelManager.paneTenant(hostID: nil, agentID: "local-1a2b")
        tunnels.pool.claim(tenant: tenant, on: "/tmp/some-socket")
        XCTAssertNotNil(tunnels.pool.recordedCarrier(of: tenant))

        manager.archivePane(pane)

        XCTAssertNil(tunnels.pool.recordedCarrier(of: tenant),
                     "the slot a closed pane held must not outlive it")
    }

    /// AND MOVING ONE DOES NOT, because it is the same pane in a different
    /// place. Releasing here would hand back a slot still in use.
    @MainActor
    func testMovingAPaneKeepsItsConnectionSlot() throws {
        let tmp = try TestTempStorage.makeDir()
        MasterPool.tenantDirectoryOverride = tmp
        defer { MasterPool.tenantDirectoryOverride = nil; TestTempStorage.removeDir(tmp) }
        let tunnels = TunnelManager()
        TunnelManager.shared = tunnels
        defer { TunnelManager.shared = nil }

        let manager = makeManager()
        manager.addPaneToActiveWorkspace()
        let moving = manager.workspaces.first!.panes.last!.id
        manager.recordLeafAgent(moving, "local-3c4d")
        let tenant = TunnelManager.paneTenant(hostID: nil, agentID: "local-3c4d")
        tunnels.pool.claim(tenant: tenant, on: "/tmp/some-socket")

        manager.movePane(moving, before: manager.workspaces.first!.panes.first!.id)

        XCTAssertNotNil(tunnels.pool.recordedCarrier(of: tenant),
                        "a pane that moved is the same pane and still on that connection")
    }

    /// TWO MACHINES CAN DRAW ONE NAME, and the qualifier is what tells
    /// them apart. A fallback id is unique within one machine and never
    /// promised more ([[RFC-0009]] C-IDENTITY-SCOPE), while this table is
    /// keyed by leaf — so the first match won, and a remote agent's
    /// request was answered by a local pane of the same name. The symptom
    /// was `FileToolServer.origin(of:)` reading this Mac's filesystem for
    /// a request from another machine.
    @MainActor
    func testAQualifiedNameDoesNotFindALocalPaneOfTheSameName() {
        let manager = makeManager()
        let localPane = manager.workspaces.first!.panes.first!.id
        manager.recordLeafAgent(localPane, "local-1a2b")

        // Bare: this is the local pane, and it is found.
        XCTAssertEqual(manager.leafID(forAgent: "local-1a2b"), localPane)

        // Qualified with another machine: this pane is NOT it. A qualifier
        // is minted at the relay boundary, and this Mac is never on the
        // far side of its own.
        XCTAssertNil(manager.leafID(forAgent: "local-1a2b@deskmac-2630"),
                     "a name from another machine must not be answered by a local pane")
    }

    /// TAPPING AN AGENT'S ROW LANDS ON THE AGENT'S PANE, not near it.
    ///
    /// `focusAgent` was written for exactly this and never had a caller:
    /// the sidebar row set `activeWorkspaceID` and stopped there, which
    /// lands on whichever leaf that workspace had focused last — the
    /// agent's only by luck, and never it when the agent sits behind a
    /// tab. A row wearing an attention mark is a request to be taken to
    /// the pane that raised it.
    @MainActor
    func testFocusingAnAgentBringsItsOwnPaneForward() {
        let manager = makeManager()
        let other = manager.workspaces[0].id
        manager.addLocalWorkspace()
        let target = manager.workspaces[1].id
        // Two panes stacked in one position: the agent is on the one
        // BEHIND, so selecting the container cannot reach it.
        manager.activeWorkspaceID = target
        let first = manager.workspaces[1].panes[0].id
        let slot = manager.workspaces[1].slots[0].id
        manager.splitFocusedLeaf(direction: .horizontal)
        let second = manager.workspaces[1].panes.first { $0.id != first }!.id
        // Behind a tab in the SAME position as `first`, so selecting the
        // container can only ever land on the one in front.
        manager.stackPane(second, intoSlot: slot)
        manager.recordLeafAgent(second, "claude-abc12345")
        manager.workspaces[1].bringToFront(first)
        manager.activeWorkspaceID = other
        XCTAssertEqual(manager.workspaces[1].slots.count, 1, "one position, two tabs")
        XCTAssertEqual(manager.workspaces[1].focusedPaneID, first)

        manager.focusAgent("claude-abc12345")

        XCTAssertEqual(manager.activeWorkspaceID, target, "it stayed on the other workspace")
        XCTAssertEqual(manager.workspaces[1].focusedPaneID, second,
                       "it selected the container and left the agent behind a tab")
    }

    /// A WORKSPACE SURVIVES BECOMING EMPTY ([[RFC-0015]] C-WORKSPACE).
    ///
    /// Closing the last tab used to delete the container, so finishing the
    /// work destroyed the place it was kept — nothing could be pinned,
    /// archived, or returned to while that was true.
    func testRemovingTheLastPaneLeavesTheWorkspaceStanding() {
        let manager = makeManager()
        let workspaceID = manager.workspaces.first!.id
        let label = manager.workspaces.first!.label

        manager.archivePane(manager.workspaces.first!.panes.first!.id)

        XCTAssertEqual(manager.workspaces.count, 1, "the workspace is still there")
        XCTAssertEqual(manager.workspaces.first!.id, workspaceID, "and it is the same one")
        XCTAssertEqual(manager.workspaces.first!.label, label)
        XCTAssertTrue(manager.workspaces.first!.panes.isEmpty)
        XCTAssertNil(manager.workspaces.first!.layout, "a position may not be empty, so there is none")
        XCTAssertNil(manager.workspaces.first!.focusedPaneID)
    }

    /// AND THE SAME WHEN NOBODY ASKED. A shell that types `exit`, or an
    /// ssh that drops, arrives here through ghostty's close callback — a
    /// path that used to delete the workspace once its last pane went. So
    /// the container for a piece of work could be destroyed by a network
    /// blip, which is C-WORKSPACE violated where it is least visible.
    func testAProcessExitingLeavesTheWorkspaceStanding() {
        let manager = makeManager()
        let workspaceID = manager.workspaces.first!.id
        let paneID = manager.workspaces.first!.panes.first!.id

        manager.leafDidClose(paneID)

        XCTAssertEqual(manager.workspaces.map(\.id), [workspaceID])
        XCTAssertTrue(manager.workspaces[0].panes.isEmpty)
        XCTAssertEqual(manager.activeWorkspaceID, workspaceID)
    }

    /// Its death is the human's explicit act and nothing else.
    func testAWorkspaceIsRemovedOnlyByAskingForIt() {
        let manager = makeManager()
        manager.archivePane(manager.workspaces.first!.panes.first!.id)
        XCTAssertEqual(manager.workspaces.count, 1)

        manager.removeWorkspace(manager.workspaces.first!)
        XCTAssertTrue(manager.workspaces.isEmpty)
    }

    // MARK: - Split Tree

    func testSplitFocusedLeaf() {
        let manager = makeManager()
        let paneID = manager.activeWorkspace!.focusedPaneID!
        manager.splitFocusedLeaf(direction: .horizontal)
        let newFocused = manager.activeWorkspace!.focusedPaneID!
        XCTAssertNotEqual(newFocused, paneID)
        XCTAssertEqual(manager.activeWorkspace!.slots.count, 2,
                       "a split makes a POSITION, not a tab")
        XCTAssertEqual(manager.activeWorkspace!.panes.count, 2)
    }

    /// SPLITTING IS COPYING. A terminal cannot be forked, so the copy is
    /// reopened — same connection, same directory, its own agent id.
    func testSplittingATerminalReopensItWhereItWasStanding() {
        let manager = makeManager()
        let original = manager.activeWorkspace!.panes[0]
        manager.leafDidUpdatePwd(original.id, pwd: "/tmp/projA")

        manager.splitFocusedLeaf(direction: .horizontal)

        let copy = manager.activeWorkspace!.panes[1]
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.workingDirectory, "/tmp/projA",
                       "a copy that opens at home is a different pane wearing the name")
        XCTAssertEqual(copy.connectionID, original.connectionID)
        XCTAssertNotEqual(manager.agentID(forLeaf: copy.id), manager.agentID(forLeaf: original.id),
                          "its own child, under its own id")
    }

    /// THE KERNEL IS NOT THE SHELL, and a duplicate may not be placed on
    /// its word.
    ///
    /// `ghostty_surface_foreground_pid` names whatever is in FRONT of the
    /// shell, so a pane duplicated while its shell runs anything that
    /// `cd`s opens wherever that command went. `jenv rehash` runs from
    /// every `.zshrc` here and lives in `~/.jenv/shims`; a copy made
    /// before the first prompt landed there, confidently.
    func testADuplicateIsNotPlacedByWhateverTheShellIsRunning() {
        let manager = makeManager()
        let original = manager.activeWorkspace!.panes[0]
        // The shell has said nothing yet; the kernel can see a command in
        // front of it, standing somewhere of its own.
        manager.observedPwd = { _ in "/Users/z/.jenv/shims" }

        manager.splitFocusedLeaf(direction: .horizontal)

        XCTAssertNil(manager.activeWorkspace!.panes[1].workingDirectory,
                     "no directory beats a build script's scratch directory")
        // And the looser reader is unchanged: a drag hint would rather say
        // somewhere plausible than nothing at all.
        XCTAssertEqual(manager.pwd(ofLeaf: original.id), "/Users/z/.jenv/shims")
        XCTAssertNil(manager.reportedPwd(ofLeaf: original.id))
    }

    /// And once the shell HAS said, its word is what places the copy —
    /// even while the kernel is looking at something else.
    func testTheShellsOwnWordPlacesTheDuplicate() {
        let manager = makeManager()
        let original = manager.activeWorkspace!.panes[0]
        manager.leafDidUpdatePwd(original.id, pwd: "/tmp/projA")
        manager.observedPwd = { _ in "/Users/z/.jenv/shims" }

        manager.splitFocusedLeaf(direction: .horizontal)

        XCTAssertEqual(manager.activeWorkspace!.panes[1].workingDirectory, "/tmp/projA")
    }

    /// A REMOTE COPY IS PLACED BY THE CONNECT COMMAND. The local surface
    /// ignores a path that is not on this Mac, so the directory has to
    /// reach the far side instead.
    func testSplittingARemoteTerminalCarriesTheDirectoryToTheFarSide() {
        let manager = WorkspaceManager()
        let host = HostEntry(label: "remotehost", address: "10.0.0.1", username: "u")
        manager.addRemoteWorkspace(label: "remotehost", hostEntry: host,
                                   command: "bash connect.sh a 10.0.0.1 22 u 9000")
        let original = manager.activeWorkspace!.panes[0]
        manager.leafDidUpdatePwd(original.id, pwd: "/srv/build")

        manager.splitFocusedLeaf(direction: .vertical)

        let command = manager.activeWorkspace!.panes[1].content.terminalCommand ?? ""
        XCTAssertTrue(command.contains("SYNAPTY_START_CWD="), "got: \(command)")
        XCTAssertTrue(command.contains("/srv/build"), "got: \(command)")
    }

    /// A file browser has nothing running behind it, so the copy is the
    /// value itself — no command minted and no agent id to mint one for.
    func testSplittingAFileBrowserCopiesItVerbatim() {
        let manager = makeManager()
        guard let files = manager.addPane(content: .files(directory: nil),
                                          toWorkspace: manager.workspaces[0].id)
        else { return XCTFail() }
        manager.focusLeaf(files)

        manager.splitFocusedLeaf(direction: .horizontal)

        let copy = manager.activeWorkspace!.focusedPane!
        XCTAssertEqual(copy.content, .files(directory: nil))
        XCTAssertNil(copy.content.terminalCommand)
        XCTAssertNil(manager.agentID(forLeaf: copy.id),
                     "nothing was spawned, so nothing is running under an id")
    }

    func testSplitNonRightmostLeafFocusesCorrectly() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let panes = manager.activeWorkspace!.panes
        XCTAssertEqual(panes.count, 2)
        let paneA = panes[0].id
        let paneB = panes[1].id

        manager.focusLeaf(paneA)
        XCTAssertEqual(manager.activeWorkspace!.focusedPaneID, paneA)

        manager.splitFocusedLeaf(direction: .horizontal)
        let newFocused = manager.activeWorkspace!.focusedPaneID!
        XCTAssertNotEqual(newFocused, paneB)
        XCTAssertNotEqual(newFocused, paneA)
        XCTAssertEqual(manager.activeWorkspace!.slots.count, 3)
    }

    func testCloseFocusedLeaf() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        XCTAssertEqual(manager.activeWorkspace!.slots.count, 2)
        manager.closeFocusedLeaf()
        XCTAssertEqual(manager.activeWorkspace!.slots.count, 1,
                       "the emptied position collapses into its sibling")
    }

    /// Closing one of several panes SHARING a position leaves the position
    /// standing with what is left, and focus falls to it.
    func testClosingOneOfTwoStackedPanesKeepsThePosition() {
        let manager = makeManager()
        let first = manager.activeWorkspace!.panes[0].id
        manager.addPaneToActiveWorkspace()
        let second = manager.activeWorkspace!.focusedPaneID!

        manager.archivePane(second)

        XCTAssertEqual(manager.activeWorkspace!.slots.count, 1)
        XCTAssertEqual(manager.activeWorkspace!.panes.map(\.id), [first])
        XCTAssertEqual(manager.activeWorkspace!.focusedPaneID, first)
        XCTAssertEqual(manager.activeWorkspace!.slots[0].isStacked, false,
                       "one pane left is not a stack")
    }

    func testFocusNextLeafCycles() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let panes = manager.activeWorkspace!.panes
        let firstID = panes[0].id
        let secondID = panes[1].id
        XCTAssertEqual(manager.activeWorkspace!.focusedPaneID, secondID)
        manager.focusNextLeaf()
        XCTAssertEqual(manager.activeWorkspace!.focusedPaneID, firstID)
        manager.focusNextLeaf()
        XCTAssertEqual(manager.activeWorkspace!.focusedPaneID, secondID)
    }

    /// FOCUS WALKS POSITIONS, NOT PANES. A pane behind a tab is one the
    /// human cannot see, so a shortcut that landed on it would move focus
    /// somewhere invisible.
    func testFocusNextLeafSkipsPanesBehindATab() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let other = manager.activeWorkspace!.panes[0].id
        // Stack a second pane into the focused position.
        manager.addPaneToActiveWorkspace()
        XCTAssertEqual(manager.activeWorkspace!.slots.count, 2)
        XCTAssertEqual(manager.activeWorkspace!.panes.count, 3)

        manager.focusNextLeaf()
        XCTAssertEqual(manager.activeWorkspace!.focusedPaneID, other)
        manager.focusNextLeaf()
        XCTAssertEqual(manager.activeWorkspace!.focusedPaneID,
                       manager.activeWorkspace!.slots[1].activePaneID,
                       "back to whatever the other position is SHOWING")
    }

    // MARK: - All Leaves

    func testAllLeavesSpansAllSessions() {
        let manager = makeManager()
        manager.addLocalWorkspace()
        XCTAssertEqual(manager.allLeaves.count, 2)
    }

    func testAllLeavesIncludesSplits() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        XCTAssertEqual(manager.allLeaves.count, 2)
    }

    // MARK: - Session IDs Stable

    func testSessionIDsStableAcrossOperations() {
        let manager = makeManager()
        let firstID = manager.workspaces.first!.id
        manager.addLocalWorkspace()
        XCTAssertEqual(manager.workspaces.first!.id, firstID)
    }

    // MARK: - Focus (background connections must not steal session focus)

    func testFocusLeafDoesNotSwitchActiveSession() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let localID = manager.activeWorkspaceID
        // Remote session connects while user is in the local session.
        manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host,
                                command: "bash connect.sh agent-1 10.0.1.5 22 user 9000", agentID: "agent-1")
        let remoteLeaf = manager.workspaces.last!.panes.first!.id
        manager.activeWorkspaceID = localID

        // A background surface becoming first responder focuses its pane…
        manager.focusLeaf(remoteLeaf)
        // …but must not switch the active session.
        XCTAssertEqual(manager.activeWorkspaceID, localID, "focusLeaf must not steal session focus")
    }

    // MARK: - Names ([[WI-2026-08-17-019]])

    func testANewSessionDoesNotTakeTheNameOfOneAlreadyOpen() {
        let m = WorkspaceManager()
        // A session that came back from a restore: its name arrives with
        // the snapshot and never passes through the naming path.
        m.workspaces.append(WorkspaceManager.Workspace(label: "remotehost", connectionID: m.connections.localID))
        m.addLocalWorkspace()

        // The counter this used to keep was zero here, so the first
        // remotehost opened by hand took the name of the one above it and
        // only the SECOND got a number.
        let host = HostEntry(label: "remotehost", address: "remotehost", username: "z")
        _ = m.addRemoteWorkspace(label: host.label, hostEntry: host)
        _ = m.addRemoteWorkspace(label: host.label, hostEntry: host)

        let names = m.workspaces.map(\.label)
        XCTAssertEqual(names.filter { $0.hasPrefix("remotehost") }.sorted(),
                       ["remotehost", "remotehost 2", "remotehost 3"])
        XCTAssertEqual(Set(names).count, names.count, "two workspaces share a name: \(names)")
    }

    func testANameFreedByClosingASessionCanBeUsedAgain() {
        let m = WorkspaceManager()
        let host = HostEntry(label: "otherhost", address: "otherhost", username: "z")
        let first = m.addRemoteWorkspace(label: host.label, hostEntry: host)
        _ = m.addRemoteWorkspace(label: host.label, hostEntry: host)
        XCTAssertEqual(m.workspaces.map(\.label), ["otherhost", "otherhost 2"])

        m.workspaces.removeAll { $0.id == first }
        _ = m.addRemoteWorkspace(label: host.label, hostEntry: host)
        // "the one that is not taken", rather than a count that only ever
        // goes up and leaves gaps a human cannot account for.
        XCTAssertEqual(m.workspaces.map(\.label).sorted(), ["otherhost", "otherhost 2"])
    }

    // MARK: - Session drag-reorder ([[WI-2026-08-17-023]])

    func testASessionDroppedOnAnotherTakesThatSlot() {
        let m = WorkspaceManager()
        let host = HostEntry(label: "a", address: "a", username: "z")
        let first = m.addRemoteWorkspace(label: "one", hostEntry: host)
        _ = m.addRemoteWorkspace(label: "two", hostEntry: host)
        let third = m.addRemoteWorkspace(label: "three", hostEntry: host)

        m.moveWorkspace(third, before: first)
        XCTAssertEqual(m.workspaces.map(\.label), ["three", "one", "two"])
    }

    func testASessionDroppedPastTheLastOneGoesToTheEnd() {
        let m = WorkspaceManager()
        let host = HostEntry(label: "a", address: "a", username: "z")
        let first = m.addRemoteWorkspace(label: "one", hostEntry: host)
        _ = m.addRemoteWorkspace(label: "two", hostEntry: host)

        m.moveWorkspaceToEnd(first)
        XCTAssertEqual(m.workspaces.map(\.label), ["two", "one"])
    }

    func testASessionDroppedOnItselfChangesNothing() {
        let m = WorkspaceManager()
        let host = HostEntry(label: "a", address: "a", username: "z")
        let only = m.addRemoteWorkspace(label: "one", hostEntry: host)
        _ = m.addRemoteWorkspace(label: "two", hostEntry: host)

        m.moveWorkspace(only, before: only)
        XCTAssertEqual(m.workspaces.map(\.label), ["one", "two"])
    }
}





// MARK: - Three-tier switching (WI-2026-08-09-015)

@MainActor
final class TierSwitchingTests: XCTestCase {

    /// addLocalWorkspace() consults TunnelManager.shared (WI-2026-08-08-020
    /// pattern — established explicitly, never ridden off the hosted app).
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

    /// ⌘⌥N picks the Nth TAB, which is the Nth pane of the position the
    /// human is in.
    func testSwitchTabActivatesNthPane() {
        let manager = makeManager()
        manager.addPaneToActiveWorkspace()
        manager.addPaneToActiveWorkspace()
        let panes = manager.workspaces[0].slots[0].panes
        XCTAssertEqual(panes.count, 3, "three panes sharing one position")
        manager.selectPane(index: 2)
        XCTAssertEqual(manager.workspaces[0].slots[0].activePaneID, panes[1].id)
        XCTAssertEqual(manager.workspaces[0].focusedPaneID, panes[1].id)
        manager.selectPane(index: 1)
        XCTAssertEqual(manager.workspaces[0].slots[0].activePaneID, panes[0].id)
    }

    func testSwitchTabOutOfRangeIsNoOp() {
        let manager = makeManager()
        manager.addPaneToActiveWorkspace()
        let before = manager.workspaces[0].focusedPaneID
        manager.selectPane(index: 9)
        XCTAssertEqual(manager.workspaces[0].focusedPaneID, before)
        manager.selectPane(index: 0)
        XCTAssertEqual(manager.workspaces[0].focusedPaneID, before)
    }

    /// ⌘⌃N picks the Nth POSITION, landing on whatever it is showing.
    func testFocusPaneFocusesNthLeaf() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        manager.splitFocusedLeaf(direction: .vertical)
        let slots = manager.workspaces[0].slots
        XCTAssertEqual(slots.count, 3)
        manager.focusSlot(index: 1)
        XCTAssertEqual(manager.workspaces[0].focusedPaneID, slots[0].activePaneID)
        manager.focusSlot(index: 3)
        XCTAssertEqual(manager.workspaces[0].focusedPaneID, slots[2].activePaneID)
    }

    func testFocusPaneOutOfRangeIsNoOp() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let before = manager.workspaces[0].focusedPaneID
        manager.focusSlot(index: 5)
        XCTAssertEqual(manager.workspaces[0].focusedPaneID, before)
    }
}

// MARK: - Shell-driven tab titles (WI-2026-08-09-017)

@MainActor
final class ShellTitleTests: XCTestCase {

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

    func testFocusedLeafTitleDrivesDisplayLabel() {
        let manager = makeManager()
        let pane = manager.workspaces[0].panes[0]
        XCTAssertEqual(manager.displayLabel(for: pane), "Shell")
        manager.leafDidUpdateTitle(pane.id, title: "vim main.rs")
        XCTAssertEqual(manager.displayLabel(for: manager.workspaces[0].panes[0]), "vim main.rs")
    }

    func testRenameWinsOverShellTitle() {
        let manager = makeManager()
        let pane = manager.workspaces[0].panes[0]
        manager.renamePane(pane.id, to: "build box")
        manager.leafDidUpdateTitle(pane.id, title: "zig build")
        XCTAssertEqual(manager.displayLabel(for: manager.workspaces[0].panes[0]), "build box")
    }

    /// EVERY PANE SPEAKS FOR ITSELF. The label belonged to a tab, which
    /// had to pick one of the leaves under it to speak for the whole strip
    /// — so a split's two shells shared one name and it changed under the
    /// human as focus moved.
    func testEachPaneShowsItsOwnTitle() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let panes = manager.workspaces[0].panes
        manager.leafDidUpdateTitle(panes[0].id, title: "left title")
        manager.leafDidUpdateTitle(panes[1].id, title: "right title")

        let after = manager.workspaces[0].panes
        XCTAssertEqual(after.map { manager.displayLabel(for: $0) },
                       ["left title", "right title"])
        manager.focusSlot(index: 1)
        XCTAssertEqual(manager.workspaces[0].panes.map { manager.displayLabel(for: $0) },
                       ["left title", "right title"],
                       "moving focus renames nothing")
    }

    func testEmptyTitleFallsBackToLabel() {
        let manager = makeManager()
        let pane = manager.workspaces[0].panes[0]
        manager.leafDidUpdateTitle(pane.id, title: "something")
        manager.leafDidUpdateTitle(pane.id, title: "  ")
        XCTAssertEqual(manager.displayLabel(for: manager.workspaces[0].panes[0]), "Shell")
    }

    func testLongTitleCapped() {
        let manager = makeManager()
        let pane = manager.workspaces[0].panes[0]
        manager.leafDidUpdateTitle(pane.id, title: String(repeating: "x", count: 500))
        XCTAssertLessThanOrEqual(manager.displayLabel(for: manager.workspaces[0].panes[0]).count, 80)
    }
}

// MARK: - Reordering (WI-2026-08-09-018)

@MainActor
final class ReorderingTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    func testMovePaneBeforeTargetBothDirections() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addPaneToActiveWorkspace()
        manager.addPaneToActiveWorkspace()
        let ids = manager.workspaces[0].panes.map(\.id)  // [A, B, C]
        // Drag A onto C: A lands in C's slot (left of C).
        manager.movePane(ids[0], before: ids[2])
        XCTAssertEqual(manager.workspaces[0].panes.map(\.id), [ids[1], ids[0], ids[2]])
        // Drag C onto B (now first): C lands in B's slot.
        manager.movePane(ids[2], before: ids[1])
        XCTAssertEqual(manager.workspaces[0].panes.map(\.id), [ids[2], ids[1], ids[0]])
    }

    func testMovePaneToEnd() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addPaneToActiveWorkspace()
        manager.addPaneToActiveWorkspace()
        let ids = manager.workspaces[0].panes.map(\.id)
        let slot = manager.workspaces[0].slots[0].id
        manager.movePane(ids[0], toEndOfSlot: slot)
        XCTAssertEqual(manager.workspaces[0].panes.map(\.id), [ids[1], ids[2], ids[0]])
    }

    /// A MOVE MUST NOT DESTROY ITS OWN DESTINATION. A position holding
    /// one pane collapses when that pane leaves, so a lone pane dropped
    /// back onto its own position would take the slot the drop names out
    /// of the tree first — and land nowhere, having already been removed.
    func testALonePaneDroppedOnItsOwnPositionChangesNothing() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.splitFocusedLeaf(direction: .horizontal)
        let lone = manager.workspaces[0].slots[1].panes[0].id
        let itsOwn = manager.workspaces[0].slots[1].id

        manager.stackPane(lone, intoSlot: itsOwn)

        XCTAssertEqual(manager.workspaces[0].panes.count, 2, "the pane is still in the tree")
        XCTAssertEqual(manager.workspaces[0].slots.count, 2)
        XCTAssertNotNil(manager.workspaces[0].panes.first { $0.id == lone })
    }

    /// The same for the edge drop: a lone pane split off its own position
    /// is the arrangement it is already in.
    func testALonePaneDroppedBesideItsOwnPositionChangesNothing() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let lone = manager.workspaces[0].panes[0].id
        let itsOwn = manager.workspaces[0].slots[0].id

        manager.movePane(lone, besideSlot: itsOwn, direction: .vertical)

        XCTAssertEqual(manager.workspaces[0].panes.map(\.id), [lone])
        XCTAssertEqual(manager.workspaces[0].slots.count, 1)
    }

    /// A DROP FROM ANOTHER POSITION IS THE SAME MOVE — the operation the
    /// old shape had no type to write ([[RFC-0015]] C-LAYOUT).
    func testAPaneDroppedOnAnotherPositionsTabJoinsThatStack() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.splitFocusedLeaf(direction: .horizontal)
        let left = manager.workspaces[0].slots[0].panes[0].id
        let right = manager.workspaces[0].slots[1].panes[0].id

        manager.movePane(right, before: left)

        XCTAssertEqual(manager.workspaces[0].slots.count, 1,
                       "the position it left collapsed into its sibling")
        XCTAssertEqual(manager.workspaces[0].slots[0].panes.map(\.id), [right, left])
        XCTAssertEqual(manager.workspaces[0].focusedPaneID, right)
    }

    func testMovePaneInvalidIDsNoOp() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addPaneToActiveWorkspace()
        let ids = manager.workspaces[0].panes.map(\.id)
        manager.movePane(ids[0], before: UUID())
        XCTAssertEqual(manager.workspaces[0].panes.map(\.id), ids)
        manager.movePane(ids[0], before: ids[0])
        XCTAssertEqual(manager.workspaces[0].panes.map(\.id), ids)
    }

    // MARK: - Which SIDE an edge drop lands on ([[WI-2026-08-17-028]])

    /// A DROP ON THE LEFT EDGE PUTS THE PANE ON THE LEFT. The tree keeps
    /// the two children in order, so a split that always appended made
    /// the near and far edges of a pane do the same thing — half the
    /// gesture, silently.
    func testAPaneDroppedOnALeftEdgeLandsBeforeTheOneItSplit() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.splitFocusedLeaf(direction: .horizontal)
        let first = manager.workspaces[0].slots[0].panes[0].id
        let second = manager.workspaces[0].slots[1].panes[0].id
        manager.addPaneToActiveWorkspace()
        let third = manager.workspaces[0].panes.first { $0.id != first && $0.id != second }!.id
        let target = manager.workspaces[0].layout!.slot(containing: first)!.id

        manager.movePane(third, besideSlot: target, direction: .horizontal, before: true)

        XCTAssertEqual(manager.workspaces[0].slots.map(\.panes).map { $0.map(\.id) },
                       [[third], [first], [second]],
                       "it takes the position to the LEFT of the one it was dropped on")
    }

    func testAPaneDroppedOnARightEdgeLandsAfterTheOneItSplit() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.splitFocusedLeaf(direction: .horizontal)
        let first = manager.workspaces[0].slots[0].panes[0].id
        let second = manager.workspaces[0].slots[1].panes[0].id
        manager.addPaneToActiveWorkspace()
        let third = manager.workspaces[0].panes.first { $0.id != first && $0.id != second }!.id
        let target = manager.workspaces[0].layout!.slot(containing: first)!.id

        manager.movePane(third, besideSlot: target, direction: .horizontal, before: false)

        XCTAssertEqual(manager.workspaces[0].slots.map(\.panes).map { $0.map(\.id) },
                       [[first], [third], [second]])
    }

    /// The default is the far side, which is what every existing caller
    /// meant and what `splitSlot` has always done.
    func testAnEdgeDropDefaultsToTheFarSide() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addPaneToActiveWorkspace()
        let ids = manager.workspaces[0].panes.map(\.id)
        let target = manager.workspaces[0].slots[0].id

        manager.movePane(ids[1], besideSlot: target, direction: .vertical)

        XCTAssertEqual(manager.workspaces[0].slots.map(\.panes).map { $0.map(\.id) },
                       [[ids[0]], [ids[1]]])
    }

    // MARK: - A region becomes an operation ([[WI-2026-08-17-028]])

    /// THE FOUR EDGES ARE FOUR DIFFERENT ARRANGEMENTS. This mapping is
    /// what the AppKit surface and the SwiftUI panes both call, so a
    /// disagreement here would be a pane landing somewhere the highlight
    /// did not promise.
    func testEachEdgeDocksThePaneOnThatSide() {
        /// The positions after docking, named rather than counted: every
        /// arrangement here has one pane per position, so a test that
        /// counted them would read the same for a left drop and a right
        /// one and measure nothing.
        func arrangement(_ region: PaneDropRegion) -> [String] {
            let manager = WorkspaceManager()
            manager.addLocalWorkspace()
            manager.splitFocusedLeaf(direction: .horizontal)
            manager.addPaneToActiveWorkspace()
            let target = manager.workspaces[0].slots[0].panes[0].id
            let behind = manager.workspaces[0].slots[1].panes[0].id
            let moved = manager.workspaces[0].slots[1].panes[1].id
            manager.dockPane(moved, onto: target, region: region)
            let names = [target: "target", behind: "behind", moved: "moved"]
            return manager.workspaces[0].slots.flatMap { $0.panes.map { names[$0.id] ?? "?" } }
        }

        // The tree reads first position to last, so WHERE the moved pane
        // appears in that reading is which side of the target it took.
        XCTAssertEqual(arrangement(.left), ["moved", "target", "behind"])
        XCTAssertEqual(arrangement(.right), ["target", "moved", "behind"])
        XCTAssertEqual(arrangement(.top), ["moved", "target", "behind"])
        XCTAssertEqual(arrangement(.bottom), ["target", "moved", "behind"])
    }

    func testTheCentreDocksThePaneIntoTheTargetsStack() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.splitFocusedLeaf(direction: .horizontal)
        let target = manager.workspaces[0].slots[0].panes[0].id
        let moved = manager.workspaces[0].slots[1].panes[0].id

        manager.dockPane(moved, onto: target, region: .stack)

        XCTAssertEqual(manager.workspaces[0].slots.count, 1)
        XCTAssertEqual(manager.workspaces[0].slots[0].panes.map(\.id), [target, moved])
    }

    /// A top drop and a bottom drop divide the position the same way and
    /// differ only in which half the arriving pane takes — so the
    /// direction has to be carried as well as the side.
    func testAVerticalDockDividesTheOtherWay() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addPaneToActiveWorkspace()
        let ids = manager.workspaces[0].panes.map(\.id)

        manager.dockPane(ids[1], onto: ids[0], region: .top)

        guard case .split(let d)? = manager.workspaces[0].layout else {
            return XCTFail("a dock on an edge divides the position")
        }
        XCTAssertEqual(d.direction, .vertical)
        XCTAssertEqual(d.first.panes.map(\.id), [ids[1]], "the arriving pane is above")
    }

    /// A POSITION HOLDING TWO MACHINES IS A LEGAL ARRANGEMENT, and the
    /// pane that arrived still answers for its own ([[RFC-0015]]
    /// C-LEAF-BINDING). This is the arrangement docking makes reachable
    /// for the first time, so it is the one the binding has to survive:
    /// file drops, the presentation plane, agent lifecycle and pwd all
    /// ask the PANE which machine it is on, never the position it sits
    /// in ([[WI-2026-08-17-028]]).
    func testAPaneDockedAmongAnotherMachinesPanesStillReportsItsOwnHost() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let localPane = manager.workspaces[0].panes[0].id
        let remoteID = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        let remoteIndex = manager.workspaces.firstIndex { $0.id == remoteID }!
        let remotePane = manager.workspaces[remoteIndex].panes[0].id
        manager.paneDidConnect(remotePane, command: "bash connect.sh a 10.0.1.5 22 user 9000",
                               agentID: "a")

        // The remote pane joins the local one's position — one slot, two
        // machines.
        manager.dockPane(remotePane, onto: localPane, region: .stack)

        let landed = manager.workspaces.first { $0.layout?.findPane(remotePane) != nil }
        XCTAssertNotNil(landed)
        XCTAssertEqual(landed?.layout?.slot(containing: remotePane)?.panes.count, 2,
                       "both machines in the one position")
        XCTAssertEqual(manager.host(ofLeaf: remotePane)?.label, "GPU Box")
        XCTAssertNil(manager.host(ofLeaf: localPane), "and the local one is still local")
        XCTAssertEqual(manager.agentID(forLeaf: remotePane), "a",
                       "the agent belongs to the pane, so it travelled with it")
    }

    func testDockingOntoAPaneThatIsNotThereChangesNothing() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addPaneToActiveWorkspace()
        let ids = manager.workspaces[0].panes.map(\.id)

        manager.dockPane(ids[0], onto: UUID(), region: .left)

        XCTAssertEqual(manager.workspaces[0].panes.map(\.id), ids)
        XCTAssertEqual(manager.workspaces[0].slots.count, 1)
    }

    /// A PANE PULLED OUT OF ITS OWN STACK ONTO ITS OWN BODY is a real
    /// arrangement, not a mistake: the position keeps the panes behind it
    /// and the one dragged takes a place of its own. Only the drop that
    /// would leave nothing behind is refused, and the tree refuses it.
    func testAStackedPaneCanBeTornOutOntoItsOwnEdge() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addPaneToActiveWorkspace()
        let ids = manager.workspaces[0].panes.map(\.id)

        manager.dockPane(ids[1], onto: ids[1], region: .right)

        XCTAssertEqual(manager.workspaces[0].slots.map { $0.panes.map(\.id) },
                       [[ids[0]], [ids[1]]])
    }

    func testALonePaneDroppedOnItsOwnBodyChangesNothing() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let lone = manager.workspaces[0].panes[0].id

        manager.dockPane(lone, onto: lone, region: .left)
        manager.dockPane(lone, onto: lone, region: .stack)

        XCTAssertEqual(manager.workspaces[0].slots.map { $0.panes.map(\.id) }, [[lone]])
    }

    // MARK: - Leaving the workspace it started in ([[WI-2026-08-17-028]])

    /// The sidebar row is the coarse target: it names a WORKSPACE and not
    /// a position, so the pane joins the position that workspace is
    /// focused on and comes to the front there — visible on arrival,
    /// rather than buried behind a tab or shrinking a layout the human
    /// is not looking at.
    func testAPaneDroppedOnAnotherWorkspacesRowJoinsThatWorkspace() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addLocalWorkspace()
        let home = manager.workspaces[0].id
        let away = manager.workspaces[1].id
        manager.addPaneToActiveWorkspace()
        // Two panes at home so the one leaving does not empty its own
        // workspace, which is a different question.
        manager.activeWorkspaceID = home
        manager.addPaneToActiveWorkspace()
        let travelling = manager.workspaces[0].panes[1].id
        let awayPanes = manager.workspaces[1].panes.count
        let awaySlots = manager.workspaces[1].slots.count

        manager.movePane(travelling, toWorkspace: away)

        XCTAssertNil(manager.workspaces[0].panes.first { $0.id == travelling },
                     "it left the workspace it was in")
        let destination = manager.workspaces[1]
        XCTAssertTrue(destination.panes.map(\.id).contains(travelling))
        XCTAssertEqual(destination.panes.count, awayPanes + 1)
        XCTAssertEqual(destination.slots.count, awaySlots,
                       "it joined a position rather than making a new one")
        XCTAssertEqual(destination.focusedPaneID, travelling)
        XCTAssertEqual(destination.layout?.slot(containing: travelling)?.activePaneID, travelling,
                       "in front of the position it landed in")
    }

    /// THE SIDEBAR DOES NOT SWITCH UNDER THE DRAG. Moving a pane away is
    /// not a request to go there; the human follows it or does not.
    func testACrossWorkspaceMoveLeavesTheHumanWhereTheyAre() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addLocalWorkspace()
        let home = manager.workspaces[0].id
        let away = manager.workspaces[1].id
        manager.activeWorkspaceID = home
        manager.addPaneToActiveWorkspace()
        let travelling = manager.workspaces[0].panes[1].id

        manager.movePane(travelling, toWorkspace: away)

        XCTAssertEqual(manager.activeWorkspaceID, home)
    }

    /// A pane keeps its machine when it changes workspace — the binding
    /// is on the pane ([[RFC-0015]] C-LEAF-BINDING), and a workspace that
    /// re-bound what it received is the bug that model was built to make
    /// impossible.
    func testATravellingPaneKeepsItsOwnConnection() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let remoteID = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        manager.paneDidConnect(manager.workspaces.first { $0.id == remoteID }!.panes[0].id,
                               command: "bash connect.sh a 10.0.1.5 22 user 9000", agentID: "a")
        let local = manager.workspaces[0].id
        manager.activeWorkspaceID = remoteID
        manager.addPaneToActiveWorkspace()
        let remoteIndex = manager.workspaces.firstIndex { $0.id == remoteID }!
        let travelling = manager.workspaces[remoteIndex].panes[1].id
        let itsConnection = manager.workspaces[remoteIndex].panes[1].connectionID

        manager.movePane(travelling, toWorkspace: local)

        let landed = manager.workspaces.first { $0.id == local }!.panes.first { $0.id == travelling }
        XCTAssertEqual(landed?.connectionID, itsConnection)
        XCTAssertEqual(manager.host(ofLeaf: travelling)?.label, "GPU Box",
                       "it still reports the machine it is on")
    }

    /// A workspace with no tree — a placeholder still dialling, or one
    /// whose last pane was closed — receives the pane as its whole
    /// layout ([[RFC-0015]] C-EMPTY).
    func testAPaneDroppedOnAnEmptyWorkspaceBecomesItsLayout() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        // AN EMPTY WORKSPACE IS ONE WITH NOTHING IN IT, and a remote one
        // is no longer a way to get it: connecting now puts a pane there
        // immediately ([[RFC-0015]] C-DIAL). So it is emptied.
        let empty = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        manager.archivePane(manager.workspaces.first { $0.id == empty }!.panes[0].id)
        manager.activeWorkspaceID = manager.workspaces[0].id
        manager.addPaneToActiveWorkspace()
        let travelling = manager.workspaces[0].panes[1].id

        manager.movePane(travelling, toWorkspace: empty)

        let destination = manager.workspaces.first { $0.id == empty }!
        XCTAssertEqual(destination.panes.map(\.id), [travelling])
        XCTAssertEqual(destination.focusedPaneID, travelling)
    }

    /// The row of the workspace the pane is ALREADY in says nothing. It
    /// names a destination, and this pane is there — reading it as a move
    /// would rearrange a layout the human never pointed at.
    func testAPaneDroppedOnItsOwnWorkspacesRowChangesNothing() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.splitFocusedLeaf(direction: .horizontal)
        let before = manager.workspaces[0].slots.map(\.panes).map { $0.map(\.id) }
        let own = manager.workspaces[0].id

        manager.movePane(manager.workspaces[0].slots[1].panes[0].id, toWorkspace: own)

        XCTAssertEqual(manager.workspaces[0].slots.map(\.panes).map { $0.map(\.id) }, before)
    }

    /// A workspace emptied by the pane that left is still standing
    /// ([[RFC-0015]] C-WORKSPACE) — the same rule closing its last pane
    /// obeys, on a path that never closed anything.
    func testTheWorkspaceAPaneLeftIsStillThere() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addLocalWorkspace()
        let home = manager.workspaces[0].id
        let away = manager.workspaces[1].id
        let lone = manager.workspaces[0].panes[0].id

        manager.movePane(lone, toWorkspace: away)

        XCTAssertEqual(manager.workspaces.count, 2)
        let source = manager.workspaces.first { $0.id == home }
        XCTAssertNotNil(source, "the workspace outlives its last pane")
        XCTAssertNil(source?.layout)
        XCTAssertNil(source?.focusedPaneID)
    }

    /// TWO MACHINES IN ONE WORKSPACE, PRODUCED BY A GESTURE RATHER THAN
    /// BY A DRAG. This is the arrangement [[RFC-0015]] C-LEAF-BINDING
    /// exists to permit, and until now nothing made one: every connect
    /// path built a workspace of its own, so the only way to get panes
    /// from two machines together was to drag one in from elsewhere.
    func testAHostCanBeConnectedIntoTheWorkspaceTheHumanIsIn() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let workspaceID = manager.workspaces[0].id
        let localPane = manager.workspaces[0].panes[0].id

        let remotePane = manager.addRemotePane(toWorkspace: workspaceID,
                                               label: "GPU Box", hostEntry: host)

        XCTAssertEqual(manager.workspaces.count, 1, "no workspace of its own was made")
        XCTAssertEqual(manager.workspaces[0].panes.count, 2)
        XCTAssertNil(manager.host(ofLeaf: localPane), "the local one is still local")
        XCTAssertEqual(manager.host(ofLeaf: remotePane)?.label, "GPU Box")
        XCTAssertEqual(manager.surface(of: remotePane), .dialling,
                       "it dials in its own place, beside a pane that is already up")
    }

    /// A RESTORED PANE NEVER PASSES THROUGH paneDidConnect, and nothing
    /// else marked its connection up — so a pane with a perfectly good
    /// command sat on the dial forever. The dial is read from the
    /// CONNECTION now ([[RFC-0015]] C-DIAL), which means every party that
    /// brings a link up has to say so, not just the one that opens a new
    /// pane.
    func testALinkBroughtUpWithoutAPaneStillLetsItsLeavesThrough() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        // WITH ITS COMMAND ALREADY ON IT, which is what makes this the
        // restore case: a restored pane comes back carrying the command
        // it was persisted with, and waits only for its link.
        manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host,
                                   command: "bash connect.sh a 10.0.1.5 22 user 9000")
        let paneID = manager.workspaces[0].panes[0].id
        XCTAssertEqual(manager.surface(of: paneID), .dialling)

        // The tunnel came up by a path that knows nothing about panes.
        manager.markConnected(hostID: host.id)

        XCTAssertEqual(manager.surface(of: paneID), .terminal)
    }

    /// And every leaf on that host follows, because they share the one
    /// connection ([[RFC-0015]] C-CONNECTION).
    func testEveryLeafOnAHostFollowsItsLinkUp() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host,
                                   command: "bash connect.sh a 10.0.1.5 22 user 9000")
        let id = manager.workspaces[0].id
        let first = manager.workspaces[0].panes[0].id
        // A second pane on the same machine, minted with a command of its
        // own — a leaf still waiting for one is waiting on more than the
        // link and is `testAPaneOnAnAlreadyReachedHostWaitsForItsOwnCommand`.
        let second = manager.addPane(content: .terminal(command: nil), toWorkspace: id)!

        manager.markConnected(hostID: host.id)

        XCTAssertEqual(manager.surface(of: first), .terminal)
        XCTAssertEqual(manager.surface(of: second), .terminal)
    }

    /// A PANE ON A HOST THAT IS ALREADY REACHED STILL HAS NOTHING TO RUN,
    /// and this is the case the connection-only gate could not see.
    ///
    /// `acquire` REUSES the connection of a host that is already up, so
    /// the new leaf is `connected` from the moment it exists — while its
    /// own dial, which is what mints its command, has not returned. Gated
    /// on the connection alone the leaf was handed a surface with a nil
    /// command, and ghostty answers that with its DEFAULT shell: a LOCAL
    /// one. The human picked a machine from the palette and got a shell
    /// on their Mac (WI-2026-03-31-003, by a second route).
    ///
    /// It is not a race that widening a window would close. `updateNSView`
    /// never applies a command — the surface is made once — so a command
    /// arriving afterwards cannot correct it.
    func testAPaneOnAnAlreadyReachedHostWaitsForItsOwnCommand() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        let id = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        let first = manager.workspaces.first { $0.id == id }!.panes[0].id
        manager.paneDidConnect(first, command: "bash connect.sh a 10.0.1.5 22 user 9000",
                               agentID: "a")

        // Now open a second pane on the same host: its link is up already.
        let second = manager.addRemotePane(toWorkspace: id, label: "GPU Box", hostEntry: host)

        XCTAssertEqual(manager.connectionID(ofLeaf: second), manager.connectionID(ofLeaf: first),
                       "the connection is shared — which is what makes it connected already")
        XCTAssertNil(manager.leafContent(second)?.terminalCommand)
        XCTAssertEqual(manager.surface(of: second), .dialling,
                       "nothing to run yet: a surface here spawns a LOCAL shell")

        manager.paneDidConnect(second, command: "bash connect.sh b 10.0.1.5 22 user 9000",
                               agentID: "b")

        XCTAssertEqual(manager.surface(of: second), .terminal)
        XCTAssertEqual(manager.leafContent(second)?.terminalCommand,
                       "bash connect.sh b 10.0.1.5 22 user 9000",
                       "and it runs its OWN command, not the pane's beside it")
    }

    // MARK: - What ONE leaf shows ([[RFC-0015]] C-DIAL, C-FAILURE)

    /// A LEAF BOUND TO A DIALLING HOST GETS NO SURFACE, and this is the
    /// rule that makes WI-2026-03-31-003 unrepresentable rather than
    /// merely avoided: a pane with no command whose surface was created
    /// anyway spawned a spurious LOCAL shell, which is why the whole
    /// placeholder model existed. The pane may now exist before its
    /// command does — [[RFC-0015]] C-DIAL requires it — so what stops the
    /// old bug is that a leaf whose connection is not up never gets one.
    func testALeafOnADiallingHostShowsTheDialAndNoTerminal() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        let id = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        let pane = manager.workspaces.first { $0.id == id }!.panes[0]

        XCTAssertEqual(manager.surface(of: pane.id), .dialling)
        XCTAssertNil(pane.content.terminalCommand,
                     "nothing to run yet, which is exactly why it must not be given a surface")
    }

    /// THE PANE IS THERE WHILE IT DIALS. C-DIAL: a leaf "MUST be created
    /// and displayed before its connection is `connected`", because a
    /// pane that appears only after a multi-second dial gives the human
    /// nothing to look at and nowhere to see progress.
    func testTheLeafExistsInTheLayoutWhileItIsStillDialling() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        let id = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        let workspace = manager.workspaces.first { $0.id == id }!

        XCTAssertNotNil(workspace.layout, "the workspace has a tree, not a placeholder")
        XCTAssertEqual(workspace.panes.count, 1)
        XCTAssertEqual(manager.paneArea(of: workspace), .layout,
                       "the layout is drawn; the dial belongs to the leaf inside it")
    }

    func testTheLeafTakesItsCommandWhenTheDialReturns() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        let id = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        let paneID = manager.workspaces.first { $0.id == id }!.panes[0].id

        manager.paneDidConnect(paneID, command: "bash connect.sh a 10.0.1.5 22 user 9000", agentID: "a")

        XCTAssertEqual(manager.surface(of: paneID), .terminal)
        let pane = manager.workspaces.first { $0.id == id }!.panes[0]
        XCTAssertEqual(pane.id, paneID, "the same pane, not a replacement")
        XCTAssertEqual(pane.content.terminalCommand, "bash connect.sh a 10.0.1.5 22 user 9000")
        XCTAssertEqual(manager.agentID(forLeaf: paneID), "a")
    }

    /// C-DIAL: "A leaf whose dial fails MUST remain in place with its
    /// binding intact and the failure reported on it. It MUST NOT be
    /// silently removed: the human asked for a pane on a host, and its
    /// absence is indistinguishable from never having asked."
    func testAFailedDialLeavesTheLeafWhereItIs() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        let id = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        let paneID = manager.workspaces.first { $0.id == id }!.panes[0].id

        // THROUGH THE PATH THAT SHIPS. This drove `paneDidFail`, a
        // per-leaf spelling of a per-connection fact that nothing called —
        // so the obligation was tested and the code carrying it was not.
        manager.markWorkspaceFailed(hostID: host.id, message: "Connection refused")

        XCTAssertEqual(manager.surface(of: paneID), .failed("Connection refused"))
        let workspace = manager.workspaces.first { $0.id == id }!
        XCTAssertEqual(workspace.panes.map(\.id), [paneID], "still there")
        XCTAssertEqual(manager.host(ofLeaf: paneID)?.label, "GPU Box", "binding intact")
    }

    /// A LOCAL LEAF IS NEVER DIALLING, because the local connection is
    /// never dialled ([[RFC-0015]] C-CONNECTION) — so a local pane with
    /// no command still gets its surface and its default shell, which is
    /// the behaviour that must NOT change.
    func testALocalLeafGetsItsSurfaceImmediately() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        XCTAssertEqual(manager.surface(of: manager.workspaces[0].panes[0].id), .terminal)
    }

    /// TWO MACHINES DIALLING AT ONCE, EACH ON ITS OWN ([[RFC-0015]]
    /// C-DIAL, C-FAILURE). One container has ONE state, so the model this
    /// replaced could not show two dials — the second host's progress was
    /// unrepresentable, and when one of them failed the workspace wore the
    /// failure without saying which machine it belonged to.
    func testTwoHostsDiallingInOneWorkspaceAreReportedSeparately() {
        let builder = HostEntry(label: "builder", address: "10.0.1.5", username: "user")
        let runner = HostEntry(label: "runner", address: "10.0.1.6", username: "user")
        let manager = WorkspaceManager()
        let id = manager.addRemoteWorkspace(label: "builder", hostEntry: builder)
        let first = manager.workspaces.first { $0.id == id }!.panes[0].id
        let second = manager.addRemotePane(toWorkspace: id, label: "runner", hostEntry: runner)

        XCTAssertNotEqual(manager.connectionID(ofLeaf: first), manager.connectionID(ofLeaf: second),
                          "two machines, two dials")
        XCTAssertEqual(manager.surface(of: first), .dialling)
        XCTAssertEqual(manager.surface(of: second), .dialling)

        // One arrives, the other refuses. Neither answer is the
        // workspace's, and neither may be read off the other.
        manager.paneDidConnect(first, command: "bash connect.sh a 10.0.1.5 22 user 9000",
                               agentID: "a")
        manager.markWorkspaceFailed(
            hostID: manager.host(ofLeaf: second)!.id, message: "Connection refused")

        XCTAssertEqual(manager.surface(of: first), .terminal)
        XCTAssertEqual(manager.surface(of: second), .failed("Connection refused"))
        XCTAssertEqual(manager.host(ofLeaf: second)?.label, "runner",
                       "the failure is reported on the leaf that owns it")
    }

    /// C-FAILURE: a workspace holding a connected pane and a dialling one
    /// shows both. The connected one is not hidden because its neighbour
    /// on another machine is still waiting.
    func testAConnectedLeafIsNotHiddenByADiallingSibling() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let localPane = manager.workspaces[0].panes[0].id
        let remotePane = manager.addRemotePane(toWorkspace: manager.workspaces[0].id,
                                               label: "GPU Box", hostEntry: host)

        XCTAssertEqual(manager.surface(of: localPane), .terminal)
        XCTAssertEqual(manager.surface(of: remotePane), .dialling)
        XCTAssertEqual(manager.paneArea(of: manager.workspaces[0]), .layout)
    }

    // MARK: - What the pane area shows ([[RFC-0015]] C-EMPTY)

    /// THE PANE AREA'S THREE OUTCOMES, decided in one place because two
    /// call sites deciding it separately is how the same conflation
    /// shipped twice.
    func testAWorkspaceWithATreeDrawsIt() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        XCTAssertEqual(manager.paneArea(of: manager.workspaces[0]), .layout)
    }

    /// The one that span forever, and the one whose message was absurd:
    /// the local connection is never dialled, so "establishing an SSH
    /// tunnel" to it is not a slow truth, it is an impossible one.
    func testAWorkspaceEmptiedOfItsLastPaneIsAtRest() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addLocalWorkspace()
        let away = manager.workspaces[1].id
        let lone = manager.workspaces[0].panes[0].id

        manager.movePane(lone, toWorkspace: away)

        XCTAssertEqual(manager.paneArea(of: manager.workspaces[0]), .empty)
    }

    func testAWorkspaceEmptiedByClosingIsAtRestToo() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.archivePane(manager.workspaces[0].panes[0].id)
        XCTAssertEqual(manager.paneArea(of: manager.workspaces[0]), .empty)
    }

    /// A DIALLING WORKSPACE DRAWS ITS LAYOUT, because the dial belongs to
    /// the leaf inside it. This asserted the opposite an hour ago, when a
    /// container could be "connecting" and covered its own layout with a
    /// card — which is what made a connected pane invisible while a
    /// sibling on another machine was still waiting.
    func testADiallingWorkspaceStillDrawsItsLayout() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        let id = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        let workspace = manager.workspaces.first { $0.id == id }!
        XCTAssertEqual(manager.paneArea(of: workspace), .layout)
        XCTAssertEqual(manager.surface(of: workspace.panes[0].id), .dialling)
    }

    /// And a failed one too: the leaf stays in the layout and carries the
    /// reason ([[RFC-0015]] C-DIAL, C-FAILURE).
    func testAFailedWorkspaceStillDrawsItsLayout() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        let id = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        let paneID = manager.workspaces.first { $0.id == id }!.panes[0].id
        manager.markWorkspaceFailed(hostID: host.id, message: "Connection refused")
        XCTAssertEqual(manager.paneArea(of: manager.workspaces.first { $0.id == id }!), .layout)
        XCTAssertEqual(manager.surface(of: paneID), .failed("Connection refused"))
    }

    // MARK: - An emptied workspace is at rest, not dialling

    /// NO PANES IS TWO DIFFERENT FACTS, and reporting them alike is what
    /// [[RFC-0015]] C-EMPTY forbids in as many words: an empty workspace
    /// "MUST NOT be confused with a workspace whose connections are still
    /// dialling". A workspace whose last pane was dragged away spun on a
    /// connecting indicator forever, because the aggregate read an empty
    /// set of connection states as `connecting`.
    func testAWorkspaceEmptiedByAMoveIsNotDialling() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addLocalWorkspace()
        let home = manager.workspaces[0].id
        let away = manager.workspaces[1].id
        let lone = manager.workspaces[0].panes[0].id

        manager.movePane(lone, toWorkspace: away)

        let source = manager.workspaces.first { $0.id == home }!
        XCTAssertTrue(source.panes.isEmpty, "the pane did leave")
        XCTAssertTrue(manager.connections(ofWorkspace: source).isEmpty,
                      "an empty workspace holds no connection to report on")
    }

    /// The same on the path that was always reachable — closing the last
    /// pane empties a workspace too, and has since the workspace stopped
    /// being destroyed with it.
    func testAWorkspaceEmptiedByClosingIsNotDialling() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()

        manager.archivePane(manager.workspaces[0].panes[0].id)

        XCTAssertTrue(manager.connections(ofWorkspace: manager.workspaces[0]).isEmpty)
    }

    /// AND THE CASE THE OLD FALLBACK WAS REACHING FOR STILL WORKS, though
    /// it no longer looks the same: a workspace mid-dial HAS a pane now,
    /// and its connection is what reports connecting.
    func testAWorkspaceMidDialStillReportsConnecting() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        let id = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)

        let workspace = manager.workspaces.first { $0.id == id }!
        XCTAssertEqual(workspace.panes.count, 1, "the pane is there while it dials")
        // THE PANE'S CONNECTION REPORTS IT, not the workspace: a
        // container whose panes may be on three machines has no single
        // state ([[WI-2026-08-17-026]]).
        let connection = manager.connections.connection(workspace.panes[0].connectionID)
        XCTAssertEqual(connection?.state, .connecting)
    }

    func testAPaneDroppedOnAWorkspaceThatIsNotThereChangesNothing() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        manager.addPaneToActiveWorkspace()
        let ids = manager.workspaces[0].panes.map(\.id)

        manager.movePane(ids[0], toWorkspace: UUID())
        manager.movePane(UUID(), toWorkspace: manager.workspaces[0].id)

        XCTAssertEqual(manager.workspaces[0].panes.map(\.id), ids)
    }
}

// MARK: - Attention pipeline (WI-2026-08-09-021)

@MainActor
final class AttentionTests: XCTestCase {

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

    /// A bell on a non-focused leaf marks attention; totals aggregate.
    func testMarkAttentionAndCount() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let leaves = manager.workspaces[0].panes
        // Focus position 2, ring bell on the pane in position 1.
        manager.focusSlot(index: 2)
        manager.markLeafAttention(leaves[0].id)
        XCTAssertTrue(manager.isAwaitingAttention(leaves[0].id))
        XCTAssertEqual(manager.attentionCount, 1)
        XCTAssertTrue(manager.workspaceNeedsAttention(manager.workspaces[0]))
    }

    /// A bell on the CURRENTLY focused, visible leaf is ignored — the
    /// user is already looking at it.
    func testBellOnFocusedLeafIgnored() {
        let manager = makeManager()
        let leafID = manager.workspaces[0].panes[0].id
        manager.markLeafAttention(leafID)
        XCTAssertFalse(manager.isAwaitingAttention(leafID))
        XCTAssertEqual(manager.attentionCount, 0)
    }

    /// Focusing the leaf clears its attention.
    func testFocusClearsAttention() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let leaves = manager.workspaces[0].panes
        manager.focusSlot(index: 2)
        manager.markLeafAttention(leaves[0].id)
        XCTAssertEqual(manager.attentionCount, 1)
        manager.focusLeaf(leaves[0].id)
        XCTAssertEqual(manager.attentionCount, 0)
    }

    /// Closing a leaf drops its attention entry.
    func testCloseClearsAttention() {
        let manager = makeManager()
        manager.splitFocusedLeaf(direction: .horizontal)
        let leaves = manager.workspaces[0].panes
        manager.focusSlot(index: 2)
        manager.markLeafAttention(leaves[0].id)
        manager.leafDidClose(leaves[0].id)
        XCTAssertEqual(manager.attentionCount, 0)
    }

    /// A PANE BEHIND A TAB STILL REPORTS. It has no rectangle of its own
    /// to wear a ring on, so the position it is stacked in carries the
    /// mark — otherwise a bell in a hidden pane is silent.
    func testAPaneBehindATabWearsItsMarkOnTheTab() {
        // WHERE THE MARK GOES IS THE POINT, and the shipped answer is
        // better than the one this test used to assert. It drove
        // `slotNeedsAttention`, which marked the POSITION — and
        // SplitContentView says why that is wrong for a hidden pane: "a
        // pane BEHIND a tab wears its mark on the tab instead — a ring
        // nobody can see is not one." The tab bar reads
        // `isAwaitingAttention` per pane, so a pane nobody can see still
        // has somewhere visible to say so.
        let manager = makeManager()
        let behind = manager.workspaces[0].panes[0].id
        manager.addPaneToActiveWorkspace()   // stacks in front of `behind`
        manager.markLeafAttention(behind)

        XCTAssertTrue(manager.isAwaitingAttention(behind),
                      "the tab bar asks this per pane, which is what puts the mark where it can be seen")
        XCTAssertTrue(manager.workspaceNeedsAttention(manager.workspaces[0]),
                      "and it aggregates to the session row in the sidebar")
    }

    /// Attention on a BACKGROUND session aggregates to its row.
    func testBackgroundSessionAttention() {
        let manager = makeManager()
        let firstLeaf = manager.workspaces[0].panes[0].id
        manager.addLocalWorkspace()  // second session becomes active
        manager.markLeafAttention(firstLeaf)
        XCTAssertTrue(manager.workspaceNeedsAttention(manager.workspaces[0]))
        XCTAssertFalse(manager.workspaceNeedsAttention(manager.workspaces[1]))
    }

}

// MARK: - Ending remote agents (WI-2026-08-17-001)

@MainActor
final class RemoteAgentEndingTests: XCTestCase {

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

    private static let remoteHost = HostEntry(
        label: "GPU", address: "10.0.1.5", username: "user")

    /// A connected remote session with one pane, and a recorder in place
    /// of the ssh.
    private func makeRemote(
        _ ended: @escaping (String) -> Void
    ) -> (WorkspaceManager, UUID) {
        let manager = WorkspaceManager()
        manager.remoteAgentEnder = { _, agentID in ended(agentID); return Task { true } }
        let id = manager.addRemoteWorkspace(label: "GPU", hostEntry: Self.remoteHost)
        let paneID = manager.workspaces.first { $0.id == id }!.panes[0].id
        manager.paneDidConnect(paneID, command: "bash connect.sh", agentID: "gpu-first")
        return (manager, id)
    }

    private func session(_ manager: WorkspaceManager, _ id: UUID)
    -> WorkspaceManager.Workspace {
        manager.workspaces.first { $0.id == id }!
    }

    /// Every tab and every split minted its own `synapty run`, so every one
    /// of them is a tmux session on the host — and the close ends all of
    /// them, not just the one the session was dialled with.
    func testClosingRemoteSessionEndsEveryAgentItHeld() {
        var ended: [String] = []
        let (manager, id) = makeRemote { ended.append($0) }
        manager.addPaneToActiveWorkspace()
        manager.splitFocusedLeaf(direction: .horizontal)

        let live = session(manager, id)
        let expected = Set(live.panes.compactMap { manager.agentID(forLeaf: $0.id) })
        XCTAssertEqual(expected.count, 3, "one agent per pane")

        manager.removeWorkspace(live)
        XCTAssertEqual(Set(ended), expected)
    }

    /// CLOSING A PANE NO LONGER ENDS ITS AGENT ([[RFC-0015]] C-PANE-ARCHIVE):
    /// it is set aside and ending it is a separate act from the list. What
    /// survives from the old test is the invariant — ending one touches
    /// ONLY its own agent.
    func testEndingOneArchivedPaneTouchesOnlyItsOwnAgent() {
        var ended: [String] = []
        let (manager, id) = makeRemote { ended.append($0) }
        manager.addPaneToActiveWorkspace()

        let second = session(manager, id).panes[1]
        let secondAgent = manager.agentID(forLeaf: second.id)

        manager.archivePane(second.id)
        XCTAssertEqual(ended, [], "closing sets aside; it does not end")

        manager.endArchivedPane(second.id)
        XCTAssertEqual(ended, [secondAgent])
    }

    /// A split is a shell the human opened and closed like any other — so
    /// it is set aside like any other, and its sibling keeps running.
    func testClosingASplitSetsItAsideAndLeavesItsSibling() {
        var ended: [String] = []
        let (manager, id) = makeRemote { ended.append($0) }
        manager.splitFocusedLeaf(direction: .horizontal)

        let focused = manager.activeWorkspace!.focusedPaneID!
        let focusedAgent = manager.agentID(forLeaf: focused)
        let sibling = session(manager, id).panes.map(\.id)
            .first { $0 != focused }!

        manager.closeFocusedLeaf()
        XCTAssertEqual(ended, [], "closing sets aside; it does not end")
        XCTAssertEqual(manager.archivedPanes.map(\.id), [focused])
        XCTAssertNotNil(manager.activeWorkspace?.layout?.findPane(sibling),
                        "the sibling is untouched")

        manager.endArchivedPane(focused)
        XCTAssertEqual(ended, [focusedAgent])
    }

    /// Closing the last tab ends its agent exactly once — and leaves the
    /// workspace standing ([[RFC-0015]] C-WORKSPACE), so there is no
    /// cascade to spend a second ssh on.
    func testClosingTheLastPaneSetsItAsideAndKeepsTheWorkspace() {
        var ended: [String] = []
        let (manager, id) = makeRemote { ended.append($0) }

        manager.archivePane(session(manager, id).panes[0].id)
        XCTAssertEqual(ended, [], "closing sets aside; it does not end")
        XCTAssertEqual(manager.workspaces.count, 1, "the workspace outlives its last pane")
        XCTAssertTrue(session(manager, id).panes.isEmpty, "it left the layout")
        XCTAssertEqual(manager.archivedPanes.count, 1, "and is still named somewhere")
    }

    /// ENDING IS ONCE. The row goes with the session, so a second attempt
    /// has nothing to end — which is what keeps a list a human can press
    /// twice from killing something else.
    func testEndingAArchivedPaneTwiceEndsItOnce() {
        var ended: [String] = []
        let (manager, id) = makeRemote { ended.append($0) }
        let pane = session(manager, id).panes[0].id
        manager.archivePane(pane)

        manager.endArchivedPane(pane)
        manager.endArchivedPane(pane)

        XCTAssertEqual(ended, ["gpu-first"])
    }

    /// THE DURABILITY CASE. `leafDidClose` fires when the LOCAL ssh ends,
    /// and from this side a dropped link and an exited shell are the same
    /// event — so nothing remote may be ended there, or a network blip
    /// would destroy the session tmux exists to keep.
    func testProcessExitEndsNothingRemote() {
        var ended: [String] = []
        let (manager, id) = makeRemote { ended.append($0) }

        manager.leafDidClose(session(manager, id).panes[0].id)
        XCTAssertTrue(ended.isEmpty)
    }

    /// AN END THAT FAILED IS ONE TO TRY AGAIN.
    ///
    /// `endedAgents` recorded the id on the way OUT, before anything had
    /// answered, so a first attempt that reached nothing — no live
    /// connection, a holder wedged in its own teardown — poisoned the
    /// name for the rest of the run: every later press was a no-op, and
    /// the row came back from the next poll for as long as the app was
    /// open ([[WI-2026-09-03-010]]).
    func testAnEndThatFailedIsTriedAgain() async {
        var attempts = 0
        let manager = makeManager()
        let host = HostEntry(label: "box", address: "10.0.0.9", username: "u")
        manager.remoteAgentEnder = { _, _ in attempts += 1; return Task { false } }

        await manager.endRemoteSession("local-a0fe", on: host)
        await manager.endRemoteSession("local-a0fe", on: host)

        XCTAssertEqual(attempts, 2, "a failed end was never retried")
    }

    /// And one that worked is not asked twice — the reason the set exists
    /// at all: a workspace close and a pane close can name one agent.
    func testAnEndThatWorkedIsNotRepeated() async {
        var attempts = 0
        let manager = makeManager()
        let host = HostEntry(label: "box", address: "10.0.0.9", username: "u")
        manager.remoteAgentEnder = { _, _ in attempts += 1; return Task { true } }

        await manager.endRemoteSession("local-a0fe", on: host)
        await manager.endRemoteSession("local-a0fe", on: host)

        XCTAssertEqual(attempts, 1, "an agent already ended was asked a second time")
    }

    /// A local session has no remote anything to end.
    func testClosingLocalSessionEndsNothing() {
        var ended: [String] = []
        let manager = makeManager()
        manager.remoteAgentEnder = { _, agentID in ended.append(agentID); return Task { true } }
        manager.removeWorkspace(manager.workspaces[0])
        XCTAssertTrue(ended.isEmpty)
    }
}


/// [[WI-2026-08-20-001]]: the find bar belongs to a leaf, which is what
/// makes [[RFC-0016]] C-DISPATCH's second row decidable.
@MainActor
final class FindBarOwnershipTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    func testTwoLeavesHaveTwoBars() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let first = manager.workspaces[0].panes[0].id
        let second = manager.addPane(content: .terminal(command: nil),
                                     toWorkspace: manager.workspaces[0].id)!

        manager.beginFinding(first)
        manager.setFindQuery(first, "error")

        XCTAssertTrue(manager.isFinding(first))
        XCTAssertFalse(manager.isFinding(second), "the other leaf's bar is not open")
        XCTAssertEqual(manager.findQuery(first), "error")
        XCTAssertEqual(manager.findQuery(second), "",
                       "and it certainly does not share the query")
    }

    /// A LEAF WITH NO SCROLLBACK HAS NOTHING TO SEARCH, and a bar there
    /// would belong to no terminal — the state ownership exists to make
    /// impossible.
    func testAFileLeafCannotOpenAFindBar() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let files = manager.addPane(content: .files(directory: nil), toWorkspace: manager.workspaces[0].id)!

        XCTAssertFalse(manager.beginFinding(files))
        XCTAssertFalse(manager.isFinding(files))
    }

    func testABarDoesNotOutliveItsLeaf() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let workspace = manager.workspaces[0].id
        let first = manager.workspaces[0].panes[0].id
        _ = manager.addPane(content: .terminal(command: nil), toWorkspace: workspace)
        manager.beginFinding(first)

        manager.archivePane(first)

        XCTAssertFalse(manager.isFinding(first))
        XCTAssertTrue(manager.facts.values.allSatisfy { $0.find == nil })
    }

    /// The query survives closing and reopening the bar on the same leaf —
    /// a human who dismissed it by accident has not lost what they typed.
    func testReopeningTheSameLeafsBarIsNotAFreshOne() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let leaf = manager.workspaces[0].panes[0].id
        manager.beginFinding(leaf)
        manager.setFindQuery(leaf, "needle")
        manager.beginFinding(leaf)
        XCTAssertEqual(manager.findQuery(leaf), "needle")
    }
}

/// A WORKSPACE HAS NO HOST OF ITS OWN ([[RFC-0015]] C-LEAF-BINDING), so
/// what the sidebar may say about one is bounded by how many machines its
/// panes are on — and THIS MAC IS ONE OF THEM.
@MainActor
final class WorkspaceMachineCountTests: XCTestCase {

    private var tunnelManager: TunnelManager!

    override func setUpWithError() throws {
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
    }

    /// THE CASE THAT WAS WRONG ON SCREEN. A local pane and a remote one is
    /// TWO machines; counting host RECORDS saw one, because the local
    /// connection has no host record — and the row then showed that one
    /// remote's address as though it were the workspace's.
    func testALocalPaneAndARemoteOneAreTwoMachines() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let workspace = manager.workspaces[0]
        manager.addRemotePane(toWorkspace: workspace.id, label: "GPU Box", hostEntry: host)

        let reread = manager.workspaces[0]
        XCTAssertEqual(manager.connections(ofWorkspace: reread).count, 2)
        XCTAssertEqual(manager.hosts(ofWorkspace: reread).count, 1,
                       "the local connection has no host record, which is why counting them misled")
    }

    /// AND THE CLOSING QUESTION ASKS THE SAME QUESTION. It counts what is
    /// about to be discarded, so it must not fall back to host RECORDS —
    /// a local workspace would then be about to close "on 0 machines"
    /// ([[WorkspaceDestruction]], [[WI-2026-08-19-007]]).
    func testTheClosingQuestionCountsMachinesAndNotHostRecords() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        guard var workspace = manager.activeWorkspace else { return XCTFail() }
        let remote = manager.connections.acquire(host: host).id
        let here = SplitNode.Pane(content: .terminal(command: "x"),
                                  connectionID: manager.connections.localID)
        let there = SplitNode.Pane(content: .terminal(command: "y"), connectionID: remote)
        workspace.setLayout(.slot(SplitNode.Slot(panes: [here, there])))
        manager.workspaces[0] = workspace

        XCTAssertEqual(manager.machineCount(ofWorkspace: manager.workspaces[0]), 2)
        XCTAssertEqual(manager.hosts(ofWorkspace: manager.workspaces[0]).count, 1,
                       "host records see one; the human is losing work on two")
    }

    func testTwoPanesOnOneHostAreOneMachine() {
        let host = HostEntry(label: "GPU Box", address: "10.0.1.5", username: "user")
        let manager = WorkspaceManager()
        let id = manager.addRemoteWorkspace(label: "GPU Box", hostEntry: host)
        manager.addRemotePane(toWorkspace: id, label: "GPU Box", hostEntry: host)

        let workspace = manager.workspaces.first { $0.id == id }!
        XCTAssertEqual(workspace.panes.count, 2)
        XCTAssertEqual(manager.connections(ofWorkspace: workspace).count, 1,
                       "one machine, however many panes name it")
    }
}

/// The unasked close the tests drive. Shipped code closes the focused pane
/// through `closePaneAsking`; this is the same removal without the question
/// ([[WI-2026-09-02-036]]: a method only tests call lives with the tests).
extension WorkspaceManager {
    func closeFocusedLeaf() {
        guard let focused = activeWorkspace?.focusedPaneID else { return }
        archivePane(focused)
    }
}
