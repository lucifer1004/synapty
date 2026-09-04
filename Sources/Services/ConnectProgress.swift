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

    private var reader: Reader?
    private var lastLineAt: Date?
    private var startedAt: Date?
    /// Whose account this is, so it can be re-read without the caller
    /// having to know which of a pane's two names it was dialled under.
    private var agentID: String?

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
        let url = prepare(for: agentID)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    /// ONE LINE OF THE CHANNEL, and the only place this process builds
    /// one.
    ///
    /// Four processes write this format — the CLI, connect.sh, the holder
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
        startedAt = Date()
        lastLineAt = Date()
        // OFF THE MAIN THREAD BY CONSTRUCTION. This file is being appended
        // to by other processes while the workbench is drawing, and a
        // connection is exactly when the workbench has the most to draw —
        // several workspaces dialling at once, each with a surface. A read
        // where the drawing happens is a dropped frame waiting for a slow
        // filesystem.
        reader = Reader(url: url, interval: Self.pollInterval) { [weak self] lines in
            Task { @MainActor in self?.absorb(lines) }
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
    func accountEndsDisplaced() -> Bool {
        guard let agentID,
              let text = try? String(contentsOf: Self.channel(for: agentID), encoding: .utf8)
        else { return false }
        return Self.endsDisplaced(text)
    }

    /// THE LAST THING SAID, not the last `end` said. One account holds
    /// every dial this pane has made, so an `end` with a later `start`
    /// after it describes a session that has already been replaced.
    static func endsDisplaced(_ text: String) -> Bool {
        guard let last = text.split(separator: "\n").last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return false }
        let parts = last.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count > 2, Int64(parts[0]) != nil else { return false }
        return parts[1] == "end" && parts[2].trimmingCharacters(in: .whitespaces) == "displaced"
    }

    func stop() {
        reader?.cancel()
        reader = nil
    }

    /// Give the pane back without waiting for anything further — used when
    /// the workbench decides on its own that the wait is over.
    func reveal() {
        revealed = true
        stop()
    }

    /// A batch from the reader, and the deadline that batch's silence may
    /// have crossed.
    private func absorb(_ lines: [String]) {
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
            if let existing = open[session], !existing.revealed { return }
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
            // a loss recorded earlier is over.
            revealed = true
            lostSince = nil
            // THE CHANNEL STAYS OPEN. It used to be closed here, on the
            // reasoning that progress is what a pane shows BEFORE it has
            // a screen. That is true of the placeholder and not of the
            // account: a transport dies mid-session, and the client's
            // `lost` then arrived at a reader that had stopped. Saying it
            // anyway is why `runAttachThrough` wrote a line into the
            // session's own terminal, where a full-screen program owns
            // every cell and the words landed in the middle of it
            // ([[WI-2026-08-29-004]]).
        case "lost":
            lostSince = lostSince ?? at
            steps.append(Step(id: steps.count, at: at, kind: kind, text: text))
        case "end":
            // A connection that ends before it ever paints never had a
            // session to show. What it said on the way is the reason, and
            // it stays on the pane instead of racing past.
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
    private let deliver: ([String]) -> Void
    private var timer: DispatchSourceTimer?
    private var handle: FileHandle?
    private var partial = Data()

    init(url: URL, interval: TimeInterval, deliver: @escaping ([String]) -> Void) {
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
        }
    }

    private func pump() {
        // OPENED WHEN IT IS THERE, not only if it was there at the start.
        // The dial creates the channel and this can begin either side of
        // that; giving up on the first miss stayed blind for the whole
        // connection.
        if handle == nil { handle = try? FileHandle(forReadingFrom: url) }
        var out: [String] = []
        if let handle, let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            partial.append(chunk)
            while let nl = partial.firstIndex(of: 0x0A) {
                let line = partial[partial.startIndex..<nl]
                partial = partial[partial.index(after: nl)...]
                if let text = String(data: line, encoding: .utf8) { out.append(text) }
            }
        }
        deliver(out)
    }
}
