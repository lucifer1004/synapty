import Foundation
import SwiftUI
import os

// MARK: - Data Models per [[RFC-0008]] C-REGISTRATION (what a registration carries)

/// Open tool identity (WI-2026-08-11-004): the wire carries tool as a
/// free string ([[RFC-0008]] C-REGISTRATION), so ANY CLI can register. Known
/// tools get bespoke presentation; unrecognized tools keep their name
/// and degrade gracefully — generic glyph, name-derived stable accent,
/// and no passive detection unless a manifest exists for them.
struct ToolType: Equatable, Hashable {
    /// Normalized (trimmed, lowercased) tool name; "unknown" when absent.
    let name: String

    init(from string: String) {
        let trimmed = string
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        name = (trimmed.isEmpty || trimmed == "-") ? "unknown" : trimmed
    }

    static let claude = ToolType(from: "claude")
    static let codex = ToolType(from: "codex")
    static let gemini = ToolType(from: "gemini")
    static let human = ToolType(from: "human")
    static let unknown = ToolType(from: "unknown")

    /// Wire/manifest lookup key (name kept from the enum era).
    var rawValue: String { name }

    var sfSymbol: String {
        switch name {
        case "claude": return "cpu"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "gemini": return "sparkles"
        case "human": return "person.fill"
        case "unknown": return "questionmark.circle"
        default: return "terminal"
        }
    }

    var accentColor: Color {
        switch name {
        case "claude": return Color(red: 0.8, green: 0.5, blue: 0.3)
        case "codex": return Color(red: 0.2, green: 0.6, blue: 0.9)
        case "gemini": return Color(red: 0.3, green: 0.7, blue: 0.5)
        case "human", "unknown": return .secondary
        default:
            // Deterministic hue from the name (FNV-1a; hashValue is
            // per-launch-seeded) so an unrecognized tool is stable and
            // distinguishable without a bespoke palette entry.
            var h: UInt32 = 2_166_136_261
            for byte in name.utf8 { h = (h ^ UInt32(byte)) &* 16_777_619 }
            return Color(
                hue: Double(h % 360) / 360.0, saturation: 0.55, brightness: 0.75)
        }
    }

    var displayName: String {
        switch name {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "human": return "Human"
        case "unknown": return "Agent"
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

struct AgentInfo: Identifiable, Equatable {
    /// var, not let: a remote fallback id is QUALIFIED at ingest
    /// ([[RFC-0009]] C-IDENTITY-SCOPE) so two machines' `local-<4 hex>`
    /// panes cannot overwrite each other in the merged list.
    var id: String
    var tool: ToolType
    var project: String
    var session: String
    /// Merged presence state per [[RFC-0004]] C-VOCABULARY: "working" |
    /// "waiting" | "done" | "idle" | "unknown". Unrecognized wire values
    /// are presented as unknown (forward compatibility).
    var status: String = "unknown"
    /// Registration generation (RFC-0004 C-WAIT): the seq of the event
    /// that created the registration. The passive detector scopes its
    /// classification memory to this (a pane's new occupant is always a
    /// fresh edge).
    var generation: UInt64 = 0
    /// [[RFC-0009]] C-PRESENCE: which MACHINE hosts this agent. Empty means
    /// this one. Never decoration — a local status is backed by evidence
    /// this machine can re-check right now, and a relayed one is a report
    /// that was true when the peer sent it. Generations are per-hub, so
    /// identity-continuity is keyed on (machine, generation) and NEVER on
    /// generation alone: two hubs' sequence spaces are unrelated, so a
    /// comparison between them is meaningless even where it type-checks.
    var machine: String = ""
    /// False when the machine hosting this agent is unreachable. The agent
    /// is still LISTED — missing evidence is never presented as evidence of
    /// absence, and dropping it would read as "that agent is gone".
    var reachable: Bool = true

    /// THE IDENTITY, WITHOUT THE ROUTING QUALIFIER. [[RFC-0009]]
    /// C-IDENTITY-SCOPE: "QUALIFICATION IS AN ENCODING AT THE RELAY
    /// BOUNDARY, NOT A RENAME... a peer-qualified id is
    /// configuration-dependent, so it MUST NOT become the identity the
    /// agent holds."
    ///
    /// `id` is the merged list's KEY and carries the qualifier, because
    /// two machines' fallback ids collide by construction and the merged
    /// list has to hold both. Anything that hands the name onward as an
    /// identity — to a leaf, to `run --id`, into a persistent artifact —
    /// wants this one. The workbench had the qualify half of that clause
    /// and none of the strip half, so the qualified string WAS the
    /// identity everywhere it travelled.
    var bareID: String { AgentMonitor.bareID(of: id) }
    /// [[RFC-0010]] C-DIAGNOSABILITY: WHY the status is `unknown`. Three
    /// facts about three different things — the agent (`no_evidence`), the
    /// link (`peer_unreachable`), and the peer's SOFTWARE
    /// (`peer_lacks_capability`) — and reading the third as the first is
    /// what made a missing feature look like a broken one.
    /// WHY A STATUS IS UNKNOWN, in the vocabulary [[protocol.UnknownCause]]
    /// defines and the hub writes onto presence rows.
    ///
    /// AN ENUM, so the compiler owns the mapping. This was a `String?` read
    /// through a `switch` with a `default:`, so `contested` — added on the
    /// Zig side with its own reasoning about why a fourth CAUSE beats a
    /// fifth STATUS — arrived here and fell into the default, and the GUI
    /// showed a bare unknown with no reason. That is the presentation
    /// [[RFC-0010]] C-DIAGNOSABILITY exists to forbid, and a string could
    /// swallow a fifth cause exactly the same way
    /// ([[WI-2026-08-30-008]]).
    enum UnknownCause: String {
        case noEvidence = "no_evidence"
        case peerUnreachable = "peer_unreachable"
        case peerLacksCapability = "peer_lacks_capability"
        case contested
    }

    var unknownCause: UnknownCause? = nil

    /// THIS HUB DID NOT OBSERVE THIS ROW ITSELF ([[RFC-0009]] C-PRESENCE:
    /// "a row this hub did not observe itself is marked `remote`, and that
    /// is what tells a relayed row from a local one when the other two
    /// fields are absent on both"). They ARE absent on both for a
    /// CONTESTED identity, which has no single hosting peer to name — so
    /// this flag is the only discriminator that works in every case, and
    /// it was the one field nothing read.
    var relayed = false

    var isRemote: Bool { !machine.isEmpty || relayed }

    /// A RELAYED ROW FOR A BARE PANE IS NOT AN AGENT. A directory entry
    /// carries identity and nothing else ([[RFC-0009]] C-DIRECTORY), so a
    /// peer's plain shell panes arrive looking exactly like its agents.
    /// The `local-` namespace [[RFC-0008]] C-IDENTITY reserves for
    /// machine-scoped fallbacks is what tells them apart — the same test
    /// the hub uses to decide a name needs qualifying at all.
    var isBarePaneIdentity: Bool { bareID.hasPrefix("local-") }

    /// THE STATUS VOCABULARY IS RFC-0004 C-VOCABULARY'S, and nothing in
    /// the app gave it a colour: an agent's state reached a human only as
    /// an attention pulse on a pane they could already see. `waiting` is
    /// the one that wants a human, so it wears the same warning colour the
    /// attention dot does.
    var statusColor: Color {
        switch status {
        case "waiting": return DS.warning
        case "working": return DS.success
        case "done": return DS.info
        default: return DS.textTertiary
        }
    }

    /// A short human sentence for an unknown status, or nil when the
    /// status speaks for itself. Nil for `no_evidence` deliberately: "the
    /// hub has no signal yet" is what `unknown` already means, and
    /// annotating it would bury the two cases that carry new information.
    var unknownExplanation: String? {
        guard status == "unknown", let unknownCause else { return nil }
        switch unknownCause {
        case .peerLacksCapability: return "this machine's build does not report status"
        case .peerUnreachable: return "machine unreachable"
        case .contested: return "two machines claim this name, so it is addressed by nobody"
        // NOTHING TO ATTRIBUTE. `no_evidence` is not a capability that is
        // missing; it is a status nobody has reported yet, which the
        // status itself already says.
        case .noEvidence: return nil
        }
    }

    /// THE STATUS AND, WHERE THERE IS ONE, WHY IT IS UNKNOWN.
    ///
    /// [[RFC-0010]] C-DIAGNOSABILITY: "every surface that would otherwise
    /// report the behaviour's absence MUST attribute it". Four surfaces
    /// ghost an agent whose status is unknown; three joined the status and
    /// the reason themselves and the fourth showed the status alone, so a
    /// pane tab said `Claude · unknown` about a machine whose build simply
    /// does not report status ([[WI-2026-08-30-008]]).
    var statusPhrase: String {
        guard let why = unknownExplanation else { return status }
        return "\(status) — \(why)"
    }

    var hasMetadata: Bool {
        tool != .unknown || project != "-" || session != "-"
    }

    /// WHETHER THIS ROW IS AN AGENT AT ALL, as opposed to a shell that
    /// registered so the hub could reach it.
    ///
    /// A pane registers for ROUTING before anything in it has said what it
    /// is — the first registration carries no metadata and the update that
    /// follows does — so every plain shell spends its life as a row with
    /// no tool, no project and no session. Drawn as an agent it becomes a
    /// question mark beside a workspace that has no agent in it, which is
    /// what a human asked about.
    ///
    /// A RELAYED ROW HAS NO METADATA BY CONSTRUCTION and is still an
    /// agent; the machine-scoped fallback id is what tells a bare pane
    /// from one.
    ///
    /// ONE OWNER, because this was decided in three places and only one of
    /// them decided it: the list pruned bare rows on the snapshot path
    /// while the event path appended them, the tab bar filtered them out,
    /// and the sidebar drew them.
    var isAgent: Bool {
        hasMetadata || (relayed && !isBarePaneIdentity)
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID = UUID()
    let from: String
    let channel: String?
    let text: String
    let timestamp: Date

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - AgentMonitor

@MainActor @Observable final class AgentMonitor {
    var agents: [AgentInfo] = []
    var messages: [ChatMessage] = []
    /// Agent IDs that need human attention (e.g., bell rang).
    var needsAttention: Set<String> = []
    /// True while the event subscription is attached (snapshot received).
    private(set) var hubConnected = false
    /// Every registration the hubs report, INCLUDING the ones `agents`
    /// filters out for lacking metadata (WI-2026-08-12-012). The list is
    /// filtered on purpose — a bare shell pane is not an agent and should
    /// not drown the view — but a number labelled "agents" must never
    /// contradict what the hub itself reports. Reading "0" while the hub
    /// held two registrations once sent the author of that filter looking
    /// for a peer-subscription failure that had not happened.
    private(set) var registeredCount = 0

    // MARK: - Event subscription (RFC-0004 C-SUBSCRIPTION)

    // Presence is PUSHED by the hub — the 5s `synapty agents` subprocess
    // poll is retired (RFC-0003 C-EVENTS amendment). The only timer left
    // is the reconnect backoff, which re-attaches the stream after a hub
    // restart; it never lists agents.

    private var client: HubEventClient?
    private var reconnectTask: Task<Void, Never>?
    private var monitoring = false
    private var port: Int = 9000
    /// Told whenever the hub stream drops. Reconnecting stays here; whether
    /// the hub is GONE is the owner's question ([[WI-2026-09-02-029]]),
    /// answered by probing the port, not by the stream closing.
    var onHubDisconnect: (() -> Void)?

    // MARK: - Peer hubs ([[ADR-0008]] stage 5, WI-2026-08-12-007)
    //
    // The workbench subscribes to EACH reachable peer hub directly, not
    // only to its own. It has to: RFC-0009 C-DIRECTORY carries identity,
    // hosting peer and reachability across a relay link and NOTHING else,
    // so the local hub can tell us a remote agent exists but not what tool
    // it runs, what it is working on, or when its status changed. Those
    // live in the peer's own event log, and the workbench is the party
    // holding the tunnels that reach it.
    //
    // ORDERING, stated rather than implied: each hub's log is totally
    // ordered within itself and the merged view has NO order across hubs.
    // Sequence numbers from different machines are unrelated, so this
    // deliberately does not sort by them or synthesise a global timeline.

    private var peerClients: [String: HubEventClient] = [:]
    private var peerPorts: [String: Int] = [:]
    private var peerReconnects: [String: Task<Void, Never>] = [:]
    /// Per-machine agent lists, keyed by machine ("" = this one). Kept
    /// separate so a peer going dark marks ITS agents unreachable without
    /// touching anyone else's.
    private var byMachine: [String: [AgentInfo]] = [:]

    func startMonitoring(port: Int) {
        self.port = port
        monitoring = true
        reconnectTask?.cancel()
        client?.stop()
        connect()
    }

    func stopMonitoring() {
        monitoring = false
        reconnectTask?.cancel()
        reconnectTask = nil
        client?.stop()
        client = nil
        hubConnected = false
        for machine in Array(peerClients.keys) { detachPeer(machine) }
    }

    private func connect() {
        guard monitoring else { return }
        let c = HubEventClient(port: port)
        c.onSnapshot = { [weak self] dicts in
            self?.hubConnected = true
            self?.applySnapshot(dicts)
        }
        c.onEvent = { [weak self] payload in
            self?.applyEvent(payload)
        }
        c.onDisconnect = { [weak self] in
            self?.handleDisconnect()
        }
        client = c
        c.start()
    }

    private func handleDisconnect() {
        guard monitoring else { return }
        client = nil
        hubConnected = false
        onHubDisconnect?()
        // Same honesty rule as a peer going dark: the agents are not
        // dropped, they are marked unobservable.
        if var list = byMachine[""] {
            for i in list.indices {
                list[i].reachable = false
                list[i].status = "unknown"
            }
            byMachine[""] = list
            publishMerged()
        }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    // MARK: - Applying snapshot + events


    func applySnapshot(_ dicts: [[String: Any]], machine: String = "") {
        var infos = Self.agentInfos(from: dicts)
        for i in infos.indices {
            // THE ROW'S OWN ANSWER WINS. A snapshot from THIS hub carries
            // relayed rows whose hosting peer is a third machine, and
            // stamping the subscription's name over it would file every
            // one of them under whoever happened to send the snapshot.
            if infos[i].machine.isEmpty { infos[i].machine = machine }
            infos[i].id = Self.qualifiedID(infos[i].id, machine: infos[i].machine)
        }
        byMachine[machine] = infos
        publishMerged()
    }

    /// RFC-0008 identity upgrade hook: (oldPaneID, durableID). Wired by
    /// ContentView to WorkspaceManager.remapLeafAgent so the pane
    /// association — and with it passive detection and badges — follows
    /// the rename instead of going stale.
    var onIdentityUpgraded: ((String, String) -> Void)?

    /// Raw event tap for consumers beyond presence (RFC-0005 wake:
    /// wake_candidate/wake_cancelled intake, status edges for the gate
    /// and the ack watch). Fires for EVERY pushed event, before the
    /// presence merge.
    var onHubEvent: (([String: Any]) -> Void)?

    /// A forwarded tool_request, with the port of the hub that sent it.
    ///
    /// SEPARATE FROM `onHubEvent` BECAUSE THE LOCALITY RULE DOES NOT APPLY
    /// TO IT. Wake injection, resume plans and exec act on panes this
    /// workbench owns, so feeding them a peer's events would have them
    /// type into another machine's terminals — RFC-0009 C-WAKE-LOCALITY
    /// draws that line and it is right. A tool request is the opposite
    /// case: an agent on a remote host asking the workbench to move a
    /// file or show a page is asking the only party that can, and
    /// withholding it made the whole presentation plane silently
    /// unavailable from every remote machine.
    ///
    /// THE PORT TRAVELS WITH IT because the answer has to go back to the
    /// hub that is holding the request parked. Replying to the local hub
    /// instead drops the receipt ("requester gone") and leaves the agent
    /// blocked forever.
    var onToolRequest: (([String: Any], Int) -> Void)?


    func applyEvent(_ payload: [String: Any], machine: String = "") {
        // The raw tap is LOCAL-ONLY. Wake injection, resume plans and exec
        // all act on panes this workbench owns; feeding them a peer's
        // events would have them try to type into terminals on another
        // machine — RFC-0009 C-WAKE-LOCALITY draws exactly this line.
        // Tool requests first, and from EVERY machine: see onToolRequest.
        if let type = payload["type"] as? String, type == "tool_request" {
            let replyPort = machine.isEmpty ? port : (peerPorts[machine] ?? port)
            // QUALIFIED, LIKE EVERY OTHER ID THAT CROSSES THE BOUNDARY
            // ([[RFC-0009]] C-IDENTITY-SCOPE). This tap returns before the
            // qualification below, so the requester arrived as the far
            // hub knows it — and a remote PANE agent is `local-<4 hex>`,
            // a namespace RFC-0008 C-IDENTITY reserves for ids that are
            // only unique on the machine that minted them. Two laptops
            // collide there by construction, which is why the qualifier
            // exists.
            //
            // THE HUMAN IS THE ONE WHO PAYS. A `view.ask` from a remote
            // pane reached the question queue reading `local-1a2b is
            // waiting on this` — a name this Mac can also have — so the
            // row named an agent the human could not tell from one of
            // their own, on the surface that exists to make them act.
            //
            // The machine was in hand HERE and thrown away one line
            // later: it picked the reply port and went no further.
            var scoped = payload
            if !machine.isEmpty, let who = payload["requester"] as? String {
                scoped["requester"] = Self.qualifiedID(who, machine: machine)
            }
            onToolRequest?(scoped, replyPort)
            return
        }
        if machine.isEmpty { onHubEvent?(payload) }
        if machine.isEmpty, let kind = payload["kind"] as? String, kind == "identity_upgraded",
           let durable = payload["agent"] as? String,
           let old = payload["peer"] as? String
        {
            onIdentityUpgraded?(old, durable)
        }
        var scoped = payload
        if !machine.isEmpty, let id = payload["agent"] as? String {
            scoped["agent"] = Self.qualifiedID(id, machine: machine)
        }
        guard let updated = Self.applying(event: scoped, to: byMachine[machine] ?? []) else { return }
        var tagged = updated
        for i in tagged.indices {
            // NOT ONTO A RELAYED ROW. This blanket-stamped every row in
            // the list on every event, so one local event was enough to
            // file a peer-hosted agent under this machine and declare its
            // link reachable — a claim about a machine this side never
            // reached.
            guard !tagged[i].relayed else { continue }
            tagged[i].machine = machine
            tagged[i].reachable = true
        }
        byMachine[machine] = tagged
        publishMerged()
    }

    /// [[RFC-0009]] C-IDENTITY-SCOPE, applied at the workbench's own
    /// ingest boundary for the same reason the hub applies it at the relay
    /// boundary: a durable id derived from a session UUID is already
    /// globally meaningful, but `local-<4 hex>` is machine-scoped and two
    /// laptops collide on it routinely. Without qualification a remote
    /// pane would silently overwrite a local one of the same name in the
    /// merged list.
    /// Whether a name from the merged list and a name a leaf recorded are
    /// the same agent.
    ///
    /// QUALIFICATION IS FOR ROUTING AND DISPLAY, NOT IDENTITY —
    /// [[RFC-0009]] C-IDENTITY-SCOPE says so — so a join between the two
    /// has to see through it. This did not exist because it did not need
    /// to: a remote pane's id used to be `<host label>-<4 hex>`, which
    /// `qualifiedID` leaves alone, so both sides held the same bare
    /// string. Moving those ids into the `local-` namespace [[RFC-0008]]
    /// C-IDENTITY reserves for them made the merged side qualified and the
    /// leaf side bare, and every `==` between them stopped matching — the
    /// tool badge, the status dot, the attention badge and the wake-armed
    /// menu item all went quiet for remote panes.
    nonisolated static func namesSameAgent(_ merged: String, _ leaf: String) -> Bool {
        merged == leaf || merged.hasPrefix(leaf + "@")
    }

    /// THE IDENTITY WITHOUT THE ROUTING QUALIFIER, and the machine the
    /// qualifier names. The inverse of `qualifiedID`, beside it because a
    /// split that lives apart from the join is a split that stops
    /// agreeing with it.
    nonisolated static func bareID(of id: String) -> String {
        guard let at = id.firstIndex(of: "@") else { return id }
        return String(id[..<at])
    }

    /// nil when the id carries no qualifier — which is most of them: only
    /// the machine-scoped `local-` fallback is qualified ([[RFC-0009]]
    /// C-IDENTITY-SCOPE), because a durable id is globally meaningful as
    /// it stands. A caller that needs the machine for a DURABLE id has to
    /// ask the merged list, not the string.
    nonisolated static func qualifierMachine(of id: String) -> String? {
        guard let at = id.firstIndex(of: "@") else { return nil }
        let rest = id[id.index(after: at)...]
        return rest.isEmpty ? nil : String(rest)
    }

    /// WHERE THIS AGENT IS, for a caller holding only a name. Reads the
    /// qualifier where there is one and the merged list otherwise, which
    /// is the only place a durable remote id's machine is written down.
    /// Empty means this Mac.
    func machine(ofAgent id: String) -> String {
        if let named = Self.qualifierMachine(of: id) { return named }
        return agents.first { Self.namesSameAgent($0.id, id) }?.machine ?? ""
    }

    nonisolated static func qualifiedID(_ id: String, machine: String) -> String {
        guard !machine.isEmpty, id.hasPrefix("local-"), !id.contains("@") else { return id }
        return "\(id)@\(machine)"
    }

    /// Pure event application (unit-testable): returns the new agent list
    /// or nil when the event does not change presence.
    nonisolated static func applying(event payload: [String: Any], to agents: [AgentInfo]) -> [AgentInfo]? {
        guard let kind = payload["kind"] as? String,
              let id = payload["agent"] as? String else { return nil }
        var list = agents
        switch kind {
        case "agent_registered":
            // Upsert; absent metadata fields must NOT clobber known values
            // (the initial routing register carries no metadata — the
            // agent_update that follows does).
            if let idx = list.firstIndex(where: { $0.id == id }) {
                if let tool = payload["tool"] as? String { list[idx].tool = ToolType(from: tool) }
                if let project = payload["project"] as? String { list[idx].project = project }
                if let session = payload["session"] as? String { list[idx].session = session }
                if let gen = payload["generation"] as? Int, gen > 0 { list[idx].generation = UInt64(gen) }
            } else {
                var info = AgentInfo(
                    id: id,
                    tool: ToolType(from: (payload["tool"] as? String) ?? "-"),
                    project: (payload["project"] as? String) ?? "-",
                    session: (payload["session"] as? String) ?? "-"
                )
                if let gen = payload["generation"] as? Int, gen > 0 { info.generation = UInt64(gen) }
                list.append(info)
            }
            return list
        case "agent_status_changed":
            guard let newState = payload["new"] as? String else { return nil }
            if let idx = list.firstIndex(where: { $0.id == id }) {
                list[idx].status = newState
            } else {
                var info = AgentInfo(id: id, tool: .unknown, project: "-", session: "-")
                info.status = newState
                list.append(info)
            }
            return list
        case "agent_unregistered", "directory_identity_removed":
            let pruned = list.filter { $0.id != id }
            return pruned.count == list.count ? nil : pruned
        // THE HUB PUSHES THESE AND NOTHING TOOK THEM. A peer-hosted agent
        // that appeared, went away, or reached `waiting` AFTER the
        // snapshot never moved in the merged list, so the directory the
        // hub keeps current was read exactly once per subscription
        // ([[RFC-0009]] C-PRESENCE).
        case "directory_identity_added":
            guard !list.contains(where: { $0.id == id }) else { return nil }
            // NO STATUS ON AN ADD, and none is invented: the directory
            // learns an identity exists before it learns anything about
            // it, and `unknown` is what RFC-0004 already means by that.
            var info = AgentInfo(id: id, tool: .unknown, project: "-", session: "-")
            info.relayed = true
            info.machine = (payload["peer"] as? String) ?? ""
            return list + [info]
        case "peer_presence_relayed":
            guard let newState = payload["new"] as? String else { return nil }
            if let idx = list.firstIndex(where: { $0.id == id }) {
                list[idx].status = newState
                return list
            }
            var info = AgentInfo(id: id, tool: .unknown, project: "-", session: "-")
            info.relayed = true
            info.machine = (payload["peer"] as? String) ?? ""
            info.status = newState
            return list + [info]
        default:
            return nil
        }
    }

    // MARK: - Stable merge + filter

    /// Flatten every machine's list into the published one.
    private func publishMerged() {
        mergeAgents(byMachine.values.flatMap { $0 })
    }

    /// Merge incoming agents into stable ordered list.
    /// Only agents with metadata (tool != unknown) are shown.
    private func mergeAgents(_ incoming: [AgentInfo]) {
        var newMap: [String: AgentInfo] = [:]
        var total = 0
        for agent in incoming {
            total += 1
            // A RELAYED ROW HAS NO METADATA BY CONSTRUCTION, so the filter
            // that keeps bare panes out of the list dropped every
            // peer-hosted agent with them. It is kept for a relayed row
            // only when the id is not the machine-scoped fallback a bare
            // pane holds — the same test the hub qualifies names by.
            guard agent.isAgent else { continue }
            // THE SAME AGENT CAN ARRIVE TWICE — relayed through this hub
            // and again over a direct subscription to the peer — and the
            // richer row is the one to keep. Dictionary order decides
            // otherwise, which is to say nondeterministically.
            if let held = newMap[agent.id], held.hasMetadata, !agent.hasMetadata { continue }
            newMap[agent.id] = agent
        }
        if total != registeredCount { registeredCount = total }
        // Sort alphabetically by ID for stable ordering.
        let sorted = Array(newMap.values).sorted { $0.id < $1.id }
        // Only publish if changed — avoids unnecessary SwiftUI re-renders.
        if sorted != agents {
            agents = sorted
        }
        // Prune attention for agents that disappeared — publish only on change.
        let pruned = needsAttention.filter { newMap[$0] != nil }
        if pruned != needsAttention {
            needsAttention = pruned
        }
    }

    // MARK: - Peer subscriptions ([[ADR-0008]] stage 5)

    /// Subscribe to a peer hub reachable on a loopback port (the local end
    /// of an SSH forward). Idempotent per machine.
    func attachPeer(machine: String, port: Int) {
        guard !machine.isEmpty else { return }
        if peerPorts[machine] == port, peerClients[machine] != nil { return }
        detachPeer(machine)
        peerPorts[machine] = port
        connectPeer(machine)
    }

    func detachPeer(_ machine: String) {
        peerReconnects[machine]?.cancel()
        peerReconnects[machine] = nil
        peerClients[machine]?.stop()
        peerClients[machine] = nil
    }

    /// Forget a machine entirely — used when the human removes the host,
    /// NOT when a link drops. A dropped link keeps the agents listed and
    /// marked unreachable, because "I cannot see it" is not "it is gone".
    func forgetPeer(_ machine: String) {
        detachPeer(machine)
        peerPorts[machine] = nil
        byMachine[machine] = nil
        publishMerged()
    }

    private func connectPeer(_ machine: String) {
        guard monitoring, let port = peerPorts[machine] else { return }
        let c = HubEventClient(port: port)
        c.onSnapshot = { [weak self] dicts in
            self?.applySnapshot(dicts, machine: machine)
        }
        c.onEvent = { [weak self] payload in
            self?.applyEvent(payload, machine: machine)
        }
        c.onDisconnect = { [weak self] in
            self?.handlePeerDisconnect(machine)
        }
        peerClients[machine] = c
        c.start()
    }

    /// A peer went dark. Its agents stay LISTED and are marked unreachable
    /// with status `unknown` — RFC-0004 already defines unknown as the
    /// honest answer when there is no reliable evidence, which is exactly
    /// this. Two things are deliberately NOT done: they are not dropped
    /// (that would read as "those agents ended"), and their last known
    /// status is not frozen and kept being served (a stale status looks
    /// identical to a fresh one).
    /// Test seam: drive the disconnect path without a socket. Named for
    /// what it is so it cannot be mistaken for production API.
    func simulatePeerDisconnectForTesting(_ machine: String) {
        handlePeerDisconnect(machine)
    }

    private func handlePeerDisconnect(_ machine: String) {
        peerClients[machine] = nil
        if var list = byMachine[machine] {
            for i in list.indices {
                list[i].reachable = false
                list[i].status = "unknown"
            }
            byMachine[machine] = list
            publishMerged()
        }
        guard monitoring, peerPorts[machine] != nil else { return }
        peerReconnects[machine]?.cancel()
        peerReconnects[machine] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.connectPeer(machine)
        }
    }

    // MARK: - Attention

    func markNeedsAttention(_ agentID: String) {
        needsAttention.insert(agentID)
    }

    func clearAttention(_ agentID: String) {
        needsAttention.remove(agentID)
    }

    // MARK: - Output parsing

    /// Snapshot agents array (dicts from the subscription snapshot).
    nonisolated static func agentInfos(from dicts: [[String: Any]]) -> [AgentInfo] {
        extractAgents(from: ["agents": dicts])
    }



    nonisolated static func extractAgents(from dict: [String: Any]) -> [AgentInfo] {
        guard let agentArray = dict["agents"] as? [[String: Any]] else { return [] }
        return agentArray.compactMap { obj -> AgentInfo? in
            guard let id = obj["id"] as? String else { return nil }
            let tool = ToolType(from: (obj["tool"] as? String) ?? "-")
            let project = (obj["project"] as? String) ?? "-"
            let session = (obj["session"] as? String) ?? "-"
            let status = (obj["status"] as? String) ?? "unknown"
            var info = AgentInfo(id: id, tool: tool, project: project, session: session, status: status)
            if let gen = obj["generation"] as? Int, gen > 0 {
                info.generation = UInt64(gen)
            }
            // [[RFC-0010]]: read the attribution off the wire rather than
            // re-deriving it here. This side does not know what a peer's
            // build provides; only the hub that negotiated the link does.
            info.unknownCause = (obj["unknown_cause"] as? String).flatMap(AgentInfo.UnknownCause.init(rawValue:))
            // `peer_reachable`, WHICH IS WHAT THE HUB SENDS. This read
            // `reachable` — a spelling the hub abandoned in a rename that
            // reached every other reader and stopped here, so the hosting
            // peer's reachability, the one fact this side cannot compute
            // for itself, was never taken off the wire at all. The test
            // that guarded it hand-authored a row in the old spelling, so
            // it was green about a shape no hub sends.
            if let reachable = obj["peer_reachable"] as? Bool { info.reachable = reachable }
            // THE HUB RELAYS EVERY IDENTITY IT KNOWS OF and this side read
            // two of the four fields it marks them with, so a peer-hosted
            // agent arrived on every snapshot and was thrown away twice
            // over — once here, having no machine to be placed on, and
            // again by the metadata filter, since a relayed row carries no
            // tool by construction ([[RFC-0009]] C-DIRECTORY).
            if let peer = obj["hosting_peer"] as? String { info.machine = peer }
            info.relayed = (obj["remote"] as? Bool) ?? false
            return info
        }
    }
}
