import XCTest
@testable import Synapty

/// [[WI-2026-08-15-012]] / [[RFC-0013]] C-AUTHORIZATION.
///
/// FOUR PROPERTIES THAT STAND OR FALL TOGETHER. Relaying through the
/// workbench does not avoid creating the ability to move data between two
/// hosts — it plainly creates it. What makes the broker better than a key in
/// authorized_keys is that the ability is scoped, human-granted, recorded
/// and mortal, and losing any one of them collapses the argument back to
/// "we built a worse SSH". Each of these failing is silent: the transfer
/// works, and something nobody agreed to has happened.
@MainActor
final class TransferAuthorityTests: XCTestCase {

    private var tmp: URL!
    private var hostStore: HostStore!
    private var paneManager: WorkspaceManager!
    private var transfers: TransferService!
    private var authority: TransferAuthority!
    private var artifacts: ArtifactService!
    private var questions: QuestionService!
    private var builder: HostEntry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
        hostStore = HostStore()
        paneManager = WorkspaceManager()
        transfers = TransferService()
        transfers.hostStore = hostStore
        authority = TransferAuthority()
        authority.transfers = transfers
        artifacts = ArtifactService()
        artifacts.transfers = transfers
        questions = QuestionService()
        builder = HostEntry(label: "builder", address: "builder.example", username: "someone")
        hostStore.hosts.append(builder)
    }

    override func tearDown() {
        // Let any filler still parked in its probe go, so no detached task
        // outlives the test that made it.
        for _ in 0..<4 { fillerGate.signal() }
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    /// What the slot fillers wait on. HELD, NOT RACED: the fillers used to
    /// be copies of files that do not exist, which fail in milliseconds and
    /// free the slots — on a GitHub runner they were gone before the
    /// transfer under test was even enqueued, and the pump started it
    /// against a host with no connection ([[WI-2026-09-02-038]]).
    private let fillerGate = DispatchSemaphore(value: 0)

    private func server() -> FileToolServer {
        FileToolServer(transfers: transfers, hostStore: hostStore,
                       paneManager: paneManager, authority: authority,
                       artifacts: artifacts, questions: questions)
    }

    @discardableResult
    private func agentInPane(_ id: String, on host: HostEntry? = nil) -> String {
        let connectionID = host.map { paneManager.connections.acquire(host: $0).id }
            ?? paneManager.connections.localID
        let session = WorkspaceManager.Workspace(
            label: host?.label ?? "Local", initialCommand: "/bin/zsh",
            connectionID: connectionID)
        paneManager.workspaces.append(session)
        if let leaf = session.panes.first {
            paneManager.recordLeafAgent(leaf.id, id)
        }
        return id
    }

    // MARK: - Human-granted

    /// AN AGENT MAY NOT AUTHORISE ITSELF. Without a human's answer the
    /// transfer does not happen — it is refused and the question is raised,
    /// rather than performed and later undone.
    func testAnAgentTransferWaitsForAHumanAndQueuesNothing() async {
        let agent = agentInPane("api-7f3c")

        let outcome = await server().serve(
            tool: "file.put", args: ["path": "/tmp/out.tar", "host": "builder"], requester: agent)

        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.error?.contains("approval") ?? false, "the refusal says what it waits on")
        XCTAssertEqual(transfers.transfers.count, 0, "and nothing moves in the meantime")
        XCTAssertEqual(authority.pending.count, 1, "while the human has something to answer")
        XCTAssertEqual(authority.pending.first?.agent, "api-7f3c")
    }

    /// Once answered, the same call goes through — and the answer covers the
    /// PAIR, not the one file, because a human approving "this machine may
    /// send to builder" is answering about a route.
    func testOnceGrantedTheSameAgentTransferProceeds() async {
        let agent = agentInPane("api-7f3c")
        _ = await server().serve(tool: "file.put",
                           args: ["path": "/tmp/out.tar", "host": "builder"], requester: agent)
        authority.grant(.init(from: nil, to: builder.id))

        let outcome = await server().serve(
            tool: "file.put", args: ["path": "/tmp/other.tar", "host": "builder"], requester: agent)

        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        XCTAssertEqual(transfers.transfers.count, 1)
        XCTAssertTrue(authority.pending.isEmpty, "granting clears what was waiting on it")
    }

    /// A HUMAN'S OWN DRAG IS ALREADY AN EXPLICIT ACT. Asking again would
    /// train them to click through the question, which is worse than not
    /// asking at all.
    func testAHumansDragIsNotAskedAboutTwice() {
        let pair = TransferAuthority.Pair(from: nil, to: builder.id)
        XCTAssertEqual(authority.requirement(initiator: .human, pair: pair), .go)
        XCTAssertEqual(authority.requirement(initiator: .agent("api-7f3c"), pair: pair), .ask)
    }

    /// A DIRECTION, NOT A RELATIONSHIP. Approving A→B says nothing about
    /// B→A; the human answered one question.
    func testApprovalDoesNotRunBothWays() {
        authority.grant(.init(from: nil, to: builder.id))
        XCTAssertTrue(authority.isGranted(.init(from: nil, to: builder.id)))
        XCTAssertFalse(authority.isGranted(.init(from: builder.id, to: nil)),
                       "the reverse route was never agreed to")
    }

    /// An agent retrying must not stack questions a human then dismisses one
    /// at a time — which is how a queue of prompts becomes a thing to clear
    /// rather than a thing to read.
    func testARetryingAgentDoesNotStackQuestions() async {
        let agent = agentInPane("api-7f3c")
        for _ in 0..<5 {
            _ = await server().serve(tool: "file.put",
                               args: ["path": "/tmp/out.tar", "host": "builder"], requester: agent)
        }
        XCTAssertEqual(authority.pending.count, 1)
    }

    // MARK: - Mortal

    /// THE CAPABILITY DOES NOT SURVIVE THE PROCESS.
    ///
    /// This is the property with no equivalent in a credential sitting on a
    /// server, and the one that would be quietly lost by making it
    /// convenient. A grant written anywhere — this application's own config,
    /// encrypted, whatever — would outlive the process the human's judgement
    /// was attached to, and the argument for preferring a broker to a direct
    /// trust would go with it.
    func testGrantsDoNotSurviveTheProcess() {
        authority.grant(.init(from: nil, to: builder.id))
        XCTAssertTrue(authority.isGranted(.init(from: nil, to: builder.id)))

        // A fresh authority is what the next launch gets.
        let next = TransferAuthority()
        XCTAssertFalse(next.isGranted(.init(from: nil, to: builder.id)))
        XCTAssertTrue(next.grants.isEmpty)
    }

    /// REVOCATION IS IMMEDIATE, which is the point of holding this in memory
    /// rather than on a host: withdrawing a key means reaching every machine
    /// that has it, and this means changing one set.
    func testRevocationTakesEffectAtOnce() async {
        let agent = agentInPane("api-7f3c")
        authority.grant(.init(from: nil, to: builder.id))
        authority.revoke(.init(from: nil, to: builder.id))

        let outcome = await server().serve(
            tool: "file.put", args: ["path": "/tmp/out.tar", "host": "builder"], requester: agent)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(transfers.transfers.count, 0)
    }

    /// AND IT REACHES WORK THE GRANT ALREADY ADMITTED. The grant is
    /// consulted once, at request admission, and never again — so a
    /// withdrawal did not touch a transfer the agent had asked for a
    /// second earlier and which was still waiting its turn to start.
    /// [[RFC-0007]] C-EXEC-AUTHORITY holds the workbench to the same
    /// standard for the other standing grant it takes: "a run whose Enter
    /// has not yet been sent is aborted".
    ///
    /// The two local copies are there to occupy the concurrency slots, so
    /// the agent's transfer is still stoppable when the human changes
    /// their mind — which is the only state in which a withdrawal has
    /// anything to reach.
    private func fillTheRunningSlots() {
        // A human transfer probes its destination first, off the main
        // actor; a probe that does not return keeps the slot occupied for
        // exactly as long as the test needs it to.
        let gate = fillerGate
        transfers.probe = { _ in gate.wait(); return .absent }
        for i in 0..<2 {
            _ = transfers.enqueue(from: FileEndpoint(hostID: nil, path: "/tmp/synapty-test-src\(i)"),
                                  to: FileEndpoint(hostID: nil, path: "/tmp"))
        }
    }

    func testWithdrawingCancelsWhatTheGrantAlreadyLetThrough() async {
        let agent = agentInPane("api-7f3c")
        fillTheRunningSlots()
        authority.grant(.init(from: nil, to: builder.id))
        let outcome = await server().serve(
            tool: "file.put", args: ["path": "/tmp/out.tar", "host": "builder"], requester: agent)
        XCTAssertTrue(outcome.ok)
        let admitted = transfers.transfers.first { $0.destination.hostID == builder.id }
        XCTAssertEqual(admitted?.state, .queued, "it never waited, so nothing here is observable")

        authority.revoke(.init(from: nil, to: builder.id))

        XCTAssertEqual(transfers.transfers.first { $0.destination.hostID == builder.id }?.state,
                       .cancelled,
                       "a withdrawal left the transfer it had just admitted to start on its own")
    }

    /// AND ONLY ALONG THE ROUTE WITHDRAWN. A grant is a direction, not a
    /// relationship, and taking one back must not reach another route's
    /// work or the human's own drags, which needed no permission at all.
    func testWithdrawingLeavesOtherRoutesAndTheHumansOwnWorkAlone() async {
        let deskmac = HostEntry(label: "deskmac", address: "deskmac.example", username: "someone")
        hostStore.hosts.append(deskmac)
        let agent = agentInPane("api-7f3c")
        fillTheRunningSlots()
        authority.grant(.init(from: nil, to: builder.id))
        authority.grant(.init(from: nil, to: deskmac.id))
        _ = await server().serve(tool: "file.put",
                           args: ["path": "/tmp/out.tar", "host": "builder"], requester: agent)
        _ = await server().serve(tool: "file.put",
                           args: ["path": "/tmp/out.tar", "host": "deskmac"], requester: agent)
        let mine = transfers.enqueue(
            from: FileEndpoint(hostID: nil, path: "/tmp/mine.tar"),
            to: FileEndpoint(hostID: builder.id, path: "/tmp/mine.tar"),
            initiator: .human)

        authority.revoke(.init(from: nil, to: builder.id))

        XCTAssertEqual(transfers.transfers.first { $0.destination.hostID == deskmac.id }?.state,
                       .queued, "another route's work was cancelled")
        XCTAssertEqual(transfers.transfers.first { $0.id == mine }?.state, .queued,
                       "the human's own drag needed no permission and lost it anyway")
    }

    /// What has been agreed to must be enumerable. A capability nobody can
    /// list is one nobody can withdraw.
    func testWhatHasBeenAgreedToCanBeListed() {
        authority.grant(.init(from: nil, to: builder.id))
        XCTAssertEqual(authority.grants.count, 1)
        XCTAssertEqual(authority.grants.first?.to, builder.id)
    }

    // MARK: - Scoped

    /// AN AGENT DOES NOT CHOOSE WHERE ITS DELIVERY LANDS.
    ///
    /// `--into` was honoured for agents when the file verbs shipped, which
    /// handed any agent the ability to write anywhere its account could
    /// reach on the far machine — a shell profile, an authorized_keys —
    /// under an approval a human gave for "deliver a file". The flag now
    /// belongs to a human's drag and nothing else.
    func testAnAgentCannotChooseTheDestinationDirectory() async {
        let agent = agentInPane("api-7f3c")
        authority.grant(.init(from: nil, to: builder.id))

        let outcome = await server().serve(
            tool: "file.put",
            args: ["path": "/tmp/out.tar", "host": "builder", "into": "/home/someone/.ssh"],
            requester: agent)

        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        XCTAssertEqual(transfers.transfers.first?.destination.path, AgentInbox.path,
                       "the path an agent asked for must not be the path it gets")
    }

    // MARK: - Addressed by agent

    /// THE CALLER NAMES WHAT, NOT WHERE. Which machine the recipient is on,
    /// and where deliveries land there, are facts that change under
    /// re-homing while the agent's identity does not.
    func testATransferAddressedToAnAgentNeedsNoHostAndNoPath() async {
        let sender = agentInPane("api-7f3c")
        agentInPane("web-2a1b", on: builder)
        authority.grant(.init(from: nil, to: builder.id))

        let outcome = await server().serve(
            tool: "file.put",
            args: ["path": "/tmp/out.tar", "host": "agent:web-2a1b"],
            requester: sender)

        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        XCTAssertEqual(transfers.transfers.first?.destination.hostID, builder.id)
        XCTAssertEqual(transfers.transfers.first?.destination.path, AgentInbox.path)
    }

    /// An agent nobody can place is refused by name rather than guessed at.
    func testAnUnknownRecipientIsRefusedByName() async {
        let sender = agentInPane("api-7f3c")
        let outcome = await server().serve(
            tool: "file.put", args: ["path": "/tmp/out.tar", "host": "agent:nobody"],
            requester: sender)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.error?.contains("nobody") ?? false)
    }

    /// FETCHING FROM AN AGENT IS A DIFFERENT CAPABILITY — reaching into
    /// another agent's machine on its behalf — and nobody has agreed to it.
    func testAnAgentCannotFetchFromAnotherAgent() async {
        let sender = agentInPane("api-7f3c")
        agentInPane("web-2a1b", on: builder)
        authority.grant(.init(from: builder.id, to: nil))

        let outcome = await server().serve(
            tool: "file.fetch", args: ["path": "/tmp/secret", "host": "agent:web-2a1b"],
            requester: sender)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(transfers.transfers.count, 0)
    }

    /// Two agents on the same machine have nothing to move between them.
    func testAnAgentAddressingOneOnItsOwnMachineIsRefused() async {
        let sender = agentInPane("api-7f3c")
        agentInPane("sibling-1")
        let outcome = await server().serve(
            tool: "file.put", args: ["path": "/tmp/out.tar", "host": "agent:sibling-1"],
            requester: sender)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(transfers.transfers.count, 0)
    }

    // MARK: - present

    /// HANDING SOMETHING OVER IS NOT WRITING SOMEWHERE. `present` moves a
    /// file TO the human's own machine, into a directory this application
    /// owns, so it is not gated on the authority that protects an agent
    /// writing where a human did not choose. The asymmetry is deliberate
    /// and it is the direction that decides.
    func testPresentNeedsNoApprovalBecauseItOnlyDeliversHere() async {
        let agent = agentInPane("api-7f3c", on: builder)
        let outcome = await server().serveView(
            tool: "view.present",
            args: ["path": "/tmp/report.pdf", "title": "Build report"],
            requester: agent, forwards: PortForwardService())

        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        XCTAssertEqual(artifacts.artifacts.count, 1)
        XCTAssertEqual(artifacts.artifacts.first?.agent, "api-7f3c")
        XCTAssertEqual(artifacts.artifacts.first?.title, "Build report")
    }

    /// THE NAME AN AGENT SENDS DOES NOT DECIDE A PATH HERE. Two agents
    /// presenting `report.pdf` must not overwrite each other, and a name an
    /// agent controls must not steer where the file lands on this Mac.
    func testTwoArtifactsWithTheSameNameDoNotCollide() async {
        let a = agentInPane("api-7f3c", on: builder)
        let b = agentInPane("web-2a1b", on: builder)
        let forwards = PortForwardService()

        _ = await server().serveView(tool: "view.present", args: ["path": "/tmp/report.pdf"],
                               requester: a, forwards: forwards)
        _ = await server().serveView(tool: "view.present", args: ["path": "/other/report.pdf"],
                               requester: b, forwards: forwards)

        XCTAssertEqual(artifacts.artifacts.count, 2)
        let paths = Set(artifacts.artifacts.map(\.localPath))
        XCTAssertEqual(paths.count, 2, "same file name, different destinations")
        XCTAssertTrue(artifacts.artifacts.allSatisfy { $0.fileName == "report.pdf" })
    }

    /// Dismissing takes the staged copy with it, so this application does
    /// not become a place files quietly accumulate.
    func testDismissingAnArtifactRemovesWhatWasStaged() async throws {
        let agent = agentInPane("api-7f3c", on: builder)
        _ = await server().serveView(tool: "view.present", args: ["path": "/tmp/report.pdf"],
                               requester: agent, forwards: PortForwardService())
        let artifact = try XCTUnwrap(artifacts.artifacts.first)
        let container = URL(fileURLWithPath: artifact.localPath).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.path))

        artifacts.dismiss(artifact.id)
        XCTAssertTrue(artifacts.artifacts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
    }

    // MARK: - ask

    /// A QUESTION BLOCKS AN AGENT, so the answer must be collectable
    /// exactly once and must not be lost in the gap between being given and
    /// being fetched.
    func testAnAnswerSurvivesUntilTheAgentCollectsIt() async throws {
        let agent = agentInPane("api-7f3c")
        let forwards = PortForwardService()

        let posted = await server().serveView(
            tool: "view.ask",
            args: ["question": "Deploy to production?", "options": ["yes", "no"]],
            requester: agent, forwards: forwards)
        XCTAssertTrue(posted.ok, posted.error ?? "")
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(posted.data?["question_id"] as? String)))

        // Polling before an answer is not an error: an agent must be able to
        // tell "not yet" from "something broke".
        let waiting = await server().serveView(
            tool: "view.answer", args: ["question_id": id.uuidString],
            requester: agent, forwards: forwards)
        XCTAssertTrue(waiting.ok)
        XCTAssertEqual(waiting.data?["state"] as? String, "waiting")

        questions.answer(id, with: "yes")
        let collected = await server().serveView(
            tool: "view.answer", args: ["question_id": id.uuidString],
            requester: agent, forwards: forwards)
        XCTAssertEqual(collected.data?["answer"] as? String, "yes")
        XCTAssertTrue(questions.questions.isEmpty, "collected, and not left to be answered twice")
    }

    /// ONLY WHAT THE AGENT OFFERED. It will act on the answer, so a value
    /// it has no branch for is worse than no answer at all.
    func testAnAnswerOutsideTheOfferedSetIsRefused() {
        let id = questions.ask(agent: "api-7f3c", text: "Deploy?", options: ["yes", "no"])
        questions.answer(id, with: "maybe")
        XCTAssertNil(questions.answer(to: id), "a value nobody offered is not an answer")

        questions.answer(id, with: "no")
        XCTAssertEqual(questions.answer(to: id), "no")
    }

    /// An agent polling or restarting must not turn one decision into a
    /// list a human clears rather than reads.
    func testARepeatedQuestionIsTheSameQuestion() {
        let first = questions.ask(agent: "api-7f3c", text: "Deploy?", options: ["yes"])
        let second = questions.ask(agent: "api-7f3c", text: "Deploy?", options: ["yes"])
        XCTAssertEqual(first, second)
        XCTAssertEqual(questions.unanswered.count, 1)
    }

    // MARK: - The limit is the operator's

    /// THE LIMIT IS A SETTING, NOT A CONSTANT. The clause requires it be
    /// stated rather than discovered; it does not require it be fixed, and
    /// the right number depends on a link and a fleet this code knows
    /// nothing about.
    func testTheAgentLimitFollowsTheSetting() throws {
        let settingsTmp = try setUpSettingsStorage()
        defer { SynaptySettings.storageOverride = nil; try? FileManager.default.removeItem(at: settingsTmp) }
        let previous = SynaptySettings.shared.agentTransferLimitMB
        defer { SynaptySettings.shared.agentTransferLimitMB = previous }

        SynaptySettings.shared.agentTransferLimitMB = 1
        XCTAssertEqual(FileToolServer.maxBytes, 1 * 1024 * 1024)
        SynaptySettings.shared.agentTransferLimitMB = 512
        XCTAssertEqual(FileToolServer.maxBytes, 512 * 1024 * 1024)
    }

    /// AND A HUMAN'S DRAG IS NOT BOUND BY IT. The limit exists because an
    /// agent asks unattended; a human who dragged the file is present and
    /// has already decided.
    func testAHumansDragIsNotSubjectToTheAgentLimit() throws {
        let settingsTmp = try setUpSettingsStorage()
        defer { SynaptySettings.storageOverride = nil; try? FileManager.default.removeItem(at: settingsTmp) }
        let previous = SynaptySettings.shared.agentTransferLimitMB
        defer { SynaptySettings.shared.agentTransferLimitMB = previous }
        SynaptySettings.shared.agentTransferLimitMB = 1

        let big = tmp.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 8 * 1024 * 1024)
        try handle.close()

        // The human's path does not go through the tool server at all — it
        // enqueues directly, which is the structural reason the limit
        // cannot reach it.
        transfers.enqueue(from: FileEndpoint(hostID: nil, path: big.path),
                          to: FileEndpoint(hostID: builder.id, path: "/tmp"))
        XCTAssertEqual(transfers.transfers.count, 1)
    }
    /// A QUESTION WITH NO OPTIONS CAN NEVER LEAVE THE QUEUE.
    ///
    /// The card renders one button per option and offers nothing else — no
    /// dismiss, because the badge is a queue of DECISIONS and a decision is
    /// made by choosing. An empty set used to be accepted end to end: the
    /// human got a card they could neither answer nor clear, the agent
    /// blocked to its own timeout, and the badge stayed lit for the life of
    /// the process. Refused where it enters.
    func testAQuestionWithNoOptionsIsRefusedRatherThanQueued() async throws {
        let agent = agentInPane("api-7f3c")
        let forwards = PortForwardService()

        let posted = await server().serveView(
            tool: "view.ask",
            args: ["question": "Ready to deploy?", "options": [String]()],
            requester: agent, forwards: forwards)

        XCTAssertFalse(posted.ok, "an unanswerable question was accepted")
        XCTAssertEqual(questions.unanswered.count, 0,
                       "a card nobody can answer or clear reached the queue")
    }

    /// The same when the field is absent rather than empty — an agent that
    /// simply forgot it is the likelier caller.
    func testAQuestionWithNoOptionsFieldIsRefusedToo() async throws {
        let agent = agentInPane("api-7f3c")
        let posted = await server().serveView(
            tool: "view.ask", args: ["question": "Ready to deploy?"],
            requester: agent, forwards: PortForwardService())
        XCTAssertFalse(posted.ok)
        XCTAssertEqual(questions.unanswered.count, 0)
    }

    // MARK: - No is an answer ([[WI-2026-08-28-004]])

    /// DENY MEANS NO, AND THE NEXT REQUEST HEARS IT.
    ///
    /// Deny used to remove the card and record nothing, so the agent's
    /// next `file.put` along the route re-created the question — and the
    /// skill reference tells agents to retry, calling `awaiting approval`
    /// "not a permanent failure". A human pressing Deny got the same
    /// question back for as long as the agent kept trying, and the only
    /// escape was quitting.
    func testDenyingARouteRefusesTheNextRequestInsteadOfAskingAgain() async throws {
        let agent = agentInPane("api-7f3c")
        let put: () async -> FileToolServer.Outcome = { [self] in
            await server().serve(tool: "file.put",
                                 args: ["path": "/tmp/out.tar", "host": "builder"],
                                 requester: agent)
        }

        let first = await put()
        XCTAssertEqual(first.data?["state"] as? String, "awaiting_approval")
        let question = try XCTUnwrap(authority.pending.first)

        authority.deny(question.id)

        let second = await put()
        XCTAssertFalse(second.ok)
        XCTAssertNil(second.data?["state"], "a refusal was reported as still awaiting a human")
        XCTAssertTrue(second.error?.contains("refused") == true, second.error ?? "")
        XCTAssertTrue(authority.pending.isEmpty,
                      "the question a human already answered was asked again")
    }

    /// A NO A HUMAN CANNOT SEE IS A NO THEY CANNOT TAKE BACK, which is the
    /// argument C-AUTHORIZATION already makes about grants.
    func testARefusalIsListedAndCanBeUndone() {
        let pair = TransferAuthority.Pair(from: nil, to: builder.id)
        authority.requestApproval(pair: pair, agent: "api-7f3c", fileName: "out.tar")
        authority.deny(authority.pending[0].id)

        XCTAssertEqual(authority.refusals, [pair])
        XCTAssertEqual(authority.requirement(initiator: .agent("api-7f3c"), pair: pair), .refuse)

        authority.allowAsking(pair)
        XCTAssertTrue(authority.refusals.isEmpty)
        XCTAssertEqual(authority.requirement(initiator: .agent("api-7f3c"), pair: pair), .ask,
                       "undoing a refusal must let them ask, and must not itself allow the route")
    }

    /// A YES ENDS AN EARLIER NO: a route cannot be both.
    func testGrantingAfterARefusalClearsIt() {
        let pair = TransferAuthority.Pair(from: nil, to: builder.id)
        authority.requestApproval(pair: pair, agent: "api-7f3c", fileName: "out.tar")
        authority.deny(authority.pending[0].id)
        authority.grant(pair)

        XCTAssertTrue(authority.refusals.isEmpty)
        XCTAssertEqual(authority.requirement(initiator: .agent("api-7f3c"), pair: pair), .go)
    }

}
