import Foundation
import os

// MARK: - Fixed wake template per [[RFC-0005:C-TEMPLATE]]

enum WakeTemplate {
    /// The canonical wake line. FIXED, with ZERO interpolation of message
    /// content, sender identity, subjects, or counts — whatever reaches a
    /// pane's input becomes user-authority text inside that harness, so
    /// nothing a peer agent can influence may ride it. Single line: a
    /// stray newline is a submit in most harnesses.
    static let line = "[synapty] You have unread A2A messages. Run: synapty recv"
}

// MARK: - State gate per [[RFC-0005:C-STATE-GATE]]

/// Everything the gate decision needs, sampled fresh at decision time.
struct WakeGateInput {
    /// Human's per-pane opt-in (C-AUTHORITY). Default off.
    var armed: Bool
    /// Merged presence from the hub event stream (RFC-0004 vocabulary).
    var mergedStatus: String
    /// Fresh manifest-backed classification of the pane's screen, taken
    /// NOW (not the detector's cached sample). nil = no manifest for the
    /// tool or no rule matched — "cannot see clearly → do not act".
    var freshSample: String?
    /// The surface's child process has exited — never type into a bare
    /// shell that inherited a dead agent's pane.
    var processExited: Bool
    /// Seconds since the human last typed into this pane; nil = never.
    var secondsSinceHumanInput: TimeInterval?
    /// An injection is already in flight for this pane.
    var injectionInFlight: Bool
}

enum WakeGate {
    /// Human-typing recency window (C-STATE-GATE SHOULD: ~3s).
    static let humanBackoff: TimeInterval = 3.0
    /// POSITIVE EVIDENCE set: what the fresh manifest-backed sample must
    /// classify the pane as. Anything else — including nil (no manifest
    /// or no match) — means we cannot see clearly.
    static let restStates: Set<String> = ["idle", "done"]
    /// VETO set for the MERGED status: the hub may know more than the
    /// screen (an explicit hook signal beats a stale-looking frame).
    /// `waiting` is an ABSOLUTE prohibition on both channels (a modal
    /// question — injected text could answer it on the human's behalf);
    /// `working` would splice into the live turn. A merged `unknown`
    /// does NOT block by itself: RFC-0004 C-PRECEDENCE deliberately
    /// parks a freshly registered at-rest agent at unknown (passive done
    /// is gated to working/waiting priors, passive idle is inert), so
    /// requiring merged idle/done made the fresh-edge wake scenario
    /// undeliverable (C-STATE-GATE as amended, 2026-08-11).
    static let vetoStates: Set<String> = ["working", "waiting"]

    enum Decision: Equatable {
        case open
        case closed(String)
    }

    /// Pure gate decision. The initiator is machinery with no judgment
    /// at injection time, so every rule errs closed.
    static func decide(_ input: WakeGateInput) -> Decision {
        if !input.armed { return .closed("not armed") }
        if input.injectionInFlight { return .closed("injection in flight") }
        if input.processExited { return .closed("pane process exited") }
        if vetoStates.contains(input.mergedStatus) {
            return .closed("merged status \(input.mergedStatus)")
        }
        guard let fresh = input.freshSample else {
            return .closed("no fresh classification")
        }
        if !restStates.contains(fresh) {
            return .closed("fresh sample \(fresh)")
        }
        if let since = input.secondsSinceHumanInput, since < humanBackoff {
            return .closed("human typed \(String(format: "%.1f", since))s ago")
        }
        return .open
    }
}

// MARK: - Pending candidates + ack machine per [[RFC-0005:C-WAKE-TRIGGER / C-WAKE-ACK]]

/// Workbench-side mirror of the hub's outstanding wake candidates, plus
/// the acknowledgement discipline the hub deliberately leaves to us:
/// inject → watch for a working edge inside the ack window → delivered,
/// else stalled; retry at most ONCE after the gate re-opens; a second
/// stall exhausts the candidate (badge the human, never loop).
struct WakePendingStore: Equatable {
    struct Entry: Equatable {
        let agentID: String
        var generation: UInt64
        var stalls: Int = 0
        var awaitingAck: Bool = false
        var exhausted: Bool = false
    }

    private(set) var entries: [String: Entry] = [:]

    /// wake_candidate event: upsert. A candidate under a NEW generation
    /// starts clean (no inherited stall count — the RFC's "no wake debt"
    /// works both directions); a duplicate push for the same generation
    /// (e.g. subscription reconnect) leaves in-flight state untouched.
    mutating func candidate(agent: String, generation: UInt64) {
        if let existing = entries[agent], existing.generation == generation { return }
        entries[agent] = Entry(agentID: agent, generation: generation)
    }

    /// wake_cancelled event (self-read / unregister / generation change),
    /// or the human disarming the pane (C-AUTHORITY: immediate).
    mutating func cancel(agent: String) {
        entries.removeValue(forKey: agent)
    }

    /// Candidates eligible for an injection attempt right now.
    var injectable: [Entry] {
        entries.values.filter { !$0.awaitingAck && !$0.exhausted }
    }

    mutating func markInjected(agent: String) {
        entries[agent]?.awaitingAck = true
    }

    /// A working edge (or any lifecycle change) observed while awaiting
    /// ack → the wake is delivered; the entry resolves and is returned
    /// so the caller can report the receipt.
    mutating func acked(agent: String) -> Entry? {
        guard let entry = entries[agent], entry.awaitingAck else { return nil }
        entries.removeValue(forKey: agent)
        return entry
    }

    enum StallOutcome: Equatable {
        /// First stall: the candidate survives; retry once the gate re-opens.
        case retryLater
        /// Second stall: stop and surface to the human (badge), never loop.
        case exhausted
    }

    /// Ack window elapsed with no edge. Returns nil when the entry is
    /// gone (cancelled or acked in the meantime) — nothing to report.
    mutating func stalled(agent: String) -> StallOutcome? {
        guard var entry = entries[agent], entry.awaitingAck else { return nil }
        entry.awaitingAck = false
        entry.stalls += 1
        if entry.stalls >= 2 { entry.exhausted = true }
        entries[agent] = entry
        return entry.exhausted ? .exhausted : .retryLater
    }
}

// MARK: - Injection mechanics per [[RFC-0005:C-INJECTION-MECHANICS]]

/// Types into the surface exactly as a keyboard would — the only viable
/// locus (the daemon does not own the harness's stdin; the surface path
/// works for local and SSH panes, focused or not). No focus theft, no
/// viewport disturbance: ghostty_surface_text/_key write straight into
/// the surface's input pipeline.
enum WakeInjector {
    /// Enter trails the text by this settle delay so TUI harnesses treat
    /// text and submit as distinct inputs (herdr's empirically proven
    /// constant, C-PRIOR-ART).
    static let enterDelay: TimeInterval = 0.3

    @MainActor
    static func type(_ text: String, into surface: ghostty_surface_t) {
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Enter as a separate key event (press + release), encoded from the
    /// keycode like a physical Return (text stays nil — ghostty encodes
    /// CR itself, mirroring TerminalSurface's non-printable path).
    @MainActor
    static func pressEnter(_ surface: ghostty_surface_t) {
        var press = ghostty_input_key_s()
        press.action = GHOSTTY_ACTION_PRESS
        press.keycode = 36 // kVK_Return
        press.mods = ghostty_input_mods_e(rawValue: 0)
        press.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        press.composing = false
        press.text = nil
        press.unshifted_codepoint = 0x0D
        _ = ghostty_surface_key(surface, press)
        var release = press
        release.action = GHOSTTY_ACTION_RELEASE
        release.unshifted_codepoint = 0
        _ = ghostty_surface_key(surface, release)
    }
}

// MARK: - Coordinator (runtime wiring)

/// Consumes wake_candidate/wake_cancelled from the hub event stream,
/// holds the pending store, evaluates the gate on candidate arrival +
/// presence edges + a ~2s cadence, injects through the ghostty surface,
/// and closes the loop with wake_report receipts.
@MainActor @Observable final class WakeCoordinator {
    private weak var paneManager: WorkspaceManager?
    private weak var agentMonitor: AgentMonitor?
    private weak var detector: AgentDetector?
    private var port: Int = 9000
    private var timer: Timer?
    private(set) var store = WakePendingStore()
    /// Ack watches per agent — cancelled on delivery/cancellation.
    private var ackTasks: [String: Task<Void, Never>] = [:]
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "synapty", category: "wake")

    /// C-WAKE-ACK window (herdr's agent_prompt_stalled constant).
    static let ackWindow: TimeInterval = 5.0
    /// Pending-candidate re-evaluation cadence (C-WAKE-TRIGGER: the
    /// passive sampling cadence).
    static let interval: TimeInterval = 2.0

    func start(
        paneManager: WorkspaceManager, agentMonitor: AgentMonitor,
        detector: AgentDetector, port: Int
    ) {
        self.paneManager = paneManager
        self.agentMonitor = agentMonitor
        self.detector = detector
        self.port = port
        paneManager.onWakeDisarmed = { [weak self] agentID in
            // C-AUTHORITY: disarm cancels pending candidates immediately.
            self?.store.cancel(agent: agentID)
            self?.dropAckTask(agentID)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for task in ackTasks.values { task.cancel() }
        ackTasks = [:]
    }

    private func dropAckTask(_ agentID: String) {
        ackTasks[agentID]?.cancel()
        ackTasks[agentID] = nil
    }

    /// Hub event intake — wired to AgentMonitor.onHubEvent.
    func handleHubEvent(_ payload: [String: Any]) {
        guard let kind = payload["kind"] as? String,
              let agent = payload["agent"] as? String else { return }
        switch kind {
        case "wake_candidate":
            let gen = UInt64(payload["generation"] as? Int ?? 0)
            store.candidate(agent: agent, generation: gen)
            evaluate()
        case "wake_cancelled":
            store.cancel(agent: agent)
            dropAckTask(agent)
        case "agent_status_changed":
            // Any observed lifecycle change inside the ack window counts
            // as the acknowledgement (C-WAKE-ACK) …
            if let entry = store.acked(agent: agent) {
                dropAckTask(agent)
                HubEventClient.sendWakeReport(
                    port: port, agent: agent, generation: entry.generation,
                    outcome: "delivered")
                Self.log.debug("wake delivered: \(agent, privacy: .public)")
            }
            // … and presence edges re-open the gate for pending
            // candidates (C-WAKE-TRIGGER re-evaluation rule).
            evaluate()
        case "agent_unregistered":
            // The hub also emits wake_cancelled, but being event-driven
            // both ways costs nothing and closes the gap if ordering
            // ever changes.
            store.cancel(agent: agent)
            dropAckTask(agent)
        default:
            break
        }
    }

    /// Try every injectable candidate against the gate; inject when open.
    private func evaluate() {
        guard let paneManager, let agentMonitor, let detector else { return }
        for entry in store.injectable {
            guard let leafID = paneManager.leafID(forAgent: entry.agentID),
                  let info = agentMonitor.agents.first(where: { $0.id == entry.agentID })
            else { continue } // no pane hosts it — stays pending
            guard let surface = GhosttyApp.shared?.surface(forLeaf: leafID) else { continue }

            let input = WakeGateInput(
                armed: paneManager.isWakeArmed(leafID),
                mergedStatus: info.status,
                freshSample: detector.freshClassification(agentID: entry.agentID),
                processExited: ghostty_surface_process_exited(surface),
                secondsSinceHumanInput: GhosttyApp.shared?.secondsSinceHumanInput(forLeaf: leafID),
                injectionInFlight: false // injectable ⇒ not awaiting ack
            )
            switch WakeGate.decide(input) {
            case .closed(let reason):
                Self.log.debug(
                    "wake gate closed for \(entry.agentID, privacy: .public): \(reason, privacy: .public)")
            case .open:
                inject(entry: entry, leafID: leafID, surface: surface)
            }
        }
    }

    private func inject(entry: WakePendingStore.Entry, leafID: UUID, surface: ghostty_surface_t) {
        let agent = entry.agentID
        let generation = entry.generation
        store.markInjected(agent: agent)
        Self.log.info("wake inject into \(agent, privacy: .public) gen \(generation, privacy: .public)")
        WakeInjector.type(WakeTemplate.line, into: surface)

        // Enter is fire-and-forget after the settle delay — once the text
        // is typed, submitting OUR OWN fixed line is always correct, even
        // if the candidate resolves in the gap (never leave a half-typed
        // wake sitting in the prompt).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(WakeInjector.enterDelay * 1_000_000_000))
            if let live = GhosttyApp.shared?.surface(forLeaf: leafID) {
                WakeInjector.pressEnter(live)
            }
        }

        // The ack watch is cancellable (delivery/cancellation drops it).
        dropAckTask(agent)
        ackTasks[agent] = Task { @MainActor [weak self] in
            let window = WakeInjector.enterDelay + Self.ackWindow
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.ackTasks[agent] = nil
            switch self.store.stalled(agent: agent) {
            case .retryLater:
                HubEventClient.sendWakeReport(
                    port: self.port, agent: agent, generation: generation, outcome: "stalled")
                Self.log.info("wake stalled (will retry once): \(agent, privacy: .public)")
            case .exhausted:
                HubEventClient.sendWakeReport(
                    port: self.port, agent: agent, generation: generation, outcome: "stalled")
                // Second stall: stop and surface to the human — a stalled
                // wake means the manifest may be misreading this harness.
                self.agentMonitor?.markNeedsAttention(agent)
                self.paneManager?.leafNeedsAttention(leafID)
                Self.log.info("wake exhausted, badged: \(agent, privacy: .public)")
            case nil:
                break // resolved while we slept
            }
        }
    }
}
