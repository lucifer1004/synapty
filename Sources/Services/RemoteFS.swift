import Foundation
import os

/// Everything needed to reach one host, resolved. Sendable so the work can
/// leave the main actor without reaching back for a store.
struct RemoteConnection: Sendable, Equatable {
    var userAtHost: String
    var port: Int
    /// The existing ControlMaster socket. Reuse is what makes a listing cost
    /// half a second instead of three, and what lets a password-only host be
    /// browsed at all without a prompt.
    var controlPath: String
    var identity: String?

    /// ssh options shared by everything that rides the master.
    var sshOptions: [String] {
        var args = ["-o", "ControlPath=\(controlPath)", "-o", "ControlMaster=no"]
            + SSHPolicy.opening(connectTimeout: 10)
            + ["-p", "\(port)"]
        // A host that names NO key gets no -i: offering this machine's own
        // identity to a host that never authorised it turns a working
        // connection into "Permission denied" ([[WI-2026-08-15-008]]).
        if let identity { args += ["-i", identity] }
        return args
    }

    /// THE SAME OPTIONS, WITH THE ONE FLAG THAT DIFFERS. `scp` spells the
    /// port `-P`; `ssh` spells it `-p`, and `-p` to scp means "preserve
    /// times". A copy that quietly went to port 22 because the letter was
    /// wrong is the kind of thing that works on every host but the one
    /// that needed it.
    var scpOptions: [String] {
        sshOptions.enumerated().compactMap { index, arg in
            if arg == "-p" { return "-P" }
            return arg
        }
    }
}

/// Reads remote directories over the SFTP subsystem of an existing SSH
/// connection.
///
/// `ssh -s <host> sftp` hands back a raw protocol stream rather than a
/// program's output, so nothing here parses a rendering — see [[SFTPWire]]
/// for why that distinction is load-bearing for file names.
///
/// SYNCHRONOUS BY DESIGN, called off the main actor. A listing is a handful
/// of round trips on a connection that already exists; wrapping it in
/// asynchrony would buy nothing and would make the caller's cancellation
/// story harder than the operation.
///
/// [[WI-2026-08-15-009]]
enum RemoteFS {

    struct Listing: Sendable, Equatable {
        /// What the host says the path actually is, so `~` and `..` are
        /// resolved by the side that knows.
        var canonicalPath: String
        var entries: [SFTPWire.Entry]
    }

    enum Failure: Error, Equatable {
        case launch(String)
        case closed(String)
        case remote(String)

        /// What a human is told. The cause belongs in the log; this is the
        /// consequence, on the thing it happened to ([[RFC-0012]]).
        var message: String {
            switch self {
            case .launch(let why): return why
            case .closed(let why): return why
            case .remote(let why): return why
            }
        }
    }

    private static let log = Logger(subsystem: "dev.synapty", category: "remote-fs")

    static func list(_ path: String, over connection: RemoteConnection) -> Result<Listing, Failure> {
        do {
            return .success(try Pool.shared.withSession(connection) { session in
            // THE HOST CANONICALISES, EXCEPT WHERE THERE IS NOTHING TO
            // CANONICALISE. A relative path or one with `..` in it is the
            // host's to resolve, and doing that here would be guessing at
            // a filesystem we cannot see — but an absolute path with no
            // `..` and no `~` is already the answer, and asking costs a
            // round trip that is 247ms on a host far enough away to
            // notice ([[WI-2026-08-19-002]]).
            let asked = withoutTilde(path)
            let canonical = isCanonical(asked) ? asked : try session.realPath(asked)
            let handle = try session.openDir(canonical)
            var entries: [SFTPWire.Entry] = []
            // READDIR returns SOME of the directory and is called until the
            // host says EOF. Stopping at the first reply silently truncates
            // every directory large enough to need a second one.
            while let batch = try session.readDir(handle) {
                entries.append(contentsOf: batch)
            }
            session.closeHandle(handle)

            // `.` and `..` are navigation, not content; the view offers its
            // own way up and would otherwise show two rows nobody can use.
            entries.removeAll { $0.name == "." || $0.name == ".." }

            // A LINK IS TYPED BY WHAT IT POINTS AT, for the one question a
            // listing has to answer: can this row be entered? READDIR
            // reports each entry as `lstat` does, so a symlink to a
            // directory arrives typed as a link and was shown as a file
            // nobody could open ([[WI-2026-08-29-002]]).
            //
            // ONE ROUND TRIP PER LINK, and only per link. Resolving the
            // whole listing would cost one per entry on directories that
            // hold no links at all, which is most of them.
            for index in entries.indices where entries[index].attributes.isSymlink {
                let target = canonical.hasSuffix("/")
                    ? canonical + entries[index].name
                    : canonical + "/" + entries[index].name
                guard let resolved = session.statFollowingLinks(target) else { continue }
                entries[index].attributes.resolvedIsDirectory = resolved.isDirectory
            }
            entries.sort { lhs, rhs in
                if lhs.attributes.isDirectory != rhs.attributes.isDirectory {
                    return lhs.attributes.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return Listing(canonicalPath: canonical, entries: entries)
            })
        } catch let failure as Failure {
            log.error("listing \(path, privacy: .public) failed: \(failure.message, privacy: .public)")
            return .failure(failure)
        } catch {
            return .failure(.remote("\(error)"))
        }
    }

    /// Whether a path is already what the host would answer: absolute, and
    /// naming no `..` or `.` component to resolve. A conservative test —
    /// symlinks still resolve elsewhere, which is why anything doubtful
    /// still asks.
    static func isCanonical(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains("..") && !parts.contains(".") && !path.contains("//")
    }

    // MARK: - The three write verbs ([[RFC-0015]] C-PANE-WRITES)

    /// CREATE, RENAME AND DELETE, AND NOTHING ELSE. The set is closed
    /// because permissions, ownership and execution are each a further
    /// grant with its own failure mode, and a verb list left open acquires
    /// them one convenience at a time.
    ///
    /// OVER THE PROTOCOL, NEVER OVER A SHELL. Every path here is a
    /// PROTOCOL STRING — length-prefixed, never parsed — so a file called
    /// `%s\n"` or `; rm -rf ~` is an ordinary name rather than an
    /// injection. A `ssh host "rm '\(path)'"` would have been shorter and
    /// is the reason this is written out.
    enum Write: Equatable {
        case makeDirectory(String)
        case rename(from: String, to: String)
        /// RENAME ONTO SOMETHING THAT IS THERE, which `rename` alone
        /// cannot do: SFTP v3 makes it an error when newpath exists, so
        /// the workbench offered a human "Replace" and then sent a packet
        /// the server had to refuse ([[WI-2026-08-28-008]]).
        ///
        /// ONE SESSION, so the window between disposing of the
        /// destination and putting the new name in its place is a round
        /// trip rather than a second connection.
        case replace(from: String, to: String, destinationIsDirectory: Bool)
        case delete(String, isDirectory: Bool)
    }

    /// ONE PRIMITIVE THE SUBSYSTEM UNDERSTANDS.
    ///
    /// A [[Write]] IS ITS STEPS, in order — `perform` runs exactly these
    /// and nothing else. Written out so the ORDER can be asserted without
    /// a server: a replace that renamed before disposing of the
    /// destination would be a rename onto something that is there, which
    /// SFTP v3 makes an error and which is the whole reason the case
    /// exists.
    enum Step: Equatable {
        case makeDirectory(String)
        case rename(from: String, to: String)
        case delete(String, isDirectory: Bool)
    }

    static func steps(of write: Write) -> [Step] {
        switch write {
        case .makeDirectory(let path):
            return [.makeDirectory(path)]
        case .rename(let from, let to):
            return [.rename(from: from, to: to)]
        case .replace(let from, let to, let isDirectory):
            return [.delete(to, isDirectory: isDirectory), .rename(from: from, to: to)]
        case .delete(let path, let isDirectory):
            return [.delete(path, isDirectory: isDirectory)]
        }
    }

    static func perform(_ write: Write, over connection: RemoteConnection) -> Result<Void, Failure> {
        do {
            try Pool.shared.withSession(connection) { session in
            for step in steps(of: write) {
                switch step {
                case .makeDirectory(let path):
                    try session.mkdir(withoutTilde(path))
                case .rename(let from, let to):
                    try session.rename(withoutTilde(from), to: withoutTilde(to))
                case .delete(let path, let isDirectory):
                    try session.delete(withoutTilde(path), isDirectory: isDirectory)
                }
            }
            }
            return .success(())
        } catch let failure as Failure {
            log.error("write failed: \(failure.message, privacy: .public)")
            return .failure(failure)
        } catch {
            return .failure(.remote("\(error)"))
        }
    }

    /// Whether something is already there — asked before a write that
    /// would replace it ([[RFC-0015]] C-PANE-WRITES: a collision MUST NOT
    /// be resolved silently).
    /// SFTP HAS NO `~`. Tilde expansion belongs to a shell, and this
    /// connection does not have one: measured against a live host,
    /// REALPATH("~") fails outright while REALPATH(".") answers
    /// /home/<user>. The subsystem opens in the home directory, so "." IS
    /// home — the substitution is exact rather than a guess at one.
    ///
    /// Worth doing here rather than in the caller: a path typed by a human,
    /// restored from a snapshot, or sent by an agent all arrive through
    /// this one door.
    static func withoutTilde(_ path: String) -> String {
        if path == "~" { return "." }
        if path.hasPrefix("~/") { return "." + path.dropFirst() }
        return path
    }

    // MARK: - One subsystem session

    /// A SESSION THAT OUTLIVES THE OPERATION ([[WI-2026-08-19-002]]).
    ///
    /// MEASURED, ON A REAL HOST 247ms AWAY. A listing was costing about
    /// eight round trips — three to open the subsystem channel, one to
    /// handshake, then REALPATH, OPENDIR and two READDIRs — which is two
    /// seconds to walk into a folder. Half of that was setting up a
    /// session we then threw away, every single time.
    ///
    /// The ControlMaster already persists the CONNECTION; what nothing
    /// persisted was the SFTP session on top of it. This does, per
    /// connection, and hands it out one caller at a time.
    ///
    /// REOPENED RATHER THAN TRUSTED. An ssh process can die for reasons
    /// this application never sees — the master exits, the network moves,
    /// the far side reboots — so a session that fails is discarded, the
    /// failure is reported, and the NEXT call opens a fresh one. (It used
    /// to retry once in place; the retry went with the per-session gate
    /// in [[WI-2026-09-02-022]], and the caller's own retry is the honest
    /// one.) A pool that assumed liveness would turn one dropped link into
    /// an application that cannot list anything until it is restarted.
    private final class Pool: @unchecked Sendable {
        static let shared = Pool()

        private let lock = NSLock()
        private var sessions: [String: Session] = [:]

        private func key(_ c: RemoteConnection) -> String {
            "\(c.userAtHost):\(c.port):\(c.controlPath)"
        }

        /// Runs `body` on a live session for this connection; a session
        /// that fails is retired so the next call gets a fresh one.
        /// ONE LOCK PER SESSION, NOT ONE FOR THE POOL ([[WI-2026-09-02-022]]).
        /// The pool's lock used to be held across `body` — a full remote
        /// listing over the network — so one host that stopped answering
        /// held it forever and every other host's browser queued behind
        /// it until the app restarted. The pool lock now guards the map
        /// only; each session has its own gate for its wire, and a read
        /// that goes quiet ends the session (`receive`).
        func withSession<T>(_ connection: RemoteConnection,
                            _ body: (Session) throws -> T) throws -> T {
            let session = try acquire(connection)
            session.gate.lock()
            defer { session.gate.unlock() }
            do {
                if !session.handshaken {
                    try session.handshake()
                    session.handshaken = true
                }
                return try body(session)
            } catch {
                // The wire is in an unknown state after a failure — drop the
                // session so the next call opens a fresh one.
                retire(session, for: connection)
                throw error
            }
        }

        /// The live session for a connection, or a new one — map lock only.
        private func acquire(_ connection: RemoteConnection) throws -> Session {
            lock.lock()
            defer { lock.unlock() }
            let id = key(connection)
            if let held = sessions[id], held.isAlive { return held }
            sessions[id]?.close()
            let fresh = try Session(connection: connection)
            sessions[id] = fresh
            return fresh
        }

        private func retire(_ session: Session, for connection: RemoteConnection) {
            lock.lock()
            if sessions[key(connection)] === session { sessions[key(connection)] = nil }
            lock.unlock()
            session.close()
        }

        /// Called when a connection goes away, so a dead ssh process does
        /// not sit here holding a file descriptor.
        func release(_ connection: RemoteConnection) {
            lock.lock()
            defer { lock.unlock() }
            sessions.removeValue(forKey: key(connection))?.close()
        }
    }

    private final class Session {
        private let process = Process()
        private let toRemote = Pipe()
        private let fromRemote = Pipe()
        private var buffer = Data()
        private var nextID: UInt32 = 1
        /// This session's own turn-taking; see Pool.withSession.
        let gate = NSLock()
        var handshaken = false

        var isAlive: Bool { process.isRunning }

        init(connection: RemoteConnection) throws {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = connection.sshOptions + ["-s", connection.userAtHost, "sftp"]
            process.standardInput = toRemote
            process.standardOutput = fromRemote
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw Failure.launch("Could not start a file session: \(error)")
            }
        }

        func close() {
            toRemote.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
        }

        func handshake() throws {
            try send(SFTPWire.initPacket())
            guard case .version = try receive() else {
                throw Failure.closed("The host did not answer as a file server.")
            }
        }

        /// The attributes of what a path RESOLVES to, links followed.
        ///
        /// `nil` where the host will not answer — a link whose target is
        /// gone is the ordinary case, and a broken link is still an entry
        /// the human should see rather than a row that vanishes.
        func statFollowingLinks(_ path: String) -> SFTPWire.Attributes? {
            let id = takeID()
            guard (try? send(SFTPWire.request(.stat, id: id, string: path))) != nil,
                  let answer = try? receive(),
                  case .attributes(_, let attributes) = answer
            else { return nil }
            return attributes
        }

        func realPath(_ path: String) throws -> String {
            let id = takeID()
            try send(SFTPWire.request(.realPath, id: id, string: path))
            switch try receive() {
            case .names(_, let entries) where !entries.isEmpty:
                return entries[0].name
            case .status(_, let code, let message):
                throw Failure.remote(describe(code, message))
            default:
                throw Failure.closed("The host gave no answer for \(path).")
            }
        }

        func mkdir(_ path: String) throws {
            let id = takeID()
            try send(SFTPWire.mkdirRequest(id: id, path: path))
            try expectOK(what: "create \(path)")
        }

        func rename(_ from: String, to: String) throws {
            let id = takeID()
            try send(SFTPWire.request(.rename, id: id, from: from, to: to))
            try expectOK(what: "rename \(from)")
        }

        /// A DIRECTORY AND A FILE ARE DIFFERENT PACKETS. Sending REMOVE for
        /// a directory fails on every server, and the failure reads as a
        /// permission problem rather than as the wrong verb.
        func delete(_ path: String, isDirectory: Bool) throws {
            let id = takeID()
            try send(SFTPWire.request(isDirectory ? .rmdir : .remove, id: id, string: path))
            try expectOK(what: "delete \(path)")
        }

        /// The one reply these three get, and the only one that means the
        /// machine did what was asked.
        private func expectOK(what: String) throws {
            switch try receive() {
            case .status(_, let code, let message):
                guard code == SFTPWire.StatusCode.ok.rawValue else {
                    throw Failure.remote(describe(code, message))
                }
            default:
                throw Failure.closed("The host gave no answer when asked to \(what).")
            }
        }

        func openDir(_ path: String) throws -> Data {
            let id = takeID()
            try send(SFTPWire.request(.openDir, id: id, string: path))
            switch try receive() {
            case .handle(_, let handle):
                return handle
            case .status(_, let code, let message):
                throw Failure.remote(describe(code, message))
            default:
                throw Failure.closed("The host would not open \(path).")
            }
        }

        /// nil means the host said EOF — the listing is complete.
        func readDir(_ handle: Data) throws -> [SFTPWire.Entry]? {
            let id = takeID()
            var payload = Data()
            payload.appendUInt32(id)
            payload.appendUInt32(UInt32(handle.count))
            payload.append(handle)
            try send(SFTPWire.frame(.readDir, payload))

            switch try receive() {
            case .names(_, let entries):
                return entries
            case .status(_, let code, let message):
                if code == SFTPWire.StatusCode.eof.rawValue { return nil }
                throw Failure.remote(describe(code, message))
            default:
                throw Failure.closed("The listing stopped unexpectedly.")
            }
        }

        func closeHandle(_ handle: Data) {
            var payload = Data()
            payload.appendUInt32(takeID())
            payload.appendUInt32(UInt32(handle.count))
            payload.append(handle)
            try? send(SFTPWire.frame(.close, payload))
            _ = try? receive()
        }

        // MARK: Plumbing

        private func takeID() -> UInt32 {
            defer { nextID &+= 1 }
            return nextID
        }

        private func send(_ data: Data) throws {
            do {
                try toRemote.fileHandleForWriting.write(contentsOf: data)
            } catch {
                throw Failure.closed("The file session closed.")
            }
        }

        /// Read until a whole packet is available. A read returns whatever
        /// arrived, so a packet split across two of them is ordinary rather
        /// than exceptional.
        /// A READ THAT GOES QUIET ENDS THE SESSION ([[WI-2026-09-02-022]]).
        /// `availableData` blocks with no deadline: an ssh that stays alive
        /// while the network black-holes never returns, and the caller —
        /// and everyone behind its lock — waited forever. Poll first.
        static let readDeadlineMs: Int32 = 30_000

        private func receive() throws -> SFTPWire.Response {
            while true {
                if let response = SFTPWire.decode(from: &buffer) { return response }
                var waiting = pollfd(fd: fromRemote.fileHandleForReading.fileDescriptor,
                                     events: Int16(POLLIN), revents: 0)
                var ready = poll(&waiting, 1, Self.readDeadlineMs)
                // EINTR is not an answer; anything else negative is a
                // session that cannot be read, not one that is readable —
                // falling through to availableData here was an unbounded
                // read ([[WI-2026-09-02-034]]).
                while ready < 0, errno == EINTR { ready = poll(&waiting, 1, Self.readDeadlineMs) }
                if ready == 0 {
                    close()
                    throw Failure.closed("The host stopped answering the file session.")
                }
                if ready < 0 {
                    close()
                    throw Failure.closed("The file session's pipe failed (errno \(errno)).")
                }
                let chunk = fromRemote.fileHandleForReading.availableData
                if chunk.isEmpty {
                    throw Failure.closed("The host closed the file session.")
                }
                buffer.append(chunk)
            }
        }

        private func describe(_ code: UInt32, _ message: String) -> String {
            // The host's own message when it sent one; several servers do
            // not, and a bare code is not something to show a person.
            if !message.isEmpty { return message }
            return SFTPWire.StatusCode(rawValue: code)?.message
                ?? "The host refused the request (code \(code))."
        }
    }
}
