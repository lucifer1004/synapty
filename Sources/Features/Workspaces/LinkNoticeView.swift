import SwiftUI

/// WHAT A PANE SAYS WHEN ITS LINK OR ITS SESSION IS NOT WHAT IT WAS
/// ([[RFC-0015]] C-FAILURE, [[LinkState]]).
///
/// THE SCRIM SAID NOTHING. A pane whose link had dropped was dimmed to 45%
/// and marked on its tab, and that was the whole of it — no words, no
/// elapsed time. A grey pane with no explanation is indistinguishable from
/// one that is merely not focused, and C-FAILURE requires a failure to
/// carry the reason it failed ([[WI-2026-09-07-004]]).
///
/// OVER THE PANE AND NEVER INSIDE IT. C-FAILURE again: "ALL OF THIS IS
/// WORKBENCH UI AND MUST NOT BE WRITTEN INTO THE TERMINAL." The grid
/// underneath holds the last true thing the session said, and it stays
/// exactly as it was.
///
/// IT DOES NOT DISMISS. The rejoin notice beside it does, because what it
/// reports is a fact about the past that the human can take or leave; this
/// reports a condition that is still true, and a notice the human can
/// silence while the thing goes on being broken is a notice that makes the
/// pane lie quietly.
struct LinkNoticeView: View {
    let state: LinkState
    /// The far side, named because a workspace may hold several
    /// ([[RFC-0015]] C-LEAF-BINDING) and "the host" answers nothing.
    let machine: String
    /// Told to try again now, where that is a thing this state can do.
    var onRetry: (() -> Void)?
    /// Close a pane whose session will not come back. AN EXPLICIT HUMAN
    /// ACT, which is the only way a pane in one of these states may go —
    /// [[RFC-0014]] C-EXIT-SIGNAL forbids the workbench closing one on the
    /// strength of a lost connection.
    var onClose: (() -> Void)?

    /// WHAT "TRY AGAIN" DOES, WHICH IS NOT THE SAME ACT IN EVERY STATE
    /// THAT OFFERS IT.
    ///
    /// A PAUSED client is alive and still holds the pane's pseudoterminal:
    /// the screen and the scrollback the human was reading are there, so
    /// the press owes a NUDGE — the marker that client polls for — and a
    /// resumed attach repaints over them. Dialling again would destroy
    /// exactly what the pause preserved.
    ///
    /// A SEVERED link has no client to nudge. The host keeps no session
    /// ([[RFC-0014]] C-OPT-OUT), the transport WAS ssh, and it is dead —
    /// so the marker would be written to a path nothing polls and the
    /// button would do nothing. It did, while the comment that used to
    /// live here claimed "connecting again is one press, and what it gives
    /// is a fresh session". The claim was right about what it should do
    /// and wrong about what it did ([[WI-2026-09-09-014]]).
    ///
    /// A FUNCTION RATHER THAN A BRANCH AT THE CALL SITE, because the call
    /// site is a view body and this is the knowledge that decides which of
    /// two very different acts a press performs.
    enum Retry { case wakeTheClient, dialAgain }

    static func retryMeans(_ state: LinkState) -> Retry? {
        switch state {
        case .paused: return .wakeTheClient
        // A DROPPED pane is the severed one without a witness. Both mean
        // nothing local is alive: `severed` is ssh having said so, and
        // `dropped` is libghostty reporting the child gone with no account
        // line to explain it. The act that helps is the same in both —
        // dial the host and put a session back in this pane — and only
        // `dropped` was refused it, on the strength of an argument about
        // the PAUSE marker having no reader ([[WI-2026-09-10-006]]).
        case .dropped, .severed: return .dialAgain
        // EXHAUSTIVE, LIKE EVERY OTHER SWITCH OVER THIS VALUE.
        // `needsSidebarMark` and `sentence` name all nine states; this one
        // said `default: return nil`, and that is how `dropped` came to be
        // the one state with no way back — refused silently, on an
        // argument nobody had to make ([[WI-2026-09-10-006]]). A tenth
        // state would inherit the same silence. Each `nil` below is a
        // decision, and the compiler now makes somebody take it.
        case .live:
            // Nothing is wrong.
            return nil
        case .lost:
            // The client is already dialling; a button that says "try
            // again" beside a client that is trying says nothing true.
            return nil
        case .gone, .ended:
            // A session that is over needs a NEW one, and putting one in
            // this pane means destroying the surface that holds the
            // frozen screen — which is the last true thing the session
            // said and usually the output the human wanted. Cancelled
            // deliberately, with its own design left to its own work
            // ([[WI-2026-09-07-004]]).
            return nil
        case .mismatch:
            // Reconnecting cannot help, and the sentence says so.
            return nil
        case .taken:
            // The way back is offered where the pane says it was taken —
            // and it says what it costs, because returning displaces the
            // other client in turn ([[LeafConnectionView]]).
            return nil
        }
    }

    static func retryHelp(_ means: Retry, machine: String) -> String {
        switch means {
        case .wakeTheClient:
            return "Starts trying \(machine) again. The session, its screen and its "
                + "scrollback are still there and come back as they were."
        case .dialAgain:
            return "Dials \(machine) again now and puts a session in this pane. What is "
                + "already running there is untouched either way."
        }
    }

    /// Whether closing is the useful act. A link that is still being
    /// dialled is not something to tidy away; one that will not come back
    /// is.
    static func offersClose(_ state: LinkState) -> Bool {
        switch state {
        case .gone, .mismatch, .dropped, .severed: return true
        case .live, .lost, .paused, .ended, .taken: return false
        }
    }

    static func icon(_ state: LinkState) -> String {
        switch state {
        case .lost: return "antenna.radiowaves.left.and.right.slash"
        case .paused: return "pause.circle"
        case .gone, .ended: return "xmark.circle"
        case .dropped, .severed: return "bolt.horizontal.circle"
        case .mismatch: return "exclamationmark.triangle"
        case .taken: return "person.crop.circle.badge.exclamationmark"
        case .live: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Amber while it may still resolve itself, red once it will not.
    static func tint(_ state: LinkState) -> Color {
        state.isTerminal ? DS.danger : DS.warning
    }

    var body: some View {
        // A CLOCK OF ITS OWN, because the sentence counts. The elapsed
        // time is the difference between "the link blinked" and "this host
        // has been gone for ten minutes", and a strip redrawn only when
        // something else changes would sit on the first of those for the
        // whole outage.
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            content(now: tick.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let said = state.sentence(now: now, on: machine) ?? ""
        HStack(spacing: DS.Space.sm) {
            Image(systemName: Self.icon(state))
                .font(DS.Typography.caption)
                .foregroundStyle(Self.tint(state))
            Text(said)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Space.sm)
            if let means = Self.retryMeans(state), let onRetry {
                Button("Try again", action: onRetry)
                    .buttonStyle(.link)
                    .font(DS.Typography.caption)
                    // THE HELP DESCRIBED ONE OF THE TWO ACTS. Both states
                    // read "Dials \(machine) again now", and a paused
                    // client is not dialled — it is woken, onto the screen
                    // and scrollback the pause preserved, which is the
                    // opposite promise ([[WI-2026-09-10-006]]).
                    .help(Self.retryHelp(means, machine: machine))
            }
            if Self.offersClose(state), let onClose {
                Button("Close", action: onClose)
                    .buttonStyle(.link)
                    .font(DS.Typography.caption)
                    .help("Closes this pane. Its screen goes with it.")
            }
        }
        .padding(.horizontal, DS.Space.md)
        .frame(height: PaneStrip.height)
        .background(DS.surfaceRaised)
        .overlay(alignment: .bottom) { DSHairline() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(said)
    }
}
