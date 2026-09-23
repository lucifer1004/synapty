import Foundation

/// WHY AN ACCOUNT STOPPED.
///
/// The client writes `end <reason>` with the reason spelled exactly as its
/// own outcome is spelled (`@tagName`), so this is a cross-process contract
/// and not a local convention — `src/cli/commands.zig`, `runAttachThrough`.
enum AccountEnd: String, Equatable {
    /// The far side's child exited. The work finished, or was killed.
    case childExited = "child_exited"
    /// Another client took the session ([[RFC-0014]] C-ONE-CLIENT).
    case displaced
    /// THE LINK CAME BACK AND THE SESSION DID NOT. The reconnect reached
    /// the host and found nothing holding that name — a reboot, most
    /// often. This is what "reconnect failed" actually looks like, and
    /// until [[WI-2026-09-07-004]] it was the one thing in this whole area
    /// a human could not be told.
    case noSession = "no_session"
    /// The two sides do not speak the same holder protocol
    /// ([[RFC-0014]] C-VERSION). Terminal: retrying reaches the same
    /// disagreement.
    case versionMismatch = "version_mismatch"
    /// The human detached, or ended a pause without resuming it. An
    /// ordinary way to leave, not a failure.
    case stopped
    /// THE LINK DIED AND TOOK THE SESSION WITH IT, on a host that keeps
    /// none between connections ([[RFC-0014]] C-OPT-OUT).
    ///
    /// Written by the connection itself rather than by a client, because
    /// path there is no client: ssh IS the pane's child. ssh(1) says "ssh
    /// exits with the exit status of the remote command or with 255 if an
    /// error occurred", so 255 is ssh saying the failure was its own —
    /// a link that dropped, a host that stopped answering — and anything
    /// else is the remote shell's own status, which is the human leaving
    /// ([[WI-2026-09-09-004]]).
    case linkSevered = "link_severed"
}

/// WHAT A PANE'S LINK AND ITS SESSION ARE DOING.
///
/// THREE SUBJECTS, AND A DROP SEPARATES THEM. The HOST LINK is a fact
/// about a machine and is shared by every pane on it; the PANE'S TRANSPORT
/// is this pane's ssh; the SESSION is the holder's child on the far side.
/// A network drop takes the first two and leaves the third untouched. The
/// workbench had states for the first and a scrim for the second, and
/// nothing at all for "the third is gone" ([[WI-2026-09-07-004]]).
///
/// READ OFF THE ACCOUNT, which is the only place these facts arrive. The
/// account already carried every one of them; what it did not have was a
/// reader. `ConnectProgress` discarded an `end` whenever the pane had
/// already painted — `if !revealed { failure = ... }` — so a reconnect that
/// found no session left libghostty's "Process exited" as the whole of what
/// the human was told.
enum LinkState: Equatable {
    /// Frames are flowing, or nothing has said otherwise.
    case live
    /// The transport died and the client is dialling again.
    case lost(since: Date)
    /// The client has stopped dialling and is waiting to be told to try
    /// again. THE PANE IS NOT DEAD: the process still owns its pty, so the
    /// screen and the scrollback are still there and a resume repaints
    /// over them.
    case paused(since: Date)
    /// The link came back and the session did not.
    case gone
    /// The far side's child exited.
    case ended
    /// The two sides disagree about the protocol.
    case mismatch
    /// Another client took the seat.
    case taken
    /// THE LINK DIED AND THERE IS NOTHING TO RETURN TO — a host that keeps
    /// no session between connections ([[RFC-0014]] C-OPT-OUT), whose ssh
    /// said the failure was its own.
    ///
    /// NOT `dropped`, WHICH IS THE SILENT ONE. This was called
    /// indistinguishable from an ordinary `exit`, on the reasoning that
    /// both arrive as the pane's child dying and the exit code that would
    /// separate them is always zero. Both halves are true and the
    /// conclusion was not: ssh KNOWS which happened and exits 255 for its
    /// own failures, and the process that ran it is standing there when it
    /// could not say so only because it `exec`ed, replacing the process
    /// that could have looked ([[WI-2026-09-09-004]]).
    ///
    /// NOT `gone` EITHER. That one is a reconnect that arrived and found
    /// nothing; nothing arrived here.
    case severed
    /// THE PROCESS CARRYING THIS PANE DIED AND NOTHING SAID WHY.
    ///
    /// ON A DURABLE HOST THIS SHOULD NOT HAPPEN, and that is what makes it
    /// evidence. The client retries rather than exiting, and when it does
    /// exit it writes an `end` first — so a death with no account is the
    /// CLIENT ITSELF dying, and the session it was carrying is still over
    /// there. The screen is the last true thing it said and the pane keeps
    /// it ([[RFC-0014]] C-EXIT-SIGNAL).
    ///
    /// AND IT DOES NOT SPEAK FOR A HOST THAT KEEPS NO SESSION
    /// ([[RFC-0014]] C-OPT-OUT), which has `severed` below. There the
    /// transport IS the pane's child and nothing about its DEATH separates
    /// a dropped link from a human typing `exit`; what separates them is
    /// something ssh says, and saying it is the connection's job rather than
    /// this one's.
    ///
    /// AND IT CARRIES NO NUMBER, BECAUSE ON THIS PLATFORM THERE IS NONE.
    /// It used to be `dropped(code:)` and the sentence quoted the code —
    /// but libghostty spawns every pane through `/usr/bin/login -flp`
    /// (upstream's own darwin tests assert that shape for both a shell and
    /// a direct command), and `login` reports 0 whatever happens
    /// underneath it. Measured on macOS 26.5:
    ///
    ///     login -flp $USER /bin/sh -c 'exit 42'    -> 0
    ///     login -flp $USER /bin/sh -c 'exit 255'   -> 0
    ///     login -flp $USER /bin/sh -c 'kill -TERM $$' -> 0
    ///     login -flp $USER /no/such/binary         -> 0
    ///     /bin/sh -c 'exit 42'                     -> 42
    ///
    /// `Surface.zig` carries upstream's own note about this — "on macOS,
    /// our exit code detection doesn't work, possibly because of our
    /// `login` wrapper" — which is why the `exit_code == 0` shortcut above
    /// it is compiled out on Darwin.
    ///
    /// So the fact is the EVENT, not the number: libghostty performs
    /// `show_child_exited` for every child exit, and its arrival is the
    /// whole of what it tells us. Keying off `code != 0` made this state
    /// unreachable and closed exactly the panes it exists to keep
    /// ([[WI-2026-09-09-001]]).
    case dropped

    /// AFTER THIS LONG, A DROP IS NO LONGER A BLIP. Most are a Wi-Fi
    /// handover or a sleep and are over in seconds; one that is still down
    /// after a minute is a different sentence and a different urgency, and
    /// it is the point at which the sidebar owes the human a mark
    /// ([[RFC-0015]] C-FAILURE).
    ///
    /// DERIVED FROM THE CLOCK RATHER THAN BEING A CASE OF ITS OWN. A state
    /// that changes without an event is not a state the account can report,
    /// and one stored in a case would be stale the moment it was written.
    static let escalateAfter: TimeInterval = 60

    /// The state, from what the account has said.
    ///
    /// AN END IS THE LAST WORD. A client that ended said so after whatever
    /// losing and pausing came before, so an end outranks both — except
    /// `stopped`, which is the human leaving and is not a state of
    /// anything.
    ///
    /// PAUSED OUTRANKS LOST because it comes after: the client loses the
    /// link, retries, and gives up. A pause with no loss recorded before it
    /// cannot happen, but reading it as `lost` if it did would say the
    /// workbench is still dialling when it is not.
    /// AND THE ACCOUNT OUTRANKS THE CHILD'S DEATH. A client that said why
    /// it stopped knows more than the bare fact that it is gone; the death
    /// is only consulted where nothing said anything, which is exactly the
    /// case it is the only evidence for.
    static func from(
        ended: AccountEnd?,
        lostSince: Date?,
        pausedSince: Date?,
        childDied: Bool = false
    ) -> LinkState {
        switch ended {
        case .childExited: return .ended
        case .displaced: return .taken
        case .noSession: return .gone
        case .versionMismatch: return .mismatch
        case .linkSevered: return .severed
        case .stopped, .none: break
        }
        // A DEATH NOBODY EXPLAINED. The caller decides whose death counts
        // — a local shell's is the human typing `exit` and is not a link
        // state at all ([[WorkspaceManager.link(ofLeaf:)]]).
        if childDied { return .dropped }
        if let pausedSince { return .paused(since: pausedSince) }
        if let lostSince { return .lost(since: lostSince) }
        return .live
    }

    /// Whether anything further will happen on its own.
    var isTerminal: Bool {
        switch self {
        case .gone, .ended, .mismatch, .taken, .dropped, .severed: return true
        case .live, .lost, .paused: return false
        }
    }

    /// WHETHER THE PANE MUST STAY, whatever its child process did.
    ///
    /// [[RFC-0014]] C-EXIT-SIGNAL: "A client MUST NOT treat the loss of its
    /// connection as evidence that the child has exited, and MUST NOT end,
    /// close, or discard the session's local state on that basis alone" —
    /// and its rationale names the exact failure: "the safe guess — treat
    /// every drop as a death — is the behaviour that makes a network blip
    /// destroy a pane".
    ///
    /// A SESSION THAT IS GONE KEEPS ITS PANE TOO, which is less obvious.
    /// The screen is the last true thing that session said, and it is
    /// often the output the human wanted; closing it to save a row costs
    /// them the reason they were looking.
    /// A CHILD THAT EXITED IS THE ONLY QUESTION THIS ANSWERS. It is asked
    /// when the pane's process has already gone, so it is not "may this
    /// pane be closed" in general — it is "was that exit the end of the
    /// human's work, or the end of the thing carrying it".
    ///
    /// PHASE 2 GAVE THIS A SHAPE BEFORE THE EXIT CODE WAS IN HAND and
    /// answered `true` for `live`, which read correctly as prose and would
    /// have refused to close a pane whose shell the human had just exited.
    /// It is answerable now because the workbench takes
    /// `GHOSTTY_ACTION_SHOW_CHILD_EXITED` and has the code
    /// ([[WI-2026-09-07-004]] phase 4).
    var keepsPane: Bool {
        switch self {
        case .gone, .mismatch, .taken, .dropped, .severed: return true
        // The holder said the child exited: the work is over, and a
        // terminal whose command finished closing is a terminal behaving
        // as one.
        case .ended: return false
        // Nothing has exited unexpectedly and nothing said otherwise, so
        // whatever just happened was ordinary.
        case .live, .lost, .paused: return false
        }
    }

    /// Whether a workspace holding this pane must be marked in the sidebar
    /// ([[RFC-0015]] C-FAILURE: the workbench MUST NOT require the human to
    /// open a workspace to learn that something in it failed).
    ///
    /// A BLIP IS NOT A FAILURE. Marking every momentary drop would put a
    /// mark on the sidebar several times a day for something that fixes
    /// itself in seconds, and a mark that usually means nothing is one
    /// nobody reads.
    func needsSidebarMark(now: Date = Date()) -> Bool {
        switch self {
        case .live, .ended: return false
        case .gone, .mismatch, .taken, .paused, .dropped, .severed: return true
        case .lost(let since): return now.timeIntervalSince(since) >= Self.escalateAfter
        }
    }

    /// One line, in the human's terms, or nothing where there is nothing
    /// to say. `machine` names the far side; it is the leaf's to supply,
    /// because a workspace may hold several ([[RFC-0015]] C-LEAF-BINDING).
    func sentence(now: Date = Date(), on machine: String) -> String? {
        switch self {
        case .live:
            return nil
        case .lost(let since):
            let down = now.timeIntervalSince(since)
            if down < Self.escalateAfter {
                return "Link lost — reconnecting · \(Self.spell(down))"
            }
            return "\(machine) has not answered for \(Self.spell(down)) — still trying"
        case .paused(let since):
            return "Stopped reconnecting · \(machine) was unreachable for \(Self.spell(now.timeIntervalSince(since)))"
        case .gone:
            return "The session is gone — \(machine) came back without it"
        case .ended:
            return "The session ended"
        case .mismatch:
            return "\(machine) runs a different build — reconnecting cannot help"
        case .taken:
            return "Another client took this session"
        case .severed:
            // WHAT HAPPENED, BECAUSE SOMETHING SAID SO. The state beside
            // this one ends in "nothing said why"; here ssh did, and the
            // second half is the part a human needs — there is no session
            // waiting on that host, so coming back means starting one.
            return "The link to \(machine) dropped, and it keeps no session to return to"
        case .dropped:
            // NO CAUSE AND NO NUMBER. Inventing a cause would be worse
            // than saying there is none, and the number this used to quote
            // was `login`'s zero rather than the child's code — a
            // fabricated fact dressed as the only real one.
            return "The connection to \(machine) ended — nothing said why"
        }
    }

    /// A DURATION AT THE PRECISION IT IS READ AT. Seconds matter while a
    /// human is watching a drop resolve; past a minute they are noise on a
    /// status line, and past an hour so are minutes.
    ///
    /// ITS OWN, AND NOT THE SIDEBAR'S. `RemoteSessionRow` spells "how long
    /// has nobody watched this" and starts at ninety seconds, because
    /// below that the answer is "just now" and does not matter. This one is
    /// watched second by second.
    static func spell(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
