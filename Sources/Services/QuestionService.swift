import Foundation
import Observation
import os

/// Questions agents are blocked on.
///
/// A HUMAN ANSWERING IS AN EVENT, NOT A RESPONSE, and the transport has to
/// admit that. The hub parks a forwarded tool request for 180 seconds and
/// then reaps it — a bound that exists because a parked request holds a
/// connection and its file descriptor until the hub exits. A human who
/// steps away outlasts it. So `ask` posts the question and returns; the
/// agent waits by asking again, each poll a short round trip well inside
/// the bound, rather than one long one that stretches a mechanism past
/// what it was built for.
///
/// [[RFC-0013]] C-PRIMITIVES, [[WI-2026-08-15-012]]
@MainActor @Observable final class QuestionService {

    static weak var shared: QuestionService?

    struct Question: Identifiable, Equatable {
        let id: UUID
        /// Who is blocked. There is no anonymous question.
        let agent: String
        let text: String
        /// What the agent will accept. Empty means free text is not
        /// offered — a closed set is the only shape a badge can present
        /// without becoming a text field an agent controls.
        let options: [String]
        let askedAt: Date
        var answer: String?

        var isAnswered: Bool { answer != nil }
    }

    private(set) var questions: [Question] = []

    private static let log = Logger(subsystem: "com.synapty.app", category: "Question")

    /// Anything still blocking someone.
    var unanswered: [Question] { questions.filter { !$0.isAnswered } }

    // MARK: - Asking

    /// IDEMPOTENT PER AGENT AND TEXT. An agent polling, restarting, or
    /// retrying must not turn one decision into a list a human clears
    /// rather than reads.
    @discardableResult
    func ask(agent: String, text: String, options: [String]) -> UUID {
        if let existing = questions.first(where: {
            $0.agent == agent && $0.text == text && !$0.isAnswered
        }) { return existing.id }

        let question = Question(id: UUID(), agent: agent, text: text,
                                options: options, askedAt: Date(), answer: nil)
        questions.append(question)
        Self.log.info("\(agent, privacy: .public) is blocked on a question")
        return question.id
    }

    /// What the agent polls. nil means still waiting.
    func answer(to id: UUID) -> String? {
        questions.first { $0.id == id }?.answer
    }

    // MARK: - Answering

    /// ONLY WHAT WAS OFFERED. A human's answer is passed to an agent that
    /// will act on it, so it must be one of the values that agent said it
    /// understood — a free-text answer to a closed question is a string an
    /// agent has no branch for.
    func answer(_ id: UUID, with choice: String) {
        guard let idx = questions.firstIndex(where: { $0.id == id }) else { return }
        guard questions[idx].options.isEmpty || questions[idx].options.contains(choice) else {
            Self.log.error("refused an answer that was not offered")
            return
        }
        questions[idx].answer = choice
    }

    /// Answered questions are kept until the agent has collected the answer
    /// — dropping one the moment it is answered would lose it in the gap
    /// before the next poll, and the agent would wait forever on a decision
    /// that was made.
    func collect(_ id: UUID) {
        questions.removeAll { $0.id == id && $0.isAnswered }
    }
}
