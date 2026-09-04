import XCTest
@testable import Synapty

/// THE PROMISE MUST NOT OUTRUN WHAT WORKS ([[RFC-0015]] C-HONESTY,
/// [[WI-2026-08-17-027]]).
final class RejoiningTests: XCTestCase {

    // MARK: - This machine

    func testALiveHolderIsARejoin() {
        XCTAssertEqual(Rejoining.local(recorded: "local-a1", durable: true,
                                       isLive: { $0 == "local-a1" }),
                       .rejoined)
    }

    /// A REBOOTED MACHINE. The name was recorded, and nothing holds it.
    func testARecordedNameNothingIsHoldingIsARestart() {
        XCTAssertEqual(Rejoining.local(recorded: "local-a1", durable: true,
                                       isLive: { _ in false }),
                       .restarted(.sessionGone))
    }

    /// THE HUMAN'S OWN OPT-OUT is a different thing from a machine that
    /// rebooted: it is a setting they can change, and saying "the session
    /// is gone" would send them looking for a fault instead.
    func testDurabilityOffIsReportedAsTheSettingItIs() {
        XCTAssertEqual(Rejoining.local(recorded: "local-a1", durable: false,
                                       isLive: { _ in true }),
                       .restarted(.durabilityOff(machine: "this Mac")))
    }

    func testAPaneThatNamedNoSessionSaysSo() {
        XCTAssertEqual(Rejoining.local(recorded: nil, durable: true, isLive: { _ in true }),
                       .restarted(.nothingRecorded))
    }

    // MARK: - Another machine

    /// RESTORE MUST NOT BLOCK ON A CONNECTION, so the answer is not
    /// invented here.
    func testARemotePaneWaitsForTheFarSideRatherThanGuessing() {
        XCTAssertEqual(Rejoining.remote(recorded: "builder-9f", machine: "builder",
                                        durable: true),
                       .undecided)
    }

    /// EXCEPT THE OPT-OUT, which this side set and therefore knows.
    func testAHostWithDurabilityOffNeedsNoRoundTrip() {
        XCTAssertEqual(Rejoining.remote(recorded: "builder-9f", machine: "builder",
                                        durable: false),
                       .restarted(.durabilityOff(machine: "builder")))
    }

    func testTheNameItRegistersUnderIsTheAnswer() {
        XCTAssertEqual(Rejoining.settled(registeredAs: "builder-9f", recorded: "builder-9f"),
                       .rejoined)
        XCTAssertEqual(Rejoining.settled(registeredAs: "builder-fresh", recorded: "builder-9f"),
                       .restarted(.sessionGone))
    }

    // MARK: - What it says

    /// EACH CASE SAYS SOMETHING DIFFERENT, because they ARE different
    /// things to someone deciding whether to close a window.
    func testTheFourAnswersReadDifferently() {
        let sentences = Set([
            Rejoining.rejoined,
            .restarted(.durabilityOff(machine: "builder")),
            .restarted(.sessionGone),
            .restarted(.nothingRecorded),
        ].map(\.sentence))
        XCTAssertEqual(sentences.count, 4, "two outcomes are reported as the same thing")
    }

    func testARestartNamesTheMachineWhoseSettingCausedIt() {
        XCTAssertTrue(Rejoining.restarted(.durabilityOff(machine: "builder"))
            .sentence.contains("builder"))
    }

    /// A NOTICE FOR THE HAPPY PATH is what teaches people to dismiss
    /// notices unread.
    func testOnlyABrokenPromiseIsPutInFrontOfTheHuman() {
        XCTAssertFalse(Rejoining.rejoined.isWorthSaying)
        XCTAssertFalse(Rejoining.undecided.isWorthSaying)
        XCTAssertTrue(Rejoining.restarted(.sessionGone).isWorthSaying)
        XCTAssertTrue(Rejoining.restarted(.durabilityOff(machine: "builder")).isWorthSaying)
        // A pane that never named a session was promised nothing — and
        // after a reboot there would be one of these on every pane.
        XCTAssertFalse(Rejoining.restarted(.nothingRecorded).isWorthSaying)
    }
}

/// THE SAME QUESTION ASKED OF A WHOLE WORKSPACE COMING BACK OUT OF THE
/// ARCHIVE ([[WI-2026-08-17-027]]).
@MainActor
final class RejoinReportingTests: XCTestCase {

    private var tmp: URL!
    private var tunnelManager: TunnelManager!
    private var store: HostStore!
    private var host: HostEntry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
        store = HostStore()
        host = HostEntry(label: "builder", address: "b.example", username: "someone")
        store.hosts.append(host)
    }

    override func tearDown() {
        TunnelManager.shared = nil
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    /// A pane on `host`, archived, taken back out.
    private func reopened(durableHost: Bool = true) -> (WorkspaceManager, UUID) {
        store.hosts[0].durableSessions = durableHost
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let connection = manager.connections.acquire(host: store.hosts[0]).id
        let pane = SplitNode.Pane(label: "build", content: .terminal(command: "x"),
                                  workingDirectory: "/srv", connectionID: connection)
        manager.workspaces[0].setLayout(.slot(SplitNode.Slot(pane: pane)))
        manager.syncReferencesForTest()
        // As if it had been running: the pane knows the name it left under.
        manager.recordLeafCandidates(pane.id, settled: "builder-9f", candidate: nil)
        let workspace = manager.workspaces[0].id
        manager.archiveWorkspace(workspace)
        _ = manager.unarchiveWorkspace(workspace, hostStore: store)
        return (manager, manager.workspaces[0].panes[0].id)
    }

    /// A REMOTE PANE SAYS NOTHING YET, because restore must not block on
    /// a connection and the answer is on the far side.
    func testAReopenedRemotePaneMakesNoClaimUntilItHears() {
        let (manager, leaf) = reopened()
        XCTAssertNil(manager.rejoinNotice(leaf),
                     "it announced an outcome it could not yet know")
    }

    /// THE REGISTRATION IS THE ANSWER. Registering under the OTHER name
    /// means the session it meant to return to was not there.
    func testRegisteringUnderTheFreshNameIsReportedAsARestart() {
        let (manager, leaf) = reopened()
        let recorded = manager.facts[leaf]?.agent
        manager.recordLeafCandidates(leaf, settled: recorded, candidate: "builder-new")

        XCTAssertEqual(manager.leafID(forAgent: "builder-new"), leaf)
        XCTAssertEqual(manager.rejoinNotice(leaf), .restarted(.sessionGone))
    }

    func testRegisteringUnderTheRecordedNameSaysNothingBecauseItWorked() {
        let (manager, leaf) = reopened()
        guard let recorded = manager.facts[leaf]?.agent else { return XCTFail("no name") }
        manager.recordLeafCandidates(leaf, settled: recorded, candidate: "builder-new")

        XCTAssertEqual(manager.leafID(forAgent: recorded), leaf)
        XCTAssertEqual(manager.facts[leaf]?.rejoining, .rejoined)
        XCTAssertNil(manager.rejoinNotice(leaf))
    }

    // MARK: - What the notice may offer ([[RFC-0006]] C-RESUME-RESTORE)

    /// A local pane that named a session, snapshotted with a plan and
    /// brought back. The restore is the only writer of an offer.
    private func restoredWithAnOffer() -> (WorkspaceManager, UUID) {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let leaf = manager.workspaces[0].panes[0].id
        manager.recordLeafCandidates(leaf, settled: "builder-9f", candidate: nil)
        let plan = ResumePlan(
            tool: "claude", cwd: "/srv", host: nil,
            resumeRef: "cafe1234", incantation: "claude --resume cafe1234")
        let snap = manager.snapshot(planFor: { $0 == leaf ? plan : nil })

        let restored = WorkspaceManager()
        _ = restored.restore(from: snap, hostStore: store)
        return (restored, restored.workspaces[0].panes[0].id)
    }

    /// A REGISTRATION ON THIS LEAF IS A LIVE CHILD IN IT, and takes the
    /// offer whichever branch it lands on.
    ///
    /// Before this, one `agent_registered` did both halves of the hazard:
    /// `leafID(forAgent:)` raised "the session that was running here is
    /// gone" on the candidate branch, and the caller then composed a plan
    /// from that same registration's `resume_ref` — so the pane offered to
    /// resume the session that was running in it right then.
    func testARegistrationTakesTheOffer() {
        let (manager, leaf) = restoredWithAnOffer()
        XCTAssertNotNil(manager.rejoinOffer(leaf), "nothing to lose")
        guard let name = manager.facts[leaf]?.agent else { return XCTFail("no name") }

        XCTAssertEqual(manager.leafID(forAgent: name), leaf)
        XCTAssertNil(manager.rejoinOffer(leaf),
                     "it offered to resume into the agent that just registered")
    }

    /// AND ON THE OTHER BRANCH TOO — the one that raises the notice.
    func testARestartReportedByARegistrationOffersNothing() {
        let (manager, leaf) = restoredWithAnOffer()
        manager.recordLeafCandidates(leaf, settled: manager.facts[leaf]?.agent,
                                     candidate: "builder-new")

        XCTAssertEqual(manager.leafID(forAgent: "builder-new"), leaf)
        XCTAssertNil(manager.rejoinOffer(leaf))
    }

    /// AN OFFER IS NOT READABLE WITHOUT ITS NOTICE, so a button cannot
    /// outlive the thing that justified it.
    func testDismissingTheNoticeTakesTheOffer() {
        let (manager, leaf) = restoredWithAnOffer()
        manager.dismissRejoinNotice(leaf)

        XCTAssertNil(manager.rejoinOffer(leaf))
        XCTAssertNil(manager.facts[leaf]?.rejoinOffer, "the value outlived the notice")
    }

    /// THE OFFER SURVIVES A RELAUNCH, WHICH IS THE ONLY TIME IT IS FOR.
    /// The plan rode the snapshot from the beginning and nothing read it
    /// back: the button was drawn from an in-memory table written only by
    /// a live registration, and every restored leaf gets a fresh id — so
    /// the one notice that had earned an offer never carried one.
    func testAnOfferRecordedBeforeTheRestartIsThereAfterIt() throws {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let leaf = manager.workspaces[0].panes[0].id
        manager.recordLeafCandidates(leaf, settled: "builder-9f", candidate: nil)
        let plan = ResumePlan(
            tool: "claude", cwd: "/srv", host: nil,
            resumeRef: "cafe1234", incantation: "claude --resume cafe1234")

        let snap = manager.snapshot(planFor: { $0 == leaf ? plan : nil })
        let restored = WorkspaceManager()
        _ = restored.restore(from: snap, hostStore: store)

        guard let newLeaf = restored.workspaces.first?.panes.first?.id else {
            return XCTFail("nothing restored")
        }
        XCTAssertNotEqual(newLeaf, leaf, "a restored leaf keeps its old id")
        XCTAssertEqual(restored.rejoinNotice(newLeaf), .restarted(.sessionGone))
        XCTAssertEqual(restored.rejoinOffer(newLeaf)?.incantation,
                       "claude --resume cafe1234")
    }

    /// A REMOTE PANE CARRIES NO OFFER OUT OF A RESTORE, because it has
    /// made no claim yet — its answer is on the far side. And by the time
    /// the registration brings that answer, the registration is itself a
    /// live child in the pane, so the offer never becomes due.
    func testARestoredRemotePaneCarriesNoOfferBecauseItHasNotSpoken() {
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let connection = manager.connections.acquire(host: store.hosts[0]).id
        let pane = SplitNode.Pane(label: "build", content: .terminal(command: "x"),
                                  workingDirectory: "/srv", connectionID: connection)
        manager.workspaces[0].setLayout(.slot(SplitNode.Slot(pane: pane)))
        manager.syncReferencesForTest()
        manager.recordLeafCandidates(pane.id, settled: "builder-9f", candidate: nil)
        let plan = ResumePlan(
            tool: "claude", cwd: "/srv", host: "builder",
            resumeRef: "cafe1234", incantation: "claude --resume cafe1234")
        let snap = manager.snapshot(planFor: { _ in plan })

        let restored = WorkspaceManager()
        _ = restored.restore(from: snap, hostStore: store)
        guard let leaf = restored.workspaces.first?.panes.first?.id else {
            return XCTFail("nothing restored")
        }
        XCTAssertNil(restored.rejoinNotice(leaf), "it claimed an outcome it cannot know")
        XCTAssertNil(restored.facts[leaf]?.rejoinOffer)
    }

    /// A HOST THE HUMAN TURNED DURABILITY OFF FOR needs no round trip, and
    /// says which setting caused it.
    func testAnOptedOutHostIsReportedAtOnceAndByName() {
        let (manager, leaf) = reopened(durableHost: false)
        XCTAssertEqual(manager.rejoinNotice(leaf), .restarted(.durabilityOff(machine: "builder")))
    }

    func testTheNoticeIsNotRepeatedOnceRead() {
        let (manager, leaf) = reopened(durableHost: false)
        manager.dismissRejoinNotice(leaf)
        XCTAssertNil(manager.rejoinNotice(leaf))
    }



    // MARK: - A question is not a registration ([[WI-2026-08-29-001]])

    /// `facts` is observable. A body that mutates it invalidates every
    /// view that read it — including the body doing the mutating — so the
    /// workbench spins in a view update that cannot settle. The sidebar's
    /// list of agents elsewhere called the registration funnel, which
    /// records a rejoin decision on the way past, and a fresh install on a
    /// second Mac (where that list is not empty) beachballed at launch.
    ///
    /// A DICTIONARY WRITE CANNOT BE ELIDED THE WAY A SCALAR CAN: `facts`
    /// is reached through `_modify`, so Observation has no old value to
    /// compare and fires whether or not anything changed. That is why
    /// `facts[x]?.rejoinOffer = nil`, a no-op after the first call, was
    /// enough to keep the loop turning.
    func testAskingWhichLeafShowsAnAgentMutatesNothing() {
        let (manager, leaf) = reopened()
        let recorded = manager.facts[leaf]?.agent ?? "builder-9f"

        var changed = false
        withObservationTracking {
            _ = manager.facts
        } onChange: {
            changed = true
        }

        _ = manager.leafShowing(agent: recorded)
        let afterAsking = changed

        // THE RIG CAN SEE A WRITE AT ALL. Without this the assertion above
        // passes for a tracking scope that observes nothing, which is how
        // a purity test becomes decoration.
        manager.recordLeafAgent(leaf, "someone-else")
        XCTAssertTrue(changed, "the tracking scope never saw a write, so it proves nothing")

        XCTAssertFalse(afterAsking,
                       "asking which leaf shows an agent wrote to `facts`, so a view body "
                       + "that asks invalidates itself and the update never settles")
    }

    /// AND THE FUNNEL STILL RECORDS. The write is deliberate and
    /// load-bearing where a REGISTRATION passes through; what changed is
    /// that a question is no longer a registration.
    func testTheRegistrationFunnelStillSettlesTheRejoin() {
        let (manager, leaf) = reopened()
        guard let recorded = manager.facts[leaf]?.agent else { return XCTFail("no name") }

        XCTAssertEqual(manager.leafID(forAgent: recorded), leaf)
        XCTAssertEqual(manager.facts[leaf]?.rejoining, .rejoined,
                       "the funnel stopped recording that the session came back")
    }

    /// Both answer the same question.
    func testTheQueryAndTheFunnelAgree() {
        let (manager, leaf) = reopened()
        guard let recorded = manager.facts[leaf]?.agent else { return XCTFail("no name") }
        XCTAssertEqual(manager.leafShowing(agent: recorded), leaf)
        XCTAssertEqual(manager.leafShowing(agent: recorded), manager.leafID(forAgent: recorded))
    }

}

/// THE STRIP MUST NOT SIT ON THE FIRST ROW ([[WI-2026-08-17-027]]).
///
/// Floated over the grid it covered the shell's prompt exactly: the pane
/// photographed as BLANK and the prompt was underneath. Every unit test
/// was green — this is the geometry those tests could not see, pulled out
/// as a value so they can.
final class RejoinNoticeGeometryTests: XCTestCase {

    private let pane = CGRect(x: 100, y: 40, width: 800, height: 600)

    func testThePaneKeepsItsWholeRectWhenNothingIsSaid() {
        XCTAssertEqual(RejoinNoticeView.paneRect(pane, showing: false), pane)
    }

    func testThePaneStartsBELOWTheStripAndLosesExactlyItsHeight() {
        let inset = RejoinNoticeView.paneRect(pane, showing: true)
        XCTAssertEqual(inset.minY, pane.minY + RejoinNoticeView.height,
                       "the terminal still starts where the strip does — it is covered")
        XCTAssertEqual(inset.height, pane.height - RejoinNoticeView.height)
        XCTAssertEqual(inset.minX, pane.minX)
        XCTAssertEqual(inset.width, pane.width, "the strip takes height, not width")
    }

    /// A pane shorter than the strip must not be handed a negative height.
    func testATinyPaneDoesNotGetANegativeHeight() {
        let sliver = CGRect(x: 0, y: 0, width: 300, height: RejoinNoticeView.height / 2)
        XCTAssertEqual(RejoinNoticeView.paneRect(sliver, showing: true).height, 0)
    }
}
