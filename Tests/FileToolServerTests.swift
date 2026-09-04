import XCTest
@testable import Synapty

/// [[WI-2026-08-15-010]] / [[RFC-0013]]. Stage two's whole claim is that an
/// agent's call and a human's drag enter the SAME service. These pin that,
/// and the refusals that make agent-initiated work acceptable — each of
/// which, wrong, looks like a transfer that simply did not happen.
@MainActor
final class FileToolServerTests: XCTestCase {

    private var tmp: URL!
    private var hostStore: HostStore!
    private var paneManager: WorkspaceManager!
    private var transfers: TransferService!
    private var authority: TransferAuthority!
    private var artifacts: ArtifactService!
    private var questions: QuestionService!
    private var remote: HostEntry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
        hostStore = HostStore()
        paneManager = WorkspaceManager()
        transfers = TransferService()
        transfers.hostStore = hostStore
        authority = TransferAuthority()
        artifacts = ArtifactService()
        artifacts.transfers = transfers
        questions = QuestionService()
        remote = HostEntry(label: "builder", address: "builder.example", username: "someone")
        hostStore.hosts.append(remote)
    }

    override func tearDown() {
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    private func server() -> FileToolServer {
        FileToolServer(transfers: transfers, hostStore: hostStore,
                       paneManager: paneManager, authority: authority,
                       artifacts: artifacts, questions: questions)
    }

    /// An agent in a pane, the way a spawn site leaves one.
    ///
    /// Built directly rather than through `addLocalWorkspace`, which resolves
    /// its command through `TunnelManager.shared` — absent here, so it would
    /// produce a session with no pane and no leaf to bind to.
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

    // MARK: - One service, two callers

    /// THE AGENT'S CALL ENTERS THE SAME QUEUE AS THE HUMAN'S DRAG. If this
    /// ever needs transfer logic of its own, stage one put the service in
    /// the wrong place and that is the finding.
    func testAnAgentsPutEntersTheSameTransferQueue() async {
        let agent = agentInPane("api-7f3c")
        authority.grant(.init(from: nil, to: remote.id))
        let before = transfers.transfers.count

        let outcome = await server().serve(
            tool: "file.put",
            args: ["path": "/tmp/out.tar", "host": "builder"],
            requester: agent)

        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        XCTAssertEqual(transfers.transfers.count, before + 1)
        XCTAssertEqual(transfers.transfers.last?.initiator, .agent("api-7f3c"),
                       "an unattributed transfer is one nobody can act on")
    }

    /// WAITING ON A HUMAN CARRIES A MARKER, NOT JUST A SENTENCE.
    ///
    /// The CLI turns this into its own exit code — retry once they answer,
    /// rather than the exit code for "no such host", where retrying is a
    /// loop. Keying that off the message would mean rewording a sentence
    /// silently changed what every agent does next, so the caller reads
    /// `state` and the words stay free to change.
    func testATransferAwaitingAHumanIsMarkedAsRetryable() async {
        let agent = agentInPane("api-7f3c")
        // Deliberately NOT granted: this is the first time down this route.
        let outcome = await server().serve(
            tool: "file.put",
            args: ["path": "/tmp/out.tar", "host": "builder"],
            requester: agent)

        XCTAssertFalse(outcome.ok, "nothing has moved yet")
        XCTAssertEqual(outcome.data?["state"] as? String, "awaiting_approval")
        XCTAssertEqual(authority.pending.count, 1, "and a human has actually been asked")
        XCTAssertTrue(outcome.error?.contains("approval") ?? false, outcome.error ?? "")
    }

    /// A REFUSAL THAT WILL NEVER SUCCEED CARRIES NO SUCH MARKER, or an
    /// agent would retry a dead route forever.
    func testARefusalThatCannotSucceedIsNotMarkedRetryable() async {
        let agent = agentInPane("api-7f3c")
        let outcome = await server().serve(
            tool: "file.put",
            args: ["path": "/tmp/out.tar", "host": "no-such-host"],
            requester: agent)

        XCTAssertFalse(outcome.ok)
        XCTAssertNil(outcome.data?["state"])
    }

    /// put and fetch are the same operation with the ends swapped, and the
    /// caller names only the OTHER end — its own machine comes from the pane
    /// it runs in.
    func testFetchIsPutWithTheEndsSwapped() async {
        let agent = agentInPane("api-7f3c")
        authority.grant(.init(from: nil, to: remote.id))
        authority.grant(.init(from: remote.id, to: nil))

        _ = await server().serve(tool: "file.put",
                           args: ["path": "/tmp/out.tar", "host": "builder"], requester: agent)
        let put = transfers.transfers.last
        XCTAssertNil(put?.source.hostID, "the agent's own pane is local here")
        XCTAssertEqual(put?.destination.hostID, remote.id)

        _ = await server().serve(tool: "file.fetch",
                           args: ["path": "/var/log/build.log", "host": "builder", "into": "/tmp"],
                           requester: agent)
        let fetch = transfers.transfers.last
        XCTAssertEqual(fetch?.source.hostID, remote.id)
        XCTAssertNil(fetch?.destination.hostID)
        XCTAssertEqual(fetch?.destination.path, AgentInbox.path,
                       "an agent does not choose where its delivery lands")
    }

    // MARK: - The refusals

    /// AN UNATTRIBUTABLE TRANSFER IS REFUSED, not performed anonymously.
    /// Every transfer is recorded with its initiator, and a caller the
    /// workbench cannot place has no initiator to record.
    func testATransferFromAnAgentInNoPaneIsRefused() async {
        let outcome = await server().serve(
            tool: "file.put", args: ["path": "/tmp/out.tar", "host": "builder"],
            requester: "some-agent-nobody-knows")

        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(transfers.transfers.count, 0, "and nothing is queued")
        XCTAssertTrue(outcome.error?.contains("attributable") ?? false,
                      "the refusal must say why, not just fail")
    }

    /// A LIMIT NAMED IN THE REFUSAL, not discovered by hitting it. This
    /// plane relays every byte across the human's machine twice, on the
    /// connection carrying their keystrokes.
    func testAnOversizedTransferIsRefusedWithTheLimitInTheMessage() async throws {
        let agent = agentInPane("api-7f3c")
        // A sparse file: the size is what is being tested, not the bytes.
        let big = tmp.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(FileToolServer.maxBytes + 1))
        try handle.close()

        authority.grant(.init(from: nil, to: remote.id))
        let outcome = await server().serve(
            tool: "file.put", args: ["path": big.path, "host": "builder"], requester: agent)

        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(transfers.transfers.count, 0)
        XCTAssertTrue(outcome.error?.contains("refused") ?? false, "a refusal must read as a refusal")
        XCTAssertTrue(outcome.error?.contains("MB") ?? false, "and must name the limit")
    }

    /// `view.present` HAD NO SIZE CHECK AT ALL, so it was the way to move
    /// a dataset onto this Mac: the authority gate does not apply to a
    /// hand-over — the file lands in a directory this application owns —
    /// and the limit lived in the file verbs only. [[RFC-0013]]
    /// C-CONTROL-PLANE binds every agent-initiated transfer, and this is
    /// one.
    func testPresentingSomethingOversizedIsRefusedWithTheLimit() async throws {
        let agent = agentInPane("api-7f3c")
        let big = tmp.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(FileToolServer.maxBytes + 1))
        try handle.close()

        let outcome = await server().serveView(
            tool: "view.present", args: ["path": big.path],
            requester: agent, forwards: PortForwardService())

        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.error?.contains("refused") ?? false,
                      "a refusal must read as a refusal, not a failure")
        XCTAssertTrue(outcome.error?.contains("MB") ?? false, "and must name the limit")
        XCTAssertEqual(transfers.transfers.count, 0, "and nothing is queued")
        XCTAssertTrue(artifacts.artifacts.isEmpty)
    }

    /// AND THE LIMIT COMES BEFORE THE HUMAN. Asking somebody to approve a
    /// transfer the workbench is going to refuse anyway spends their
    /// attention on a question with one answer.
    func testAnOversizedTransferIsRefusedWithoutAskingAnybody() async throws {
        let agent = agentInPane("api-7f3c")
        let big = tmp.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(FileToolServer.maxBytes + 1))
        try handle.close()

        // No grant: the old order would have queued a question first.
        let outcome = await server().serve(
            tool: "file.put", args: ["path": big.path, "host": "builder"], requester: agent)

        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.error?.contains("refused") ?? false)
        XCTAssertTrue(authority.pending.isEmpty,
                      "a human was asked to approve something that was going to be refused")
    }

    /// A TREE IS MEASURED AS A TREE. `attributesOfItem` on a directory
    /// reports the size of the ENTRY — 128 bytes for a tree holding fifty
    /// megabytes — so anything deciding on size has to walk it, and the
    /// probe that used to answer "is this a directory" returned false for
    /// everything not on this Mac.
    func testADirectoryIsMeasuredByWhatIsUnderIt() throws {
        let dir = tmp.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inside = dir.appendingPathComponent("a.bin")
        FileManager.default.createFile(atPath: inside.path, contents: nil)
        let handle = try FileHandle(forWritingTo: inside)
        try handle.truncate(atOffset: 4096)
        try handle.close()

        let measured = TransferRunner.measure(.local(dir.path))
        XCTAssertTrue(measured.isDirectory)
        XCTAssertEqual(measured.bytes, 4096)

        let file = TransferRunner.measure(.local(inside.path))
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.bytes, 4096)

        // A path that is not there answers "unknown" rather than zero: a
        // size of zero and a size nobody could establish are different
        // claims, and only one of them is honest here.
        let missing = TransferRunner.measure(.local(dir.path + "/nope"))
        XCTAssertNil(missing.bytes)
    }

    /// A host the workbench does not know is a refusal that says so, rather
    /// than a transfer queued against nothing.
    func testAnUnknownHostIsRefusedByName() async {
        let agent = agentInPane("api-7f3c")
        let outcome = await server().serve(
            tool: "file.put", args: ["path": "/tmp/out.tar", "host": "nowhere"], requester: agent)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.error?.contains("nowhere") ?? false)
        XCTAssertEqual(transfers.transfers.count, 0)
    }

    /// Sending a file to the machine it is already on is not work. Reporting
    /// success would claim something moved.
    func testATransferToTheMachineTheFileIsAlreadyOnIsRefused() async {
        // An agent in a pane on the SAME host it is sending to.
        agentInPane("api-7f3c", on: remote)

        let outcome = await server().serve(
            tool: "file.put", args: ["path": "/home/z/out.tar", "host": "builder"],
            requester: "api-7f3c")
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(transfers.transfers.count, 0)
    }

    /// Arguments the caller got wrong are named, not answered with a
    /// generic failure.
    func testMissingArgumentsAreNamed() async {
        let agent = agentInPane("api-7f3c")
        let noPath = await server().serve(
            tool: "file.put", args: ["host": "builder"], requester: agent)
        XCTAssertTrue(noPath.error?.contains("path") ?? false)
        let noHost = await server().serve(
            tool: "file.put", args: ["path": "/tmp/a"], requester: agent)
        XCTAssertTrue(noHost.error?.contains("other end") ?? false)
    }
}

@MainActor
extension FileToolServerTests {

    // MARK: - Reading back what you put there

    /// THE TITLE IS WHAT TELLS AN AGENT IT REACHED ITS OWN PAGE rather
    /// than some other service that took the port, so a HEAD would not
    /// answer the question this exists to answer.
    func testATitleIsFoundAndKeepsItsCase() {
        let html = Data("<html><head><TITLE>Ubuntu 24.04.4 LTS</TITLE></head></html>".utf8)
        XCTAssertEqual(ViewProbe.htmlTitle(in: html), "Ubuntu 24.04.4 LTS")
    }

    /// The page belongs to somebody else and promises nothing: no title,
    /// no head, not even HTML, and the probe still has to answer.
    func testAPageWithNoTitleIsNotAFailure() {
        XCTAssertNil(ViewProbe.htmlTitle(in: Data("{\"json\": true}".utf8)))
        XCTAssertNil(ViewProbe.htmlTitle(in: Data("<html><body>hi</body></html>".utf8)))
        XCTAssertNil(ViewProbe.htmlTitle(in: Data()))
    }

    /// A truncated tag must not be read as a title that runs to the end of
    /// the document.
    func testAnUnclosedTitleIsNoTitle() {
        XCTAssertNil(ViewProbe.htmlTitle(in: Data("<html><title>never closed".utf8)))
    }

    /// AN AGENT READS BACK ITS OWN AND NOTHING ELSE — the same rule as
    /// withdraw. Another agent's view is something IT put in front of a
    /// human, and this caller has no claim on it.
    func testAnAgentCannotReadAnotherAgentsView() async {
        let agent = agentInPane("api-7f3c")
        let forwards = PortForwardService()
        let outcome = await server().serveView(
            tool: "view.status", args: [:], requester: agent, forwards: forwards)

        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.error?.contains("not exposed") ?? false, outcome.error ?? "")
    }

    // MARK: - Identity ([[WI-2026-08-17-020]])

    func testAnAgentIsToldWhichWorkspaceItIsIn_NotOnlyWhatItIsCalled() async {
        let session = WorkspaceManager.Workspace(
            label: "builder 2", initialCommand: "/bin/zsh",
            connectionID: paneManager.connections.acquire(host: remote).id)
        paneManager.workspaces.append(session)
        let agent = "api-7f3c"
        if let leaf = session.panes.first {
            paneManager.recordLeafAgent(leaf.id, agent)
        }

        let outcome = await server().serveView(
            tool: "agent.identify", args: [:], requester: agent,
            forwards: PortForwardService())

        XCTAssertTrue(outcome.ok)
        // The label, for saying where it is.
        XCTAssertEqual(outcome.data?["workspace"] as? String, "builder 2")
        // AND the name that still means this workspace tomorrow. Without
        // it, an agent quoting "builder 2" into a task has written down
        // "whichever builder was second at the time".
        XCTAssertEqual(outcome.data?["workspace_id"] as? String, session.id.uuidString)
    }

    /// THE OLD ANSWER NAMED A DIFFERENT AGENT. `session_id` was the id the
    /// container had been DIALLED with, so every pane after the first was
    /// told somebody else's identity when it asked where it was
    /// ([[RFC-0015]] C-IDENTIFY).
    func testASecondPaneIsNotToldTheFirstPanesAgentID() async {
        let session = WorkspaceManager.Workspace(
            label: "builder", initialCommand: "/bin/zsh",
            connectionID: paneManager.connections.acquire(host: remote).id)
        paneManager.workspaces.append(session)
        let first = "builder-1d99"
        let second = "api-7f3c"
        let leaves = session.panes
        paneManager.recordLeafAgent(leaves.first?.id, first)

        // A second pane in the same workspace, with its own agent.
        paneManager.activeWorkspaceID = session.id
        paneManager.addPaneToActiveWorkspace()
        let added = paneManager.workspaces[0].panes.last
        paneManager.recordLeafAgent(added?.id, second)

        let outcome = await server().serveView(
            tool: "agent.identify", args: [:], requester: second,
            forwards: PortForwardService())

        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.data?["agent"] as? String, second,
                       "an agent is told its OWN id")
        XCTAssertEqual(outcome.data?["workspace_id"] as? String, session.id.uuidString)
        XCTAssertNil(outcome.data?["session_id"],
                     "the field that named another agent is gone, not renamed")
    }

    // MARK: - view.expose ([[WI-2026-08-19-001]])

    /// A LOCAL AGENT'S EXPOSE IS AN EXPOSE.
    ///
    /// It was refused here — "this agent is on this Mac, its port is
    /// already reachable at 127.0.0.1" — which mistook the mechanism for
    /// the primitive. [[RFC-0013]] C-PRIMITIVES defines `expose` as a
    /// forward "where one is needed": locally none is, "and the offer is
    /// the naming and the attribution rather than the reach". Refused, the
    /// human was told nothing and the services pane on the connection most
    /// humans are in could never hold anything.
    func testALocalAgentCanExposeAndTheOfferIsRecorded() async {
        let agent = agentInPane("docs-9a12")
        let forwards = PortForwardService()

        let outcome = await server().serveView(
            tool: "view.expose", args: ["port": 3000, "title": "the docs site"],
            requester: agent, forwards: forwards)

        XCTAssertTrue(outcome.ok, outcome.error ?? "a local expose was refused")
        XCTAssertEqual(forwards.exposures.count, 1)
        XCTAssertNil(forwards.exposures.first?.hostID,
                     "this Mac is a machine, not the absence of one")
        XCTAssertEqual(forwards.exposures.first?.agent, "docs-9a12",
                       "the offer IS the attribution")
        XCTAssertEqual(outcome.data?["local_port"] as? Int, 3000,
                       "no forward is opened, so the agent is told the port it is already on")
    }

    /// And the agent can take it back, which is the other half of an offer.
    func testALocalAgentCanWithdrawItsOwnView() async {
        let agent = agentInPane("docs-9a12")
        let forwards = PortForwardService()
        _ = await server().serveView(tool: "view.expose", args: ["port": 3000],
                               requester: agent, forwards: forwards)

        let outcome = await server().serveView(tool: "view.withdraw", args: ["port": 3000],
                                         requester: agent, forwards: forwards)

        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        XCTAssertTrue(forwards.exposures.isEmpty)
    }

}
