import Foundation
import os

// MARK: - RFC-0007 exec primitives (pure logic)

/// The closed terminal-outcome set (C-PRIMITIVES). Wire strings match the
/// hub/CLI exit-code mapping.
enum ExecOutcome: String {
    case opened          // open succeeded
    case ran             // run submitted
    case closed          // close succeeded
    case matched         // wait-output found the pattern
    case timedOut = "timed-out"
    case targetGone = "target-gone"      // pane closed / shell exited / host lost
    case ownershipLost = "ownership-lost" // registration generation ended
    case disarmed        // exec disarmed mid-operation
    case refused         // gate/scope/foreground/validation refusal
}

/// [[RFC-0007]] C-PRIMITIVES run validation: a single line of printable
/// characters, with every C0 control byte and DEL rejected.
///
/// THIS IS THE ENFORCEMENT. The CLI checks the same thing as a
/// convenience, but an agent can reach the workbench over a raw hub
/// connection without going through the CLI at all, so a command that
/// gets past this one is a command that lands in a human's pane.
///
/// MIRRORED FROM [[protocol.isValidExecCommand]], which Swift cannot
/// import. The two are kept identical by holding the same list of cases:
/// `ExecValidationTests` and that function's own test assert the same
/// boundaries, so tightening one without the other takes the other red.
///
/// C1 (U+0080–U+009F) PASSES ON BOTH SIDES, deliberately: the raw bytes
/// are UTF-8 continuation bytes on the Zig side, and the load-bearing
/// defence is single-line plus no C0, which seals the submit and escape
/// vectors this rule exists for.
enum ExecCommandValidator {
    static func isValid(_ cmd: String) -> Bool {
        guard !cmd.isEmpty else { return false }
        for scalar in cmd.unicodeScalars {
            // Reject C0 (< 0x20, includes CR/LF/TAB) and DEL. Higher
            // scalars (printable + non-ASCII) pass.
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        }
        return true
    }
}

/// One exec pane's ownership record (C-EXEC-SCOPE: single-owner by
/// id + generation).
struct ExecPaneRecord: Equatable {
    let handle: String
    let ownerAgentID: String
    /// The owning registration's generation — access is checked against
    /// the LIVE generation per request; a generation bump orphans it.
    let generation: UInt64
    let leafID: UUID
}

/// Pure registry: pane handles → ownership, per-owner bounds, and the
/// scope/ownership checks. No GUI, fully testable.
struct ExecPaneRegistry: Equatable {
    /// C-EXEC-AUTHORITY bound: concurrent exec panes per agent.
    static let maxPanesPerOwner = 3

    private(set) var panes: [String: ExecPaneRecord] = [:]

    func count(owner: String) -> Int {
        panes.values.filter { $0.ownerAgentID == owner }.count
    }

    /// C-EXEC-AUTHORITY: may this owner open another exec pane?
    func canOpen(owner: String) -> Bool {
        count(owner: owner) < Self.maxPanesPerOwner
    }

    mutating func add(_ record: ExecPaneRecord) {
        panes[record.handle] = record
    }

    mutating func remove(handle: String) {
        panes.removeValue(forKey: handle)
    }

    /// Result of an ownership check for a run/wait/read/close on `handle`
    /// by `requester` whose CURRENT live generation is `liveGeneration`
    /// (nil = the requester is no longer registered).
    enum Access: Equatable {
        case ok(ExecPaneRecord)
        case noSuchPane
        case notOwner
        case ownershipLost   // same id, generation ended
    }

    func access(handle: String, requester: String, liveGeneration: UInt64?) -> Access {
        guard let record = panes[handle] else { return .noSuchPane }
        guard record.ownerAgentID == requester else { return .notOwner }
        // Generation must still match the live registration — an agent
        // whose generation ended loses access (its orphaned panes stay
        // visible for the human to close).
        guard let live = liveGeneration, live == record.generation else {
            return .ownershipLost
        }
        return .ok(record)
    }

}

// MARK: - Exec request (parsed from the hub-forwarded envelope)

struct ExecRequest {
    enum Verb: String { case open, run, waitOutput = "wait-output", read, close }
    let verb: Verb
    let owner: String
    let requester: String
    let requestID: String
    var pane: String?
    var command: String?
    var followUp: Bool = false
    var cwd: String?
    var pattern: String?
    var timeoutSecs: Int = 30
    var rows: Int = 40

    init?(_ payload: [String: Any]) {
        guard let verbStr = payload["verb"] as? String, let v = Verb(rawValue: verbStr),
              let owner = payload["owner"] as? String,
              let requester = payload["requester"] as? String
        else { return nil }
        self.verb = v
        self.owner = owner
        self.requester = requester
        self.requestID = (payload["request_id"] as? String) ?? "exec"
        self.pane = payload["pane"] as? String
        self.command = payload["command"] as? String
        self.followUp = (payload["follow_up"] as? Bool) ?? false
        self.cwd = payload["cwd"] as? String
        self.pattern = payload["pattern"] as? String
        if let t = payload["timeout_secs"] as? Int { self.timeoutSecs = t }
        if let r = payload["rows"] as? Int { self.rows = r }
    }
}

// MARK: - Controller (GUI executor)

/// Owns exec-pane execution: consumes exec_request from the hub event
/// stream, enforces arming/scope/ownership/foreground/validation, drives
/// the ghostty surfaces (create/inject/read), and sends exec_receipt
/// one-shots back. The per-session arm switch is C-EXEC-AUTHORITY.
@MainActor @Observable final class ExecController {
    private weak var paneManager: WorkspaceManager?
    private weak var agentMonitor: AgentMonitor?
    private weak var detector: AgentDetector?
    private var port: Int = 9000
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "synapty", category: "exec")

    /// C-EXEC-AUTHORITY: ONE per-session switch, default OFF. Arming is
    /// the human's act; nothing over the hub may set it.
    private(set) var armed = false
    private(set) var registry = ExecPaneRegistry()

    /// WHAT A PANE IS SHOWING, or nil when its terminal is gone.
    ///
    /// A SEAM, because without one the wait loop is unreachable from a
    /// test: with no Ghostty behind it every wait ends `targetGone` on its
    /// first poll, so no test could hold one in flight and none of
    /// [[RFC-0007]] C-PRIMITIVES' outcomes could be exercised
    /// ([[WI-2026-08-28-003]]).
    var screenOfLeaf: (UUID) -> String? = { leafID in
        guard let surface = GhosttyApp.shared?.surface(forLeaf: leafID),
              !ghostty_surface_process_exited(surface)
        else { return nil }
        // Whole-screen tail: a fresh shell prints at the TOP of a tall
        // pane, so a bottom-anchored window matches nothing
        // (first-armed-smoke defect).
        return AgentDetector.readScreenTail(surface: surface, rows: 200) ?? ""
    }

    /// C-WAKE-ACK-style ack window for run's Enter settle (reuse the wake
    /// injection constant).
    static let ackWindow: TimeInterval = 5.0
    /// wait-output poll cadence.
    static let pollInterval: TimeInterval = 0.4
    /// Settle after an exec pane's surface appears, before `open`
    /// receipts: the shell must have spawned and finished terminal init
    /// or a following run's keystrokes are discarded as type-ahead.
    static let shellSettle: TimeInterval = 0.9

    func start(paneManager: WorkspaceManager, agentMonitor: AgentMonitor, detector: AgentDetector, port: Int) {
        self.paneManager = paneManager
        self.agentMonitor = agentMonitor
        self.detector = detector
        self.port = port
    }

    // C-EXEC-AUTHORITY arming (human act in the UI).
    func setArmed(_ on: Bool) {
        guard armed != on else { return }
        armed = on
        if !on {
            // DISARM IS IMMEDIATE AND ANSWERED ([[RFC-0007]]
            // C-EXEC-AUTHORITY: "in-flight waits terminate with the
            // `disarmed` outcome").
            //
            // THE RECEIPT IS SENT HERE, NOT BY THE WAIT. Cancellation is
            // what makes the disarm immediate, and it is also why the
            // loop's own `.disarmed` branch could never run: the only
            // suspension point is the poll sleep, so a cancelled task
            // leaves at `while !Task.isCancelled` without going round
            // again to reach its guard. An agent sitting in
            // `wait-output --timeout 300` got no receipt at all and
            // blocked to its own deadline.
            for handle in waitTasks.keys { endWait(on: handle, outcome: .disarmed) }
            Self.log.info("exec disarmed — in-flight waits answered and cancelled")
        }
    }

    /// ONE WAIT PER PANE, with the request that started it — because the
    /// party that ENDS a wait is not always the loop, and whoever ends it
    /// owes the agent a receipt addressed to that request.
    private struct InFlightWait {
        /// Identity of this particular wait, so a task tearing down does
        /// not clear a slot a newer wait has already taken.
        let token: UUID
        let request: ExecRequest
        let task: Task<Void, Never>
    }

    private var waitTasks: [String: InFlightWait] = [:]

    /// END AN IN-FLIGHT WAIT AND ANSWER IT.
    ///
    /// WHOEVER ENDS A WAIT OWES THE AGENT A RECEIPT. Cancelling leaves the
    /// loop at its own `while !Task.isCancelled` condition — its only
    /// suspension point is the poll sleep — so NO branch inside it can
    /// send one. Both callers used to cancel and say nothing, and an
    /// agent in `wait-output --timeout 300` blocked to its own deadline
    /// with no answer at all ([[RFC-0007]] C-EXEC-AUTHORITY,
    /// [[WI-2026-08-28-003]]).
    private func endWait(on handle: String, outcome: ExecOutcome) {
        guard let wait = waitTasks.removeValue(forKey: handle) else { return }
        receipt(wait.request, kind: "exec_wait_completed", outcome: outcome,
                pane: handle, detail: wait.request.pattern)
        wait.task.cancel()
    }

    /// Hub event intake — wired to AgentMonitor.onHubEvent. Only
    /// exec_request frames are ours.
    func handleHubEvent(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String, type == "exec_request",
              let inner = payload["payload"] as? [String: Any],
              let req = ExecRequest(inner)
        else { return }
        Task { @MainActor [weak self] in await self?.dispatch(req) }
    }

    private func dispatch(_ req: ExecRequest) async {
        switch req.verb {
        case .open: await handleOpen(req)
        case .run: await handleRun(req)
        case .waitOutput: await handleWaitOutput(req)
        case .read: handleRead(req)
        case .close: handleClose(req)
        }
    }

    // MARK: - Gate helpers

    /// Live generation of the requester (nil = unregistered).
    private func liveGeneration(_ agentID: String) -> UInt64? {
        guard let agent = agentMonitor?.agents.first(where: { $0.id == agentID }) else { return nil }
        return agent.generation
    }

    private func receipt(_ req: ExecRequest, kind: String, outcome: ExecOutcome,
                         pane: String?, excerpt: String? = nil, detail: String? = nil) {
        var data: [String: Any] = ["outcome": outcome.rawValue]
        if let pane { data["pane"] = pane }
        if let excerpt { data["excerpt"] = excerpt }
        HubEventClient.sendExecReceipt(
            port: port, kind: kind, owner: req.owner,
            generation: registry.panes[req.pane ?? ""]?.generation ?? (liveGeneration(req.owner) ?? 0),
            pane: pane, detail: detail, requester: req.requester,
            requestID: req.requestID, data: data)
    }

    // MARK: - open (C-PRIMITIVES, gated by C-EXEC-AUTHORITY)

    private func handleOpen(_ req: ExecRequest) async {
        guard armed else { return refuse(req, kind: "exec_pane_opened", "exec disarmed") }
        guard let paneManager else { return }
        guard liveGeneration(req.owner) != nil else {
            return refuse(req, kind: "exec_pane_opened", "requester not registered")
        }
        guard registry.canOpen(owner: req.owner) else {
            return refuse(req, kind: "exec_pane_opened", "exec pane bound reached")
        }
        let handle = "exec-\(UUID().uuidString.prefix(8).lowercased())"
        guard let leafID = paneManager.newExecTab(handle: handle, owner: req.owner, cwd: req.cwd) else {
            return refuse(req, kind: "exec_pane_opened", "could not open exec pane")
        }
        let gen = liveGeneration(req.owner) ?? 0
        registry.add(ExecPaneRecord(handle: handle, ownerAgentID: req.owner, generation: gen, leafID: leafID))
        // The handle must be USABLE when open returns (C-PRIMITIVES:
        // "open ... Returns a pane handle"). Found in the first armed
        // live smoke: receipting `opened` at pane-record creation let a
        // following run type into a surface whose shell had not spawned
        // — the bytes were swallowed and the wait matched nothing, with
        // every receipt reporting success. Wait for the surface, then
        // let the shell finish its terminal init.
        await awaitShellReady(leafID: leafID)
        receipt(req, kind: "exec_pane_opened", outcome: .opened, pane: handle, detail: "cwd=\(req.cwd ?? "-")")
        Self.log.info("exec pane opened \(handle, privacy: .public) owner \(req.owner, privacy: .public)")
    }

    /// Poll for the leaf's ghostty surface, then settle for the shell's
    /// spawn + prompt. Bounded: an open whose surface never materializes
    /// still receipts — the run gate refuses it as target-gone later,
    /// which is the honest outcome rather than a hang.
    private func awaitShellReady(leafID: UUID) async {
        var waited = 0
        while GhosttyApp.shared?.surface(forLeaf: leafID) == nil, waited < 40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        guard GhosttyApp.shared?.surface(forLeaf: leafID) != nil else { return }
        // Login shells run terminal init (ZLE/stty) that can discard
        // type-ahead, so the settle is not merely cosmetic.
        try? await Task.sleep(nanoseconds: UInt64(Self.shellSettle * 1_000_000_000))
    }

    // MARK: - run (gated; foreground rule + splice guard + C0/C1)

    private func handleRun(_ req: ExecRequest) async {
        guard armed else { return refuse(req, kind: "exec_command_ran", "exec disarmed") }
        guard let handle = req.pane, let cmd = req.command else {
            return refuse(req, kind: "exec_command_ran", "run requires pane and command")
        }
        guard ExecCommandValidator.isValid(cmd) else {
            return refuse(req, kind: "exec_command_ran", "command must be a single printable line")
        }
        switch registry.access(handle: handle, requester: req.requester, liveGeneration: liveGeneration(req.requester)) {
        case .noSuchPane: return refuse(req, kind: "exec_command_ran", "no such exec pane")
        case .notOwner: return refuse(req, kind: "exec_command_ran", "not the pane owner")
        case .ownershipLost: return receipt(req, kind: "exec_command_ran", outcome: .ownershipLost, pane: handle)
        case .ok(let record):
            guard let surface = GhosttyApp.shared?.surface(forLeaf: record.leafID) else {
                return receipt(req, kind: "exec_command_ran", outcome: .targetGone, pane: handle)
            }
            if ghostty_surface_process_exited(surface) {
                return receipt(req, kind: "exec_command_ran", outcome: .targetGone, pane: handle)
            }
            // Splice guard (~3s human typing) — never splice into
            // half-composed human input.
            if let since = GhosttyApp.shared?.secondsSinceHumanInput(forLeaf: record.leafID), since < 3.0 {
                return refuse(req, kind: "exec_command_ran", "human typed recently")
            }
            // (Foreground rule: V1 exec panes run a plain shell; a
            // follow-up flag would target the same agent's previous run's
            // process. Without a per-process foreground probe we honor the
            // spawned-shell case and treat follow_up as advisory —
            // recorded in the receipt detail for the human's audit.)
            WakeInjector.type(cmd, into: surface)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(WakeInjector.enterDelay * 1_000_000_000))
                // Disarm between text and Enter suppresses the submit
                // (C-EXEC-AUTHORITY immediate disarm).
                if self.armed, let live = GhosttyApp.shared?.surface(forLeaf: record.leafID) {
                    WakeInjector.pressEnter(live)
                    self.receipt(req, kind: "exec_command_ran", outcome: .ran, pane: handle,
                                 detail: "\(req.followUp ? "[follow-up] " : "")\(cmd)")
                } else {
                    self.receipt(req, kind: "exec_command_ran", outcome: .disarmed, pane: handle,
                                 detail: "aborted (disarmed before submit): \(cmd)")
                }
            }
        }
    }

    // MARK: - wait-output (snapshot-first, bounded, one in-flight per pane)

    private func handleWaitOutput(_ req: ExecRequest) async {
        guard armed else { return refuse(req, kind: "exec_wait_completed", "exec disarmed") }
        guard let handle = req.pane, let pattern = req.pattern else {
            return refuse(req, kind: "exec_wait_completed", "wait-output requires pane and pattern")
        }
        guard waitTasks[handle] == nil else {
            return refuse(req, kind: "exec_wait_completed", "a wait is already in flight for this pane")
        }
        switch registry.access(handle: handle, requester: req.requester, liveGeneration: liveGeneration(req.requester)) {
        case .noSuchPane: return refuse(req, kind: "exec_wait_completed", "no such exec pane")
        case .notOwner: return refuse(req, kind: "exec_wait_completed", "not the pane owner")
        case .ownershipLost: return receipt(req, kind: "exec_wait_completed", outcome: .ownershipLost, pane: handle)
        case .ok(let record):
            let regex = try? NSRegularExpression(pattern: pattern)
            let deadline = Date().addingTimeInterval(TimeInterval(req.timeoutSecs))
            let token = UUID()
            let task = Task { @MainActor [weak self] in
                defer {
                    if self?.waitTasks[handle]?.token == token { self?.waitTasks[handle] = nil }
                }
                while !Task.isCancelled {
                    // DISARM IS NOT CHECKED HERE. `setArmed(false)`
                    // answers this wait and cancels it in one act, so a
                    // branch for it would be a branch nothing can reach —
                    // and an unreachable branch that claims to send a
                    // receipt is how this stopped sending one.
                    guard let self else { return }
                    // Mid-wait pane close / generation end / shell exit
                    // terminate promptly (never idle to timeout).
                    if self.registry.panes[handle] == nil {
                        self.receipt(req, kind: "exec_wait_completed", outcome: .targetGone, pane: handle, detail: pattern)
                        return
                    }
                    if self.liveGeneration(req.requester) != record.generation {
                        self.receipt(req, kind: "exec_wait_completed", outcome: .ownershipLost, pane: handle, detail: pattern)
                        return
                    }
                    guard let text = self.screenOfLeaf(record.leafID) else {
                        self.receipt(req, kind: "exec_wait_completed", outcome: .targetGone, pane: handle, detail: pattern)
                        return
                    }
                    if Self.matches(text, pattern: pattern, regex: regex) {
                        let excerpt = String(text.suffix(2000))
                        self.receipt(req, kind: "exec_wait_completed", outcome: .matched, pane: handle,
                                     excerpt: excerpt, detail: pattern)
                        return
                    }
                    if Date() >= deadline {
                        self.receipt(req, kind: "exec_wait_completed", outcome: .timedOut, pane: handle, detail: pattern)
                        return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                }
            }
            waitTasks[handle] = InFlightWait(token: token, request: req, task: task)
        }
    }

    nonisolated static func matches(_ text: String, pattern: String, regex: NSRegularExpression?) -> Bool {
        if text.contains(pattern) { return true } // literal-first
        guard let regex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    // MARK: - read (bounded excerpt, NOT gated, NOT receipted)

    private func handleRead(_ req: ExecRequest) {
        guard let handle = req.pane else {
            return refuse(req, kind: "exec_wait_completed", "read requires pane")
        }
        // read/close of OWN panes stay available while disarmed
        // (observation and cleanup are not execution).
        switch registry.access(handle: handle, requester: req.requester, liveGeneration: liveGeneration(req.requester)) {
        case .ok(let record):
            let text = GhosttyApp.shared?.surface(forLeaf: record.leafID).flatMap {
                AgentDetector.readScreenTail(surface: $0, rows: max(1, min(req.rows, 200)))
            } ?? ""
            // read is NOT receipted (passive observation); reply directly.
            HubEventClient.sendExecReceipt(
                port: port, kind: "exec_read", owner: req.owner, generation: record.generation,
                pane: handle, detail: nil, requester: req.requester, requestID: req.requestID,
                data: ["outcome": ExecOutcome.ran.rawValue, "excerpt": String(text.suffix(4000))])
        default:
            refuse(req, kind: "exec_read", "no such exec pane or not owner")
        }
    }

    // MARK: - close (own pane; available while disarmed)

    private func handleClose(_ req: ExecRequest) {
        guard let handle = req.pane else {
            return refuse(req, kind: "exec_pane_closed", "close requires pane")
        }
        switch registry.access(handle: handle, requester: req.requester, liveGeneration: liveGeneration(req.requester)) {
        case .ok(let record):
            paneManager?.closeExecPane(leafID: record.leafID)
            registry.remove(handle: handle)
            // The pane is gone, so its wait is over — and the agent
            // waiting on it is a DIFFERENT request from this close, owed
            // its own answer.
            endWait(on: handle, outcome: .targetGone)
            receipt(req, kind: "exec_pane_closed", outcome: .closed, pane: handle)
        case .noSuchPane: refuse(req, kind: "exec_pane_closed", "no such exec pane")
        default: refuse(req, kind: "exec_pane_closed", "not the pane owner")
        }
    }

    private func refuse(_ req: ExecRequest, kind: String, _ reason: String) {
        Self.log.info("exec refused (\(kind, privacy: .public)): \(reason, privacy: .public)")
        receipt(req, kind: kind, outcome: .refused, pane: req.pane, detail: reason)
    }
}
