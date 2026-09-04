import XCTest
@testable import Synapty

/// WI-2026-08-11-014: RFC-0006 session snapshot, resume plans, and the
/// pure composition/validation pieces.
final class SessionSnapshotTests: XCTestCase {

    /// Class-level isolation, so no test in this file can reach the real
    /// machine-scoped session.json — the same harness HostStoreTests has
    /// carried since WI-2026-08-08-037. It was missing here, and the file
    /// was relying on the fact that only one of its tests happened to
    /// write.
    private var sessionFile: URL!

    override func setUpWithError() throws {
        sessionFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-session-\(UUID().uuidString).json")
        WorkspaceStore.storageOverride = sessionFile
    }

    override func tearDownWithError() throws {
        XCTAssertNotNil(WorkspaceStore.storageOverride,
                        "a test dropped the storage override — the next test would write real state")
        WorkspaceStore.storageOverride = nil
        try? FileManager.default.removeItem(at: sessionFile)
    }

    // MARK: - C-RESUME-PLAN allowlist validation

    func testResumeRefValidatorAllowlist() {
        XCTAssertEqual(ResumeRefValidator.validate("abc123-DEF_456.z"), "abc123-DEF_456.z")
        // Whitespace, control chars, emptiness, overlength: all rejected.
        XCTAssertNil(ResumeRefValidator.validate(""))
        XCTAssertNil(ResumeRefValidator.validate("has space"))
        XCTAssertNil(ResumeRefValidator.validate("tab\there"))
        XCTAssertNil(ResumeRefValidator.validate("new\nline"))
        XCTAssertNil(ResumeRefValidator.validate("ctrl\u{07}bell"))
        XCTAssertNil(ResumeRefValidator.validate("non-ascii-日本"))
        XCTAssertNil(ResumeRefValidator.validate(String(repeating: "a", count: 200)))
    }

    // MARK: - Plan composition

    private let claudeSpec = ToolLifecycleSpec(
        tool: "claude",
        resumeArgv: ["claude", "--resume", "{resume_ref}"])

    func testComposeValidRefYieldsIncantation() {
        let plan = ResumePlanComposer.compose(
            tool: "claude", resumeRef: "deadbeef-1234", cwd: "/tmp/x", host: nil,
            spec: claudeSpec)
        XCTAssertEqual(plan.incantation, "claude --resume deadbeef-1234")
        XCTAssertEqual(plan.resumeRef, "deadbeef-1234")
        XCTAssertEqual(plan.cwd, "/tmp/x")
    }

    func testComposeDegradesToLaunchFresh() {
        // Invalid ref → launch-fresh, honestly (no incantation).
        let bad = ResumePlanComposer.compose(
            tool: "claude", resumeRef: "has space", cwd: nil, host: nil,
            spec: claudeSpec)
        XCTAssertNil(bad.incantation)
        XCTAssertNil(bad.resumeRef)

        // Missing ref → launch-fresh.
        XCTAssertNil(ResumePlanComposer.compose(
            tool: "claude", resumeRef: nil, cwd: nil, host: nil,
            spec: claudeSpec).incantation)

        // No template → launch-fresh even with a valid ref.
        XCTAssertNil(ResumePlanComposer.compose(
            tool: "mystery", resumeRef: "abc", cwd: nil, host: nil,
            spec: nil).incantation)
    }

    // MARK: - Spec loader (data-file discipline)

    func testSpecLoaderReadsOverrideDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-lifecycle-test-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"tool":"mytool","resumeArgv":["mytool","-r","{resume_ref}"]}
        """
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("mytool.json"))

        let specs = LifecycleSpecLoader.loadAll(bundledDir: nil, overrideDir: dir)
        XCTAssertEqual(specs["mytool"]?.resumeArgv, ["mytool", "-r", "{resume_ref}"])
    }

    // MARK: - Snapshot round-trip through the pane manager

    @MainActor
    private func makeManager() -> (WorkspaceManager, TunnelManager) {
        let tunnel = TunnelManager()
        TunnelManager.shared = tunnel
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        return (manager, tunnel)
    }

    @MainActor
    func testSnapshotRestoreRoundTrip() throws {
        let (manager, tunnel) = makeManager()
        defer { TunnelManager.shared = nil; _ = tunnel }

        // Shape: one workspace split into two positions, with pwd +
        // armed + plan.
        manager.splitFocusedLeaf(direction: .horizontal)
        let leaves = manager.workspaces[0].panes
        XCTAssertEqual(leaves.count, 2)
        manager.leafDidUpdatePwd(leaves[0].id, pwd: "/tmp/projA")
        manager.setWakeArmed(leaves[0].id, true)
        let plan = ResumePlan(
            tool: "claude", cwd: "/tmp/projA", host: nil,
            resumeRef: "cafe1234", incantation: "claude --resume cafe1234")

        let snap = manager.snapshot(planFor: { $0 == leaves[0].id ? plan : nil })

        // Codable round-trip survives.
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)

        // Restore into a FRESH manager: layout, cwd, armed bit, plan.
        let restored = WorkspaceManager()
        let leafMeta = restored.restore(from: decoded, hostStore: nil)
        XCTAssertEqual(restored.workspaces.count, 1)
        let newLeaves = restored.workspaces[0].panes
        XCTAssertEqual(newLeaves.count, 2)
        XCTAssertEqual(restored.workspaces[0].slots.count, 2, "two positions, not a stack")
        // Fresh leaf ids (never reused), fresh wrapper agent per leaf.
        XCTAssertNotEqual(Set(newLeaves.map(\.id)), Set(leaves.map(\.id)))
        // cwd threads into the leaf's spawn working directory.
        let cwds = newLeaves.compactMap(\.workingDirectory)
        XCTAssertEqual(cwds, ["/tmp/projA"])
        // Armed bit re-arms on the NEW leaf carrying the entry.
        let armedNew = newLeaves.filter { restored.isWakeArmed($0.id) }
        XCTAssertEqual(armedNew.count, 1)
        XCTAssertEqual(armedNew.first?.workingDirectory, "/tmp/projA")
        // The plan rides leafMeta for the resume engine.
        let planEntries = leafMeta.values.compactMap(\.resumePlan)
        XCTAssertEqual(planEntries, [plan])

        // Restore is fresh-launch only: a second call is a no-op.
        XCTAssertTrue(restored.restore(from: decoded, hostStore: nil).isEmpty)
    }

    /// A STACK IS AN ARRANGEMENT AND MUST COME BACK AS ONE, with the same
    /// tab in front. It was a list of tabs each holding a tree of its own;
    /// a restore that flattened the stacks or reopened them showing the
    /// wrong pane has not restored what the human left.
    @MainActor
    func testAStackAndWhichTabWasInFrontSurviveARestart() throws {
        let (manager, tunnel) = makeManager()
        defer { TunnelManager.shared = nil; _ = tunnel }

        // Two positions; the right one holding three panes, with the
        // MIDDLE one in front — neither the first, which a lost index
        // would fall back to, nor the last, which is simply the one added
        // most recently.
        manager.splitFocusedLeaf(direction: .horizontal)
        manager.addPaneToActiveWorkspace()
        manager.addPaneToActiveWorkspace()
        manager.renamePane(manager.workspaces[0].slots[1].panes[1].id, to: "front")
        manager.selectPane(index: 2)

        XCTAssertEqual(manager.workspaces[0].slots.map(\.panes.count), [1, 3])
        XCTAssertEqual(manager.displayLabel(for: try XCTUnwrap(
            manager.workspaces[0].slots[1].activePane)), "front")

        let snap = manager.snapshot(planFor: { _ in nil })
        let restored = WorkspaceManager()
        _ = restored.restore(from: snap, hostStore: nil)

        XCTAssertEqual(restored.workspaces[0].slots.map(\.panes.count), [1, 3],
                       "two positions, one of them a stack of three")
        XCTAssertEqual(restored.displayLabel(for: try XCTUnwrap(
            restored.workspaces[0].slots[1].activePane)), "front",
                       "the tab that was in front is in front")
        XCTAssertEqual(restored.workspaces[0].focusedPaneID,
                       restored.workspaces[0].slots[1].activePaneID,
                       "and the human is back in the position they were working in")
    }

    /// Live-verification finding: a restored exec pane came back as an
    /// ordinary shell tab — unowned (its registration died with the
    /// restart) and stripped of its machine-operated marker. Machine
    /// scratch space must not outlive the workbench that owned it.
    @MainActor
    func testSnapshotExcludesExecPanes() throws {
        let (manager, tunnel) = makeManager()
        defer { TunnelManager.shared = nil; _ = tunnel }

        let humanPane = manager.workspaces[0].panes[0]
        let execLeaf = manager.newExecTab(handle: "exec-x1", owner: "local-a", cwd: "/tmp")
        XCTAssertNotNil(execLeaf)
        XCTAssertEqual(manager.workspaces[0].panes.count, 2)
        // newExecTab brings its pane to the front, so the active index
        // must survive the exclusion rather than pointing past the end.
        XCTAssertEqual(manager.workspaces[0].focusedPaneID, execLeaf)

        let snap = manager.snapshot(planFor: { _ in nil })
        XCTAssertEqual(snap.workspaces.count, 1)
        let entries = try XCTUnwrap(snap.workspaces[0].root?.paneEntries)
        XCTAssertEqual(entries.count, 1, "only the human's pane is snapshotted")
        XCTAssertEqual(entries[0].label, humanPane.label)
        for slot in try XCTUnwrap(snap.workspaces[0].root?.slotEntries) {
            XCTAssertTrue(slot.activeIndex < slot.panes.count, "active index must stay in range")
        }

        // And restore brings back only that one pane.
        let restored = WorkspaceManager()
        _ = restored.restore(from: snap, hostStore: nil)
        XCTAssertEqual(restored.workspaces[0].panes.count, 1)
    }


    // MARK: - Store isolation

    func testSessionStoreRoundTrip() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-session-test-\(ProcessInfo.processInfo.processIdentifier).json")
        let saved = WorkspaceStore.storageOverride
        WorkspaceStore.storageOverride = file
        defer {
            WorkspaceStore.storageOverride = saved
            try? FileManager.default.removeItem(at: file)
        }
        var snap = WorkspaceSnapshot()
        snap.workspaces.append(.init(
            label: "Local 1",
            root: .slot(.init(panes: [.init(label: "Shell", pwd: "/x", wakeArmed: true)])),
            focusedSlotIndex: 0))
        WorkspaceStore.save(snap)
        XCTAssertEqual(WorkspaceStore.load(), snap)
    }
}

@MainActor
extension SessionSnapshotTests {

    // MARK: - Coming back to the machines you had open

    /// A REMOTE SESSION COMES BACK CONNECTING, NOT FAILED.
    ///
    /// It used to be restored as `.failed("Restored — reconnect to
    /// resume")`, citing C-RESUME-RESTORE — a clause about what may be
    /// TYPED into a restored pane, which says nothing about opening the
    /// connection. The cost was paid every launch: a workbench whose whole
    /// point is several machines at once came back with all of them down.
    func testARestoredRemoteSessionIsDialledRatherThanParked() throws {
        let store = HostStore()
        let host = HostEntry(label: "builder", address: "builder.example", username: "u")
        store.hosts.append(host)

        let snapshot = WorkspaceSnapshot(workspaces: [
            .init(label: "builder",
                  root: .slot(.init(panes: [.init(label: "Shell", hostID: host.id)])))
        ])
        let manager = WorkspaceManager()
        _ = manager.restore(from: snapshot, hostStore: store)

        let session = try XCTUnwrap(manager.workspaces.first)
        let leaf = try XCTUnwrap(session.panes.first)
        XCTAssertEqual(manager.host(ofLeaf: leaf.id)?.id, host.id,
                       "the pane comes back on the machine it was on")
        XCTAssertEqual(manager.connections.connection(leaf.connectionID)?.state, .connecting)
        XCTAssertEqual(manager.workspacesAwaitingDial, [session.id],
                       "the caller has to know which ones to dial")
    }

    /// A HOST THAT IS GONE IS NOT DIALLED — AND ITS PANE IS NOT DISCARDED
    /// EITHER ([[WI-2026-08-17-025]]).
    ///
    /// This asserted that the whole workspace vanished, which was the
    /// behaviour before a host was a per-leaf fact: there was nothing
    /// finer to drop. Deleting a host is not an instruction to discard the
    /// arrangements that named it, and a pane that silently failed to come
    /// back is one the human cannot act on. It comes back saying what is
    /// wrong with it instead.
    func testAPaneWhoseHostWasDeletedComesBackSayingSo() {
        let store = HostStore()
        let gone = UUID()
        let snapshot = WorkspaceSnapshot(workspaces: [
            .init(label: "builder",
                  root: .slot(.init(panes: [.init(label: "Shell", hostID: gone)])))
        ])
        let manager = WorkspaceManager()
        _ = manager.restore(from: snapshot, hostStore: store)

        let panes = manager.workspaces.flatMap(\.panes)
        XCTAssertEqual(panes.count, 1, "the pane was discarded with its host")
        let state = manager.connections.connection(panes[0].connectionID)?.state
        guard case .failed(let why) = state else {
            return XCTFail("a pane whose host is gone came back as though it could be dialled: \(String(describing: state))")
        }
        XCTAssertTrue(why.contains("no longer"), "the reason does not say what happened: \(why)")
        XCTAssertTrue(manager.workspacesAwaitingDial.isEmpty,
                      "a host that is gone must not be dialled")
    }

    /// The list belongs to THIS restore. A second call must not hand the
    /// caller hosts it already dialled.
    func testTheDialListIsNotCumulative() {
        let store = HostStore()
        let host = HostEntry(label: "builder", address: "builder.example", username: "u")
        store.hosts.append(host)
        let snapshot = WorkspaceSnapshot(workspaces: [
            .init(label: "builder",
                  root: .slot(.init(panes: [.init(label: "Shell", hostID: host.id)])))
        ])
        let manager = WorkspaceManager()
        _ = manager.restore(from: snapshot, hostStore: store)
        let first = manager.workspacesAwaitingDial

        // restore() refuses once workspaces exist, so the list must not grow.
        _ = manager.restore(from: snapshot, hostStore: store)
        XCTAssertEqual(manager.workspacesAwaitingDial, first)
    }
}

