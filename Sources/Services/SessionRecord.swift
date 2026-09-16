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

    /// THE NAME THE HOLDER WRITES, WHICH IS NOT ALWAYS THE NAME IT WAS
    /// GIVEN.
    ///
    /// `holder.canonical` folds A-Z to a-z and bounds the name at 98
    /// bytes before building any of the three paths, and says why: "These
    /// three paths are built the same way from the same string, so a name
    /// that may not be a socket may not be a record either, and one that
    /// folds must fold identically or a session's three files stop being
    /// one session's." This side interpolated the raw string into all
    /// three ([[WI-2026-09-11-015]]).
    ///
    /// MASKED TODAY BY THE FILESYSTEM, which is the part that makes it
    /// worth fixing rather than watching. On a case-insensitive APFS
    /// volume both spellings reach the same inode; on a case-sensitive
    /// one — or a `SYNAPTY_CONFIG_ROOT` pointed at one — `isLive` answers
    /// false for a session that is running and the workbench tells the
    /// human their work is gone while the holder still holds the pty.
    /// `holder.zig` names that hazard in those words: "a semantic that
    /// differs by filesystem is not a semantic".
    ///
    /// AND UNMASKED EVEN THERE: `live()` maps directory entries to names,
    /// so it returns the FOLDED name, while `Rejoining.settled` compares
    /// with `==`.
    ///
    /// A MIRROR IS A MIRROR, and the honest pin is the crossing test
    /// beside it, which starts a holder under a mixed-case id with the
    /// real binary and asks this side where it would look.
    static func canonical(_ name: String) -> String {
        // BYTE BY BYTE, BECAUSE THAT IS WHAT THE OWNER DOES.
        // `holder.canonical` is a loop over BYTES mapping 'A'...'Z' and
        // leaving everything else alone, and `validName` accepts any byte
        // from 0x20 up except '/' and 0x7f — so multibyte names are legal.
        // This used `String.lowercased()`, full Unicode case mapping, and
        // went looking for `ü.json` for a session written as `Ü.json`.
        //
        // AND PER-CHARACTER ASCII IS NOT THE SAME THING, which is the part
        // reasoning alone got wrong and the crossing test caught: a
        // DECOMPOSED `Ü` is U+0055 U+0308, one Swift `Character` whose
        // `isASCII` is false — so a per-character fold leaves it while the
        // holder folds its leading 'U' byte and writes `ü`. Measured: the
        // holder wrote `übercase-probe.json` and this side asked for
        // `Übercase-probe.json`.
        //
        // `holder.validName` refuses non-ASCII names outright now, for the
        // same reason in the other direction — a byte-wise fold cannot
        // keep "one string is one identifier" over Unicode. So the only
        // names this ever sees are ASCII, and this loop is then exactly
        // the holder's ([[WI-2026-09-12-002]]).
        //
        // IT ALSO MAKES THE BOUND MEAN THE SAME THING. The holder measures
        // the RAW name; this measured the FOLDED one, and Unicode folding
        // can change a name's byte count (U+0130 is two bytes, its
        // lowering three). A byte-wise ASCII fold cannot.
        let folded = String(decoding: name.utf8.map { byte in
            byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
        }, as: UTF8.self)
        // The holder's bound is on BYTES, and it refuses rather than
        // truncating — so a name it would refuse is one this cannot name
        // either, and returning it unchanged keeps the two agreeing that
        // there is no such session.
        return folded.utf8.count <= 98 ? folded : name
    }

    /// The record of one session. One place decides what it is called.
    static func url(for name: String) -> URL {
        directory().appendingPathComponent("\(canonical(name)).json")
    }

    /// Where the holder puts this session's socket. Named here for the
    /// reason `directory()` is: a second statement of the Zig side's
    /// layout is a second thing to move.
    static func socketURL(for name: String) -> URL {
        directory().appendingPathComponent("\(canonical(name)).sock")
    }

    /// WHERE THE CLAIM IS, which is deliberately not where the data is.
    /// An flock binds to an inode, so a claim taken on the record itself
    /// is released by anything that replaces that file — an atomic write,
    /// a rename, a restore — and the live holder behind it then reads as
    /// a tombstone here and gets swept ([[holder.claimState]],
    /// [[WI-2026-09-03-009]]).
    static func lockURL(for name: String) -> URL {
        directory().appendingPathComponent("\(canonical(name)).lock")
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
                // SWEPT ON ANYTHING THAT IS NOT `held`, which is the same
                // rule the Zig side applies ([[holder.Record.ownerGone]]).
                //
                // IT USED TO ASK FOR `free` SPECIFICALLY, on the stated
                // grounds that "a session still starting up looks exactly
                // like that, and treating it as a tombstone deletes one on
                // its way to being born". That is not true and the code it
                // cited says so: the holder creates and CLAIMS the lock
                // before it writes the record, so a record exists only
                // where a lock did. The ordering that is real is the
                // SOCKET's — bound before the record is written — and it is
                // guarded by requiring a record, not by refusing `absent`.
                //
                // What the narrow rule actually produced was a record that
                // was neither live nor sweepable: `isLive` wants `held` and
                // this wanted `free`, so a name whose lock had gone could
                // not be returned to and could not be removed. One sat in a
                // human's sidebar for six days ([[WI-2026-09-07-005]]).
                switch claim(name) {
                case .held: return true
                case .free, .absent: sweep(name); return false
                // A QUESTION THAT COULD NOT BE ASKED LEAVES THE ROW.
                // Listing it is wrong in one direction and sweeping it is
                // wrong in the other, and the two are not equally wrong:
                // a stale row is litter, a swept record is a live session
                // nothing names ([[RFC-0014]] C-LIVENESS).
                case .unknown: return true
                }
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
    /// FOUR ANSWERS, BECAUSE "I COULD NOT ASK" IS NOT AN ANSWER. This had
    /// three, and every `open(2)` failure became `absent` — ENOENT
    /// alongside EACCES, EMFILE, EIO. `absent` is what sweeps a record, so
    /// a workbench that had run out of descriptors would have deleted the
    /// record of every live session it held, at exactly the moment it had
    /// the most of them ([[holder.Claim]], [[WI-2026-09-07-008]]).
    enum Claim { case held, free, absent, unknown }

    /// ASKED OF THE LOCK, as the Zig side asks it ([[holder.claimState]]).
    /// Asking the record instead is asking a file that gets rewritten,
    /// and the answer then depends on whether anyone has replaced it
    /// since — which swept 49 live sessions ([[WI-2026-09-03-009]]).
    static func claim(_ name: String) -> Claim {
        let fd = open(lockURL(for: name).path, O_RDONLY)
        guard fd >= 0 else {
            // ENOENT IS THE ONLY FAILURE THAT MEANS ANYTHING. Everything
            // else is this process being unable to look, and a record is
            // never removed on the strength of that.
            return errno == ENOENT ? .absent : .unknown
        }
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
