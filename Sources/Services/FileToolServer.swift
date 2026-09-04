import Foundation
import os

/// Serves the CLI's file verbs out of the workbench's own transfer service.
///
/// SAME TRANSPORT AS THE TASK TOOLS, DELIBERATELY. `file.put` and
/// `file.fetch` ride the existing tool_request/tool_receipt round trip: the
/// hub already parks the requester, forwards to the workbench and routes the
/// receipt back, and it already records the request in the activity stream
/// with the agent that asked. A second envelope type would have duplicated
/// all of that to carry a different noun.
///
/// WHAT IT DOES NOT SHARE is execution. The task verbs are run by spawning
/// `synapty tools exec`; a transfer is not, because the queue, the
/// concurrency limit and the record belong to the resident service
/// ([[ADR-0010]]). A transfer run in a subprocess would be one the human
/// cannot see or cancel.
///
/// [[RFC-0013]], [[WI-2026-08-15-010]]
@MainActor
struct FileToolServer {

    let transfers: TransferService
    let hostStore: HostStore
    let paneManager: WorkspaceManager
    let authority: TransferAuthority
    let artifacts: ArtifactService
    let questions: QuestionService

    private static let log = Logger(subsystem: "com.synapty.app", category: "FileTool")

    /// An agent may ask for at most this much in one transfer.
    ///
    /// THIS PLANE IS A CONTROL PLANE ([[RFC-0013]] C-CONTROL-PLANE). Every
    /// relayed byte crosses this machine twice and shares the connection
    /// carrying the human's keystrokes. The limit is stated here and in the
    /// refusal rather than discovered by hitting it, because a limit found
    /// by surprise reads as a defect.
    ///
    /// THE OPERATOR'S TO SET, and it syncs: the clause requires the limit
    /// be stated, not that it be fixed, and the right number depends on a
    /// link and a fleet this code knows nothing about.
    static var maxBytes: Int64 {
        Int64(SynaptySettings.shared.agentTransferLimitMB) * 1024 * 1024
    }

    struct Outcome {
        var ok: Bool
        var data: [String: Any]?
        var error: String?

        static func refused(_ why: String) -> Outcome { Outcome(ok: false, data: nil, error: why) }

        /// NOT DONE, BUT NOT A DEAD END EITHER. A human has been asked and
        /// has not answered; retrying once they do is exactly right, while
        /// retrying a genuine refusal is a loop.
        ///
        /// The marker is what the caller reads, not the message: a
        /// reworded refusal must not silently change what agents do.
        static func awaitingHuman(_ why: String) -> Outcome {
            Outcome(ok: false, data: ["state": "awaiting_approval"], error: why)
        }
    }

    func serve(tool: String, args: [String: Any], requester: String) async -> Outcome {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return .refused("a transfer needs a path")
        }
        guard let hostLabel = args["host"] as? String, !hostLabel.isEmpty else {
            return .refused("a transfer needs the other end")
        }
        // ADDRESSED BY AGENT, resolved by the workbench ([[RFC-0013]]
        // C-ADDRESSING). The caller says WHAT it wants reached; which
        // machine that agent is on, and where deliveries land there, are
        // facts it should not have to carry — they change under re-homing
        // while the identity does not.
        if hostLabel.hasPrefix("agent:") {
            return await serveAgentAddressed(
                tool: tool, path: path,
                target: String(hostLabel.dropFirst("agent:".count)), requester: requester)
        }
        guard let remote = resolveHost(hostLabel) else {
            return .refused("no host called \(hostLabel)")
        }

        // WHERE THE AGENT IS, resolved from the pane it runs in. This is what
        // lets the caller name only the OTHER end: `put out.tar --to builder`
        // means "from my machine to builder", and the agent should not have
        // to know what its own machine is called here.
        guard let origin = origin(of: requester) else {
            return .refused(
                "cannot tell which machine \(requester) is on — a transfer must be attributable to a pane")
        }

        // AN AGENT DOES NOT CHOOSE THE DESTINATION DIRECTORY.
        //
        // `--into` was honoured for agents when the file verbs first
        // shipped, which handed any agent the ability to write anywhere its
        // account could reach on another machine — a shell profile, an
        // authorized_keys — under an approval the human gave for "deliver a
        // file". Scoping is what makes an agent-initiated write acceptable
        // at all ([[RFC-0013]] C-AUTHORIZATION), so the flag now applies to
        // a human's drag and nothing else.
        let intoDirectory = args["into"] as? String
        let inbox = AgentInbox.path
        var source: FileEndpoint
        let destination: FileEndpoint
        switch tool {
        case "file.put":
            source = FileEndpoint(hostID: origin.hostID, path: path)
            destination = FileEndpoint(hostID: remote.id, path: inbox)
        case "file.fetch":
            source = FileEndpoint(hostID: remote.id, path: path)
            destination = FileEndpoint(hostID: origin.hostID, path: inbox)
        default:
            return .refused("unknown file verb \(tool)")
        }
        _ = intoDirectory

        if source == destination || DropRule.outcome(dragging: source, onto: destination) == .pastePath {
            // Not an error worth failing over, but not work either: saying so
            // is better than reporting a transfer that moved nothing.
            return .refused("that file is already on \(hostLabel)")
        }

        // THE LIMIT COMES BEFORE THE HUMAN. Asking somebody to approve a
        // transfer the workbench is going to refuse anyway spends their
        // attention on a question with one answer.
        let (measured, oversized) = await inspectSource(source)
        if let oversized { return oversized }
        source = measured

        // THE HUMAN'S ANSWER COMES FIRST, and the transfer waits for it
        // rather than running and being undone.
        let pair = TransferAuthority.Pair(from: source.hostID, to: destination.hostID)
        switch authority.requirement(initiator: .agent(requester), pair: pair) {
        case .go: break
        case .ask:
            authority.requestApproval(pair: pair, agent: requester,
                                      fileName: (path as NSString).lastPathComponent)
            return .awaitingHuman(
                "waiting for approval to send from \(machineName(source.hostID)) to "
                + "\(machineName(destination.hostID)) — a human has been asked")
        case .refuse:
            return .refused(
                "a human refused sending from \(machineName(source.hostID)) to "
                + "\(machineName(destination.hostID)). Retrying will not change it; "
                + "they can undo the refusal in Settings")
        }

        let id = transfers.enqueue(from: source, to: destination, initiator: .agent(requester))
        Self.log.info(
            "\(tool, privacy: .public) for \(requester, privacy: .public): \(path, privacy: .public) -> \(hostLabel, privacy: .public)")
        return Outcome(ok: true, data: ["transfer_id": id.uuidString, "state": "queued"], error: nil)
    }

    // MARK: - Addressing by agent

    /// `--to agent:<id>`: the workbench resolves the machine and the inbox.
    private func serveAgentAddressed(
        tool: String, path: String, target: String, requester: String
    ) async -> Outcome {
        guard tool == "file.put" else {
            // Fetching FROM an agent would be reaching into another agent's
            // machine on its behalf, which is a different capability and one
            // nobody has agreed to.
            return .refused("only `put` can address an agent")
        }
        guard let sender = origin(of: requester) else {
            return .refused("cannot tell which machine \(requester) is on")
        }
        guard let recipient = origin(of: target) else {
            return .refused("no agent called \(target) is in a pane here")
        }
        guard recipient.hostID != sender.hostID else {
            return .refused("\(target) is on the same machine — nothing to move")
        }

        let (source, oversized) = await inspectSource(
            FileEndpoint(hostID: sender.hostID, path: path))
        if let oversized { return oversized }
        let destination = AgentInbox.destination(hostID: recipient.hostID)
        let pair = TransferAuthority.Pair(from: source.hostID, to: destination.hostID)
        switch authority.requirement(initiator: .agent(requester), pair: pair) {
        case .go: break
        case .ask:
            authority.requestApproval(pair: pair, agent: requester,
                                      fileName: (path as NSString).lastPathComponent)
            return .awaitingHuman(
                "waiting for approval to send from \(machineName(source.hostID)) to "
                + "\(machineName(destination.hostID)) — a human has been asked")
        case .refuse:
            return .refused(
                "a human refused sending from \(machineName(source.hostID)) to "
                + "\(machineName(destination.hostID)). Retrying will not change it; "
                + "they can undo the refusal in Settings")
        }
        let id = transfers.enqueue(from: source, to: destination, initiator: .agent(requester))
        return Outcome(ok: true,
                       data: ["transfer_id": id.uuidString, "state": "queued",
                              "delivered_to": AgentInbox.path],
                       error: nil)
    }

    private func machineName(_ hostID: UUID?) -> String {
        guard let hostID else { return "this Mac" }
        guard let host = hostStore.hosts.first(where: { $0.id == hostID }) else { return "a host" }
        return host.label.isEmpty ? host.address : host.label
    }

    // MARK: - Resolution

    private func resolveHost(_ label: String) -> HostEntry? {
        hostStore.hosts.first { $0.label == label }
            ?? hostStore.hosts.first { $0.address == label }
            ?? hostStore.hosts.first { $0.label.lowercased() == label.lowercased() }
    }

    /// Named rather than returned as a doubly-optional UUID: "no pane
    /// found" and "the pane is on this Mac" are different answers and the
    /// second one is a nil host id, which a `UUID??` makes easy to misread.
    struct Origin {
        /// nil means this Mac.
        let hostID: UUID?
    }

    /// ASKED OF THE LEAF ([[RFC-0015]] C-LEAF-BINDING). This walked up to
    /// the containing session and took its host, which stamps every
    /// primitive an agent presents with the machine of whatever tab its
    /// pane happens to be sitting in.
    private func origin(of agentID: String) -> Origin? {
        guard let leaf = paneManager.leafID(forAgent: agentID),
              paneManager.connectionID(ofLeaf: leaf) != nil else { return nil }
        return Origin(hostID: paneManager.host(ofLeaf: leaf)?.id)
    }

    /// Only a local source can be sized without a round trip. A remote one
    /// is left to the transfer itself, which is honest: the alternative is
    /// an extra connection to learn a number we would then have to trust.
    ///
    /// A DIRECTORY IS WALKED, NOT STATTED. `attributesOfItem` on one reports
    /// the size of the ENTRY — 128 bytes for a tree holding fifty megabytes
    /// — so checking a limit against it would let any agent send an
    /// arbitrarily large tree by putting it in a folder first. The limit and
    /// the thing it limits have to be the same quantity.
    /// WHAT IS AT THE SOURCE, measured where it lives, and the refusal if
    /// there is one.
    ///
    /// TWO LOCAL-ONLY PROBES USED TO STAND HERE and both silently degraded
    /// for anything on another machine: one answered "not a directory" for
    /// every remote path, the other answered "size unknown", and the size
    /// limit [[RFC-0013]] C-CONTROL-PLANE requires was therefore skipped
    /// for three of the four agent-initiated transfers — `file.fetch`
    /// always, `file.put` from a remote agent, and `view.present`
    /// entirely. The human sets a limit in Settings believing it bounds
    /// what an agent may move; it bound the one case with a local source.
    ///
    /// THE REASON THEY WERE LOCAL-ONLY STILL HOLDS and is answered rather
    /// than ignored: a synchronous ssh round trip on the thread that draws
    /// the window froze the application for as long as the host took
    /// ([[WI-2026-08-08-010]]). This is `async` and the measurement runs
    /// off the actor, so the window keeps drawing while the far side
    /// answers.
    ///
    /// AN UNKNOWN SIZE IS NOT A REFUSAL, deliberately and as before. A
    /// path that is not there, or a host that cannot be reached, fails as
    /// a transfer with the far side's own message; turning those into
    /// refusals here would be a different change to a different rule.
    private func inspectSource(_ endpoint: FileEndpoint) async -> (FileEndpoint, Outcome?) {
        guard let leg = transfers.leg(for: endpoint) else { return (endpoint, nil) }
        let measured = await Task.detached(priority: .utility) {
            TransferRunner.measure(leg)
        }.value
        var resolved = endpoint
        resolved.isDirectory = measured.isDirectory
        guard let size = measured.bytes, size > Self.maxBytes else { return (resolved, nil) }
        return (resolved, .refused(
            "refused: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) exceeds the "
            + "\(ByteCountFormatter.string(fromByteCount: Self.maxBytes, countStyle: .file)) "
            + "limit for agent transfers — this is a control plane, not a data plane"))
    }

    // MARK: - Views ([[RFC-0013]] C-PRIMITIVES)

    /// `view.expose` / `view.withdraw`.
    ///
    /// THE AGENT NAMES ITS OWN PORT, not a local one. Which port on THIS
    /// Mac reaches it is the workbench's to choose — an agent picking one
    /// would be choosing a number on a machine it cannot see, and the
    /// choice is load-bearing: a port that served another host would make
    /// the two one web origin.
    func serveView(tool: String, args: [String: Any], requester: String,
                   forwards: PortForwardService) async -> Outcome {
        guard let origin = origin(of: requester) else {
            return .refused(
                "cannot tell which machine \(requester) is on — a view must be attributable to a pane")
        }
        if tool == "view.ask" {
            guard let text = args["question"] as? String, !text.isEmpty else {
                return .refused("ask needs a question")
            }
            let options = (args["options"] as? [Any])?.compactMap { $0 as? String } ?? []
            // A QUESTION WITH NO OPTIONS CAN NEVER LEAVE THE QUEUE. The
            // card renders one button per option and nothing else — no
            // dismiss, because the badge is a queue of DECISIONS and a
            // decision is made by choosing. So an empty set produces a
            // card the human cannot answer and cannot clear, the agent
            // times out, and the badge stays lit for the life of the
            // process. Refused where it enters rather than presented.
            guard !options.isEmpty else {
                return .refused("ask needs at least one option: the human answers by "
                                + "choosing one, and a question with none cannot be answered")
            }
            let id = questions.ask(agent: requester, text: text, options: options)
            return Outcome(ok: true, data: ["question_id": id.uuidString], error: nil)
        }
        if tool == "view.answer" {
            guard let raw = args["question_id"] as? String, let id = UUID(uuidString: raw) else {
                return .refused("answer needs a question id")
            }
            guard let answer = questions.answer(to: id) else {
                // STILL WAITING IS NOT AN ERROR. An agent polling must be
                // able to tell "no answer yet" from "something went wrong",
                // and a refusal would read as the latter.
                return Outcome(ok: true, data: ["state": "waiting"], error: nil)
            }
            questions.collect(id)
            return Outcome(ok: true, data: ["answer": answer], error: nil)
        }
        // WHERE THE CALLER IS. A shell sees its own environment and
        // nothing about the window it is drawn in, so this is the one
        // party that can answer. It presents nothing and grants nothing —
        // it reports facts about the asker's own placement, which is why
        // it is not a fifth primitive ([[RFC-0013]] C-PRIMITIVES).
        if tool == "agent.identify" {
            var data: [String: Any] = ["agent": requester]
            data["machine"] = machineName(origin.hostID)
            data["is_local"] = origin.hostID == nil
            if let paneID = paneManager.leafID(forAgent: requester),
               let session = paneManager.workspaces.first(where: {
                   $0.panes.contains { $0.id == paneID }
               }) {
                // A NAME IS NOT AN IDENTIFIER ([[RFC-0015]] C-IDENTIFY).
                // `workspace` is what the human reads in the sidebar:
                // chosen by them, editable, and not unique — an agent that
                // quotes it into a message or a task has written down
                // something nobody can resolve later. `workspace_id` is
                // the durable one.
                //
                // THIS USED TO ANSWER WITH THE CONTAINER'S AGENT ID, which
                // was the id the session had been DIALLED with. Every leaf
                // runs its own child under its own id, so for any pane but
                // the first that named a different agent entirely — and
                // the thing an agent is really being told is which piece
                // of work it belongs to, which is a workspace.
                //
                // Two agents on different machines in one workspace can
                // recognise each other from this, which is what a
                // workspace id buys that a machine name cannot.
                data["workspace"] = session.label
                data["workspace_id"] = session.id.uuidString
            }
            // Its own exposures, so "what have I put in front of them"
            // has an answer that does not require remembering.
            data["exposed"] = forwards.exposures
                .filter { $0.agent == requester }
                .map { $0.remotePort }
            return Outcome(ok: true, data: data, error: nil)
        }

        // WHAT BECAME OF WHAT THIS AGENT PUT THERE. Gathered here, probed
        // off the main actor by the caller: reaching the page is a network
        // round trip and this method answers synchronously.
        if tool == "view.status" {
            let wanted = (args["port"] as? Int) ?? (args["port"] as? NSNumber)?.intValue
            let mine = forwards.exposures.filter {
                // ITS OWN, AND ONLY ITS OWN — the same rule as withdraw.
                // Reading back another agent's view is reading something
                // it put in front of a human.
                $0.agent == requester && (wanted == nil || $0.remotePort == wanted)
            }
            guard !mine.isEmpty else {
                return .refused(wanted.map { "you have not exposed port \($0)" }
                    ?? "you have not exposed anything")
            }
            return Outcome(ok: true, data: ["probe": mine.map {
                ["remote_port": $0.remotePort, "local_port": $0.localPort,
                 "url": $0.url.absoluteString, "title": $0.title as Any]
            }], error: nil)
        }

        if tool == "view.present" {
            guard let path = args["path"] as? String, !path.isEmpty else {
                return .refused("present needs a path")
            }
            // NO APPROVAL GATE HERE, and the asymmetry is deliberate: this
            // moves a file TO the human's own machine, into a directory
            // this application owns. What the authority protects is an
            // agent WRITING somewhere a human did not choose; handing
            // something over is the other direction.
            // A HAND-OVER IS STILL AN AGENT-INITIATED TRANSFER. The
            // authority gate does not apply — see above — but the size
            // limit does: [[RFC-0013]] C-CONTROL-PLANE binds every
            // agent-initiated transfer, and this verb had no check at all,
            // so `present` was the way to move a dataset onto this Mac.
            let (measured, oversized) = await inspectSource(
                FileEndpoint(hostID: origin.hostID, path: path))
            if let oversized { return oversized }
            guard let id = artifacts.present(
                from: measured,
                agent: requester, title: args["title"] as? String)
            else { return .refused("the workbench cannot fetch artifacts right now") }
            return Outcome(ok: true, data: ["artifact_id": id.uuidString], error: nil)
        }
        guard let port = (args["port"] as? Int) ?? (args["port"] as? NSNumber)?.intValue else {
            return .refused("expose needs a port")
        }
        // A LOCAL AGENT'S EXPOSE IS AN EXPOSE. It opens no forward —
        // there is nothing between the human and the service — but the
        // offer is the naming and the attribution, and both are exactly
        // what a human sitting in front of the services pane needs
        // ([[RFC-0013]] C-PRIMITIVES). Refused here, this Mac's pane could
        // never hold anything.
        let hostID = origin.hostID

        switch tool {
        case "view.expose":
            // `at`, not `path`: `path` on this wire is a FILE on the
            // agent's machine (view.present). One name for a filesystem
            // path and a URL path would mean whichever the reader assumed.
            switch await forwards.expose(hostID: hostID, remotePort: port,
                                         agent: requester, title: args["title"] as? String,
                                         path: args["at"] as? String) {
            case .ok(let exposure):
                return Outcome(ok: true,
                               data: ["local_port": exposure.localPort,
                                      "url": exposure.url.absoluteString],
                               error: nil)
            case .refused(let why):
                return .refused(why)
            }
        case "view.withdraw":
            guard let existing = forwards.exposures.first(where: {
                $0.hostID == hostID && $0.remotePort == port
            }) else { return .refused("nothing is exposed on port \(port)") }
            // ONLY ITS OWN. One agent withdrawing another's view would let
            // a poisoned one hide what a working one is showing.
            guard existing.agent == requester else {
                return .refused("that view belongs to \(existing.agent)")
            }
            await forwards.withdraw(existing.id)
            return Outcome(ok: true, data: nil, error: nil)
        default:
            return .refused("unknown view verb \(tool)")
        }
    }
}
