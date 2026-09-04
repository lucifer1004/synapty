import Foundation

/// WHETHER A REOPENED PANE CAME BACK TO ITS WORK, OR STARTED OVER
/// ([[RFC-0015]] C-HONESTY, [[WI-2026-08-17-027]]).
///
/// THE PROMISE MUST NOT OUTRUN WHAT WORKS. "Restored" said of a pane whose
/// build was killed and whose shell is a fresh one is a lie the human
/// discovers by typing into it — and the discovery is expensive, because
/// by then they have closed the thing they could have left open.
///
/// THE WAYS IT CAN GO ARE DIFFERENT THINGS TO SOMEONE DECIDING WHETHER TO
/// CLOSE SOMETHING, so they are separate cases rather than one grey
/// "could not restore": durability turned off is a setting they can
/// change, a holder that is gone is a machine that rebooted, and a pane
/// that never named a session had nothing to come back to.
enum Rejoining: Equatable {

    /// The pane is attached to the session it left.
    case rejoined

    /// It is a new child. The working directory is restored; the work is
    /// not.
    case restarted(Reason)

    /// A REMOTE PANE'S ANSWER IS ON THE FAR SIDE. Restore must not block
    /// on a connection ([[RFC-0015]] C-UNARCHIVE), so the workbench hands
    /// over both names and learns which was used when the session
    /// registers — `settled(registeredAs:recorded:)` below.
    case undecided

    enum Reason: Equatable {
        /// The human turned durable sessions off for this machine, so
        /// nothing was kept running to come back to.
        case durabilityOff(machine: String)
        /// A session was named and nothing is holding it any more.
        case sessionGone
        /// The pane never named a session.
        case nothingRecorded
    }

    // MARK: - Judging it

    /// ON THIS MACHINE THE QUESTION IS ANSWERABLE AT ONCE: the record is
    /// here and the kernel can be asked, which is the same test that
    /// decides whether the recorded name may be reused at all.
    static func local(recorded: String?, durable: Bool,
                      isLive: (String) -> Bool = SessionRecord.isLive) -> Rejoining {
        guard durable else { return .restarted(.durabilityOff(machine: "this Mac")) }
        guard let recorded else { return .restarted(.nothingRecorded) }
        return isLive(recorded) ? .rejoined : .restarted(.sessionGone)
    }

    /// ON ANOTHER MACHINE ONLY THE OPT-OUT IS KNOWN HERE. Everything else
    /// waits for the registration.
    static func remote(recorded: String?, machine: String, durable: Bool) -> Rejoining {
        guard durable else { return .restarted(.durabilityOff(machine: machine)) }
        guard recorded != nil else { return .restarted(.nothingRecorded) }
        return .undecided
    }

    /// WHAT THE REGISTRATION SAID. Only one of the two names can exist, so
    /// the name a session registers under IS the answer — a stronger one
    /// than any account the launch script could give of itself.
    static func settled(registeredAs name: String, recorded: String?) -> Rejoining {
        name == recorded ? .rejoined : .restarted(.sessionGone)
    }

    // MARK: - Saying it

    /// One line, in the human's terms. Not "attach failed".
    var sentence: String {
        switch self {
        case .rejoined:
            return "Rejoined the session that was running here."
        case .undecided:
            return "Reconnecting…"
        case .restarted(.durabilityOff(let machine)):
            return "Started a new shell — durable sessions are off for \(machine), "
                + "so nothing was kept running. The directory is restored."
        case .restarted(.sessionGone):
            return "Started a new shell — the session that was running here is gone. "
                + "The directory is restored."
        case .restarted(.nothingRecorded):
            return "Started a new shell. The directory is restored."
        }
    }

    /// Whether this is worth putting in front of the human at all.
    ///
    /// ONLY A BROKEN PROMISE IS. A pane that rejoined got what it was
    /// promised, and a pane that never named a session was never promised
    /// anything — a notice on either is the noise that teaches people to
    /// dismiss notices unread, and after a reboot there would be one per
    /// pane.
    var isWorthSaying: Bool {
        switch self {
        case .restarted(.durabilityOff), .restarted(.sessionGone): return true
        case .rejoined, .undecided, .restarted(.nothingRecorded): return false
        }
    }
}
