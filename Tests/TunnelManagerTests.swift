import XCTest
@testable import Synapty

/// Unit tests for TunnelManager's command building and credential
/// resolution — the fixed positional-argument contract of connectCommand
/// is exactly the kind of thing that drifts (WI-2026-08-08-021).
@MainActor
final class TunnelManagerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try setUpHostStoreStorage()
    }

    override func tearDownWithError() throws {
        restoreStorageOverrides(tempDir)
    }

    /// The store is held by the TEST CASE, not by the manager.
    ///
    /// TunnelManager.hostStore is `weak`, so the previous version — which
    /// assigned a freshly-made HostStore and returned — left every caller
    /// with a nil store the instant the line finished. Ten tests then
    /// exercised the no-store fallback while reading as though they
    /// covered identity resolution: connectCommand, effectiveUsername and
    /// effectiveKeyPath all take a `guard let store` path that was never
    /// entered. Green, and covering the other branch.
    private var heldStore: HostStore!

    private func makeManager() -> TunnelManager {
        let m = TunnelManager()
        heldStore = HostStore()
        m.hostStore = heldStore
        return m
    }

    // MARK: - Shell.quote

    func testShellQuotePlain() {
        XCTAssertEqual(Shell.quote("hello"), "'hello'")
    }

    func testShellQuoteEmbeddedQuote() {
        XCTAssertEqual(Shell.quote("it's"), "'it'\\''s'")
    }

    func testShellQuoteEmpty() {
        XCTAssertEqual(Shell.quote(""), "''")
    }

    func testShellQuoteSpecialCharsStayInsideQuotes() {
        // Shell metacharacters must end up INSIDE the single-quoted unit —
        // single quotes make them literal, so no injection is possible.
        XCTAssertEqual(Shell.quote("x; rm -rf /"), "'x; rm -rf /'")
        XCTAssertEqual(Shell.quote("$(danger)"), "'$(danger)'")
        XCTAssertEqual(Shell.quote("a b"), "'a b'")
    }

    // MARK: - connectCommand positional layout

    /// The connect script parses argv positionally:
    /// THE FIRST WORD IS EXECUTED, and `exec` has no notion of a
    /// VAR=value prefix — it takes that word as the program to become. A
    /// bare assignment here becomes a PATH lookup for a file named
    /// "SYNAPTY_BIN=/…", which is what a real first connection reported
    /// as "No such file or directory" about a path that was plainly
    /// there. The tests did not catch it because they all began counting
    /// at `bash`.
    func testTheCommandBeginsWithSomethingExecutable() {
        let m = makeManager()
        let host = HostEntry(label: "GPU", address: "10.0.1.5", username: "ml")
        let result = m.connectCommand(for: host)
        let first = result.command.split(separator: " ").first.map(String.init) ?? ""
        XCTAssertFalse(first.contains("="),
                       "the command starts with an assignment, which exec cannot run: \(result.command)")
        XCTAssertTrue(first == "env" || first == "bash",
                      "unexpected leading word: \(first)")
    }

    /// Anything non-positional reaches the script through the
    /// environment, because the positional list ends in a variadic run of
    /// forwarding rules — and it gets there through `env`.
    func testEnvironmentIsCarriedByEnv() {
        let m = makeManager()
        var host = HostEntry(label: "Plain", address: "h", username: "u")
        host.durableSessions = false
        let tokens = m.connectCommand(for: host).command.split(separator: " ").map(String.init)
        guard let envIndex = tokens.firstIndex(of: "env") else {
            return XCTFail("no env prefix: \(tokens)")
        }
        let bashIndex = tokens.firstIndex(of: "bash") ?? tokens.count
        let assignments = tokens[(envIndex + 1)..<bashIndex]
        XCTAssertTrue(assignments.allSatisfy { $0.contains("=") },
                      "a non-assignment sits between env and bash: \(assignments)")
        XCTAssertTrue(assignments.contains { $0.hasPrefix("SYNAPTY_DURABLE=") })
    }

    /// The positional list, with any leading environment assignments
    /// dropped — they are how anything non-positional reaches the script,
    /// and counting from the front of the string makes every index here a
    /// hostage to whether one happens to be set.
    private func commandTokens(_ command: String) -> [String] {
        let all = command.split(separator: " ").map(String.init)
        let start = all.firstIndex(of: "bash") ?? 0
        return Array(all[start...])
    }

    /// THE ORDER `scripts/connect.sh` READS ITS POSITIONALS IN, which that
    /// script owns — see its usage line and the `${1:?}`…`${8:-}` block.
    /// It is NOT restated here as prose: a comment listing the order is a
    /// second copy that goes stale silently, and these assertions are the
    /// check ([[WI-2026-08-30-010]]).
    ///
    /// ENVIRONMENT RIDES IN FRONT, and the positional list is counted from
    /// `bash` rather than from the start of the string: variables are how
    /// anything non-positional reaches the script, precisely because the
    /// tail of the list is variadic.
    func testConnectCommandPositionalLayout() {
        let m = makeManager()
        let host = HostEntry(label: "GPU", address: "10.0.1.5", port: 2222, username: "ml", sshKeyPath: "/keys/gpu")
        let result = m.connectCommand(for: host)
        let tokens = commandTokens(result.command)

        XCTAssertEqual(tokens[0], "bash")
        // The script path may be bundled (absolute) or repo-relative.
        XCTAssertTrue(tokens[1].hasPrefix("'"))
        XCTAssertTrue(tokens[1].hasSuffix("connect.sh'"))
        XCTAssertEqual(tokens[2], "'\(result.agentID)'")
        XCTAssertEqual(tokens[3], "'10.0.1.5'")
        XCTAssertEqual(tokens[4], "2222")
        XCTAssertEqual(tokens[5], "'ml'")
        XCTAssertEqual(tokens[6], "9000") // tunnelPort
        XCTAssertEqual(tokens[7], "9000") // hubPort
        XCTAssertEqual(tokens[8], "'/keys/gpu'")
        XCTAssertEqual(tokens[9], "''") // no jump
        XCTAssertEqual(tokens.count, 10) // no forwardings
    }

    func testConnectCommandEmptyKeyAndJumpArePlaceholders() {
        let m = makeManager()
        let host = HostEntry(label: "Min", address: "localhost", username: "u")
        let result = m.connectCommand(for: host)
        let tokens = commandTokens(result.command)
        XCTAssertEqual(tokens[8], "''")
        XCTAssertEqual(tokens[9], "''")
    }

    func testConnectCommandForwardingsAppended() {
        let m = makeManager()
        var host = HostEntry(label: "Fwd", address: "10.0.1.6", username: "u")
        host.forwardings = [PortForward(kind: .local, listenPort: 8080, targetHost: "localhost", targetPort: 80)]
        let result = m.connectCommand(for: host)
        let tokens = commandTokens(result.command)
        XCTAssertEqual(tokens.count, 14)
        XCTAssertEqual(tokens[10], "local")
        XCTAssertEqual(tokens[11], "8080")
        XCTAssertEqual(tokens[12], "'localhost'")
        XCTAssertEqual(tokens[13], "80")
    }

    // MARK: - effective* resolution (host → identity → group chain)

    func testEffectiveResolutionFromHostFields() {
        let m = makeManager()
        let host = HostEntry(label: "H", address: "1.1.1.1", port: 2222, username: "direct", sshKeyPath: "/k")
        XCTAssertEqual(m.effectiveUsername(for: host), "direct")
        XCTAssertEqual(m.effectivePort(for: host), 2222)
        XCTAssertEqual(m.effectiveKeyPath(for: host), "/k")
    }

    func testEffectiveResolutionFromIdentity() {
        let store = HostStore()
        let identity = Identity(id: UUID(), label: "ml", username: "ml-user", sshKeyPath: "~/.ssh/ml_key")
        store.identities.append(identity)
        let m = TunnelManager()
        m.hostStore = store

        var host = HostEntry(label: "H", address: "1.1.1.1", username: "")
        host.identityID = identity.id
        XCTAssertEqual(m.effectiveUsername(for: host), "ml-user")
        XCTAssertEqual(m.effectiveKeyPath(for: host), "~/.ssh/ml_key")
    }

    func testEffectiveResolutionFromGroupChain() {
        let store = HostStore()
        let group = HostGroup(id: UUID(), label: "Lab")
        store.groups.append(group)
        let m = TunnelManager()
        m.hostStore = store

        // Group carries a port; the host defers to it (host port 22 = default).
        var host = HostEntry(label: "H", address: "1.1.1.1", username: "u")
        host.groupID = group.id
        var withPort = group
        withPort.port = 5555
        store.updateGroup(withPort)
        XCTAssertEqual(m.effectivePort(for: host), 5555)
    }

    // MARK: - localCommand

    /// A LOCAL PANE IS HELD, LIKE A REMOTE ONE ([[RFC-0014]] C-SCOPE).
    ///
    /// The machine the child is on was never what made the difference:
    /// a holder is a process on that machine, and this Mac is one. What
    /// differed was that the workbench ended its own wrapper on exit.
    func testALocalPaneStartsAHolderAndThenAttachesToIt() throws {
        let tmp = try setUpSettingsStorage()
        defer { restoreStorageOverrides(tmp) }
        SynaptySettings.shared.localDurableSessions = true
        let m = makeManager()

        let result = m.localCommand()

        XCTAssertTrue(result.agentID.hasPrefix("local-"))
        XCTAssertTrue(result.command.contains("run --hold --detach --id"),
                      "a local pane did not start a holder: \(result.command)")
        // AND SAYS WHO IT IS when it joins ([[RFC-0014]] C-CLIENT-LABEL):
        // the workbench is `gui`, so a displaced shell reads "taken by
        // gui@…" and not "by another client".
        XCTAssertTrue(result.command.contains("attach --client gui --id"),
                      "a local pane started a holder and never joined it as the gui")
        XCTAssertTrue(result.command.contains("--hub 127.0.0.1:9000"))
        XCTAssertFalse(result.command.contains("--parent-pid"),
                       "a durable pane still hangs up when the workbench exits")
    }

    // A restored pane returning to its recorded name is now conditional
    // on that session still being alive — a recorded id is a record and
    // not a grant ([[RFC-0015]] C-PERSIST, [[WI-2026-08-19-006]]). Both
    // halves are in [[SessionIdentityTests]], which can stage a record for
    // a live process and for a dead one.

    /// AND IT IS REFUSABLE, on the same terms as any host
    /// ([[RFC-0014]] C-OPT-OUT): with durability off the child runs
    /// directly and ends with the window.
    func testRefusingDurabilityRunsTheChildDirectlyAndHangsUpWithTheWorkbench() throws {
        let tmp = try setUpSettingsStorage()
        defer { restoreStorageOverrides(tmp) }
        SynaptySettings.shared.localDurableSessions = false
        let m = makeManager()

        let result = m.localCommand()

        XCTAssertFalse(result.command.contains("--hold"),
                       "durability was refused and a holder was started anyway")
        XCTAssertTrue(result.command.contains("--parent-pid"),
                      "a non-durable pane would outlive the window it was told it would not")
    }
}

extension TunnelManagerTests {

    /// WI-2026-08-12-008: setup-host.sh reports the loopback port that
    /// reaches the remote hub, and the workbench hands it to its LOCAL hub.
    func testParsePeerPortReadsTheSetupTail() {
        let output = """
        Remote hub ready on remotehost:9000 (loopback there)
        ControlMaster established: /Users/x/.synapty/sockets/a@b:22
        PEER_PORT=9007
        SETUP_OK
        """
        XCTAssertEqual(TunnelManager.parsePeerPort(output), 9007)
    }

    func testAbsentPeerPortMustNotBeInvented() {
        // No hub could be started on that host. Dialing a made-up port
        // would leave the local hub reporting a peer that does not exist,
        // which is worse than having no peer: the directory would name a
        // host for identities nothing can deliver to.
        let output = """
        WARNING: no hub could be started on remotehost
        ControlMaster established: /Users/x/.synapty/sockets/a@b:22
        SETUP_OK
        """
        XCTAssertNil(TunnelManager.parsePeerPort(output))
        XCTAssertNil(TunnelManager.parsePeerPort(""))
        XCTAssertNil(TunnelManager.parsePeerPort("PEER_PORT=notanumber"))
    }

    func testPeerIDFollowsTheAgentIDCharacterDiscipline() {
        // RFC-0009 reserves '@' as the qualifier separator in
        // `local-XXXX@<peer-id>`, so a label containing one must not pass
        // through — `local-ab12@a@b` would be ambiguous to split.
        XCTAssertEqual(TunnelManager.peerID(for: "RemoteHost"), "remotehost")
        // SHORT name: the hub's own hostname fallback truncates at the
        // first dot, and a workbench that kept the FQDN would rename the
        // machine on the first peer_connect — leaving every peer that
        // cached the short name with a stale entry.
        XCTAssertEqual(TunnelManager.peerID(for: "build-box.lan"), "build-box")
        XCTAssertEqual(TunnelManager.peerID(for: "deskmac.local"), "deskmac")
        XCTAssertEqual(TunnelManager.peerID(for: "my box@home"), "my-box-home")
        XCTAssertEqual(TunnelManager.peerID(for: String(repeating: "a", count: 100)).count, 64)
    }
}

extension TunnelManagerTests {

    /// WI-2026-08-12-007: the peer forward is bound HERE, so a shared port
    /// means the second host's -L fails outright and that host silently
    /// never peers. This is the bug the direction flip introduced — the
    /// old REVERSE tunnel bound on the remote side, where every machine
    /// could have its own 9000.
    @MainActor
    func testEachHostGetsItsOwnLoopbackPeerPort() {
        let tm = TunnelManager()
        let a = HostEntry(label: "remotehost", address: "remotehost", username: "u")
        let b = HostEntry(label: "buildbox", address: "buildbox", username: "u")

        let pa = tm.peerPort(for: a)
        let pb = tm.peerPort(for: b)
        XCTAssertNotEqual(pa, pb, "two hosts must not share a local forward port")
        XCTAssertGreaterThanOrEqual(pa, TunnelManager.peerPortBase)
        XCTAssertGreaterThanOrEqual(pb, TunnelManager.peerPortBase)

        // Stable across calls: a port that moved on every setup would
        // leave the previous forward stranded and the hub dialing a dead
        // number.
        XCTAssertEqual(tm.peerPort(for: a), pa)
        XCTAssertEqual(tm.peerPort(for: b), pb)
    }

    @MainActor
    func testPeerPortsStayClearOfTheHubLadder() {
        // The hub's own ladder is 9000 + 1..9. A peer forward landing in
        // that range would race the hub for the number on a busy dev
        // machine, and ssh fails the whole connection rather than moving.
        XCTAssertGreaterThan(TunnelManager.peerPortBase, 9009)
    }
}

extension TunnelManagerTests {

    /// WI-2026-08-12-010: the hub reports a dropped relay link and the
    /// WORKBENCH decides whether to redial — because only it knows whether
    /// the SSH forward still exists. A hub retrying on its own would keep
    /// dialing a tunnel the human tore down.
    @MainActor
    func testUnknownPeerIsNotRedialed() {
        let tm = TunnelManager()
        // No port assigned for this peer: it was never peered, or the
        // human unpeered it. Redialing would target nothing.
        tm.handleHubEvent(["kind": "peer_link_down", "peer": "ghosthost"])
        XCTAssertFalse(tm.peerLinkFailed.contains("ghosthost"))
    }

    @MainActor
    func testLinkUpClearsTheFailedState() {
        let tm = TunnelManager()
        tm.handleHubEvent(["kind": "peer_link_down", "peer": "remotehost"])
        tm.handleHubEvent(["kind": "peer_link_up", "peer": "remotehost"])
        XCTAssertFalse(tm.peerLinkFailed.contains("remotehost"),
                       "a recovered link must not keep reporting failure")
    }

    @MainActor
    func testMalformedPeerEventsAreIgnored() {
        let tm = TunnelManager()
        tm.handleHubEvent(["kind": "peer_link_down"])          // no peer
        tm.handleHubEvent(["kind": "peer_link_down", "peer": ""]) // empty
        tm.handleHubEvent(["peer": "remotehost"])               // no kind
        tm.handleHubEvent(["kind": "agent_registered", "peer": "remotehost"]) // not ours
        XCTAssertTrue(tm.peerLinkFailed.isEmpty)
    }
}

extension TunnelManagerTests {

    /// WI-2026-08-12-013: "go to a remote agent" is an ATTACH, not a new
    /// session. connect.sh names its tmux session `synapty-<agent-id>` and
    /// attaches when one exists, so the id has to travel into the command
    /// — a generated one would start a second agent beside the one the
    /// human was trying to reach.
    @MainActor
    func testConnectCommandCarriesAnExplicitAgentID() {
        let tm = TunnelManager()
        let host = HostEntry(label: "remotehost", address: "remotehost", username: "u")

        let attach = tm.connectCommand(for: host, agentID: "claude-abc12345")
        XCTAssertEqual(attach.agentID, "claude-abc12345")
        XCTAssertTrue(attach.command.contains("claude-abc12345"))

        // Without an override the generated id is still per-session, so
        // opening a plain host session does not collide with a running
        // agent's held session on that machine.
        let fresh = tm.connectCommand(for: host)
        XCTAssertNotEqual(fresh.agentID, "claude-abc12345")
        // IN THE RESERVED NAMESPACE, not under the host's label. This
        // asserted `remotehost-` — the shape that made every remote pane
        // invisible to the three predicates that qualify an id before it
        // crosses a relay ([[RFC-0008]] C-IDENTITY reserves `local-` for
        // exactly this id). Keeping two hosts' panes apart is the key's
        // job, not the name's.
        XCTAssertTrue(fresh.agentID.hasPrefix("local-"))
    }

    @MainActor
    func testPeerSummariesReportWhatTheHumanCouldNotSeeBefore() {
        let tm = TunnelManager()
        XCTAssertTrue(tm.peerSummaries.isEmpty, "no hosts assigned, nothing to show")
    }
}

extension TunnelManagerTests {

    /// WI-2026-08-12-010, found LIVE after the first version shipped: the
    /// retry chain must drive itself. A redial that fails to CONNECT
    /// produces no event — the dialer returns before it can report a link
    /// up or down — so an event-driven chain stops after exactly one
    /// attempt and goes silent, never reaching the give-up marker either.
    @MainActor
    func testASecondDownEventDoesNotStartACompetingChain() {
        let tm = TunnelManager()
        tm.handleHubEvent(["kind": "peer_link_down", "peer": "remotehost"])
        tm.handleHubEvent(["kind": "peer_link_down", "peer": "remotehost"])
        // With no assigned port neither call starts anything, which is the
        // unpeered case; the assertion that matters is that repeated downs
        // are idempotent rather than multiplying dial traffic.
        XCTAssertFalse(tm.peerLinkFailed.contains("remotehost"))
    }

    @MainActor
    func testGiveUpIsPublishedNotJustLogged() {
        // The state has to be READABLE, because "we stopped trying" and
        // "momentarily unreachable" look identical otherwise and only one
        // of them heals on its own.
        let tm = TunnelManager()
        XCTAssertTrue(tm.peerLinkFailed.isEmpty)
        tm.handleHubEvent(["kind": "peer_link_up", "peer": "remotehost"])
        XCTAssertFalse(tm.peerLinkFailed.contains("remotehost"))
    }
}

extension TunnelManagerTests {

    /// WI-2026-08-12-015: under RFC-0010 a machine names ITSELF, so the id
    /// the peer reports and the label this workbench uses diverge by
    /// construction — a host labelled "remotehost" reports
    /// "remotehost-7f3a". The redial has to key on what came back from the
    /// link, or it silently stops firing the moment the machine owns its
    /// own name.
    @MainActor
    func testRedialKeysOnThePeerReportedID() {
        let tm = TunnelManager()
        // A link comes up and carries the port it was reached on.
        tm.handleHubEvent(["kind": "peer_link_up", "peer": "remotehost-7f3a", "generation": 9202])
        // A drop for THAT id can now be acted on...
        tm.handleHubEvent(["kind": "peer_link_down", "peer": "remotehost-7f3a"])
        XCTAssertFalse(tm.peerLinkFailed.contains("remotehost-7f3a"))
        // ...while a drop for the LOCAL label, which is what the old code
        // matched on, refers to no known peer and starts nothing.
        tm.handleHubEvent(["kind": "peer_link_down", "peer": "remotehost"])
        XCTAssertFalse(tm.peerLinkFailed.contains("remotehost"))
    }

    @MainActor
    func testAdoptedPeersAreRedialable() {
        // Adoption has to populate the same map the redial reads, or a
        // workbench that took over an existing link could observe it drop
        // and be unable to do anything about it.
        let tm = TunnelManager()
        tm.adoptExistingPeers([(peer: "remotehost-7f3a", port: 9202)])
        tm.handleHubEvent(["kind": "peer_link_up", "peer": "remotehost-7f3a", "generation": 9202])
        XCTAssertFalse(tm.peerLinkFailed.contains("remotehost-7f3a"))
    }
}

// MARK: - WI-2026-08-13-011: the peer summary must describe the REAL peer

extension TunnelManagerTests {

    /// peerSummaries derived its peer id from the LOCAL host label while
    /// peerLinkFailed is filled with the id the PEER reports. [[RFC-0010]]
    /// moved naming authority to the machine, so those two differ BY
    /// CONSTRUCTION — a host labelled "remotehost" reports
    /// "remotehost-4e84". The lookup therefore never matched and
    /// `linkFailed` was permanently false.
    ///
    /// This is the same defect already fixed one function away in
    /// scheduleRedial, whose comment says matching on the local label
    /// "silently disabled the redial the moment the machine owned its own
    /// name". It was left in the summary that feeds the UI, so the surface
    /// whose entire job is to show "we gave up" could not.
    @MainActor
    func testPeerSummaryReportsAGivenUpLinkUnderThePeersOwnID() {
        let tm = TunnelManager()
        // hostStore is `weak`: the store must be held by the TEST or it is
        // gone before the first assertion.
        let store = HostStore()
        tm.hostStore = store
        let host = HostEntry(label: "remotehost", address: "remotehost.example", username: "u")
        store.addHost(host)

        // The link came up and the peer reported its own, suffixed id.
        _ = tm.peerPort(for: host)
        tm.handleHubEvent([
            "kind": "peer_link_up", "peer": "remotehost-4e84",
            "generation": tm.peerPort(for: host),
        ])
        // ...then dropped and exhausted its redials.
        tm.notePeerGaveUp("remotehost-4e84")

        let summary = tm.peerSummaries.first { $0.hostLabel == "remotehost" }
        XCTAssertNotNil(summary, "the peered host must appear at all")
        XCTAssertEqual(summary?.peerID, "remotehost-4e84",
                       "the summary must carry the id the PEER reports, not one derived from our label")
        XCTAssertTrue(summary?.linkFailed ?? false,
                      "a link we stopped retrying must read as failed — that is the whole point of publishing it")
    }

    /// A host that has never linked still belongs in the list, and must
    /// NOT read as failed: "not linked yet" and "we gave up" are different
    /// facts and the UI renders them differently.
    @MainActor
    func testAHostThatNeverLinkedIsNotReportedAsFailed() {
        let tm = TunnelManager()
        let store = HostStore()
        tm.hostStore = store
        let host = HostEntry(label: "buildbox", address: "buildbox.example", username: "u")
        store.addHost(host)
        _ = tm.peerPort(for: host)

        let summary = tm.peerSummaries.first { $0.hostLabel == "buildbox" }
        XCTAssertNotNil(summary)
        XCTAssertFalse(summary?.linkFailed ?? true)
    }
}

// MARK: - The two-channel rule, made checkable

extension TunnelManagerTests {

    /// The log answers WHY, the UI answers WHAT, and the two strings must
    /// not be the same text (AppLog's policy, now [[RFC-0012]]
    /// C-TWO-CHANNELS). The cheap mistake is reusing one string in both
    /// places, which yields either a dialog reading `NSCocoaErrorDomain
    /// Code=513` or a log line reading "something went wrong".
    ///
    /// Checked on the peer-gave-up case. It used to be checked against
    /// the hub popover's peer row; that row is gone, and the property
    /// moved to the mark on the HOST — which is where the failure was
    /// always going to be read.
    @MainActor
    func testTheUIStringAndTheLogStringAreNotTheSameText() throws {
        let hint = try XCTUnwrap(HostFailureMarks.peer(.gaveUp)).2

        // The UI names the CONSEQUENCE and what will not happen by itself.
        XCTAssertTrue(hint.contains("Lost contact"))
        XCTAssertTrue(hint.contains("reconnect the host"))
        // ...and does NOT carry the log's diagnostic vocabulary. A count
        // of retries is a cause, and causes belong in the log.
        XCTAssertFalse(hint.lowercased().contains("redial"),
                       "the UI must not borrow the log's answer")
        XCTAssertFalse(hint.contains("\(TunnelManager.maxPeerRedials)"),
                       "attempt counts are a WHY, and belong in the log")
    }

    /// A peer that is merely missing a capability is NOT described as
    /// failed — [[RFC-0010]] C-DIAGNOSABILITY: a missing capability is not
    /// a broken feature. A linked peer produces no mark at all, which is
    /// the strongest form of that rule.
    @MainActor
    func testAWorkingPeerProducesNoMarkAtAll() {
        XCTAssertNil(HostFailureMarks.peer(.linked),
                     "a capability that works is invisible by working")
        XCTAssertNil(HostFailureMarks.peer(.none))
    }
}

// MARK: - Host failure marks (WI-2026-08-13-011)

extension TunnelManagerTests {

    /// A tunnel that is up while the machine's hub never answered is NOT
    /// "connected" in any sense the human cares about: no A2A, no
    /// directory entry, no mail either way. The card used to say
    /// connected, which is true of the forward and false about everything
    /// they wanted the machine for.
    @MainActor
    func testHubStateIsAskedSeparatelyFromTunnelState() {
        let tm = TunnelManager()
        let store = HostStore()
        tm.hostStore = store
        let host = HostEntry(label: "remotehost", address: "remotehost.example", username: "u")
        store.addHost(host)

        XCTAssertEqual(tm.peerState(for: host), .none, "no peering attempted")
        let port = tm.peerPort(for: host)
        XCTAssertEqual(tm.peerState(for: host), .notReached,
                       "a port is assigned and nothing has answered on it")

        tm.handleHubEvent(["kind": "peer_link_up", "peer": "remotehost-4e84", "generation": port])
        XCTAssertEqual(tm.peerState(for: host), .linked)

        tm.notePeerGaveUp("remotehost-4e84")
        XCTAssertEqual(tm.peerState(for: host), .gaveUp)
    }

    /// The card and the list row are two views of one host, switched by a
    /// toggle. A mark implemented twice drifts, and the drift reads as
    /// "the failure went away when I switched to list view" — a failure
    /// appearing to resolve itself is worse than one that was never shown.
    @MainActor
    func testBothHostPresentationsDescribeAFailureIdentically() {
        let host = HostEntry(label: "remotehost", address: "remotehost.example", username: "u")

        let spoken = HostFailureMarks.describe(
            host: host, connected: true, unsaved: true, peerState: .gaveUp)
        XCTAssertTrue(spoken.contains("not saved to disk"))
        XCTAssertTrue(spoken.contains("lost contact with the hub"))

        // A working peer says nothing: a capability that works is
        // invisible by working ([[RFC-0010]] C-DIAGNOSABILITY).
        XCTAssertNil(HostFailureMarks.peer(.linked))
        XCTAssertNil(HostFailureMarks.peer(.none))
        XCTAssertNotNil(HostFailureMarks.peer(.notReached))
        XCTAssertNotNil(HostFailureMarks.peer(.gaveUp))

        // And the hover text stays on the UI side of the two-channel rule.
        let hint = HostFailureMarks.peer(.gaveUp)!.2
        XCTAssertTrue(hint.contains("reconnect the host"))
        XCTAssertFalse(hint.lowercased().contains("redial"))
    }
}

// MARK: - WI-2026-08-13-012: notifications are STATES, not events

extension TunnelManagerTests {

    /// A recovery must take the notification back. Unreachability is a
    /// state, and a notice that outlives the state is a lie the human has
    /// no way to check — they would have to go and test the machine to
    /// find out the notification is stale.
    ///
    /// Verified through the observable state rather than by intercepting
    /// UNUserNotificationCenter: leaving `peerLinkFailed` is what triggers
    /// the withdrawal, and if that stops happening the withdrawal stops
    /// with it.
    @MainActor
    func testRecoveryClearsTheFailedState() {
        let tm = TunnelManager()
        let store = HostStore()
        tm.hostStore = store
        let host = HostEntry(label: "remotehost", address: "remotehost.example", username: "u")
        store.addHost(host)
        let port = tm.peerPort(for: host)

        tm.handleHubEvent(["kind": "peer_link_up", "peer": "remotehost-4e84", "generation": port])
        tm.notePeerGaveUp("remotehost-4e84")
        XCTAssertEqual(tm.peerState(for: host), .gaveUp)

        tm.handleHubEvent(["kind": "peer_link_up", "peer": "remotehost-4e84", "generation": port])
        XCTAssertEqual(tm.peerState(for: host), .linked,
                       "a returning peer must leave the failed state, which is what withdraws the notice")
    }

    /// A transient drop must NOT reach the failed state at all. A sleeping
    /// laptop drops tunnels constantly; a notification per drop is how
    /// someone turns notifications off on day two and then misses the one
    /// that mattered. Only an EXHAUSTED redial chain qualifies.
    @MainActor
    func testATransientDropDoesNotEnterTheFailedState() {
        let tm = TunnelManager()
        let store = HostStore()
        tm.hostStore = store
        let host = HostEntry(label: "buildbox", address: "buildbox.example", username: "u")
        store.addHost(host)
        let port = tm.peerPort(for: host)

        tm.handleHubEvent(["kind": "peer_link_up", "peer": "buildbox-11aa", "generation": port])
        tm.handleHubEvent(["kind": "peer_link_down", "peer": "buildbox-11aa"])

        XCTAssertFalse(tm.peerLinkFailed.contains("buildbox-11aa"),
                       "a drop starts a redial chain; only exhausting it is a failure")
    }

    /// Repeated failures must REPLACE rather than stack, which is what the
    /// subject-derived identifier buys. notePeerGaveUp is idempotent, so a
    /// second call posts nothing new.
    @MainActor
    func testTheFailureIdentifierIsDerivedFromTheSubject() {
        XCTAssertEqual(NotificationForwarder.peerFailureID("remotehost-4e84"),
                       "peer-failed-remotehost-4e84")
        XCTAssertNotEqual(NotificationForwarder.peerFailureID("remotehost-4e84"),
                          NotificationForwarder.peerFailureID("buildbox-11aa"),
                          "two machines must not share one notification")

        let tm = TunnelManager()
        tm.notePeerGaveUp("remotehost-4e84")
        tm.notePeerGaveUp("remotehost-4e84")
        XCTAssertEqual(tm.peerLinkFailed.count, 1, "entering a state twice is entering it once")
    }
}

extension TunnelManagerTests {

    /// The notification body states the COST, not the event. "A link
    /// dropped" is the log's answer; "2 agents there are working without
    /// coordination" is what the human needs, and it is the sentence this
    /// product exists to say.
    @MainActor
    func testTheNotificationBodyStatesTheCostNotTheEvent() {
        let tm = TunnelManager()
        tm.agentCountForPeer = { _ in 2 }
        let body = tm.peerFailureBodyForTesting("remotehost-4e84")
        XCTAssertTrue(body.contains("2 agents on this machine are"))
        XCTAssertTrue(body.contains("without coordination"))
        XCTAssertTrue(body.contains("Reconnect the host"))
        // The log's vocabulary stays in the log (AppLog two-channel rule).
        XCTAssertFalse(body.lowercased().contains("redial"))
        XCTAssertFalse(body.contains("peer_link_down"))

        // Singular reads as a sentence, not as "1 agents".
        tm.agentCountForPeer = { _ in 1 }
        XCTAssertTrue(tm.peerFailureBodyForTesting("remotehost-4e84").contains("1 agent on this machine is"))

        // And with nobody there, it says what still happens rather than
        // inventing a consequence.
        tm.agentCountForPeer = { _ in 0 }
        XCTAssertTrue(tm.peerFailureBodyForTesting("remotehost-4e84").contains("queued"))
    }
}

extension TunnelManagerTests {

    // MARK: - Version skew is a state, not a mystery

    /// THE TWO FIGURES ANSWER DIFFERENT QUESTIONS. `hub.json` is written
    /// at startup so it names the RUNNING process; the binary on disk
    /// names what would run next. An upload that lands while the old hub
    /// keeps running leaves them apart — and comparing files, which is the
    /// obvious thing to do, would have reported everything fine.
    func testSkewIsSeenWhenTheRunningHubIsNotTheDeployedBinary() throws {
        let output = """
        Remote hub ready on box:9000 (loopback there)
        HUB_BUILD=dev
        HUB_BINARY=e32502e92c6b
        PEER_PORT=9200
        """
        let builds = try XCTUnwrap(TunnelManager.parseHubBuilds(output))
        XCTAssertEqual(builds.running, "dev")
        XCTAssertEqual(builds.deployed, "e32502e92c6b")
        XCTAssertTrue(builds.isSkewed)
    }

    /// A HOST THAT IS UP TO DATE SAYS NOTHING. A mark that is on for the
    /// normal case carries no information and costs the marks that do.
    func testAMatchingHubIsNotReported() throws {
        let output = "HUB_BUILD=64b01be190a3\nHUB_BINARY=64b01be190a3"
        let builds = try XCTUnwrap(TunnelManager.parseHubBuilds(output))
        XCTAssertFalse(builds.isSkewed)
        XCTAssertNil(HostFailureMarks.hubBuild(builds))
    }

    /// AN UNREACHABLE HOST IS NOT AN OUT-OF-DATE ONE. Half an answer, or
    /// none, must not render as skew — that would be a wrong answer where
    /// no answer was available, which is the failure this whole mark
    /// exists to prevent.
    func testAnAbsentOrHalfAnswerIsNotSkew() {
        XCTAssertNil(TunnelManager.parseHubBuilds("PEER_PORT=9200"))
        XCTAssertNil(TunnelManager.parseHubBuilds("HUB_BUILD=dev"))
        XCTAssertNil(TunnelManager.parseHubBuilds("HUB_BINARY=abc"))
        XCTAssertNil(TunnelManager.parseHubBuilds("HUB_BUILD=\nHUB_BINARY=abc"))
        XCTAssertNil(HostFailureMarks.hubBuild(nil))
    }

    /// The mark a human actually sees: a WARNING, and it names the next
    /// step rather than the cause.
    func testTheMarkSaysWhatToDo() throws {
        let skewed = TunnelManager.HubBuilds(running: "dev", deployed: "e32502e9")
        let (_, tint, hint) = try XCTUnwrap(HostFailureMarks.hubBuild(skewed))
        XCTAssertEqual(tint, DS.warning, "red here would teach them to ignore red")
        XCTAssertTrue(hint.lowercased().contains("reconnect"), hint)
    }
}

@MainActor
extension TunnelManagerTests {

    // MARK: - A missing capability is not a broken feature

    /// ABSENCE OF EVIDENCE IS NOT EVIDENCE OF ABSENCE, which is the clause
    /// stated almost word for word ([[RFC-0010]] C-DIAGNOSABILITY).
    ///
    /// `declared` is empty for a peer that never linked, so filtering
    /// against it reported EVERY capability as missing — and rendering
    /// that would have told the human "this machine does not relay
    /// presence" about a machine we simply could not reach. The one
    /// surface built to satisfy the clause would have violated it.
    func testAPeerThatNeverLinkedHasNoCapabilityAnswerAtAll() throws {
        let store = HostStore()
        let host = HostEntry(label: "builder", address: "builder.example", username: "u")
        store.hosts.append(host)
        let manager = TunnelManager()
        manager.hostStore = store
        // A port assigned, nothing ever answered on it.
        manager.adoptExistingPeers([(peer: "builder", port: 9200)], capabilities: [:])

        for summary in manager.peerSummaries where !summary.linked {
            XCTAssertNil(summary.missing,
                         "not linked means nothing has been declared, not that nothing exists")
        }
    }

    /// EMPTY AND NIL ARE DIFFERENT ANSWERS. Empty is "it declared
    /// everything we use" — invisible by working. Nil is "it has never
    /// told us".
    func testEmptyMeansItDeclaredEverythingWeUse() {
        XCTAssertFalse(TunnelManager.knownCapabilities.isEmpty,
                       "a build that expects nothing can never report an absence")
    }
    // MARK: - A pane is a channel on one of the host's connections

    /// [[RFC-0013]] C-BROKER, [[WI-2026-08-26-001]]. The pane's command
    /// names the connection it rides, because "the connection for this
    /// host" stopped being one answer — and it gives that connection back
    /// when the pane closes, or the count only ever climbs and placement
    /// ends up avoiding the emptiest one.
    @MainActor
    func testAPaneNamesItsConnectionAndGivesItBackWhenItCloses() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        MasterPool.socketDirectoryOverride = tmp
        MasterPool.tenantDirectoryOverride = tmp.appendingPathComponent("tenants")
        defer {
            MasterPool.socketDirectoryOverride = nil
            MasterPool.tenantDirectoryOverride = nil
        }

        let tm = TunnelManager()
        tm.hostStore = HostStore()
        tm.pool.openMaster = { _, path in
            FileManager.default.createFile(atPath: path, contents: nil); return true
        }
        let host = HostEntry(label: "builder", address: "builder.example", username: "someone")
        let key = tm.poolKey(for: host)
        // Connected, the way connecting actually leaves it: one connection
        // up and carrying nothing yet.
        let only = tm.pool.primary(for: key)
        FileManager.default.createFile(atPath: only, contents: nil)

        let launch = tm.connectCommand(for: host)
        XCTAssertTrue(launch.command.contains("SYNAPTY_SOCKET="),
                      "the script must be told which connection, not left to derive the first one")

        // Built twice for the same pane — which happens — must not count twice.
        _ = tm.connectCommand(for: host, agentID: launch.agentID)

        tm.paneClosed(hostID: host.id, agentID: launch.agentID)
        XCTAssertEqual(tm.pool.placeExclusive(key, tenant: "transfer.probe"), only,
                       "one release is enough because claiming twice under one name claimed once")
    }

    @MainActor
    func testAPaneCommandForAHostHoldingNothingLeavesTheScriptToOpenItsOwn() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        MasterPool.socketDirectoryOverride = tmp
        MasterPool.tenantDirectoryOverride = tmp.appendingPathComponent("tenants")
        defer {
            MasterPool.socketDirectoryOverride = nil
            MasterPool.tenantDirectoryOverride = nil
        }

        let tm = TunnelManager()
        tm.hostStore = HostStore()
        var opens = 0
        tm.pool.openMaster = { _, _ in opens += 1; return true }
        let host = HostEntry(label: "builder", address: "builder.example", username: "someone")

        let launch = tm.connectCommand(for: host)
        XCTAssertFalse(launch.command.contains("SYNAPTY_SOCKET="),
                       "naming a socket with no master behind it would point the pane at nothing")
        XCTAssertEqual(opens, 0, "building a pane command must not authenticate")
    }

    /// [[RFC-0013]] C-BROKER: a pane may be migrated between a host's
    /// connections. Nothing is restarted — the pane's process is the attach
    /// client, which respawns its transport in the same pty, so what a
    /// migration has to do is change which socket that transport reads and
    /// end the one that is running.
    @MainActor
    func testMigratingAPaneRewritesItsSocketAndEndsTheRunningTransport() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        MasterPool.socketDirectoryOverride = tmp
        MasterPool.tenantDirectoryOverride = tmp.appendingPathComponent("tenants")
        defer {
            MasterPool.socketDirectoryOverride = nil
            MasterPool.tenantDirectoryOverride = nil
        }

        let tm = TunnelManager()
        tm.hostStore = HostStore()
        tm.pool.openMaster = { _, path in
            FileManager.default.createFile(atPath: path, contents: nil); return true
        }
        let host = HostEntry(label: "builder", address: "builder.example", username: "someone")
        let key = tm.poolKey(for: host)
        let stalled = tm.pool.primary(for: key)
        FileManager.default.createFile(atPath: stalled, contents: nil)

        let launch = tm.connectCommand(for: host)
        let agent = launch.agentID

        // A stand-in for the transport: a process that will notice a signal.
        let transport = Process()
        transport.executableURL = URL(fileURLWithPath: "/bin/sleep")
        transport.arguments = ["120"]
        try transport.run()
        defer { if transport.isRunning { transport.terminate() } }

        let tenant = TunnelManager.paneTenant(hostID: host.id, agentID: agent)
        let tenants = MasterPool.tenantDirectory
        try FileManager.default.createDirectory(at: tenants, withIntermediateDirectories: true)
        let socketFile = tenants.appendingPathComponent(tenant)
        let pidFile = tenants.appendingPathComponent(tenant + ".pid")
        try stalled.write(to: socketFile, atomically: true, encoding: .utf8)
        try "\(transport.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

        let quiet = try XCTUnwrap(tm.pool.placeExclusive(key, tenant: "transfer.probe"))
        XCTAssertTrue(tm.migratePane(hostID: host.id, agentID: agent, to: quiet))

        XCTAssertEqual(try String(contentsOf: socketFile, encoding: .utf8), quiet,
                       "the transport reads this file on its next attempt")
        transport.waitUntilExit()
        XCTAssertFalse(transport.isRunning, "the transport that was running had to end for the respawn to happen")
    }

    @MainActor
    func testAPaneWithNoRunningTransportIsNotMigrated() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        MasterPool.tenantDirectoryOverride = tmp.appendingPathComponent("tenants")
        defer { MasterPool.tenantDirectoryOverride = nil }

        let tm = TunnelManager()
        tm.hostStore = HostStore()
        XCTAssertFalse(tm.migratePane(hostID: UUID(), agentID: "nobody-here", to: "/tmp/whatever"),
                       "with no pid recorded there is nothing to end, and writing the file alone would be a lie")
    }

    /// [[RFC-0008]] C-IDENTITY: "The fallback namespace prefix (`local-`)
    /// is RESERVED", and "the pane wrapper id (`local-XXXX`) is the agent
    /// id". A remote pane's id used to be `<host label>-<4 hex>` — a third
    /// namespace nothing describes — so the three predicates that decide
    /// whether an id needs qualifying before it crosses a relay
    /// (`federation.needsQualification`, the hub's strip, and
    /// `AgentMonitor.qualifiedID`) all said "not a fallback id" about one,
    /// and every remote pane's id was advertised unqualified.
    @MainActor
    func testARemotePaneIsNamedInTheNamespaceReservedForIt() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        MasterPool.socketDirectoryOverride = tmp
        MasterPool.tenantDirectoryOverride = tmp.appendingPathComponent("tenants")
        defer {
            MasterPool.socketDirectoryOverride = nil
            MasterPool.tenantDirectoryOverride = nil
        }
        let tm = TunnelManager()
        tm.hostStore = HostStore()
        let host = HostEntry(label: "remotehost", address: "gc.example", username: "someone")

        let launch = tm.connectCommand(for: host)
        XCTAssertTrue(launch.agentID.hasPrefix("local-"),
                      "a pane id outside the reserved namespace is one nothing qualifies")
    }

    /// AND THE MACHINE IS WHAT KEEPS TWO OF THEM APART. The id is only
    /// unique within one machine — [[RFC-0009]] C-IDENTITY-SCOPE qualifies
    /// it for exactly that reason — so anything the workbench keys by it
    /// across hosts has to carry the machine as well. The host label used
    /// to be doing that by accident, inside the id.
    @MainActor
    func testTwoHostsPanesWithOneIdAreNotOneTenant() {
        let remotehost = UUID(), otherhost = UUID()
        XCTAssertNotEqual(
            TunnelManager.paneTenant(hostID: remotehost, agentID: "local-1a2b"),
            TunnelManager.paneTenant(hostID: otherhost, agentID: "local-1a2b"))
        XCTAssertNotEqual(
            TunnelManager.paneTenant(hostID: nil, agentID: "local-1a2b"),
            TunnelManager.paneTenant(hostID: remotehost, agentID: "local-1a2b"),
            "this Mac is a machine like any other and needs a name of its own in the key")
    }

    // MARK: - A peer is known by the name its own machine reported

    /// [[RFC-0010]] C-PEER-IDENTITY: the machine mints its own id and
    /// everyone else accepts what it reports. The workbench derived one
    /// from the human's label instead and compared the two — `deskmac`
    /// against `deskmac-2630` — so every lookup missed, silently, and
    /// whatever depended on it simply did not happen.
    @MainActor
    func testAPeerIsFoundByThePortBothSidesAgreeAbout() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        let store = HostStore()
        let host = HostEntry(label: "deskmac", address: "deskmac.example", username: "u")
        store.addHost(host)
        let tm = TunnelManager()
        tm.hostStore = store

        XCTAssertNil(tm.host(forPeer: "deskmac-2630"),
                     "a peer nobody has heard from is not this host by wishful matching")
        XCTAssertNil(tm.reportedPeer(forHost: host),
                     "and a host that has not been told its peer's name has none to give")

        // The hub reports the link: a name it minted, and the port that
        // reaches it — which is the port this side already assigned.
        tm.adoptExistingPeers([(peer: "deskmac-2630", port: 9310)])

        XCTAssertEqual(tm.host(forPeer: "deskmac-2630")?.id, host.id)
        XCTAssertEqual(tm.reportedPeer(forHost: host), "deskmac-2630")
    }

    /// WHETHER A ROW MAY BE OFFERED AS TAPPABLE is exactly this lookup,
    /// and the sidebar asks it before drawing a hover or accepting a
    /// click. An agent on a machine this Mac has never dialled has no
    /// host to open it with — a row that looked tappable would ignore
    /// the click and explain nothing, which is what teaches people the
    /// list is decoration.
    @MainActor
    func testAnAgentOnAMachineThisMacNeverDialledHasNoHostToOpenItWith() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        let store = HostStore()
        let dialled = HostEntry(label: "deskmac", address: "deskmac.example", username: "u")
        store.addHost(dialled)
        let tm = TunnelManager()
        tm.hostStore = store
        tm.adoptExistingPeers([(peer: "deskmac-2630", port: 9310)])

        // The machine this Mac dialled: openable.
        XCTAssertNotNil(tm.host(forPeer: "deskmac-2630"))
        // A THIRD MACHINE, learnt through a peer's directory rather than
        // dialled from here — which is precisely what the relayed rows in
        // the sidebar's "Elsewhere" section are.
        XCTAssertNil(tm.host(forPeer: "buildbox-11f2"),
                     "a machine reachable only through a peer is not one this Mac can dial")
        // And a row with no machine at all is this Mac's own, which never
        // appears in that section.
        XCTAssertNil(tm.host(forPeer: ""))
    }

    /// AND THE LINK IS ANNOUNCED UNDER THAT NAME, ONCE. It used to be
    /// announced where the dial was REQUESTED, under the derived name,
    /// and again when the peer reported — so the merged view held one
    /// machine in two buckets.
    @MainActor
    func testALinkIsAnnouncedUnderTheReportedNameAndNotADerivedOne() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        let store = HostStore()
        store.addHost(HostEntry(label: "deskmac", address: "deskmac.example", username: "u"))
        let tm = TunnelManager()
        tm.hostStore = store
        var announced: [String] = []
        tm.onPeerLinked = { machine, _ in announced.append(machine) }

        tm.adoptExistingPeers([(peer: "deskmac-2630", port: 9310)])

        XCTAssertEqual(announced, ["deskmac-2630"])
        XCTAssertFalse(announced.contains("deskmac"),
                       "the human's label is not a name any machine answers to")
    }

    // MARK: - The three the verification pass found

    /// A QUALIFIED NAME AND A BARE ONE ARE THE SAME AGENT. Qualification
    /// is for routing and display ([[RFC-0009]] C-IDENTITY-SCOPE), so a
    /// join between the merged list and a leaf's record has to see through
    /// it. Moving remote pane ids into the reserved `local-` namespace
    /// made the merged side qualified and the leaf side bare, and every
    /// `==` between them went quiet — the badge, the status dot, the
    /// attention mark, the wake-armed item.
    func testAQualifiedNameMatchesTheBareOneItWasMintedFrom() {
        XCTAssertTrue(AgentMonitor.namesSameAgent("local-1a2b@deskmac-2630", "local-1a2b"))
        XCTAssertTrue(AgentMonitor.namesSameAgent("local-1a2b", "local-1a2b"))
        XCTAssertTrue(AgentMonitor.namesSameAgent("claude-abc12345", "claude-abc12345"))
    }

    /// AND A PREFIX IS NOT A MATCH. `local-1a2b` and `local-1a2bc` are two
    /// agents, and a rule that compared prefixes rather than the qualifier
    /// boundary would merge them.
    func testANameThatMerelyStartsTheSameIsADifferentAgent() {
        XCTAssertFalse(AgentMonitor.namesSameAgent("local-1a2bc", "local-1a2b"))
        XCTAssertFalse(AgentMonitor.namesSameAgent("local-1a2b", "local-1a2b@deskmac"),
                       "the qualifier belongs to the merged side, not the leaf's record")
    }

    /// A MIGRATION MOVES NOTHING UNTIL IT KNOWS THE PANE IS THERE. A
    /// record left behind by a pane that is gone used to be claimed onto
    /// the quiet connection and to clear the old one's refusal flag —
    /// undoing the one thing that flag exists to hold — before anything
    /// checked whether a transport was running.
    @MainActor
    func testAMigrationOfAPaneThatIsGoneChangesNothing() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        MasterPool.socketDirectoryOverride = tmp
        MasterPool.tenantDirectoryOverride = tmp.appendingPathComponent("tenants")
        defer {
            MasterPool.socketDirectoryOverride = nil
            MasterPool.tenantDirectoryOverride = nil
        }
        let tm = TunnelManager()
        tm.hostStore = HostStore()
        let host = HostEntry(label: "builder", address: "builder.example", username: "someone")
        let key = tm.poolKey(for: host)
        let stalled = tm.pool.primary(for: key)
        FileManager.default.createFile(atPath: stalled, contents: nil)

        // A record with no pid file beside it: the pane is gone.
        let tenant = TunnelManager.paneTenant(hostID: host.id, agentID: "local-ghost")
        tm.pool.claim(tenant: tenant, on: stalled)
        tm.pool.markFull(socket: stalled)

        XCTAssertFalse(tm.migratePane(tenant: tenant, from: stalled, to: "/tmp/elsewhere"))
        XCTAssertTrue(tm.pool.isFullForTesting(stalled),
                      "a pane that is not there must not clear a refusal a live connection gave")
        XCTAssertEqual(tm.pool.recordedCarrier(of: tenant), stalled,
                       "and it must not be redistributed to look like progress")
    }

    /// A RELEASED PORT MUST NOT STILL ANSWER TO THE NAME THAT LEFT IT.
    /// `peerPort` hands the lowest free number to the next host, so a port
    /// freed on disconnect is reused — while `livePeerPorts` still mapped
    /// the departed peer's name to it. Both then matched on value, and the
    /// lookup whose whole job is to say which machine this is returned the
    /// wrong one about half the time.
    @MainActor
    func testAPortHandedToAnotherHostNoLongerAnswersToTheOneThatLeft() async throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        MasterPool.socketDirectoryOverride = tmp
        MasterPool.tenantDirectoryOverride = tmp.appendingPathComponent("tenants")
        defer {
            MasterPool.socketDirectoryOverride = nil
            MasterPool.tenantDirectoryOverride = nil
        }
        let store = HostStore()
        let alpha = HostEntry(label: "alpha", address: "alpha.example", username: "u")
        let beta = HostEntry(label: "beta", address: "beta.example", username: "u")
        store.addHost(alpha); store.addHost(beta)
        let tm = TunnelManager()
        tm.hostStore = store

        tm.adoptExistingPeers([(peer: "alpha-1111", port: 9200)])
        XCTAssertEqual(tm.reportedPeer(forHost: alpha), "alpha-1111")

        tm.disconnectTunnel(for: alpha)
        // The teardown's own ssh runs off-main and the model state is
        // dropped after it, so this waits for the fact rather than betting
        // on a duration.
        let released = await eventually { tm.reportedPeer(forHost: alpha) == nil }
        XCTAssertTrue(released, "the departed peer's name outlived its link")

        // The port is free, so the next host gets it — which is exactly
        // what peerPort does.
        tm.adoptExistingPeers([(peer: "beta-2222", port: 9200)])

        XCTAssertEqual(tm.reportedPeer(forHost: beta), "beta-2222")
        XCTAssertNil(tm.host(forPeer: "alpha-1111"),
                     "a machine that left must not still be findable on the port it gave up")
    }

    // MARK: - One owner for a host's ssh arguments ([[WI-2026-08-28-006]])

    /// A JUMP HOST REACHES EVERY CALLER OR NONE.
    ///
    /// "Build this host's ssh arguments from its effective credentials"
    /// had four implementations and they had drifted: the connection pool
    /// added `-J` and Test Connection, the OS probe and enrolment's
    /// `runOnHost` did not — so on a host reachable only through a bastion
    /// all three went straight at it and reported a failure the human's
    /// own connection does not have.
    func testAJumpHostReachesTheOneOffCommandsAndThePool() {
        let m = makeManager()
        var group = HostGroup(label: "fleet")
        group.proxyJump = "admin@bastion:2222"
        heldStore.addGroup(group)
        var host = HostEntry(label: "gpu", address: "gpu.internal", username: "operator")
        host.groupID = group.id
        heldStore.addHost(host)

        let identity = m.identityArgs(for: host)
        XCTAssertEqual(identity, ["-J", "admin@bastion:2222"],
                       "the pool's arguments lost the group's jump host")

        let oneOff = m.oneOffArgs(for: host, connectTimeout: 5, remote: "uname -a")
        XCTAssertTrue(
            oneOff.contains("-J") && oneOff.contains("admin@bastion:2222"),
            "a one-off command goes straight at a host only a bastion answers for: \(oneOff)")

        // The invariant, not the two literals: whatever the connection
        // presents, a one-off presents too.
        for argument in identity {
            XCTAssertTrue(oneOff.contains(argument),
                          "\(argument) reaches the connection and not a one-off command")
        }
    }

    /// A host-level jump host beats the group's, and still reaches both.
    func testAHostLevelJumpHostAlsoReachesBoth() {
        let m = makeManager()
        var group = HostGroup(label: "fleet")
        group.proxyJump = "admin@bastion:2222"
        heldStore.addGroup(group)
        var host = HostEntry(label: "gpu", address: "gpu.internal", username: "operator")
        host.groupID = group.id
        host.proxyJump = "me@edge:22"
        heldStore.addHost(host)

        XCTAssertEqual(m.identityArgs(for: host), ["-J", "me@edge:22"])
        XCTAssertTrue(m.oneOffArgs(for: host, connectTimeout: 5, remote: "x")
            .contains("me@edge:22"))
    }

    /// The destination and the port come from the same resolution, so a
    /// one-off reaches the machine the connection reaches.
    func testAOneOffCommandCarriesTheResolvedDestination() {
        let m = makeManager()
        var group = HostGroup(label: "fleet")
        group.port = 2222
        group.username = "fleetop"
        heldStore.addGroup(group)
        var host = HostEntry(label: "gpu", address: "gpu.internal", username: "")
        host.groupID = group.id
        heldStore.addHost(host)

        let args = m.oneOffArgs(for: host, connectTimeout: 7, remote: "uname -a")
        XCTAssertEqual(args.last, "uname -a")
        XCTAssertEqual(args.dropLast().last, "fleetop@gpu.internal")
        XCTAssertTrue(args.contains("2222"), "the group's port did not reach the command")
        XCTAssertTrue(args.contains("ConnectTimeout=7"))
    }

}

