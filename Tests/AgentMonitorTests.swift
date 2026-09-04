import XCTest
@testable import Synapty

/// AgentMonitor's pure parsing and merging (WI-2026-08-08-021, and
/// [[WI-2026-08-27-003]] for what left).
///
/// It used to test three STRING shapes — IPC-wrapped, direct hub response,
/// hub envelope — accepted by a parser for the output of `synapty agents`.
/// The workbench stopped spawning that subprocess when [[RFC-0004]]
/// C-SUBSCRIPTION made presence pushed rather than polled, so those tests
/// were green about a parser nothing ran. The rules that were real are
/// kept below, asserted through `applySnapshot`, which is the door the
/// hub's own pushes come in by.
final class AgentMonitorParserTests: XCTestCase {

    /// A ROW WITH NO ID IS SKIPPED, NOT FATAL — through the door that
    /// ships. This rule was real; the parser it used to be asserted
    /// through was not being run.
    @MainActor
    func testARowWithNoIdIsSkippedRatherThanFatal() {
        let m = AgentMonitor()
        m.applySnapshot([
            ["tool": "claude", "project": "p", "session": "s"],
            ["id": "ok-1", "tool": "claude"],
        ])
        XCTAssertEqual(m.agents.count, 1)
        XCTAssertEqual(m.agents.first?.id, "ok-1")
    }
}

// MARK: - [[ADR-0008]] stage 5: merged multi-hub view (WI-2026-08-12-007)

extension AgentMonitorParserTests {

    private func snapshotRow(_ id: String, tool: String = "claude", status: String = "working") -> [String: Any] {
        ["id": id, "tool": tool, "project": "/p", "session": "s", "status": status]
    }

    @MainActor
    func testRemoteAgentsCarryTheirMachineAndLocalOnesDoNot() {
        let m = AgentMonitor()
        m.applySnapshot([snapshotRow("claude-local001")], machine: "")
        m.applySnapshot([snapshotRow("claude-remote01")], machine: "remotehost")

        let local = m.agents.first { $0.id == "claude-local001" }
        let remote = m.agents.first { $0.id == "claude-remote01" }
        XCTAssertEqual(local?.machine, "")
        XCTAssertFalse(local?.isRemote ?? true)
        XCTAssertEqual(remote?.machine, "remotehost")
        XCTAssertTrue(remote?.isRemote ?? false)
        XCTAssertEqual(m.agents.count, 2)
    }

    @MainActor
    func testFallbackIDsFromDifferentMachinesDoNotOverwriteEachOther() {
        // `local-<4 hex>` is machine-scoped and two laptops collide on it
        // routinely. Unqualified, the second snapshot would REPLACE the
        // first in the merged map and one machine's pane would vanish
        // with nothing reporting it.
        let m = AgentMonitor()
        m.applySnapshot([snapshotRow("local-ab12")], machine: "")
        m.applySnapshot([snapshotRow("local-ab12")], machine: "remotehost")

        XCTAssertEqual(m.agents.count, 2)
        XCTAssertTrue(m.agents.contains { $0.id == "local-ab12" && $0.machine == "" })
        XCTAssertTrue(m.agents.contains { $0.id == "local-ab12@remotehost" })

        // A durable id is already globally meaningful — rewriting it would
        // break RFC-0008's hub-state-independent derivation.
        XCTAssertEqual(AgentMonitor.qualifiedID("claude-abc12345", machine: "remotehost"), "claude-abc12345")
        // Idempotent: qualifying twice must not stack separators.
        XCTAssertEqual(AgentMonitor.qualifiedID("local-ab12@remotehost", machine: "other"), "local-ab12@remotehost")
    }

    @MainActor
    func testUnreachableMachineKeepsItsAgentsListedRatherThanDroppingThem() {
        // The rule this pins: missing evidence is never presented as
        // evidence of absence. Dropping the rows would read as "those
        // agents ended"; keeping the last status would be a stale claim
        // indistinguishable from a fresh one. Both are wrong, in opposite
        // directions.
        let m = AgentMonitor()
        m.applySnapshot([snapshotRow("claude-local001")], machine: "")
        m.applySnapshot([snapshotRow("claude-remote01", status: "working")], machine: "remotehost")
        XCTAssertEqual(m.agents.count, 2)

        m.simulatePeerDisconnectForTesting("remotehost")

        XCTAssertEqual(m.agents.count, 2, "an unreachable machine's agents must stay listed")
        let remote = m.agents.first { $0.id == "claude-remote01" }
        XCTAssertEqual(remote?.reachable, false)
        XCTAssertEqual(remote?.status, "unknown", "a frozen last-known status looks identical to a fresh one")

        // The OTHER machine is untouched — one peer going dark must not
        // degrade the view of anything else.
        let local = m.agents.first { $0.id == "claude-local001" }
        XCTAssertEqual(local?.reachable, true)
        XCTAssertEqual(local?.status, "working")
    }

    @MainActor
    func testForgettingAPeerIsDistinctFromLosingIt() {
        // Removing a host is the human saying "this machine is not part of
        // my fleet"; a dropped link is the machine being unreachable. Only
        // the first may remove rows.
        let m = AgentMonitor()
        m.applySnapshot([snapshotRow("claude-remote01")], machine: "remotehost")
        XCTAssertEqual(m.agents.count, 1)
        m.forgetPeer("remotehost")
        XCTAssertEqual(m.agents.count, 0)
    }

    @MainActor
    func testPeerEventsDoNotReachTheLocalRawTap() {
        // Wake injection, resume plans and exec all act on panes THIS
        // workbench owns. Feeding them a peer's events would have them try
        // to type into a terminal on another machine.
        let m = AgentMonitor()
        var tapped: [String] = []
        m.onHubEvent = { payload in
            if let kind = payload["kind"] as? String { tapped.append(kind) }
        }
        m.applyEvent(["kind": "wake_candidate", "agent": "claude-remote01"], machine: "remotehost")
        XCTAssertTrue(tapped.isEmpty, "a peer's wake candidate must not drive this workbench's injector")

        m.applyEvent(["kind": "wake_candidate", "agent": "claude-local001"], machine: "")
        XCTAssertEqual(tapped, ["wake_candidate"])
    }
}

extension AgentMonitorParserTests {

    @MainActor
    func testMergedOrderIsIdentityBasedAndNeverATimeline() {
        // ADR-0008 point 7: event logs are per-machine. Two hubs' sequence
        // numbers are unrelated, so sorting the merged list by generation
        // would synthesise a global timeline that does not exist — a
        // plausible-looking "improvement" that would make the UI assert
        // something false. This pins the decision: order is by identity,
        // stable, and carries no temporal meaning.
        let m = AgentMonitor()
        var high = ["id": "claude-zzz00001", "tool": "claude", "project": "/p", "session": "s"] as [String: Any]
        high["generation"] = 9999
        var low = ["id": "claude-aaa00001", "tool": "claude", "project": "/p", "session": "s"] as [String: Any]
        low["generation"] = 1
        // The remote machine's "later" generation must not float to the top.
        m.applySnapshot([low], machine: "")
        m.applySnapshot([high], machine: "remotehost")

        XCTAssertEqual(m.agents.map(\.id), ["claude-aaa00001", "claude-zzz00001"])

        // And the reverse arrival order produces the SAME arrangement —
        // the view does not encode when this workbench happened to hear
        // about each machine either.
        let m2 = AgentMonitor()
        m2.applySnapshot([high], machine: "remotehost")
        m2.applySnapshot([low], machine: "")
        XCTAssertEqual(m2.agents.map(\.id), m.agents.map(\.id))
    }
}

extension AgentMonitorParserTests {

    /// WI-2026-08-12-012: the count is the HUB's, not the filtered list's.
    /// Reading "0 agents" while the hub held two registrations once sent
    /// the author of that filter hunting a peer-subscription failure that
    /// had not happened.
    @MainActor
    func testCountReportsRegistrationsTheListFiltersOut() {
        let m = AgentMonitor()
        m.applySnapshot([
            ["id": "claude-real0001", "tool": "claude", "project": "/p", "session": "s"],
            ["id": "local-bare01", "tool": "-", "project": "-", "session": "-"],
            ["id": "local-bare02", "tool": "-", "project": "-", "session": "-"],
        ], machine: "")

        // The list still filters — a bare shell is not an agent and should
        // not drown the view.
        XCTAssertEqual(m.agents.count, 1)
        XCTAssertEqual(m.agents.first?.id, "claude-real0001")
        // ...but the number never claims those registrations are absent.
        XCTAssertEqual(m.registeredCount, 3)
    }

    @MainActor
    func testCountSpansMachines() {
        let m = AgentMonitor()
        m.applySnapshot([["id": "local-bare01", "tool": "-", "project": "-", "session": "-"]], machine: "")
        m.applySnapshot([["id": "claude-remote01", "tool": "claude", "project": "/p", "session": "s"]],
                        machine: "remotehost")
        XCTAssertEqual(m.registeredCount, 2)
        XCTAssertEqual(m.agents.count, 1)
    }
}

extension AgentMonitorParserTests {

    /// WI-2026-08-12-017. THE test this RFC exists for: it fails if a
    /// capability-absent unknown reads as an evidence-absent one — the
    /// exact confusion that sent a debugging session into the receiving
    /// side while the receiving side was correct throughout.
    @MainActor
    func testTheThreeCausesOfUnknownAreNotInterchangeable() {
        let m = AgentMonitor()
        m.applySnapshot([
            ["id": "claude-quiet0001", "tool": "claude", "project": "/p", "session": "s",
             "status": "unknown", "unknown_cause": "no_evidence", "peer_reachable": true],
            ["id": "claude-mute00001", "tool": "claude", "project": "/p", "session": "s",
             "status": "unknown", "unknown_cause": "peer_lacks_capability", "peer_reachable": true],
            ["id": "claude-gone00001", "tool": "claude", "project": "/p", "session": "s",
             "status": "unknown", "unknown_cause": "peer_unreachable", "peer_reachable": false],
        ], machine: "remotehost-7f3a")

        let quiet = m.agents.first { $0.id == "claude-quiet0001" }
        let mute = m.agents.first { $0.id == "claude-mute00001" }
        let gone = m.agents.first { $0.id == "claude-gone00001" }

        // no_evidence adds nothing: "the hub has no signal yet" is what
        // `unknown` already means, and annotating it would bury the two
        // cases that carry new information.
        XCTAssertNil(quiet?.unknownExplanation)
        // The two that DO carry information must be distinct sentences.
        XCTAssertNotNil(mute?.unknownExplanation)
        XCTAssertNotNil(gone?.unknownExplanation)
        XCTAssertNotEqual(mute?.unknownExplanation, gone?.unknownExplanation)
        XCTAssertTrue(mute?.unknownExplanation?.contains("build") == true,
                      "a missing capability must read as a property of that machine's SOFTWARE")
    }

    @MainActor
    func testReachabilityComesFromTheHubNotFromAnAssumption() {
        // applySnapshot used to force reachable = true on every row, which
        // would have overwritten exactly the fact the hub computed.
        let m = AgentMonitor()
        m.applySnapshot([
            ["id": "claude-gone00001", "tool": "claude", "project": "/p", "session": "s",
             "status": "unknown", "unknown_cause": "peer_unreachable", "peer_reachable": false],
        ], machine: "remotehost-7f3a")
        XCTAssertEqual(m.agents.first?.reachable, false)
    }

    /// A TOOL REQUEST CROSSES THE SAME BOUNDARY AS EVERYTHING ELSE, and
    /// its requester was the one id that did not get qualified: the tap
    /// fires before the qualification block and returns, so the name
    /// arrived as the far hub knows it. A remote PANE agent is
    /// `local-<4 hex>` — a namespace reserved for ids unique only on the
    /// machine that minted them, where two laptops collide by
    /// construction — so a question from another machine reached the
    /// queue reading like one from a pane on this desk.
    @MainActor
    func testAToolRequestFromAPeerCarriesAQualifiedRequester() {
        let m = AgentMonitor()
        var seen: String?
        m.onToolRequest = { payload, _ in seen = payload["requester"] as? String }
        m.applyEvent([
            "type": "tool_request", "tool": "view.ask", "request_id": "r1",
            "requester": "local-1a2b",
            "args": ["question": "which branch?"],
        ], machine: "deskmac-2630")

        XCTAssertEqual(seen, "local-1a2b@deskmac-2630",
                       "the question named an agent this Mac could also have")
    }

    /// AND A DURABLE ID IS LEFT ALONE, because it is globally meaningful
    /// as it stands ([[RFC-0009]] C-IDENTITY-SCOPE): qualifying it would
    /// rename an identity rather than route it.
    @MainActor
    func testADurableRequesterIsNotRewritten() {
        let m = AgentMonitor()
        var seen: String?
        m.onToolRequest = { payload, _ in seen = payload["requester"] as? String }
        m.applyEvent([
            "type": "tool_request", "tool": "view.ask", "request_id": "r1",
            "requester": "claude-abc12345", "args": [:],
        ], machine: "deskmac-2630")

        XCTAssertEqual(seen, "claude-abc12345")
    }

    /// WHERE AN AGENT IS, FOR A CALLER HOLDING ONLY A NAME. A qualified
    /// id says so itself; a durable one does not, and the merged list is
    /// the only place it is written down.
    @MainActor
    func testTheMachineIsAnswerableFromEitherShapeOfName() {
        let m = AgentMonitor()
        m.applySnapshot([relayedRow(id: "claude-abc12345", peer: "deskmac-2630")])

        XCTAssertEqual(m.machine(ofAgent: "local-1a2b@deskmac-2630"), "deskmac-2630")
        XCTAssertEqual(m.machine(ofAgent: "claude-abc12345"), "deskmac-2630")
        // Empty means this Mac, and is not a guess: nothing claims it.
        XCTAssertEqual(m.machine(ofAgent: "local-9z9z"), "")
    }

    /// WHAT MAY BE HANDED ONWARD AS AN IDENTITY. The merged list's key
    /// carries the qualifier this workbench minted at ITS relay boundary;
    /// the far machine knows the session by the name IT minted, so
    /// `attach --relay --id local-1a2b@deskmac-2630` looks for a session
    /// that machine has never heard of and the human gets a fresh shell
    /// where they expected the agent's.
    ///
    /// AND IT IS REACHABLE THROUGH THE SUBSCRIPTION PATH, which is the
    /// half I first missed. A RELAYED row for a `local-` id is filtered
    /// out — a peer's bare shell panes are not agents — so I concluded
    /// the two sets were disjoint. They are not: a remote pane RUNNING
    /// something arrives over a direct peer subscription WITH metadata,
    /// so `hasMetadata` decides it and `isBarePaneIdentity` is never
    /// consulted. It is qualified, it is listed, and it is tappable.
    @MainActor
    func testAQualifiedPaneAgentIsListedAndTravelsBare() {
        let m = AgentMonitor()
        // The shape a direct subscription to that peer delivers: a pane
        // agent with a tool, which is what makes it an agent at all.
        m.applySnapshot([
            ["id": "local-1a2b", "tool": "claude", "project": "/srv", "session": "s",
             "status": "working", "peer_reachable": true],
        ], machine: "deskmac-2630")

        guard let listed = m.agents.first else { return XCTFail("not listed") }
        XCTAssertEqual(listed.id, "local-1a2b@deskmac-2630", "the key carries the qualifier")
        XCTAssertTrue(listed.isRemote)
        // AND THE NAME THAT TRAVELS IS THE BARE ONE.
        XCTAssertEqual(listed.bareID, "local-1a2b")

        // A durable id is bare already, so one call is right for both.
        let m2 = AgentMonitor()
        m2.applySnapshot([relayedRow(id: "claude-abc12345")])
        XCTAssertEqual(m2.agents.first?.bareID, "claude-abc12345")
    }

    // MARK: - The relayed row ([[RFC-0009]] C-PRESENCE, C-DIRECTORY)

    /// THE SHAPE THE LOCAL HUB ACTUALLY SENDS for an agent it does not
    /// host: identity, hosting peer, reachability, `remote` — and
    /// tool/project/session present but `-`, because only identity crosses
    /// a relay link ([[RFC-0009]] C-DIRECTORY) and a substituted default
    /// would read as fact.
    ///
    /// TAKEN FROM THE HUB'S OWN OUTPUT, not composed here. The `reachable`
    /// → `peer_reachable` defect was a test hand-authoring a row in a
    /// spelling no hub sent, so these bytes were read off
    /// `buildAgentsArray` (src/hub/handlers.zig, the C-PRESENCE row test's
    /// fixture) rather than written from the clause:
    ///   {"id":"claude-remote01","status":"unknown",
    ///    "unknown_cause":"no_evidence","hosting_peer":"remotehost-4e84",
    ///    "peer_reachable":true,"remote":true}
    ///
    /// TOOL, PROJECT AND SESSION ARE ABSENT, not `"-"`. On a LOCAL row
    /// `"-"` is a fact — that agent registered without a tool — and here
    /// it would mean "the hub has no way to know", which is a different
    /// one. This side must therefore not require them: reading an absent
    /// field as `"-"` collapses the two again, which is fine as a default
    /// and wrong as an assumption about what arrives.
    private func relayedRow(id: String, peer: String = "deskmac-2630",
                            status: String = "waiting") -> [String: Any] {
        ["id": id, "status": status,
         "hosting_peer": peer, "peer_reachable": true, "remote": true]
    }

    /// IT ARRIVED ON EVERY SNAPSHOT AND WAS THROWN AWAY TWICE — once for
    /// having no machine to be placed on, and again by the metadata filter
    /// a relayed row can never satisfy. The hub's own comment says
    /// omitting these rows would leave the workbench "blind to every agent
    /// it does not host — addressable yet invisible", and the workbench
    /// then made them invisible on its own side.
    @MainActor
    func testAnAgentHostedByAPeerIsListedWithItsMachine() {
        let m = AgentMonitor()
        m.applySnapshot([relayedRow(id: "claude-abc12345")])

        guard let agent = m.agents.first(where: { $0.id == "claude-abc12345" }) else {
            return XCTFail("a peer-hosted agent is not readable anywhere")
        }
        XCTAssertEqual(agent.machine, "deskmac-2630")
        XCTAssertTrue(agent.isRemote)
        XCTAssertEqual(agent.status, "waiting")
    }

    /// A CONTESTED IDENTITY NAMES NO PEER — two hubs claim it, so there is
    /// nothing true to put in `hosting_peer` — and `remote` is then the
    /// only thing marking it as somebody else's.
    @MainActor
    func testAContestedIdentityIsStillKnownToBeElsewhere() {
        let m = AgentMonitor()
        m.applySnapshot([
            ["id": "claude-abc12345", "tool": "-", "project": "-", "session": "-",
             "status": "unknown", "unknown_cause": "contested", "remote": true],
        ])
        guard let agent = m.agents.first else { return XCTFail("dropped") }
        XCTAssertTrue(agent.isRemote, "the one field that marks it was the one nothing read")
        XCTAssertEqual(agent.machine, "", "it must not be filed under this machine")
    }

    /// A LOCAL ROW STILL CARRIES `"-"` AND STILL MEANS SOMETHING BY IT,
    /// so the filter that keeps bare panes out of the list must go on
    /// working against the shape a single-hub snapshot has always had.
    @MainActor
    func testALocalRowWithNoMetadataIsStillNotAnAgent() {
        let m = AgentMonitor()
        m.applySnapshot([
            ["id": "local-1a2b", "tool": "-", "project": "-", "session": "-",
             "status": "unknown"],
        ])
        XCTAssertTrue(m.agents.isEmpty, "a bare pane is a registration, not an agent")
    }

    /// A PEER ADVERTISES ITS BARE PANES TOO, and a directory row carries
    /// no tool to tell them apart — so the discriminator is the `local-`
    /// namespace reserved for machine-scoped fallbacks.
    @MainActor
    func testAPeersBareShellPanesAreNotListedAsAgents() {
        let m = AgentMonitor()
        m.applySnapshot([relayedRow(id: "local-1a2b"), relayedRow(id: "claude-abc12345")])
        XCTAssertEqual(m.agents.map(\.bareID), ["claude-abc12345"])
    }

    /// A LOCAL EVENT MUST NOT RE-FILE A PEER'S AGENT. Every event
    /// blanket-stamped the whole list with the subscription's machine and
    /// declared it reachable — a claim about a machine this side never
    /// reached.
    @MainActor
    func testALocalEventLeavesARelayedRowWhereItIs() {
        let m = AgentMonitor()
        m.applySnapshot([relayedRow(id: "claude-abc12345")])
        m.applyEvent(["kind": "agent_registered", "agent": "claude-local0001",
                      "tool": "claude", "project": "/p", "session": "s"])

        let relayed = m.agents.first { $0.id == "claude-abc12345" }
        XCTAssertEqual(relayed?.machine, "deskmac-2630",
                       "one local event filed a peer's agent under this machine")
    }

    /// THE DIRECTORY IS KEPT CURRENT AND WAS READ ONCE. All three
    /// federation event kinds fell into `default: return nil`, so an agent
    /// that appeared, went away, or reached `waiting` after the snapshot
    /// never moved.
    @MainActor
    func testAPeerHostedAgentAppearsAndMovesWithoutAFreshSnapshot() {
        let m = AgentMonitor()
        m.applySnapshot([])
        m.applyEvent(["kind": "directory_identity_added", "agent": "claude-abc12345",
                      "peer": "deskmac-2630"])
        XCTAssertEqual(m.agents.first?.machine, "deskmac-2630")
        XCTAssertEqual(m.agents.first?.status, "unknown", "an add says nothing about state")

        m.applyEvent(["kind": "peer_presence_relayed", "agent": "claude-abc12345",
                      "peer": "deskmac-2630", "new": "waiting"])
        XCTAssertEqual(m.agents.first?.status, "waiting")

        m.applyEvent(["kind": "directory_identity_removed", "agent": "claude-abc12345",
                      "peer": "deskmac-2630"])
        XCTAssertTrue(m.agents.isEmpty)
    }

    /// THE SAME AGENT ARRIVES TWICE — relayed through this hub and again
    /// over a direct subscription to the peer — and which row survived was
    /// Dictionary order, which is to say nondeterministic.
    @MainActor
    func testTheRicherRowWinsWhenAnAgentArrivesBothWays() {
        let m = AgentMonitor()
        m.applySnapshot([relayedRow(id: "claude-abc12345")])
        m.applySnapshot([
            ["id": "claude-abc12345", "tool": "claude", "project": "/p", "session": "s",
             "status": "working", "peer_reachable": true],
        ], machine: "deskmac-2630")

        let rows = m.agents.filter { $0.bareID == "claude-abc12345" }
        XCTAssertEqual(rows.count, 1, "one agent, one row")
        XCTAssertEqual(rows.first?.tool, .claude, "the row with nothing in it won")
        XCTAssertEqual(rows.first?.status, "working")
    }

    @MainActor
    func testAnExplanationOnlyAppliesToUnknown() {
        // A working agent needs no excuse; carrying one would be noise on
        // every row that is fine.
        let m = AgentMonitor()
        m.applySnapshot([
            ["id": "claude-busy00001", "tool": "claude", "project": "/p", "session": "s",
             "status": "working", "unknown_cause": "peer_lacks_capability", "peer_reachable": true],
        ], machine: "remotehost-7f3a")
        XCTAssertNil(m.agents.first?.unknownExplanation)
    }
}

/// A terminal with a shell in it is a REGISTRATION, not an agent.
///
/// The badge counted every registration under a heading reading "Agents",
/// so a window with three shells open announced three agents and then
/// explained on the next line that none of them had agent metadata. The
/// two lines contradicted each other, and the badge is the one people
/// read — which is how someone goes looking for an agent that was never
/// there.
@MainActor
final class AgentCountLabellingTests: XCTestCase {

    func testABarePaneIsARegistrationAndNotAnAgent() {
        let pane = AgentInfo(id: "local-ab12", tool: .unknown, project: "-", session: "-")
        XCTAssertFalse(pane.hasMetadata, "a shell with no tool, project or session is not an agent")

        let agent = AgentInfo(id: "claude-abcd1234", tool: ToolType(from: "claude"),
                              project: "/w/synapty", session: "sync")
        XCTAssertTrue(agent.hasMetadata)
    }

    /// The distinction has to survive each field independently — a pane
    /// that picked up a project but no tool is still a pane.
    func testAnyOneFieldIsEnoughToBeAnAgent() {
        XCTAssertTrue(AgentInfo(id: "x", tool: ToolType(from: "codex"), project: "-", session: "-").hasMetadata)
        XCTAssertTrue(AgentInfo(id: "x", tool: .unknown, project: "/w", session: "-").hasMetadata)
        XCTAssertTrue(AgentInfo(id: "x", tool: .unknown, project: "-", session: "s").hasMetadata)
        XCTAssertFalse(AgentInfo(id: "x", tool: .unknown, project: "-", session: "-").hasMetadata)
    }
}

/// THE CHIP COUNTS AGENTS, SO THE POPOVER LISTS AGENTS
/// ([[WI-2026-08-29-003]]).
///
/// "Hub: 6 agents" is a count and therefore an invitation; it used to open
/// a problem list that never mentioned an agent. The sidebar does not
/// answer it either — it shows workspaces, and under Elsewhere only the
/// remote agents no pane here is showing.
@MainActor
final class HubAgentListTests: XCTestCase {

    private func agent(_ id: String, machine: String = "") -> AgentInfo {
        var info = AgentInfo(id: id, tool: .claude,
                             project: "", session: "")
        info.machine = machine
        return info
    }

    /// A FIXED ORDER: this machine first, then by machine and name. A list
    /// that reorders itself between two looks is one nobody can read.
    func testThisMachineComesFirstAndTheRestAreOrdered() {
        let sorted = HubStatusPopover.registered([
            agent("zeta", machine: "builder"),
            agent("beta"),
            agent("alpha", machine: "builder"),
            agent("gamma", machine: "atlas"),
            agent("alpha"),
        ])

        XCTAssertEqual(sorted.map(\.bareID), ["alpha", "beta", "gamma", "alpha", "zeta"])
        XCTAssertEqual(sorted.map(\.machine), ["", "", "atlas", "builder", "builder"])
    }

    /// AND EVERY AGENT THE CHIP COUNTS IS IN IT. The count and the list
    /// read the same array; nothing filters between them, which is the
    /// whole of the fix.
    func testTheListHoldsEveryAgentTheChipCounts() {
        let agents = [agent("a"), agent("b", machine: "builder"), agent("c")]
        XCTAssertEqual(HubStatusPopover.registered(agents).count, agents.count)
    }
}

/// ONE RULE FOR WHAT COUNTS AS AN AGENT, AND ONE PLACE THAT APPLIES IT
/// ([[AgentInfo.isAgent]], [[WI-2026-08-30-002]]).
///
/// A pane registers for routing before anything in it has said what it is,
/// so a plain shell arrives as a row with no tool, no project and no
/// session. The list pruned those on the snapshot path and appended them
/// on the event path; of the surfaces reading the list, the tab bar
/// filtered them out, the workspace sidebar drew them as an agent with a
/// question mark for a tool, and the hub popover listed them.
@MainActor
final class BarePaneRegistrationTests: XCTestCase {

    private func registered(_ id: String, tool: String? = nil,
                            project: String? = nil, session: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["kind": "agent_registered", "agent": id]
        if let tool { payload["tool"] = tool }
        if let project { payload["project"] = project }
        if let session { payload["session"] = session }
        return payload
    }

    func testAnEventForABareRegistrationAddsNoAgent() {
        let monitor = AgentMonitor()
        monitor.applyEvent(registered("local-ab12"))
        XCTAssertTrue(monitor.agents.isEmpty,
                      "a shell that registered for routing was listed as an agent")
    }

    /// AND THE ROW APPEARS THE MOMENT IT SAYS WHAT IT IS. The metadata
    /// arrives as a second registration, so dropping the first must not
    /// cost the agent its row.
    func testTheSameIdBecomesAnAgentWhenItNamesItself() {
        let monitor = AgentMonitor()
        monitor.applyEvent(registered("local-ab12"))
        monitor.applyEvent(registered("local-ab12", tool: "claude"))

        XCTAssertEqual(monitor.agents.count, 1)
        XCTAssertEqual(monitor.agents.first?.tool, ToolType(from: "claude"))
    }

    /// A row that named itself is not un-named by a later bare
    /// registration — the upsert already refuses to clobber, and dropping
    /// bare rows must not turn that into a deletion.
    func testABareRegistrationDoesNotUnmakeAnAgent() {
        let monitor = AgentMonitor()
        monitor.applyEvent(registered("local-ab12", tool: "claude"))
        monitor.applyEvent(registered("local-ab12"))

        XCTAssertEqual(monitor.agents.count, 1)
        XCTAssertEqual(monitor.agents.first?.tool, ToolType(from: "claude"))
    }

    /// Any one field is enough, so a pane that picked up a project without
    /// a tool is an agent and keeps its row.
    func testAProjectAloneIsEnoughToBeListed() {
        let monitor = AgentMonitor()
        monitor.applyEvent(registered("local-ab12", project: "/w/synapty"))
        XCTAssertEqual(monitor.agents.count, 1)
    }
}

/// EVERY CAUSE IS ATTRIBUTED, AND A NEW ONE CANNOT SLIP PAST
/// ([[RFC-0010]] C-DIAGNOSABILITY, [[WI-2026-08-30-008]]).
///
/// The carrier was a `String?` read through a switch with a `default:`, so
/// `contested` — added on the Zig side with its own argument for why a
/// fourth CAUSE beats a fifth STATUS — arrived and fell into the default.
/// The GUI showed a bare unknown with no reason, which is the presentation
/// the clause exists to forbid.
@MainActor
final class UnknownCauseAttributionTests: XCTestCase {

    private func agent(_ cause: AgentInfo.UnknownCause?) -> AgentInfo {
        var info = AgentInfo(id: "a", tool: ToolType(from: "claude"),
                             project: "-", session: "-")
        info.status = "unknown"
        info.unknownCause = cause
        return info
    }


    /// A cause that names a missing capability or an unreachable machine
    /// says which; `no_evidence` is not a missing capability, so it has
    /// nothing to add to the word the status already carries.
    func testEveryCauseThatNamesSomethingSaysIt() {
        for cause in [AgentInfo.UnknownCause.peerLacksCapability, .peerUnreachable, .contested] {
            XCTAssertNotNil(agent(cause).unknownExplanation, "\(cause) was not attributed")
        }
        XCTAssertNil(agent(.noEvidence).unknownExplanation)
        XCTAssertNil(agent(nil).unknownExplanation)
    }

    /// THE SENTENCE HAS ONE OWNER, so a surface showing the status shows
    /// the reason with it rather than each one deciding.
    func testTheStatusPhraseCarriesTheReason() {
        XCTAssertEqual(agent(nil).statusPhrase, "unknown")
        XCTAssertTrue(agent(.peerUnreachable).statusPhrase.hasPrefix("unknown — "))
        XCTAssertTrue(agent(.contested).statusPhrase.contains("claim this name"))
    }

    /// The wire spellings are the ones the hub writes.
    func testTheCausesSpellThemselvesTheWayTheWireDoes() {
        XCTAssertEqual(AgentInfo.UnknownCause(rawValue: "peer_lacks_capability"), .peerLacksCapability)
        XCTAssertEqual(AgentInfo.UnknownCause(rawValue: "no_evidence"), .noEvidence)
        XCTAssertEqual(AgentInfo.UnknownCause(rawValue: "contested"), .contested)
        XCTAssertNil(AgentInfo.UnknownCause(rawValue: "invented"))
    }
}
