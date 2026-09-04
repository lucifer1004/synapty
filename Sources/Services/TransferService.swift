import Foundation
import Observation
import os

/// Where a file is: a host, or this Mac.
///
/// LOCAL IS AN ENDPOINT, NOT A SPECIAL CASE. Every cross-host transfer
/// relays through this machine ([[RFC-0013]] C-BROKER), so a download and
/// an upload are the two halves the relay is built from rather than
/// separate features.
struct FileEndpoint: Equatable, Hashable {
    /// nil means this Mac.
    var hostID: UUID?
    var path: String
    /// A TREE, NOT A FILE. Carried on the endpoint because almost
    /// everything downstream has to know: the copy needs `-r`, the size is
    /// a walk rather than a stat, and the limit that protects a human from
    /// an agent depends on that size being the real one.
    var isDirectory: Bool = false

    var isLocal: Bool { hostID == nil }

    var fileName: String { (path as NSString).lastPathComponent }
}

/// What a drop MEANS, which depends only on whether the two ends are the
/// same machine.
///
/// The same gesture has to do two different things, and guessing between
/// them by file type or by modifier key would make it unpredictable. The
/// machine identity is the whole rule: a file already on the destination
/// does not need to be sent there, so the useful act is naming it.
enum DropOutcome: Equatable {
    case transfer
    case pastePath
}

enum DropRule {
    static func outcome(dragging source: FileEndpoint, onto destination: FileEndpoint) -> DropOutcome {
        source.hostID == destination.hostID ? .pastePath : .transfer
    }
}

/// The resident owner of every byte this workbench moves.
///
/// RESIDENT, AND THE VIEWS ARE ITS CALLERS — never the other way round
/// ([[ADR-0010]]). A transfer outlives the panel that started it: the
/// human switches the panel to another view, closes it, or changes host
/// while a file is still moving, and none of that may cancel or orphan the
/// work. The same service is what the CLI verbs enter at stage two, so a
/// transfer implemented inside a view would have to be torn out to get
/// there.
///
/// [[WI-2026-08-15-009]]
@MainActor @Observable final class TransferService {

    /// For the CLI bridge and the status bar, which need the queue without
    /// owning it. Weak for the same reason TunnelManager's is.
    static weak var shared: TransferService?

    weak var tunnelManager: TunnelManager?
    weak var hostStore: HostStore?

    /// Who asked. Recorded per transfer because a plane serving both a
    /// human's gesture and an agent's call must be able to say which one
    /// it was serving ([[RFC-0013]] C-AUTHORIZATION).
    enum Initiator: Equatable {
        case human
        case agent(String)

        var label: String {
            switch self {
            case .human: return "you"
            case .agent(let id): return id
            }
        }
    }

    enum State: Equatable {
        case queued
        case running
        /// A name at the destination is taken and the human has not said
        /// what to do. NOT a failure and not progress — it is a question,
        /// and the transfer resumes the moment it is answered.
        case awaitingChoice(String)
        case done
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            case .queued, .running, .awaitingChoice: return false
            }
        }
    }

    struct Transfer: Identifiable, Equatable {
        let id: UUID
        let source: FileEndpoint
        let destination: FileEndpoint
        let initiator: Initiator
        let startedAt: Date
        var state: State
        /// Bytes the destination has, as far as we can tell. nil while the
        /// size is unknown rather than 0 — a progress bar reading zero and
        /// a progress bar that does not know are different claims, and only
        /// one of them is honest here.
        var bytesWritten: Int64?
        var totalBytes: Int64?
        /// What the human answered about a name collision, when they were
        /// asked. nil means nobody has been asked — and the safe answer
        /// stands until they are.
        var conflictChoice: TransferPlan.OnConflict?

        var fileName: String { source.fileName }

        var fraction: Double? {
            guard let bytesWritten, let totalBytes, totalBytes > 0 else { return nil }
            return min(1, Double(bytesWritten) / Double(totalBytes))
        }
    }

    private(set) var transfers: [Transfer] = []

    // MARK: - Pane writes ([[RFC-0015]] C-PANE-WRITES)

    /// A DESTRUCTIVE FILE-PANE OPERATION MUST BE VISIBLE AFTERWARDS, on
    /// the same surface transfers are reported on.
    ///
    /// NOT MODELLED AS A TRANSFER, though it would have been shorter: a
    /// deletion has no destination, no byte count and no progress, and a
    /// record that invents them is a record that lies in three fields to
    /// save one type. The clause asks for the same SURFACE, not the same
    /// shape.
    ///
    /// The human's own writes are unscoped — C-PANE-WRITES says so, and
    /// says why: the four properties an agent's write must have exist to
    /// make an ABSENT party's actions reviewable, and here the human IS
    /// the reviewing party. What survives is this: an act nobody can find
    /// again is one nobody can audit, including their own.
    struct PaneWrite: Identifiable, Equatable {
        enum Verb: Equatable {
            case createdFolder
            case renamed(to: String)
            case deleted(PaneWrites.Disposal)
        }

        let id: UUID
        let verb: Verb
        let machine: String
        let path: String
        let at: Date
        var failure: String?

        var name: String { (path as NSString).lastPathComponent }

        /// What the human reads in the stream. The disposal is said out
        /// loud for a deletion, because "deleted" means two different
        /// things on the two sides of C-PANE-WRITES' split.
        var summary: String {
            if let failure { return "could not \(attempt): \(failure)" }
            switch verb {
            case .createdFolder: return "created \(name) on \(machine)"
            case .renamed(let to): return "renamed \(name) to \(to) on \(machine)"
            case .deleted(.trash): return "moved \(name) to the Trash"
            case .deleted(.unrecoverable): return "deleted \(name) on \(machine) — not recoverable"
            }
        }

        private var attempt: String {
            switch verb {
            case .createdFolder: return "create \(name) on \(machine)"
            case .renamed(let to): return "rename \(name) to \(to) on \(machine)"
            case .deleted: return "delete \(name) on \(machine)"
            }
        }
    }

    private(set) var paneWrites: [PaneWrite] = []
    /// A record a human reads in Activity, not an audit log: the system
    /// log has every write. Bounded so a long session does not keep every
    /// one in memory ([[WI-2026-09-02-034]]).
    static let paneWritesKept = 500

    @discardableResult
    func record(_ write: PaneWrite) -> UUID {
        paneWrites.append(write)
        if paneWrites.count > Self.paneWritesKept {
            paneWrites.removeFirst(paneWrites.count - Self.paneWritesKept)
        }
        return write.id
    }

    /// A FAILED WRITE IS REPORTED AS A FAILURE ([[RFC-0015]]
    /// C-PANE-WRITES) — the record is amended rather than dropped, because
    /// an attempt that failed is a thing that happened.
    func noteFailure(_ id: UUID, _ why: String) {
        guard let idx = paneWrites.firstIndex(where: { $0.id == id }) else { return }
        paneWrites[idx].failure = why
    }

    /// Cancellation is cooperative: the runner checks this between its two
    /// halves and before it starts. A relay is a download then an upload,
    /// so a cancel that lands between them must not begin the second.
    private var cancelled: Set<UUID> = []

    /// SEVERAL COPIES AT ONCE IS SLOWER THAN A FEW, and now each of them
    /// also takes a connection of its own — five files dropped at once would
    /// be five authentications and five scp processes contending for the
    /// same link, which finishes later than two at a time and leaves the
    /// host holding five masters. This is also where the backpressure
    /// agent-initiated transfers will need ([[RFC-0013]] C-CONTROL-PLANE)
    /// has somewhere to go.
    private let maxConcurrent = 2

    private var runningCount: Int { transfers.filter { $0.state == .running }.count }

    private static let log = Logger(subsystem: "com.synapty.app", category: "Transfer")

    /// Transfers still doing something. What the status bar shows, and what
    /// keeps a progress indicator alive while the panel is elsewhere.
    var inFlight: [Transfer] { transfers.filter { !$0.state.isFinished } }

    /// Called on every state change so the activity stream can record what
    /// happened without this service knowing what an activity stream is.
    var onEvent: ((Transfer) -> Void)?

    /// One-shot callbacks for callers that are holding something open until
    /// a transfer lands — a file promise a receiver is waiting on, and
    /// nothing else so far.
    private var completions: [UUID: (State) -> Void] = [:]

    /// Run `body` once this transfer reaches a terminal state, or at once
    /// if it already has.
    func whenFinished(_ id: UUID, _ body: @escaping (State) -> Void) {
        guard let transfer = transfers.first(where: { $0.id == id }) else {
            return body(.failed("that transfer is gone"))
        }
        if transfer.state.isFinished { return body(transfer.state) }
        completions[id] = body
    }

    // MARK: - Queueing

    @discardableResult
    func enqueue(
        from source: FileEndpoint,
        to destination: FileEndpoint,
        initiator: Initiator = .human
    ) -> UUID {
        let transfer = Transfer(
            id: UUID(),
            source: source,
            destination: destination,
            initiator: initiator,
            startedAt: Date(),
            state: .queued,
            bytesWritten: nil,
            totalBytes: nil)
        transfers.append(transfer)
        recordNew(transfer)
        onEvent?(transfer)
        pump()
        return transfer.id
    }

    /// Start whatever the concurrency limit has room for, oldest first.
    private func pump() {
        while runningCount < maxConcurrent,
              let next = transfers.first(where: { $0.state == .queued }) {
            // start() always leaves .queued — for .running, or for a
            // terminal state when it cannot plan — so this cannot spin.
            start(next.id)
        }
    }

    func cancel(_ id: UUID) {
        cancelled.insert(id)
        // A transfer with nothing running finishes HERE, because nothing
        // will come along later to notice. A running one is left to its
        // runner, which reports the cancellation when it next looks.
        //
        // `.awaitingChoice` belongs in the first group and was missed:
        // there is no runner behind a paused transfer, so Cancel in the
        // sheet left it waiting forever — and still counted on the badge,
        // which is the one number that must not lie about what is waiting.
        guard let transfer = transfers.first(where: { $0.id == id }) else { return }
        switch transfer.state {
        case .queued, .awaitingChoice:
            update(id) { $0.state = .cancelled }
        case .running, .done, .failed, .cancelled:
            break
        }
    }

    /// How many finished transfers are kept. Bounded because this is a
    /// record a human reads, not an audit log — the durable answer is the
    /// system log, which has every one of them with its initiator.
    private static let historyLimit = 100

    /// Trim the oldest finished rows once the record outgrows what anyone
    /// would scroll. In-flight ones are never dropped.
    private func trimHistory() {
        var finished = transfers.enumerated().filter { $0.element.state.isFinished }
        guard finished.count > Self.historyLimit else { return }
        let excess = finished.count - Self.historyLimit
        let doomed = Set(finished.prefix(excess).map { $0.element.id })
        transfers.removeAll { doomed.contains($0.id) }
        finished.removeAll()
    }

    // MARK: - Running

    private func update(_ id: UUID, _ mutate: (inout Transfer) -> Void) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        let before = transfers[idx].state
        mutate(&transfers[idx])
        // ONLY A TRANSITION IS AN EVENT. Progress arrives once a second and
        // is not news: recording it would put a line per second per
        // transfer into the log and into the activity stream, which is how
        // a record stops being read.
        if transfers[idx].state != before {
            record(transfers[idx])
            if transfers[idx].state.isFinished, let done = completions.removeValue(forKey: id) {
                done(transfers[idx].state)
            }
        }
        onEvent?(transfers[idx])
    }

    /// A first write, which has no previous state to differ from.
    private func recordNew(_ transfer: Transfer) { record(transfer) }

    /// EVERY TRANSFER IS RECORDED WITH ITS INITIATOR ([[RFC-0013]]
    /// C-AUTHORIZATION). The log is the channel that still exists after the
    /// window is gone and that an agent on the machine can read; the strip
    /// in the panel answers the other question, for the person present now
    /// ([[RFC-0012]] C-TWO-CHANNELS).
    private func record(_ transfer: Transfer) {
        let who = transfer.initiator.label
        let from = describe(transfer.source)
        let to = describe(transfer.destination)
        switch transfer.state {
        case .queued, .running:
            AppLog.transfer.info(
                "\(transfer.state == .running ? "started" : "queued", privacy: .public) \(from, privacy: .public) -> \(to, privacy: .public) for \(who, privacy: .public)")
        case .done:
            AppLog.transfer.info(
                "delivered \(from, privacy: .public) -> \(to, privacy: .public) (\(transfer.bytesWritten ?? 0) bytes) for \(who, privacy: .public)")
        case .awaitingChoice(let name):
            // WHY, for whoever reads this later: a transfer that stopped
            // and said nothing looks identical to one that hung.
            AppLog.transfer.info(
                "waiting on a name decision for \(name, privacy: .public): \(to, privacy: .public) already has one")
        case .cancelled:
            AppLog.transfer.info("cancelled \(from, privacy: .public) -> \(to, privacy: .public)")
        case .failed(let why):
            AppLog.transfer.error(
                "failed \(from, privacy: .public) -> \(to, privacy: .public): \(why, privacy: .public)")
        }
    }

    /// The machine an endpoint is on, as a human names it. Needed by the
    /// activity stream, where "where did this file come from" is the whole
    /// question a record exists to answer.
    func machineName(of endpoint: FileEndpoint) -> String {
        guard let hostID = endpoint.hostID else { return "this Mac" }
        guard let host = hostStore?.hosts.first(where: { $0.id == hostID }) else { return "a host" }
        return host.label.isEmpty ? host.address : host.label
    }

    private func describe(_ endpoint: FileEndpoint) -> String {
        guard let hostID = endpoint.hostID else { return "local:\(endpoint.path)" }
        let host = hostStore?.hosts.first { $0.id == hostID }
        let name = host.map { $0.label.isEmpty ? $0.address : $0.label } ?? hostID.uuidString
        return "\(name):\(endpoint.path)"
    }

    private func start(_ id: UUID) {
        guard let transfer = transfers.first(where: { $0.id == id }) else { return }
        if takeCancellation(of: id) { return }
        guard let plan = plan(for: transfer) else {
            update(id) { $0.state = .failed("No connection to that host.") }
            return
        }
        // A HUMAN CAN BE ASKED, SO ASK — ONCE. An agent is not present and
        // its plan already carries `.rename`, so this costs nothing on
        // that path. The check is a round trip when the destination is
        // remote, which is why it runs off the main actor and why the
        // answer is remembered on the transfer rather than asked again.
        if transfer.initiator == .human, transfer.conflictChoice == nil {
            update(id) { $0.state = .running }
            let probe = self.probe
            Task.detached(priority: .utility) { [weak self] in
                let name = (plan.from.path as NSString).lastPathComponent
                let destination = TransferRunner.destinationLeg(plan.to, defaultName: name)
                let presence = probe(destination)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // A CANCEL THAT LANDED WHILE THE PROBE RAN is the
                    // human's answer, and it arrived before the question
                    // could be put ([[WI-2026-09-02-023]]).
                    if self.takeCancellation(of: id) { return }
                    switch presence {
                    case .absent:
                        self.run(id, plan: plan)
                    case .present:
                        self.update(id) { $0.state = .awaitingChoice(name) }
                        self.pump()
                    case .unknown:
                        self.update(id) {
                            $0.state = .failed(
                                TransferRunner.DeliveryRefusal.destinationUnknown(destination.path).message)
                        }
                    }
                }
            }
            return
        }
        run(id, plan: plan)
    }

    /// How the destination is asked whether a name is taken. A round trip
    /// for a remote leg; replaceable so the window between asking and
    /// answering can be held open by a test.
    var probe: @Sendable (TransferPlan.Leg) -> TransferRunner.Presence = TransferRunner.presence

    /// True, and the mark consumed, if this transfer was cancelled while
    /// nothing was watching for it. The caller stops there.
    private func takeCancellation(of id: UUID) -> Bool {
        guard cancelled.contains(id) else { return false }
        cancelled.remove(id)
        update(id) { $0.state = .cancelled }
        return true
    }

    private func run(_ id: UUID, plan: TransferPlan) {
        if takeCancellation(of: id) { return }
        update(id) { $0.state = .running }
        Task.detached(priority: .utility) { [weak self] in
            let (bound, release) = plan.takingExclusiveConnections()
            let outcome = TransferRunner.execute(bound)
            // BEFORE THE HOP BACK, not after: a connection still counted as
            // occupied is one the next transfer will refuse to reuse, and it
            // would grow the pool for a copy that has already finished.
            release()
            await MainActor.run { [weak self] in
                self?.finish(id, outcome)
            }
        }
        trackProgress(id, plan: plan)
    }

    // MARK: - The question

    /// Transfers stopped on a name that is already taken.
    var awaitingChoice: [Transfer] {
        transfers.filter { if case .awaitingChoice = $0.state { return true }; return false }
    }

    /// FINDER'S WORDS, because the human already has them. "Keep Both" is
    /// the same rename an agent takes; "Replace" is the only way anything
    /// is ever destroyed here, and it exists only because a person asked
    /// for it in front of the file it applies to.
    func resolveConflict(_ id: UUID, _ choice: TransferPlan.OnConflict) {
        guard let transfer = transfers.first(where: { $0.id == id }),
              case .awaitingChoice = transfer.state else { return }
        update(id) {
            $0.conflictChoice = choice
            $0.state = .queued
        }
        pump()
    }

    /// Watch a running copy by asking how much has ARRIVED.
    ///
    /// scp reports progress only to a terminal — it looks for a TTY and
    /// draws a bar — and this spawns it on a pipe, so nothing comes back
    /// until it exits. Before this, `fraction` was computed from bytes that
    /// were only ever written at COMPLETION, which made the determinate
    /// branch of the progress view unreachable and left an indeterminate
    /// spinner that cannot tell "moving" from "wedged".
    ///
    /// Polling the destination is coarse — scp buffers, so the number lags
    /// — but it is a MEASUREMENT rather than an estimate, and it is the
    /// same question a human would ask: how much of it is there now.
    ///
    /// FIRST POLL AFTER A SECOND, so a small transfer finishes without ever
    /// costing a round trip.
    ///
    /// AND THEN AS OFTEN AS THE ANSWER IS CHEAP. Measured against a live
    /// host: asking a file's size costs the round trip and nothing more
    /// (0.35s), while walking a large tree costs 16 to 35 SECONDS — and a
    /// fixed one-second interval against that means polls pile up on each
    /// other, hammer the far side's disk, and crowd the connection, all to
    /// draw a bar. So each probe is timed and the next one waits a multiple
    /// of what the last cost. A cheap answer is asked for often; an
    /// expensive one backs off on its own, without a number chosen per tool
    /// or per tree.
    ///
    /// PAST A POINT, PROGRESS IS NOT WORTH ITS PRICE. A probe over the
    /// ceiling stops the polling entirely and the view falls back to the
    /// indeterminate spinner — which says "moving, amount unknown", and is
    /// the honest thing to say when finding out would cost more than the
    /// transfer gains.
    private func trackProgress(_ id: UUID, plan: TransferPlan) {
        Task.detached(priority: .utility) { [weak self] in
            // THE SAME ANSWER THE COPY USES. Both readers resolve a remote
            // source the same way or the progress bar sizes a directory as
            // a file — already off the main actor here, which is the whole
            // reason the question is asked in these two places and not at
            // the call site.
            let recursive = plan.sourceIsDirectory
                || TransferRunner.isRemoteDirectory(plan.from)
            let total = TransferRunner.size(of: plan.from, recursive: recursive)
            // A relay writes its first hop into a staging directory, so the
            // destination worth watching is the one the plan names.
            let destination = TransferRunner.destinationLeg(
                plan.to, defaultName: (plan.from.path as NSString).lastPathComponent)

            var interval: UInt64 = 1_000_000_000
            let ceiling: TimeInterval = 5
            while true {
                try? await Task.sleep(nanoseconds: interval)
                let stillRunning = await MainActor.run { [weak self] in
                    self?.transfers.first { $0.id == id }?.state == .running
                }
                guard stillRunning == true else { return }

                let started = Date()
                let written = TransferRunner.size(of: destination, recursive: recursive)
                let cost = Date().timeIntervalSince(started)

                await MainActor.run { [weak self] in
                    guard let self, self.transfers.first(where: { $0.id == id })?.state == .running
                    else { return }
                    self.update(id) {
                        $0.totalBytes = total
                        $0.bytesWritten = written
                    }
                }
                guard cost <= ceiling else {
                    Self.log.info(
                        "progress polling stopped: one probe cost \(cost, format: .fixed(precision: 1))s")
                    return
                }
                // Never more than a tenth of the time spent finding out how
                // far along we are.
                interval = UInt64(max(1.0, cost * 10) * 1_000_000_000)
            }
        }
    }

    private func finish(_ id: UUID, _ outcome: TransferRunner.Outcome) {
        // A cancel that landed while the copy ran reports as cancelled, not
        // as whatever the copy happened to return: the human's answer is
        // the one that stands.
        if cancelled.contains(id) {
            cancelled.remove(id)
            update(id) { $0.state = .cancelled }
        } else {
            switch outcome {
            case .ok(let bytes):
                update(id) {
                    $0.bytesWritten = bytes
                    $0.totalBytes = bytes
                    $0.state = .done
                }
                // A TRANSFER THAT WORKED HAD NOTHING TO SHOW FOR IT. The
                // strip clears, the row lands in Activity nobody is
                // looking at, and a drag that succeeded looked exactly
                // like a drag that silently did nothing — which is how the
                // drop being broken went unnoticed for as long as it did.
                announce(id, .done)
            case .failed(let why):
                update(id) { $0.state = .failed(why) }
                announce(id, .failed, why)
            }
        }
        trimHistory()
        // A slot just freed.
        pump()
    }

    /// Say what became of it, naming the FILE — "Delivered" alone is not
    /// an answer to "delivered what", and this is the last moment anything
    /// can say so.
    private func announce(_ id: UUID, _ tone: AppNotifications.Tone, _ why: String? = nil) {
        guard let transfer = transfers.first(where: { $0.id == id }) else { return }
        let name = (transfer.source.path as NSString).lastPathComponent
        let where_ = machineName(of: transfer.destination)
        AppNotifications.shared?.post(
            tone,
            tone == .done ? "Delivered to \(where_)" : "Transfer failed",
            detail: tone == .done ? name : "\(name) — \(why ?? "")")
    }

    /// Resolve the hosts into everything the runner needs, ON THE MAIN
    /// ACTOR, so the work itself touches no shared state. The runner is a
    /// pure function of this plan.
    /// WHERE THIS ENDPOINT IS, resolved into something the runner can use
    /// without reaching back for anything.
    ///
    /// Lifted out of `plan` because deciding whether a transfer may happen
    /// needs the same resolution as running it, and answering the question
    /// twice is how the two answers come to differ.
    func leg(for endpoint: FileEndpoint) -> TransferPlan.Leg? {
        guard let hostID = endpoint.hostID else { return .local(endpoint.path) }
        guard let tunnelManager,
              let host = hostStore?.hosts.first(where: { $0.id == hostID })
        else { return nil }
        // The connection here is the one a SHORT command would ride —
        // what the progress poll needs. The transfer itself takes one
        // carrying nothing else, and it takes it in the runner because
        // doing so authenticates when every existing connection is busy
        // ([[RFC-0013]] C-BROKER).
        return .remote(tunnelManager.connection(for: host), path: endpoint.path)
    }

    private func plan(for transfer: Transfer) -> TransferPlan? {
        func leg(_ endpoint: FileEndpoint) -> TransferPlan.Leg? { self.leg(for: endpoint) }
        func binding(_ endpoint: FileEndpoint) -> TransferPlan.PoolBinding? {
            guard let hostID = endpoint.hostID, let tunnelManager,
                  let host = hostStore?.hosts.first(where: { $0.id == hostID })
            else { return nil }
            return TransferPlan.PoolBinding(pool: tunnelManager.pool,
                                            key: tunnelManager.poolKey(for: host))
        }
        guard let from = leg(transfer.source), let to = leg(transfer.destination) else { return nil }
        // A HUMAN'S DRAG CAN STILL BE ASKED; AN AGENT CANNOT. Until the
        // asking exists, both take the safe answer — the one that destroys
        // nothing — because the alternative to asking is not replacing, it
        // is losing a file with no record that it was there.
        return TransferPlan(from: from, to: to,
                            onConflict: transfer.conflictChoice ?? .rename,
                            sourceIsDirectory: transfer.source.isDirectory,
                            fromPool: binding(transfer.source),
                            toPool: binding(transfer.destination))
    }
}

/// Everything one transfer needs, resolved. Sendable by construction so
/// the runner can leave the main actor without reaching back for anything.
struct TransferPlan: Sendable, Equatable {
    enum Leg: Sendable, Equatable {
        case local(String)
        case remote(RemoteConnection, path: String)

        var path: String {
            switch self {
            case .local(let p): return p
            case .remote(_, let p): return p
            }
        }

        var isLocal: Bool { if case .local = self { return true }; return false }
    }

    /// What to do when the destination name is already taken.
    ///
    /// TWO ANSWERS, BECAUSE THERE ARE TWO INITIATORS. A human is present
    /// and gets asked; an agent is not, so it takes a new name rather than
    /// somebody else's place. Silently replacing is not on the list — it
    /// is the only outcome that destroys something and leaves no trace it
    /// existed ([[RFC-0013]] C-AUTHORIZATION).
    enum OnConflict: Equatable {
        /// Take the next free name. What an agent always does.
        case rename
        /// The human answered "replace", so replace.
        case replace
    }

    /// Which pool a remote end belongs to, so the runner can take a
    /// connection carrying nothing else. Held beside the leg rather than
    /// inside it because every other reader of a leg wants a path and a
    /// connection, not a placement.
    struct PoolBinding: @unchecked Sendable, Equatable {
        let pool: MasterPool
        let key: MasterPool.HostKey
        /// THE NAME THE SLOT WAS TAKEN UNDER, set when the leg is bound.
        /// Carried so the runner can move the slot rather than take a
        /// second one: a connection that refuses a channel has to be left
        /// behind WITH its record, and a release keyed on the tenant finds
        /// the slot wherever it ended up.
        var tenant: String?
        static func == (a: Self, b: Self) -> Bool {
            a.pool === b.pool && a.key == b.key && a.tenant == b.tenant
        }
    }

    var from: Leg
    var to: Leg
    var onConflict: OnConflict = .rename
    /// A tree, so the copy recurses and the size is a walk.
    var sourceIsDirectory: Bool = false
    var fromPool: PoolBinding?
    var toPool: PoolBinding?

    /// Put each remote end on a connection carrying nothing else, and hand
    /// back what releases them.
    ///
    /// This is the placement C-BROKER's measurement requires and the only
    /// one that is not least-loaded: sharing with a waiting human cost
    /// 8-18 seconds of keystroke latency during a 60 MB transfer. A host
    /// that will not open another connection keeps the leg it already has,
    /// because a slow terminal beats a transfer that cannot run.
    ///
    /// BLOCKS — it authenticates when every existing connection is busy, so
    /// it belongs off the main actor.
    func takingExclusiveConnections() -> (TransferPlan, @Sendable () -> Void) {
        var held: [(MasterPool, String)] = []
        // ONE NAME PER LEG, minted here and used for both the claim and
        // the release, so the slot is given back by the thing that took it
        // rather than by a remembered socket path.
        func bind(_ leg: Leg, _ binding: inout PoolBinding?, _ side: String) -> Leg {
            guard case .remote(var connection, let path) = leg, let held_binding = binding
            else { return leg }
            let tenant = "transfer.\(UUID().uuidString).\(side)"
            guard let socket = held_binding.pool.placeExclusive(held_binding.key, tenant: tenant)
            else { return leg }
            held.append((held_binding.pool, tenant))
            binding?.tenant = tenant
            connection.controlPath = socket
            return .remote(connection, path: path)
        }
        var bound = self
        bound.from = bind(from, &bound.fromPool, "from")
        bound.to = bind(to, &bound.toPool, "to")
        let taken = held
        return (bound, { for (pool, tenant) in taken { pool.release(tenant: tenant) } })
    }

    /// TWO REMOTE ENDS MEANS TWO HOPS, and that is the design rather than a
    /// limitation of the tool: `scp` can take one ControlPath, and these are
    /// two different hosts with two different masters. Relaying through here
    /// is also the only topology in which neither host learns a credential
    /// for the other ([[RFC-0013]] C-BROKER).
    var needsRelay: Bool { !from.isLocal && !to.isLocal }
}

/// The half of a transfer that runs off the main actor. Free functions over
/// a plan, so nothing here can touch observable state.
enum TransferRunner {

    enum Outcome: Equatable {
        case ok(Int64)
        case failed(String)
    }

    static func execute(_ plan: TransferPlan) -> Outcome {
        // RESOLVED HERE FOR A REMOTE SOURCE, because asking costs an ssh
        // round trip and this is the first place that can afford one: the
        // caller decides on the main actor, where a fifteen-second answer
        // is fifteen seconds of frozen window.
        let recursive = plan.sourceIsDirectory || isRemoteDirectory(plan.from)
        if plan.needsRelay {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("synapty-relay-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            // The staging path is a DIRECTORY for a tree, so the first hop
            // lands the whole thing inside it and the second sends that on.
            try? FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
            let name = (plan.from.path as NSString).lastPathComponent
            switch copyRetryingRefusal(from: plan.from, to: .local(staging.path),
                                       recursive: recursive, plan: plan) {
            case .failed(let why): return .failed(why)
            case .ok: break
            }
            let staged = TransferPlan.Leg.local(staging.appendingPathComponent(name).path)
            return deliverRefusingUnknown(from: staged, named: name, recursive: recursive, plan: plan)
        }
        let name = (plan.from.path as NSString).lastPathComponent
        return deliverRefusingUnknown(from: plan.from, named: name, recursive: recursive, plan: plan)
    }

    /// A COPY, AND IF THE CONNECTION IT WAS HANDED WILL NOT OPEN A CHANNEL,
    /// ANOTHER CONNECTION TO THAT HOST AND THE SAME COPY THERE
    /// ([[RFC-0013]] C-BROKER).
    ///
    /// THE HEARTBEAT ONLY FINDS THIS AHEAD OF TIME. It probes each member
    /// and marks a refusing one full, so demand arriving LATER is placed
    /// elsewhere — but a transfer that walks into the bound between two
    /// probes was simply failing, with the remote's own message, and the
    /// pool learnt nothing from it. Detection was shipped and the retry the
    /// clause asks for was not.
    ///
    /// NO REMOTE LIMIT IS READ OR ASSUMED. The refusal IS the discovery:
    /// the far side says no, this connection is marked full, and the next
    /// one is opened. That is what makes it right on a host permitting five
    /// sessions and on one permitting a hundred.
    ///
    /// ONCE. A second refusal on a fresh connection is not a bound being
    /// reached, it is something else wearing the same message, and looping
    /// on it would turn one failed transfer into a connection per attempt.
    private static func copyRetryingRefusal(
        from: TransferPlan.Leg, to: TransferPlan.Leg,
        recursive: Bool, plan: TransferPlan
    ) -> Outcome {
        let outcome = copy(from: from, to: to, recursive: recursive)
        guard case .failed(let why) = outcome,
              let moved = movedAfterRefusal(why, from: from, to: to, plan: plan)
        else { return outcome }
        return copy(from: moved.from, to: moved.to, recursive: recursive)
    }

    /// THE DECISION, SEPARATED FROM THE COPY so it can be tested without a
    /// network: does this failure mean the connection will not open another
    /// channel, and if so where does the same copy go instead?
    ///
    /// Returns nil when the failure is something else, when the remote end
    /// holds no pool slot, or when the host cannot be grown.
    static func movedAfterRefusal(
        _ why: String, from: TransferPlan.Leg, to: TransferPlan.Leg, plan: TransferPlan
    ) -> (from: TransferPlan.Leg, to: TransferPlan.Leg)? {
        guard why.contains(MasterPool.channelRefusal) else { return nil }
        // WHICHEVER END IS REMOTE — a copy has at most one, because a
        // transfer between two hosts is relayed as two hops with a local
        // end each.
        let remoteIsSource = !from.isLocal
        guard let binding = remoteIsSource ? plan.fromPool : plan.toPool,
              let tenant = binding.tenant,
              case .remote(var connection, let path) = (remoteIsSource ? from : to),
              let fresh = binding.pool.placeAfterRefusal(
                  on: connection.controlPath, binding.key, tenant: tenant)
        else { return nil }
        connection.controlPath = fresh
        let moved = TransferPlan.Leg.remote(connection, path: path)
        return remoteIsSource ? (moved, to) : (from, moved)
    }

    /// Where a delivery actually writes: the directory the drop named, plus
    /// the source's own name, and only THEN the conflict policy.
    ///
    /// BOTH HOPS OF A RELAY GO THROUGH HERE, which is the whole point of it
    /// existing. The second hop used to hand `plan.to` — a DIRECTORY —
    /// straight to the policy, so `nonColliding` asked whether the
    /// directory was taken (it always is) and renamed that. Measured
    /// against a live pair: a drop of `remotehost:/home/operator/Caddyfile`
    /// into `otherhost:~` turned the destination into `~ 2` and scp answered
    /// `expand ~ 2: no such user`, because sshd reads it as the home of a
    /// user called "2". The file name never entered the path at all.
    ///
    /// The ordering is not cosmetic either: `withoutTilde` strips a tilde
    /// only in leading position, correctly, so anything that renames a bare
    /// `~` puts the tilde somewhere it can no longer be reached.
    static func delivery(to leg: TransferPlan.Leg, named name: String,
                         onConflict: TransferPlan.OnConflict,
                         taken: (TransferPlan.Leg) -> Presence = presence) throws -> TransferPlan.Leg {
        let destination = destinationLeg(leg, defaultName: name)
        switch onConflict {
        case .replace: return destination
        case .rename: return try nonColliding(destination, taken: taken)
        }
    }

    /// The destination named, or the reason nothing will be written there.
    private static func deliverRefusingUnknown(from: TransferPlan.Leg, named name: String,
                                               recursive: Bool, plan: TransferPlan) -> Outcome {
        let to: TransferPlan.Leg
        do {
            to = try delivery(to: plan.to, named: name, onConflict: plan.onConflict)
        } catch let refusal as DeliveryRefusal {
            return .failed(refusal.message)
        } catch {
            return .failed("\(error)")
        }
        return copyRetryingRefusal(from: from, to: to, recursive: recursive, plan: plan)
    }

    /// A drop names a DIRECTORY, and the staged relay file is named after a
    /// UUID. Without this the second hop would deliver the relay's temp name.
    static func destinationLeg(_ leg: TransferPlan.Leg, defaultName: String) -> TransferPlan.Leg {
        switch leg {
        case .local(let p):
            return .local((p as NSString).appendingPathComponent(defaultName))
        case .remote(let connection, let p):
            return .remote(connection, path: (p as NSString).appendingPathComponent(defaultName))
        }
    }

    /// Internal so the connection-reuse claim can be asserted without a
    /// network: whether a transfer re-authenticates is decided entirely
    /// here, and no test that runs scp for real could tell the difference
    /// between reuse and a fast second handshake.
    static func arguments(from: TransferPlan.Leg, to: TransferPlan.Leg,
                          recursive: Bool = false) -> [String] {
        // -r FOR A TREE. scp refuses a directory without it, with a message
        // about it being a directory that reads as a permission problem.
        // -s FORCES SFTP MODE, which decides how the remote path is read.
        // In SFTP mode the path reaches the server as bytes; in the legacy
        // SCP protocol it is expanded by a remote shell. Modern OpenSSH
        // defaults to SFTP, but leaving it to the default would make the
        // quoting below correct or wrong depending on the peer's version —
        // and the file browser already requires this subsystem, so nothing
        // is lost by naming it.
        //
        // -p preserves times and modes; the rest is the connection's own
        // reuse options, with scp's capital -P for the port.
        var args = ["-s", "-p"]
        if recursive { args.append("-r") }
        for leg in [from, to] {
            if case .remote(let connection, _) = leg {
                args += connection.sshOptions.map { $0 == "-p" ? "-P" : $0 }
            }
        }
        args.append(spec(from))
        args.append(spec(to))
        return args
    }

    /// `~` IS A SHELL'S, AND NOTHING HERE HAS ONE.
    ///
    /// scp with `-s` speaks SFTP, which has no tilde, and a LOCAL path
    /// never passes through a shell either — so `~/.synapty/inbox`
    /// arrived at `cp` verbatim and became a relative directory named
    /// `~` that does not exist. Measured: `cp: ~/.synapty/inbox/src.txt:
    /// No such file or directory`.
    ///
    /// This is why [[AgentInbox]] had never delivered a byte despite
    /// being the documented destination for every agent transfer: the
    /// verbs were exercised with an explicit `--into /tmp`, which has no
    /// tilde to expand.
    ///
    /// The two ends resolve DIFFERENTLY and must: this Mac's home is
    /// known here, and the remote's is not — `.` is what the SFTP
    /// subsystem opens in, which IS the remote home ([[RemoteFS]]).
    static func withoutTilde(_ leg: TransferPlan.Leg) -> TransferPlan.Leg {
        switch leg {
        case .local(let path):
            return .local((path as NSString).expandingTildeInPath)
        case .remote(let connection, let path):
            return .remote(connection, path: RemoteFS.withoutTilde(path))
        }
    }

    /// scp will not create the directory it is asked to write into, and
    /// the agent inbox does not exist until something makes it. A delivery
    /// to a path nobody created fails with the same message as a typo.
    private static func ensureLocalDirectory(for leg: TransferPlan.Leg) {
        guard case .local(let path) = leg else { return }
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return }
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
    }

    /// Does a REMOTE source path name a directory?
    ///
    /// False for a local leg: the caller already knows that cheaply and
    /// has put it in the plan. False on failure too — a copy that should
    /// have recursed fails with the host's own message, which is a better
    /// outcome than a recursive copy of something we guessed at.
    static func isRemoteDirectory(_ leg: TransferPlan.Leg) -> Bool {
        guard case .remote(let connection, let path) = withoutTilde(leg) else { return false }
        return SubprocessRunner.runQuiet(
            executable: "/usr/bin/ssh",
            arguments: connection.sshOptions + [connection.userAtHost,
                                                "test -d \(Shell.quote(path))"],
            timeout: 15)
    }

    /// What a probe of the destination can say. THREE ANSWERS, NOT TWO:
    /// `test -e` over ssh used to come back as one bit, so a host that
    /// could not be reached, a shell that refused, and a name that was
    /// genuinely free all read as "free" — and the rename policy then
    /// handed back the original name for scp to overwrite
    /// ([[WI-2026-09-02-023]]).
    enum Presence: Equatable {
        case present
        case absent
        case unknown
    }

    /// Why a delivery was not attempted. Either way nothing was written,
    /// and the message says which.
    enum DeliveryRefusal: Error, Equatable {
        case destinationUnknown(String)
        case namesExhausted(String)

        var message: String {
            switch self {
            case .destinationUnknown(let path):
                return "Could not tell whether \((path as NSString).lastPathComponent) is already there; nothing was written."
            case .namesExhausted(let name):
                return "Every name for \(name) is taken at the destination; nothing was written."
            }
        }
    }

    /// Is something already at this exact path?
    ///
    /// The remote answer is a ROUND TRIP, not a stat, so it is asked once
    /// per candidate and only when a delivery is about to happen. `test -e`
    /// over the master that is already open is the cheapest true answer
    /// available; guessing from a listing would be a second source for a
    /// fact with one. The shell says yes or no in so many words, so a
    /// connection that fails is told apart from a name that is free.
    static func presence(_ leg: TransferPlan.Leg) -> Presence {
        switch withoutTilde(leg) {
        case .local(let path):
            return FileManager.default.fileExists(atPath: path) ? .present : .absent
        case .remote(let connection, let path):
            let out = SubprocessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: connection.sshOptions + [connection.userAtHost,
                                                    "test -e \(Shell.quote(path)) && echo yes || echo no"],
                timeout: 10)
            guard out.error == nil, !out.timedOut, out.exitCode == 0 else { return .unknown }
            switch out.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "yes": return .present
            case "no": return .absent
            default: return .unknown
            }
        }
    }

    /// A name at the destination that is not already taken.
    ///
    /// AN AGENT NEVER OVERWRITES. It is not present to be asked, the inbox
    /// it delivers into is shared by every agent on that machine, and the
    /// thing it would destroy belongs to somebody else — so the collision
    /// is resolved by taking a new name rather than by taking the old
    /// one's place ([[ConflictName]]).
    ///
    /// A probe that cannot answer REFUSES the delivery rather than
    /// guessing, and a series that runs out refuses too: both are
    /// visible, and the alternative to each is the overwrite.
    static func nonColliding(_ leg: TransferPlan.Leg,
                             taken: (TransferPlan.Leg) -> Presence = presence) throws -> TransferPlan.Leg {
        let path = leg.path
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let chosen = try ConflictName.available(for: name) { candidate in
            let at = (directory as NSString).appendingPathComponent(candidate)
            switch taken(rename(leg, to: at)) {
            case .present: return true
            case .absent: return false
            case .unknown: throw DeliveryRefusal.destinationUnknown(at)
            }
        }
        guard let chosen else { throw DeliveryRefusal.namesExhausted(name) }
        guard chosen != name else { return leg }
        return rename(leg, to: (directory as NSString).appendingPathComponent(chosen))
    }

    private static func rename(_ leg: TransferPlan.Leg, to path: String) -> TransferPlan.Leg {
        switch leg {
        case .local: return .local(path)
        case .remote(let connection, _): return .remote(connection, path: path)
        }
    }

    private static func copy(from rawFrom: TransferPlan.Leg, to rawTo: TransferPlan.Leg,
                             recursive: Bool = false) -> Outcome {
        let from = withoutTilde(rawFrom)
        let to = withoutTilde(rawTo)
        ensureLocalDirectory(for: to)
        let args = arguments(from: from, to: to, recursive: recursive)
        let out = SubprocessRunner.run(
            executable: "/usr/bin/scp", arguments: args, timeout: 600)
        if let error = out.error { return .failed(error) }
        if out.timedOut { return .failed("Timed out after 10 minutes.") }
        guard out.exitCode == 0 else {
            let lastLine: String? = out.stderr.split(separator: "\n").last.map(String.init)
            let status: String = out.exitCode.map { "\($0)" } ?? "?"
            return .failed(lastLine ?? "scp exited \(status)")
        }
        // Sized from whichever end is on this machine. Every copy has one —
        // a download's destination, an upload's source, and each half of a
        // relay in turn — and asking the remote for a size would be another
        // round trip to learn what we can already see.
        let localPath = to.isLocal ? to.path : (from.isLocal ? from.path : nil)
        return .ok(localPath.flatMap { recursive ? localTreeSize($0) : localFileSize($0) } ?? 0)
    }

    /// The shell that prints a path's size in BYTES on the far side.
    /// ONE OWNER, because the gate that decides whether a transfer may
    /// happen and the poll that draws its progress must not be measuring
    /// by different means.
    private static func remoteSizeCommand(path: String, recursive: Bool) -> String {
        recursive
            ? "if command -v dust >/dev/null 2>&1; then "
                + "dust -o b -d 0 " + Shell.quote(path)
                + " 2>/dev/null | grep -oE '^ *[0-9]+B' | tr -dc '0-9'; else "
                + "du -sk " + Shell.quote(path) + " | cut -f1 | "
                + "awk '{print $1*1024}'; fi"
            : "wc -c < " + Shell.quote(path)
    }

    /// WHAT IS AT THIS LEG — whether it is a tree, and how many bytes —
    /// measured where it lives.
    ///
    /// ONE ROUND TRIP, because both facts are needed before the same
    /// decision and asking twice costs twice. The workbench used to answer
    /// both questions with local-only code (`FileManager` for the first, a
    /// local stat for the second), which returned "not a directory" and
    /// "size unknown" for everything on another machine — so the size
    /// limit [[RFC-0013]] C-CONTROL-PLANE requires was skipped for exactly
    /// the transfers that cross a link.
    ///
    /// THE COST IS NOT UNIFORM AND IS NOT HIDDEN. Measured against a live
    /// host, a file costs the round trip and nothing more (0.35s); walking
    /// a large tree costs 16-35 SECONDS whichever tool walks it. An agent
    /// that asks to move a tree waits for the answer to whether it may.
    static func measure(_ leg: TransferPlan.Leg) -> (isDirectory: Bool, bytes: Int64?) {
        switch leg {
        case .local(let path):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                return (false, nil)
            }
            return isDir.boolValue
                ? (true, localTreeSize(path))
                : (false, localFileSize(path))
        case .remote(let connection, let path):
            let quoted = Shell.quote(path)
            let command = "if [ -d \(quoted) ]; then printf 'd '; "
                + remoteSizeCommand(path: path, recursive: true)
                + "; else printf 'f '; "
                + remoteSizeCommand(path: path, recursive: false) + "; fi"
            let out = SubprocessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: connection.sshOptions + [connection.userAtHost, command],
                timeout: 40)
            let parts = out.stdout.split(separator: " ", maxSplits: 1)
            guard let kind = parts.first else { return (false, nil) }
            let bytes = parts.count > 1
                ? Int64(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                : nil
            return (kind == "d", bytes)
        }
    }

    /// How big a leg's file is, or nil when it cannot be known cheaply.
    ///
    /// MEASURED, NOT ESTIMATED. A local end is a `stat`; a remote one is a
    /// single round trip on a connection that already exists. Neither is a
    /// guess, which matters because a progress bar that reports a guess is
    /// worse than one that reports nothing — it invites the reader to
    /// believe a number the code does not know.
    static func size(of leg: TransferPlan.Leg, recursive: Bool = false) -> Int64? {
        switch leg {
        case .local(let path):
            return recursive ? localTreeSize(path) : localFileSize(path)
        case .remote(let connection, let path):
            // `wc -c <` for a file and `du -sk` for a tree, rather than
            // `stat`, whose flags differ between BSD and GNU and would need
            // the host's platform known first.
            // `dust` where it exists, `du` otherwise — the same
            // "ask, do not assume" shape as the listener probe. It is a
            // modest win and not the reason this is affordable: measured
            // against a live host, `wc -c` costs the round trip and nothing
            // more (0.35s), while walking a large tree costs 16-35 SECONDS
            // whichever tool walks it. What makes a tree affordable is
            // asking less often, not asking faster.
            let out = SubprocessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: connection.sshOptions
                    + [connection.userAtHost,
                       remoteSizeCommand(path: path, recursive: recursive)],
                timeout: 20)
            // Both branches of the recursive command print BYTES, so the
            // caller does not have to know which tool answered.
            return Int64(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func localFileSize(_ path: String) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    /// EVERY BYTE UNDER A DIRECTORY, because `attributesOfItem` on one
    /// reports the size of the ENTRY — 128 bytes for a tree holding fifty
    /// megabytes. Anything that decides on size and accepts a directory has
    /// to walk it, or the decision is being made about a number that means
    /// something else entirely.
    static func localTreeSize(_ path: String) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        else { return nil }
        guard isDirectory.boolValue else { return localFileSize(path) }

        // Hidden files are NOT skipped: they are part of what is being
        // sent, so leaving them out of the total would understate it — and
        // the total is what a limit is checked against.
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return nil }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// THE REMOTE PATH IS NOT SHELL-QUOTED, and that is not an oversight.
    ///
    /// It was, at first, on the reasoning that a path the human named
    /// reaches a remote shell. In SFTP mode there is no remote shell: the
    /// path is passed as bytes, so quotes become part of the filename.
    /// Measured against a live host — `scp … host:'/tmp/probe.txt'` fails
    /// with `dest open "'/tmp/probe.txt'": No such file or directory`,
    /// while the same path unquoted succeeds, including one containing
    /// spaces. No shell also means nothing to inject into, so this is the
    /// safer of the two and not a trade.
    private static func spec(_ leg: TransferPlan.Leg) -> String {
        switch leg {
        case .local(let path): return path
        case .remote(let connection, let path):
            return "\(connection.userAtHost):\(path)"
        }
    }
}
