import Foundation
import Observation
import os

/// Who may move data where, and on whose say-so.
///
/// THE FOUR PROPERTIES STAND OR FALL TOGETHER ([[RFC-0013]]
/// C-AUTHORIZATION). Relaying through the workbench does not avoid creating
/// the ability to move data from one host to another — it plainly creates
/// it. The claim that makes the broker better than a key in authorized_keys
/// is that the ability is SCOPED, HUMAN-GRANTED, RECORDED and MORTAL, and
/// any one of those missing collapses the argument back to "we built a
/// worse SSH".
///
/// [[WI-2026-08-15-012]]
@MainActor @Observable final class TransferAuthority {

    static weak var shared: TransferAuthority?

    /// A direction, not a relationship. Authorising A to send to B says
    /// nothing about B sending to A: the human agreed to one of those.
    struct Pair: Hashable {
        /// nil is this Mac.
        let from: UUID?
        let to: UUID?
    }

    /// A grant the human has not answered yet. The transfer waits; it is
    /// never performed optimistically and undone.
    struct Pending: Identifiable, Equatable {
        let id: UUID
        let pair: Pair
        let agent: String
        let fileName: String
        let askedAt: Date
    }

    /// IN MEMORY, AND NOWHERE ELSE.
    ///
    /// Mortality is the property with no equivalent in a credential sitting
    /// on a server, and it is the one that would be quietly lost by making
    /// this convenient. A grant written to disk — even to this application's
    /// own config, even encrypted — would outlive the process that the
    /// human's judgement was attached to, and the argument for preferring a
    /// broker to a direct trust would be gone with it.
    ///
    /// The cost is real and is not hidden: the human answers again after a
    /// relaunch. That is the price of a capability that cannot be inherited
    /// by a future session nobody was present for.
    private var granted: Set<Pair> = []

    /// ROUTES A HUMAN HAS SAID NO TO, for the session.
    ///
    /// A REFUSAL IS AN ANSWER AND NEEDS SOMEWHERE TO LIVE. Without this,
    /// Deny removed the card and recorded nothing, so the agent's next
    /// request re-created it — and the skill reference TELLS agents to
    /// retry, calling `awaiting approval` "not a permanent failure ...
    /// once they agree, retry and it goes". The human's only escape from
    /// the same question was to quit.
    private var refused: Set<Pair> = []

    private(set) var pending: [Pending] = []

    private static let log = Logger(subsystem: "com.synapty.app", category: "Authority")

    // MARK: - Asking

    func isGranted(_ pair: Pair) -> Bool { granted.contains(pair) }

    func isRefused(_ pair: Pair) -> Bool { refused.contains(pair) }

    /// WHAT THIS ROUTE NEEDS BEFORE ANYTHING MOVES.
    ///
    /// THREE ANSWERS, NOT TWO. It was a Bool, and a Bool cannot say
    /// "already refused" — so a route the human had said no to was
    /// indistinguishable from one they had not been asked about yet, and
    /// the agent was told a human "has been asked" every time.
    enum Requirement { case go, ask, refuse }

    /// A HUMAN'S OWN GESTURE NEEDS NO SECOND CONFIRMATION. They dragged the
    /// file; asking again would train them to click through the question,
    /// which is worse than not asking. The requirement binds agents.
    func requirement(initiator: TransferService.Initiator, pair: Pair) -> Requirement {
        switch initiator {
        case .human: return .go
        case .agent:
            if isGranted(pair) { return .go }
            return isRefused(pair) ? .refuse : .ask
        }
    }

    /// Record that an agent is waiting on a human. Idempotent per pair and
    /// agent: an agent retrying must not stack questions the human then has
    /// to dismiss one at a time.
    @discardableResult
    func requestApproval(pair: Pair, agent: String, fileName: String) -> UUID {
        if let existing = pending.first(where: { $0.pair == pair && $0.agent == agent }) {
            return existing.id
        }
        let request = Pending(id: UUID(), pair: pair, agent: agent,
                              fileName: fileName, askedAt: Date())
        pending.append(request)
        Self.log.info("\(agent, privacy: .public) is waiting on approval to send")
        return request.id
    }

    // MARK: - Answering

    /// The human said yes. Everything waiting on this pair is released.
    func grant(_ pair: Pair) {
        granted.insert(pair)
        // A YES ENDS AN EARLIER NO. The two sets are answers to the same
        // question and a route cannot be in both.
        refused.remove(pair)
        pending.removeAll { $0.pair == pair }
        Self.log.info("authorised for this session")
    }

    /// NO, AND IT STAYS NO FOR THE SESSION.
    ///
    /// The card is removed as before, and the answer is now recorded, so
    /// the agent's next request along the route is REFUSED rather than
    /// asked again. Undone from the same settings surface the grants are
    /// withdrawn from ([[RFC-0013]] C-AUTHORIZATION: a capability nobody
    /// can enumerate is one nobody can withdraw — which is as true of a
    /// refusal as of a grant).
    func deny(_ id: UUID) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        refused.insert(request.pair)
        // EVERY QUESTION ABOUT THIS ROUTE, not only the card clicked: the
        // human answered about the route, which is what they were asked.
        pending.removeAll { $0.pair == request.pair }
        Self.log.info("refused for this session")
    }

    /// The human is willing to be asked about this route again. NOT a
    /// grant: it clears the standing no and nothing more, so the next
    /// request puts the question back in front of them.
    func allowAsking(_ pair: Pair) {
        refused.remove(pair)
    }

    /// Where an agent's transfers along a route go to be stopped. Set by
    /// ContentView beside `shared`; nil in tests that only exercise the
    /// grant table itself.
    weak var transfers: TransferService?

    /// The human changed their mind. Takes effect immediately and for the
    /// rest of the session, which is the whole point of holding this in
    /// memory rather than on a host.
    ///
    /// AND IT REACHES WORK ALREADY ACCEPTED. The grant is consulted once,
    /// at request admission, and never again — so without this a withdrawal
    /// did not stop a transfer the agent had asked for a second earlier and
    /// which had not started yet. [[RFC-0007]] C-EXEC-AUTHORITY holds the
    /// workbench to the same standard for the other standing grant it
    /// takes: "a run whose Enter has not yet been sent is aborted".
    ///
    /// WHAT IT DOES NOT REACH is a copy already running: the transfer is a
    /// blocking `scp` with no handle to signal, so bytes in flight finish.
    /// The settings copy says so rather than implying otherwise, because a
    /// withdrawal that reads as a stop and is not one is worse than one
    /// that states its limit.
    func revoke(_ pair: Pair) {
        granted.remove(pair)
        pending.removeAll { $0.pair == pair }
        guard let transfers else { return }
        for transfer in transfers.transfers
        where transfer.initiator != .human
            && Pair(from: transfer.source.hostID, to: transfer.destination.hostID) == pair
        {
            transfers.cancel(transfer.id)
        }
    }

    /// Every pair currently authorised, for a human who wants to see what
    /// they have agreed to. A capability nobody can enumerate is one nobody
    /// can withdraw.
    var grants: [Pair] { Array(granted) }

    /// Every route currently refused, for the same reason `grants` is
    /// enumerable: an answer a human cannot see is one they cannot change.
    var refusals: [Pair] { Array(refused) }
}

/// Where an agent-addressed delivery lands, and the only place it can.
///
/// SCOPED MEANS THE RECEIVER DECLARES IT, not the sender. An agent that
/// could name an arbitrary path on another machine has been given the
/// ability to overwrite anything its account can reach — a config, a shell
/// profile, an authorized_keys — which is a materially larger capability
/// than "deliver me a file" and one no human agreed to when they approved a
/// transfer.
///
/// A FIXED, KNOWN DIRECTORY rather than a per-agent negotiation, for now:
/// the receiving agent needs no protocol to declare it, the human needs no
/// configuration to predict it, and it is one directory to inspect when
/// asking what arrived.
enum AgentInbox {
    static let path = "~/.synapty/inbox"

    /// The delivery destination for an agent on this host.
    static func destination(hostID: UUID?) -> FileEndpoint {
        FileEndpoint(hostID: hostID, path: path)
    }
}
