import Foundation
import Observation
import AppKit

/// What the application has to say to the human, in one place.
///
/// THIS IS NOT "EVERY MESSAGE". Four kinds of thing were being reported
/// across ten surfaces, and only one of them was missing a home:
///
///   - A STATE of an object — a host offline, a hub behind the workbench,
///     a host that did not reach disk. These belong ON the object and are
///     deliberately NOT here: [[WI-2026-08-13-012]] moved them from events
///     to states precisely because a condition that persists is not an
///     announcement, and announcing it once leaves the human with no way
///     to ask again.
///   - AN AGENT'S ATTENTION — tab markers, the Dock badge. Already has a
///     home, and its home is the pane.
///   - SOMETHING WAITING ON THE HUMAN — approvals, questions. Blocking,
///     counted, and it stays until answered.
///   - SOMETHING THAT JUST HAPPENED — a file delivered, a view exposed, a
///     transfer that failed. Nothing is required of the human. THIS had no
///     surface at all: a drag that worked and a drag that silently did
///     nothing looked identical.
///
/// The last two share this module. The first two do not, and folding them
/// in would undo decisions already made.
///
/// ONE BADGE, ONE ANSWER. Approvals and questions were merged for a stated
/// reason — two badges make "is anything waiting on me" a question with two
/// answers ([[WI-2026-08-15-012]]). A second badge for transient outcomes
/// would bring that straight back, so the count here is BLOCKING ITEMS
/// ONLY. A delivery that succeeded must never inflate a number that means
/// "you have to act".
@MainActor @Observable final class AppNotifications {

    static weak var shared: AppNotifications?

    /// How something reads, which is the only thing that varies.
    enum Tone: Equatable {
        case done
        case failed

        var icon: String {
            switch self {
            case .done: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var tone: Tone
        /// What happened, in the human's terms.
        var title: String
        /// The thing it happened to. Optional: "Delivered" alone is not an
        /// answer to "delivered what".
        var detail: String?
        var postedAt: Date
    }

    /// Showing right now. Bounded: a burst of transfers must not become a
    /// column taller than the window.
    private(set) var visible: [Item] = []

    private var timers: [UUID: Timer] = [:]

    /// Long enough to read a short line, short enough not to sit over the
    /// terminal. Failures linger: the human may have been looking away,
    /// and a failure they never saw is the case this module exists for.
    private static let doneSeconds: TimeInterval = 4
    private static let failedSeconds: TimeInterval = 10
    private static let maxVisible = 4

    // MARK: - Posting

    /// Whether the human is looking at this window.
    ///
    /// INJECTABLE, because `NSApp.isActive` is a global the caller cannot
    /// see: with it read inline, every post silently did one of two very
    /// different things and a test could observe neither. Caught by the
    /// first test written against this module, which found `visible`
    /// empty after four posts.
    var isActive: () -> Bool = { NSApp.isActive }

    /// SILENT WHEN THE HUMAN IS NOT HERE — the system takes over.
    ///
    /// An in-app toast shown to an empty screen is a report nobody
    /// received. `NotificationForwarder` already draws this line for OSC
    /// pings; the same rule applies to our own outcomes so the human gets
    /// exactly one of the two, never both and never neither.
    func post(_ tone: Tone, _ title: String, detail: String? = nil) {
        guard isActive() else {
            NotificationForwarder.forward(title: title, body: detail ?? "")
            return
        }
        let item = Item(tone: tone, title: title, detail: detail, postedAt: Date())
        visible.append(item)
        // Oldest goes first: the newest is the one being read.
        while visible.count > Self.maxVisible {
            let dropped = visible.removeFirst()
            timers.removeValue(forKey: dropped.id)?.invalidate()
        }
        let life = tone == .failed ? Self.failedSeconds : Self.doneSeconds
        timers[item.id] = Timer.scheduledTimer(withTimeInterval: life, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.dismiss(item.id) }
        }
    }

    func dismiss(_ id: UUID) {
        visible.removeAll { $0.id == id }
        timers.removeValue(forKey: id)?.invalidate()
    }

    // MARK: - What is waiting

    /// WHAT IS WAITING ON THE HUMAN, one line each. BLOCKING ONLY, so
    /// the number derived from it always means "you have to act" and
    /// never "something went fine".
    ///
    /// THE LIST IS THE OWNER AND THE NUMBER IS DERIVED FROM IT. The badge
    /// summed three sources and the tooltip under it enumerated two, so a
    /// human read "3" and hovered onto two sentences — the badge counted a
    /// transfer stopped on a name it will not take, and nothing said so
    /// ([[WI-2026-08-30-009]]). A source can only be added to both at once
    /// now.
    static func waitingLines(authority: TransferAuthority?, questions: QuestionService?,
                             transfers: TransferService? = nil) -> [String] {
        (authority?.pending.map { "\($0.agent) is waiting to send \($0.fileName)" } ?? [])
            + (questions?.unanswered.map { "\($0.agent) asked: \($0.text)" } ?? [])
            // A transfer stopped on a name it will not take without an
            // answer is waiting on a human like any other, so the badge is
            // the ONE answer to "is anything waiting on me" rather than the
            // answer to most of it.
            + (transfers?.awaitingChoice.map { "\($0.fileName) needs a name before it can land" } ?? [])
    }

    static func waitingCount(authority: TransferAuthority?, questions: QuestionService?,
                             transfers: TransferService? = nil) -> Int {
        waitingLines(authority: authority, questions: questions, transfers: transfers).count
    }
}
