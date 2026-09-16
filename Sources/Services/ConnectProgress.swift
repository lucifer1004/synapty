import Darwin
import Foundation
import Observation

/// What a connection is doing, read from the channel the connection writes
/// ([[WI-2026-08-17-016]], `src/cli/progress.zig`).
///
/// WHY THIS IS NOT ON THE PANE. The pane is the session's screen
/// ([[ADR-0012]]): the session's own screen arrives and takes it, so
/// narration printed there is erased a moment later and the human sees
/// words flash past. The connection appends its steps here instead, and
/// this is what the workbench shows in front of the pane until there is a
/// screen to show.
///
/// A LINE IS `<milliseconds> <kind> <text>`. Kinds this acts on are
/// `paint` and `live` (there is something true on the pane now), and
/// `end` (nothing further will happen). Everything else is shown.
@MainActor
@Observable
final class ConnectProgress {

    struct Step: Identifiable, Equatable {
        let id: Int
        let at: Date
        let kind: String
        let text: String
    }

    /// Read every quarter second. Fast enough that the steps of a
    /// connection appear as it makes them, slow enough to be free.
    private static let pollInterval: TimeInterval = 0.25

    /// HOW LONG SILENCE IS ALLOWED TO LOOK LIKE PROGRESS. A placeholder is
    /// a promise that something is happening; when nothing has happened
    /// for this long the promise is not being kept, so the pane is handed
    /// back and whatever is really there becomes visible.
    static let silenceDeadline: TimeInterval = 8

    private(set) var steps: [Step] = []
    /// The pane has something true on it and should be shown.
    private(set) var revealed = false
    /// Nothing further will happen and no screen was ever painted.
    private(set) var failure: String?

    /// WHY THIS ACCOUNT STOPPED, when it has.
    ///
    /// RECORDED WHATEVER THE PANE HAS ON IT. `failure` below is only ever
    /// set for an account that ended BEFORE it painted, which is the dial
    /// that never produced a session; the `if !revealed` guarding it was
    /// read as covering both cases and covers one. So a client that ended
    /// after a paint — a reconnect that found no session, a child that
    /// exited, a protocol mismatch — had its reason discarded, and what
    /// the human was left with was libghostty's "Process exited"
    /// ([[WI-2026-09-07-004]]).
    private(set) var ended: AccountEnd?

    /// THE CLIENT HAS STOPPED DIALLING, since this instant. `nil` while it
    /// is still trying or has been told to try again.
    private(set) var pausedSince: Date?

    /// THE LINK IS DOWN AND THE CLIENT IS DIALLING AGAIN, since this
    /// instant. `nil` while it is up.
    ///
    /// A MID-SESSION LOSS IS NOT A CONNECTION FAILURE. The pane HAS a
    /// screen, and it is still the last true thing the session said — so
    /// nothing may be drawn over it and nothing may be written INTO it.
    /// What the workbench owes is to say the screen is no longer live
    /// ([[WI-2026-08-29-004]]).
    private(set) var lostSince: Date?

    /// How long this pane has been showing a screen nothing is updating.
    var lostFor: TimeInterval? { lostSince.map { Date().timeIntervalSince($0) } }

    /// A GAP IN WHAT THIS PANE CAN SHOW ([[RFC-0015]] C-FAILURE,
    /// [[progress.Hole]]). `nil` when there is none to report.
    ///
    /// SEPARATE FROM `steps` BECAUSE OF WHEN IT ARRIVES. The steps are
    /// read by the dialling placeholder, which is gone the moment the
    /// pane paints — and a hole is something the far side says about a
    /// pane that is already painting. Said on the same channel as
    /// progress, it was recorded here and shown to nobody, so "there is a
    /// hole in your scrollback" was a fact the human never received
    /// ([[WI-2026-09-16-002]]).
    ///
    /// IT DOES NOT CLEAR ITSELF. A `paint` clears `lostSince` because the
    /// link coming back ends the loss; nothing fills a gap back in, so
    /// this goes only when the human dismisses it or the pane re-dials.
    private(set) var hole: Hole?

    /// WHAT THE FAR SIDE SAID, AND WHETHER THE PANE WAS ALREADY SHOWING A
    /// SCREEN WHEN IT SAID IT.
    ///
    /// The second field is what the defect turned on: before the paint
    /// the placeholder is up and `latest` reaches the human; after it,
    /// nothing reads the steps at all. Both need the strip, and keeping
    /// the distinction is what lets a test tell the two apart rather than
    /// asserting the same thing twice.
    struct Hole: Equatable {
        let text: String
        let afterPaint: Bool
    }

    /// Read. The gap stays in the scrollback; the notice does not.
    func dismissHole() { hole = nil }

    // NO `link` HERE, AND ITS ABSENCE IS THE POINT. A `var link` stood
    // on this line deriving a [[LinkState]] from the three facts above,
    // and nothing in `Sources/` ever read it — five tests did. It was not
    // the derivation that ships: `WorkspaceManager.link(ofLeaf:fromDisk:)`
    // also passes `childDied`, without which `.dropped` is UNREACHABLE,
    // and on the `fromDisk` path it re-reads the account from disk where
    // this read the in-memory field, which lags by up to a poll. So the
    // tests exercised a path production does not take — the failure
    // `scripts/unshipped.py` was written about, in the one shape that gate
    // cannot see, because it scans `func` and this was a `var`
    // ([[WI-2026-09-11-011]]).
    //
    // This type owns the FACTS. What they mean together is
    // `LinkState.from`'s answer, and it has one caller.

    private var reader: Reader?
    private var lastLineAt: Date?
    private var startedAt: Date?
    /// WHOSE ACCOUNT THIS IS — the name the pane was DIALLED under, which
    /// is not always the name it ends up answering to: the hub renames a
    /// pane's agent to its durable id ([[RFC-0008]]), and a restored pane
    /// carries two names until the far side picks one. The channel and the
    /// retry marker beside it are addressed by THIS one, so anything
    /// speaking to the client that is writing here must ask for it rather
    /// than reach for `facts` ([[WI-2026-09-08-016]]).
    private(set) var agentID: String?
    /// WHICH DIAL'S ACCOUNT THIS IS. The channel is one path re-made per
    /// dial, so the file's identity is what distinguishes them.
    private var account: UInt64?

    /// The last thing worth putting in front of a human, in the order it
    /// was said.
    var latest: String? { steps.last(where: { $0.kind != "paint" })?.text }

    var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    /// Where a connection for this agent writes its account. Under
    /// `machine` because it describes THIS box's connection and means
    /// nothing on another one ([[ConfigPaths]]).
    static func channel(for agentID: String) -> URL {
        ConfigPaths.url(.machine, "connect")
            .appendingPathComponent("\(safe(agentID)).log")
    }

    /// An agent id reaches this from a host label the human typed, so it
    /// is not allowed to name a path.
    ///
    /// DOTS GO TOO, not just separators: a name is only safe if it cannot
    /// be a traversal, and `..` is made of characters that look harmless
    /// one at a time.
    private static func safe(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    /// Begin an account: empty whatever the last dial left and return
    /// where this one writes.
    ///
    /// THE DIAL OWNS THIS, and owns it at its very first instant. Emptying
    /// it later wiped an account that was already being written; emptying
    /// it earlier is impossible, because before the dial there is no dial.
    @discardableResult
    static func begin(for agentID: String) -> URL {
        beginDial(for: agentID, joining: false)
    }

    /// A DIAL BEGINS. `joining` says whether it is attaching to a name
    /// that already exists rather than minting one of its own.
    ///
    /// THE DIFFERENCE IS WHETHER THIS IS A FIRST INSTANT. A dial that
    /// mints `local-<4 hex>` owns the channel and empties it. A dial that
    /// was handed a name — the Still Running row, the status bar's agent
    /// row — is attaching to a session whose client is ALIVE and writing
    /// this very file. Emptying it there unlinks the inode that client
    /// holds an fd on, so everything it says next goes somewhere no path
    /// reaches: including the `end displaced` a taken session depends on,
    /// which `accountEnd()` then reads as nothing, closing the displaced
    /// pane in silence ([[RFC-0014]] C-ONE-CLIENT, [[WI-2026-09-09-002]]).
    ///
    /// PERMISSION IS CLEARED EITHER WAY. That a new dial must not take a
    /// retry meant for the last one is a separate obligation from
    /// replacing the channel; they were discharged by one line, so
    /// skipping the replacement silently skipped the other.
    @discardableResult
    static func beginDial(for agentID: String, joining: Bool) -> URL {
        let url = prepare(for: agentID)
        if !joining {
            // UNLINKED, NOT TRUNCATED. A reader following the previous
            // dial holds an open handle on this path, and truncation in
            // place is invisible to it — same file, and its offset is
            // simply past the end, so it goes quiet without anything
            // failing. Replacing the file gives the new dial an IDENTITY,
            // which is what lets a reader (and `Center.begin`) tell "still
            // the dial I am following" from "a dial that is over"
            // ([[WI-2026-09-08-016]]).
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        try? FileManager.default.removeItem(at: retryMarker(for: agentID))
        return url
    }

    /// WHICH FILE A PATH NAMES RIGHT NOW, or nil if it names none.
    ///
    /// The channel is a path that is re-made per dial, so the path alone
    /// does not say which dial is being read; the inode does.
    nonisolated static func account(at url: URL) -> UInt64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// ONE LINE OF THE CHANNEL, and the only place this process builds
    /// one.
    ///
    /// Three processes write this format — the CLI, the holder
    /// and this — and none can import another, so the shape is a
    /// cross-process contract rather than a shared function. What can have
    /// an owner is each process's own writing of it, and this one had none:
    /// `note` formatted the line inline ([[WI-2026-08-30-010]]).
    static func line(_ kind: String, _ text: String) -> String {
        "\(Int(Date().timeIntervalSince1970 * 1000)) \(kind) \(text)\n"
    }

    /// A step the workbench itself took, written the way the connection
    /// writes its own so that one account reads as one sequence.
    static func note(_ text: String, for agentID: String) {
        let line = line("note", text)
        let url = channel(for: agentID)
        guard let h = try? FileHandle(forWritingTo: url) else {
            try? Data(line.utf8).write(to: url)
            return
        }
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
    }

    /// WHERE A PAUSED CLIENT LOOKS FOR PERMISSION TO TRY AGAIN. Derived
    /// from the account channel so there is only ever one path to agree
    /// about, exactly as the Zig side derives it
    /// ([[progress.RetrySignal]]).
    static func retryMarker(for agentID: String) -> URL {
        let channel = channel(for: agentID)
        return channel.deletingLastPathComponent()
            .appendingPathComponent(channel.lastPathComponent + ".retry")
    }

    /// Leave it. The client takes it — one press, one attempt.
    static func requestRetry(for agentID: String) {
        prepare(for: agentID)
        FileManager.default.createFile(atPath: retryMarker(for: agentID).path, contents: Data())
    }

    @discardableResult
    static func prepare(for agentID: String) -> URL {
        let url = channel(for: agentID)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func start(agentID: String) {
        stop()
        // NOT EMPTIED HERE. The dial is what empties it, at the moment it
        // begins — which is before this, because the first slow thing a
        // connection does happens before there is a pane to read for.
        let url = Self.prepare(for: agentID)
        self.agentID = agentID
        steps = []
        revealed = false
        failure = nil
        ended = nil
        lostSince = nil
        pausedSince = nil
        hole = nil
        startedAt = Date()
        lastLineAt = Date()
        account = Self.account(at: url)
        // OFF THE MAIN THREAD BY CONSTRUCTION. This file is being appended
        // to by other processes while the workbench is drawing, and a
        // connection is exactly when the workbench has the most to draw —
        // several workspaces dialling at once, each with a surface. A read
        // where the drawing happens is a dropped frame waiting for a slow
        // filesystem.
        reader = Reader(url: url, interval: Self.pollInterval) { [weak self] lines, account in
            Task { @MainActor in self?.absorb(lines, of: account) }
        }
    }

    /// WHETHER THE ACCOUNT ENDS IN A DISPLACEMENT ([[RFC-0014]]
    /// C-ONE-CLIENT).
    ///
    /// READ NOW, NOT AWAITED. The caller is the pane's close, which IS
    /// the client's exit arriving; the client wrote this line with one
    /// unbuffered write before that exit, so it is on disk by the time
    /// there is anything to decide. The reader that follows this file
    /// polls every quarter second, and a poll cannot be relied upon to
    /// have run — a decision that waited for it would close the pane
    /// first and learn why afterwards.
    func accountEndsDisplaced() -> Bool { accountEnd() == .displaced }

    /// WHY THE ACCOUNT ENDED, READ FROM DISK RATHER THAN FROM THE POLL.
    ///
    /// The `ended` property above is fed by a reader that polls every
    /// quarter second, and every caller of THIS is a decision taken at the
    /// instant the client exits — which is before that poll can be relied
    /// on to have run. A decision that waited for it would close the pane
    /// first and learn why afterwards, and a decision that read the
    /// property would see `nil` and treat a session that is gone as an
    /// ordinary exit ([[WI-2026-09-07-011]]).
    ///
    /// The client writes its `end` with one unbuffered write before that
    /// exit, so it is on disk by the time there is anything to decide.
    func accountEnd() -> AccountEnd? {
        guard let agentID,
              let text = try? String(contentsOf: Self.channel(for: agentID), encoding: .utf8)
        else { return nil }
        return Self.endReason(text)
    }

    /// THE LAST THING SAID, not the last `end` said. One account holds
    /// every dial this pane has made, so an `end` with a later `start`
    /// after it describes a session that has already been replaced.
    static func endReason(_ text: String) -> AccountEnd? {
        // A LINE IS A LINE ONLY ONCE IT IS TERMINATED. This is read from a
        // file another process is appending to, at the instant that
        // process is exiting, so it can be observed mid-write — and a
        // trailing FRAGMENT is indistinguishable from a whole line by
        // shape. `"… end no_sess"` parses as an ending this build does not
        // know, which is `nil`, which falls through to the exit code,
        // which for a session that is gone is zero, which reads as an
        // ordinary exit and CLOSES THE PANE. Precisely the outcome
        // [[WI-2026-09-07-004]] exists to prevent, reached by a torn write
        // ([[WI-2026-09-08-011]]).
        //
        // CHEAPER THAN REASONING ABOUT WRITE ATOMICITY. Whether an
        // 80-byte append can tear on this filesystem is a question with a
        // filesystem-shaped answer; whether the text ends in a newline is
        // a question with a yes.
        var lines = text.split(separator: "\n")
        if !text.hasSuffix("\n") { _ = lines.popLast() }
        guard let last = lines.last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        let parts = last.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count > 2, Int64(parts[0]) != nil, parts[1] == "end" else { return nil }
        return AccountEnd(rawValue: parts[2].trimmingCharacters(in: .whitespaces))
    }

    /// Back to knowing nothing, without dropping the reader — the same
    /// state `start` leaves, for a dial that began under a reader that was
    /// already running.
    private func forgetTheLastDial() {
        steps = []
        revealed = false
        failure = nil
        ended = nil
        lostSince = nil
        pausedSince = nil
        hole = nil
        startedAt = Date()
        lastLineAt = Date()
    }

    /// WHETHER THIS IS STILL THE ACCOUNT OF THE DIAL NOW ON THE CHANNEL.
    ///
    /// `Center.begin` used to ask "has this pane revealed a screen yet",
    /// and answer NO for exactly the accounts a Retry follows — a dial
    /// that failed before it painted. So the retry returned early and the
    /// pane kept reading the file the previous dial left behind
    /// ([[WI-2026-09-08-016]]).
    func follows(agentID: String) -> Bool {
        guard self.agentID == agentID, reader != nil else { return false }
        return self.account == Self.account(at: Self.channel(for: agentID))
    }

    func stop() {
        reader?.cancel()
        reader = nil
    }

    /// Give the pane back without waiting for anything further — used when
    /// the workbench decides on its own that the wait is over.
    ///
    /// AND KEEP LISTENING. This used to `stop()` as well, which reads as
    /// tidy and is the same mistake `paint` made and had corrected: the
    /// channel outlives the moment the pane becomes worth looking at,
    /// because a transport dies mid-session and the client's `lost`,
    /// `paused` and `end` all come after it.
    ///
    /// WHAT IT COST. A dial that went quiet for the silence deadline had
    /// its reader cancelled and nothing ever restarted it — `Center.begin`
    /// runs at pane creation, restore and an explicit re-dial, and its
    /// `follows` guard requires a live reader anyway. So that pane
    /// answered `live` for the rest of its life while the session was
    /// gone: no scrim, no notice, no mark in the sidebar. Measured against
    /// a second reader on the same file, which reported `gone` at once
    /// ([[RFC-0015]] C-FAILURE, [[WI-2026-09-10-001]]).
    ///
    /// ONLY `end` HAS EARNED A STOP, because only `end` means nothing
    /// further will happen. Revealing means "show the pane now".
    func reveal() {
        revealed = true
    }

    /// A batch from the reader, the dial it came from, and the deadline
    /// that batch's silence may have crossed.
    private func absorb(_ lines: [String], of account: UInt64?) {
        // A DIFFERENT FILE IS A DIFFERENT DIAL. Everything below describes
        // the dial it was read from, so carrying it across a re-dial is
        // how a pane came to show the PREVIOUS attempt's reason for
        // stopping ([[WI-2026-09-08-016]]).
        if let account, let known = self.account, account != known { forgetTheLastDial() }
        if let account { self.account = account }
        for line in lines { absorb(line) }
        guard !revealed else { return }
        // A HANG IS NEVER HIDDEN. Silence for long enough means the pane
        // comes back, whatever the account did or did not say.
        if let last = lastLineAt, Date().timeIntervalSince(last) > Self.silenceDeadline {
            reveal()
        }
    }

    /// One account per session, for as long as that session is connecting.
    ///
    /// KEYED BY SESSION, NOT BY HOST: two panes can be dialling the same
    /// host at once, and each is waiting for its own screen.
    @MainActor
    @Observable
    final class Center {
        private var open: [UUID: ConnectProgress] = [:]

        /// Watch this session's account. IDEMPOTENT: the dial and the
        /// pane both reach this, and the second one must not restart a
        /// reader that is already following the first one's account.
        func begin(session: UUID, agentID: String) {
            if let existing = open[session], existing.follows(agentID: agentID) { return }
            let p = ConnectProgress()
            open[session] = p
            p.start(agentID: agentID)
        }

        func progress(for session: UUID) -> ConnectProgress? { open[session] }

        /// True while this session has something to say and no screen to
        /// show yet — which is exactly when the workbench shows the
        /// account instead of the pane.
        func waiting(for session: UUID) -> Bool {
            guard let p = open[session] else { return false }
            return !p.revealed
        }

        func forget(session: UUID) {
            open[session]?.stop()
            open[session] = nil
        }
    }

    private func absorb(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let ms = Int64(parts[0]) else { return }
        let at = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let kind = String(parts[1])
        let text = parts.count > 2 ? String(parts[2]) : ""
        lastLineAt = Date()
        if startedAt == nil || at < startedAt! { startedAt = at }

        switch kind {
        case "paint", "live":
            // The pane has the session on it now — and the link is up, so
            // a loss recorded earlier is over, and so is any pause that
            // followed it.
            revealed = true
            lostSince = nil
            pausedSince = nil
            ended = nil
            // THE CHANNEL STAYS OPEN. It used to be closed here, on the
            // reasoning that progress is what a pane shows BEFORE it has
            // a screen. That is true of the placeholder and not of the
            // account: a transport dies mid-session, and the client's
            // `lost` then arrived at a reader that had stopped. Saying it
            // anyway is why `runAttachThrough` wrote a line into the
            // session's own terminal, where a full-screen program owns
            // every cell and the words landed in the middle of it
            // ([[WI-2026-08-29-004]]).
        case "hole":
            // NOT APPENDED TO `steps`. The steps are the dial's account
            // and the placeholder reads the last of them; this outlives
            // the placeholder and has a surface of its own.
            hole = Hole(text: text, afterPaint: revealed)
        case "lost":
            lostSince = lostSince ?? at
            steps.append(Step(id: steps.count, at: at, kind: kind, text: text))
        case "paused":
            pausedSince = pausedSince ?? at
            steps.append(Step(id: steps.count, at: at, kind: kind, text: text))
        case "resumed":
            // DIALLING AGAIN, so the pause is over — but the link is still
            // down until something paints, so `lostSince` stays.
            pausedSince = nil
            steps.append(Step(id: steps.count, at: at, kind: kind, text: text))
        case "end":
            // WHY, ALWAYS. This is the fact a pane that has painted needs
            // most and was the one it never got ([[WI-2026-09-07-004]]).
            ended = AccountEnd(rawValue: text.trimmingCharacters(in: .whitespaces))
            // A connection that ends before it ever paints never had a
            // session to show. What it said on the way is the reason, and
            // it stays on the pane instead of racing past. THAT IS A
            // DIFFERENT QUESTION from the one above, and reading the two
            // off one `if` is what discarded every end that mattered.
            if !revealed { failure = latest ?? text }
            stop()
        default:
            steps.append(Step(id: steps.count, at: at, kind: kind, text: text))
        }
    }
}

/// Follows a file that another process is appending to, on a queue that is
/// not the one drawing the workbench ([[WI-2026-08-17-016]]).
///
/// WHOLE LINES ONLY. A reader that hands over half a line hands over half
/// a fact; the tail waits for the rest of itself. Every tick delivers,
/// even with nothing new, because the absence of lines is itself something
/// the caller judges — silence has a deadline.
private final class Reader: @unchecked Sendable {
    /// One queue for every account: they are tiny reads and a queue each
    /// would be a thread each, on the machine that is also connecting.
    private static let queue = DispatchQueue(label: "com.synapty.connect-progress")

    private let url: URL
    private let deliver: ([String], UInt64?) -> Void
    private var timer: DispatchSourceTimer?
    private var handle: FileHandle?
    private var opened: UInt64?
    private var partial = Data()

    init(url: URL, interval: TimeInterval, deliver: @escaping ([String], UInt64?) -> Void) {
        self.url = url
        self.deliver = deliver
        let t = DispatchSource.makeTimerSource(queue: Self.queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.pump() }
        timer = t
        t.resume()
    }

    func cancel() {
        timer?.cancel()
        timer = nil
        Self.queue.async { [self] in
            try? handle?.close()
            handle = nil
            opened = nil
        }
    }

    private func pump() {
        // A HANDLE OUTLIVES THE FILE IT WAS OPENED ON, and says nothing
        // about it. Each dial replaces the channel; a handle held across
        // that goes on reading an inode nothing will ever append to again,
        // returning no bytes and no error forever. Nothing here failed —
        // the reader simply went deaf, and the pane stayed on the previous
        // dial's account ([[WI-2026-09-08-016]]).
        if handle != nil, ConnectProgress.account(at: url) != opened {
            try? handle?.close()
            handle = nil
            opened = nil
            partial = Data()
        }
        // OPENED WHEN IT IS THERE, not only if it was there at the start.
        // The dial creates the channel and this can begin either side of
        // that; giving up on the first miss stayed blind for the whole
        // connection.
        if handle == nil {
            handle = try? FileHandle(forReadingFrom: url)
            // TAKEN FROM THE DESCRIPTOR, not from the path: between the
            // two there is a window in which a dial replaces the file, and
            // an identity read from the path could name a file this
            // handle is not on.
            opened = handle.flatMap { Self.account(ofDescriptor: $0.fileDescriptor) }
        }
        var out: [String] = []
        if let handle, let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            partial.append(chunk)
            while let nl = partial.firstIndex(of: 0x0A) {
                let line = partial[partial.startIndex..<nl]
                partial = partial[partial.index(after: nl)...]
                if let text = String(data: line, encoding: .utf8) { out.append(text) }
            }
        }
        deliver(out, opened)
    }

    private static func account(ofDescriptor fd: Int32) -> UInt64? {
        var s = Darwin.stat()
        guard fstat(fd, &s) == 0 else { return nil }
        return UInt64(s.st_ino)
    }
}
