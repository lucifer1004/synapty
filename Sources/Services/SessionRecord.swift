import Foundation

/// WHETHER A SESSION THIS WORKBENCH ONCE NAMED IS STILL RUNNING.
///
/// A RECORDED AGENT ID IS A RECORD, NOT A GRANT ([[RFC-0015]] C-PERSIST,
/// [[WI-2026-08-19-006]]). It may be used to re-associate a pane with a
/// child that SURVIVED; it must not be conferred on one that is newly
/// started. The two are told apart by asking, before the pane's command
/// is built, whether anything still answers to that name — because once
/// the command runs, the id is already the child's.
///
/// THE CLAIM, NOT THE SOCKET AND NOT THE PID.
///
/// NOT THE SOCKET, because a socket cannot be asked this safely: measured
/// on this platform, the fifth simultaneous `connect` to a live holder
/// whose backlog is full returns ECONNREFUSED — the same answer as no
/// listener at all. A liveness test whose false negative discards a
/// running session is not one to build on.
///
/// NOT THE PID, which is what this used to ask. `kill(pid, 0)` answers
/// whether anything wears the number, so a holder that died and had its
/// number handed to an unrelated process read as alive — and the caller
/// below then conferred that dead session's name on a NEWLY STARTED
/// child, which is precisely what [[RFC-0015]] C-PERSIST forbids and what
/// routes one agent's mail to a process that never was it.
///
/// The claim is `flock` on the record file, taken by the holder before it
/// writes and held open for the session's whole life ([[holder.Record]] on
/// the Zig side). It binds to the open file rather than to a number, and
/// the kernel releases it however the owner dies — exit, SIGKILL, a
/// reboot. Being able to take it is therefore the kernel saying that
/// particular process is gone.
enum SessionRecord {

    /// THROUGH THE CLASSIFICATION, like every other synapty path. Built by
    /// hand from the root, this was a second statement of where the Zig
    /// side puts records: move or rename that directory and the holder
    /// writes and sweeps in the new place while this opens a path nothing
    /// writes — `isLive` then answers false for EVERY live session, and
    /// every surviving holder is treated as gone ([[WI-2026-08-30-009]]).
    static func directory() -> URL { ConfigPaths.sessions }

    /// The record of one session. One place decides what it is called.
    static func url(for name: String) -> URL {
        directory().appendingPathComponent("\(name).json")
    }

    /// Where the holder puts this session's socket. Named here for the
    /// reason `directory()` is: a second statement of the Zig side's
    /// layout is a second thing to move.
    static func socketURL(for name: String) -> URL {
        directory().appendingPathComponent("\(name).sock")
    }

    /// WHERE THE CLAIM IS, which is deliberately not where the data is.
    /// An flock binds to an inode, so a claim taken on the record itself
    /// is released by anything that replaces that file — an atomic write,
    /// a rename, a restore — and the live holder behind it then reads as
    /// a tombstone here and gets swept ([[holder.claimState]],
    /// [[WI-2026-09-03-009]]).
    static func lockURL(for name: String) -> URL {
        directory().appendingPathComponent("\(name).lock")
    }

    /// EVERY SESSION STILL RUNNING, AND A SWEEP OF THE ONES THAT ARE NOT.
    ///
    /// LISTING IS SWEEPING, as it is on the Zig side ([[holder.sweepEnded]],
    /// called from the CLI's own enumeration). A record whose holder is
    /// gone offers nothing to return to and nothing to end — a row that can
    /// only be read — and they accumulate: 83 against one live session,
    /// measured before this existed, because the CLI was the only thing
    /// that ever swept and a human can go weeks without running it.
    ///
    /// THAT IS NOT HOUSEKEEPING, it is the premise of [[RFC-0015]]
    /// C-PANE-ARCHIVE: a live session named nowhere is the leak, and being
    /// listed is what makes it not one. A list mostly full of dead rows
    /// makes "listed" mean nothing.
    static func live() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: directory().path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .filter { name in
                // SWEPT ON `free`, NOT ON `not held` — the same three
                // states the Zig side distinguishes, and the same one of
                // them that justifies removing anything
                // ([[holder.sweepEnded]], [[WI-2026-08-30-010]]). A
                // record with no claim beside it is `absent`: a session
                // still starting up looks exactly like that, and treating
                // it as a tombstone deletes one on its way to being born.
                guard claim(name) != .free else { sweep(name); return false }
                return true
            }
            .sorted()
    }

    /// A record, its claim and its socket go together: a socket left
    /// behind is the leak the record was hiding, and a lock left behind
    /// is a name that reads as a tombstone forever.
    private static func sweep(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
        try? FileManager.default.removeItem(at: lockURL(for: name))
        try? FileManager.default.removeItem(at: socketURL(for: name))
    }

    /// What the claim on this name says, in the three states the Zig side
    /// names them ([[holder.Claim]]). The distinction is the whole point:
    /// `free` is a holder that is gone, `absent` is a name no holder has
    /// reached yet, and only the first is a tombstone.
    enum Claim { case held, free, absent }

    /// ASKED OF THE LOCK, as the Zig side asks it ([[holder.claimState]]).
    /// Asking the record instead is asking a file that gets rewritten,
    /// and the answer then depends on whether anyone has replaced it
    /// since — which swept 49 live sessions ([[WI-2026-09-03-009]]).
    static func claim(_ name: String) -> Claim {
        let fd = open(lockURL(for: name).path, O_RDONLY)
        guard fd >= 0 else { return .absent }
        defer { close(fd) }
        // NON-BLOCKING, because a caller asking whether to return to a
        // session must not wait on the answer. Taking the claim means
        // nobody was holding it; closing hands it straight back.
        return flock(fd, LOCK_EX | LOCK_NB) == 0 ? .free : .held
    }

    /// Whether a holder of this name is still running. A name whose claim
    /// is `absent` is not one to return to, which is the same answer
    /// [[holder.startWouldJoin]] gives.
    static func isLive(_ name: String) -> Bool { claim(name) == .held }
}
