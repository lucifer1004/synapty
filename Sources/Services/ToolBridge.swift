import Foundation
import Observation
import os

/// Executes credential-bound task tools on behalf of agents ([[ADR-0008]]
/// decision 6, [[RFC-0003]] C-EVENTS as amended).
///
/// THE HUB ROUTES, THE WORKBENCH EXECUTES. A hub that loaded the GitHub
/// PAT itself would be non-relocatable regardless of any process
/// boundary: a hub on a Linux server has no Keychain, no `security` CLI
/// and no token. Keeping execution here means the credential never leaves
/// the machine the human authorized it on.
///
/// The honest consequence, stated rather than hidden: task tools now
/// require a reachable workbench. An agent working overnight while the
/// laptop is closed can still message peers and queue mail, but it cannot
/// claim or comment on an issue — it gets the same fast, honest refusal
/// the exec path already returns. Queueing these for later is REJECTED by
/// design: a "claim this task" that lands eight hours late is worse than a
/// refusal, because the world has moved on. Operations with side effects
/// must not be deferred.
///
/// A future escape hatch, noted and deliberately not built: a human
/// provisioning a SEPARATE, scoped credential on a server for autonomous
/// operation — the same shape as RFC-0007 exec arming (explicit human act,
/// bounded authority, visible), never an automatic copy of this laptop's
/// PAT.
@MainActor @Observable final class ToolBridge {

    /// Seconds a tool subprocess is given: the innermost rung of the
    /// nested deadline ladder. Mirrored from
    /// [[protocol.tool_exec_budget_ms]], which Swift cannot import;
    /// `testTheBudgetAgreesWithTheLadder` is what keeps them equal.
    static let execBudgetSeconds: TimeInterval = 60

    private var port: Int = 9000
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "synapty", category: "tools")
    /// Concurrency bound. GitHub calls are slow, and an agent loop that
    /// fires faster than they complete would otherwise spawn unbounded
    /// subprocesses; refusing past the bound is visible, a pile-up is not.
    static let maxConcurrent = 8
    private var inFlight = 0

    /// Requests refused for want of a slot — surfaced so a human can see
    /// that agents are being throttled rather than silently served slowly.
    private(set) var refusedCount = 0
    private(set) var executedCount = 0

    /// Bind to the hub once it has a port — same lifecycle shape as
    /// ExecController and WakeCoordinator, so the wiring reads the same.
    func start(port: Int) {
        self.port = port
    }

    /// Parsed form of a forwarded tool_request. The hub has ALREADY applied
    /// RFC-0003 attribution to comment/create bodies, because only it knows
    /// which identity a connection holds; this side passes args through
    /// verbatim rather than re-deriving a claim it cannot verify.
    struct Request {
        let tool: String
        let argsJSON: String
        /// The same arguments unserialised, for the verbs served in process.
        let argsDictionary: [String: Any]
        let requester: String
        let requestID: String

        init?(_ payload: [String: Any]) {
            guard let tool = payload["tool"] as? String,
                  let requestID = payload["request_id"] as? String
            else { return nil }
            self.tool = tool
            self.requester = payload["requester"] as? String ?? ""
            self.requestID = requestID
            let args = payload["args"] as? [String: Any] ?? [:]
            self.argsDictionary = args
            if let data = try? JSONSerialization.data(withJSONObject: args),
               let text = String(data: data, encoding: .utf8) {
                self.argsJSON = text
            } else {
                self.argsJSON = "{}"
            }
        }
    }

    /// Hub event intake — wired alongside ExecController. Only tool_request
    /// frames are ours.
    /// `replyPort` is the hub that FORWARDED this, which is not always
    /// ours: a remote agent's request is parked by ITS hub, and a receipt
    /// sent anywhere else is dropped as "requester gone" while the agent
    /// stays blocked.
    func handleHubEvent(_ payload: [String: Any], replyPort: Int? = nil) {
        guard let type = payload["type"] as? String, type == "tool_request",
              let inner = payload["payload"] as? [String: Any],
              let req = Request(inner)
        else { return }
        dispatch(req, replyPort: replyPort ?? port)
    }

    /// Served in THIS process rather than by a subprocess ([[WI-2026-08-15-010]]).
    /// Set at wiring time, alongside the hub port.
    var fileServer: (() -> FileToolServer?)?

    private func dispatch(_ req: Request, replyPort: Int) {
        // File verbs never reach the subprocess: their queue, limit and
        // record belong to the resident transfer service, and a transfer run
        // out of process would be one nobody can see or cancel.
        if req.tool.hasPrefix("file.") || req.tool.hasPrefix("view.") || req.tool == "agent.identify" {
            executedCount += 1
            // THE SIZE A TRANSFER MAY NOT EXCEED IS MEASURED WHERE THE
            // FILE IS, which for anything on another machine is a round
            // trip ([[RFC-0013]] C-CONTROL-PLANE). It happens inside the
            // server, off this actor, for the same reason the view probe
            // below does: a synchronous ssh here froze the window for as
            // long as the far side took ([[WI-2026-08-08-010]]).
            Task { @MainActor in
                await self.finishInProcess(req, replyPort: replyPort)
            }
            return
        }

        guard inFlight < Self.maxConcurrent else {
            refusedCount += 1
            Self.log.error("refusing \(req.tool, privacy: .public): \(Self.maxConcurrent) already in flight")
            HubEventClient.sendToolReceipt(
                port: replyPort, requester: req.requester, requestID: req.requestID,
                ok: false, data: nil, error: "workbench busy: too many tool requests in flight")
            return
        }
        guard let binary = SynaptyBinary.resolve() else {
            HubEventClient.sendToolReceipt(
                port: replyPort, requester: req.requester, requestID: req.requestID,
                ok: false, data: nil, error: "synapty binary not found at the workbench")
            return
        }
        inFlight += 1
        executedCount += 1
        // The receipt goes to the ASKING hub's port, captured for the hop.
        DispatchQueue.global(qos: .utility).async {
            let output = SubprocessRunner.run(
                executable: binary,
                arguments: ["tools", "exec", "--tool", req.tool, "--args", req.argsJSON],
                // THE INNERMOST RUNG OF THE LADDER
                // ([[protocol.tool_exec_budget_ms]], which Swift cannot
                // import). The hub parks the requester's connection for
                // this plus its own slack, and the CLI waits longer still;
                // raising this without raising those has the hub give up
                // on work that is still running.
                timeout: ToolBridge.execBudgetSeconds
            )
            let result = Self.parseResult(output)
            HubEventClient.sendToolReceipt(
                port: replyPort, requester: req.requester, requestID: req.requestID,
                ok: result.ok, data: result.data, error: result.error)
            Task { @MainActor in self.inFlight -= 1 }
        }
    }

    /// Set alongside the file server, for the verbs that need the forward
    /// service as well ([[WI-2026-08-15-011]]).
    var forwardService: (() -> PortForwardService?)?

    private func finishInProcess(_ req: Request, replyPort: Int) async {
        let outcome = await serveInProcess(req)
            ?? FileToolServer.Outcome.refused("the workbench cannot serve that right now")
        // REACHING THE PAGE IS A ROUND TRIP, so it happens after the
        // facts are gathered and off this actor. Answering "did it
        // load" from the exposure record alone would report a forward
        // that exists as a page that works, which is the difference
        // the agent is asking about.
        if req.tool == "view.status", outcome.ok,
           let targets = outcome.data?["probe"] as? [[String: Any]] {
            DispatchQueue.global(qos: .utility).async {
                let probed = targets.map { ViewProbe.check($0) }
                HubEventClient.sendToolReceipt(
                    port: replyPort, requester: req.requester, requestID: req.requestID,
                    ok: true, data: Self.jsonString(["views": probed]), error: nil)
            }
            return
        }
        HubEventClient.sendToolReceipt(
            port: replyPort, requester: req.requester, requestID: req.requestID,
            ok: outcome.ok, data: outcome.data.flatMap(Self.jsonString), error: outcome.error)
    }

    private func serveInProcess(_ req: Request) async -> FileToolServer.Outcome? {
        guard let server = fileServer?() else { return nil }
        // `agent.identify` is served here for the same reason the view
        // verbs are — the workbench is the only party that knows where a
        // pane is — so it routes with them rather than falling through to
        // the transfer path, which answered it with "a transfer needs a
        // path".
        if req.tool.hasPrefix("view.") || req.tool == "agent.identify" {
            guard let forwards = forwardService?() else { return nil }
            return await server.serveView(tool: req.tool, args: req.argsDictionary,
                                          requester: req.requester, forwards: forwards)
        }
        return await server.serve(tool: req.tool, args: req.argsDictionary, requester: req.requester)
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    struct ToolResult {
        var ok: Bool
        var data: Any?
        var error: String?
    }

    /// Turn the executor's output into a result. `tools exec` prints
    /// `{ok, data?, error?}` and exits 0 EVEN ON TOOL FAILURE, because the
    /// reason has to survive back to the agent — an exit code alone would
    /// lose it. So a non-JSON stdout means the process itself failed
    /// (crash, timeout, missing binary), which is a different report.
    nonisolated static func parseResult(_ output: SubprocessRunner.Output) -> ToolResult {
        if output.timedOut {
            return ToolResult(ok: false, data: nil, error: "task tool timed out at the workbench")
        }
        if let launchError = output.error {
            return ToolResult(ok: false, data: nil, error: "workbench could not run the task tool: \(launchError)")
        }
        guard let data = output.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = root["ok"] as? Bool
        else {
            let detail = output.stderr.isEmpty ? "no output" : output.stderr
            return ToolResult(ok: false, data: nil, error: "task tool produced no usable result: \(detail)")
        }
        return ToolResult(ok: ok, data: root["data"], error: root["error"] as? String)
    }
}
