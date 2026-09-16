import Foundation

/// What a remote host is listening on, AND WHAT IS HOLDING EACH PORT, so a
/// human can reach a service no agent thought to expose.
///
/// THE FALLBACK, NOT THE MAIN PATH ([[RFC-0013]] C-PRIMITIVES). An agent
/// that runs `synapty expose` says what its service is and gets a title;
/// discovery has to ask the machine. It exists for the processes that know
/// nothing about this application — a dev server someone started by hand, a
/// dashboard that predates the agent — which would otherwise be unreachable
/// from here.
///
/// A NUMBER ALONE IS NOT SOMETHING ANYBODY RECOGNISES, which is why the
/// program comes back with it ([[WI-2026-09-07-001]]). [[RFC-0015]]
/// C-CONTENT admits this list only behind an explicit act because "a
/// machine answers on many ports that are nobody's work, and a list that
/// leads with them buries the few that are" — and seventy-six rows reading
/// `port 51220` bury them just as thoroughly as no heading would.
///
/// [[WI-2026-08-15-011]]
enum PortDiscovery {

    /// One listener, as far as the host was willing to describe it.
    ///
    /// EVERY FIELD BUT THE PORT IS OPTIONAL, because every field but the
    /// port is something a host may decline to say: Linux names only the
    /// caller's own processes, and a machine that answers with plain
    /// `netstat` names none at all. A port whose owner is unknown is still
    /// a port worth offering, so it appears with the number alone rather
    /// than being dropped or given a guessed name.
    struct Listener: Equatable, Hashable, Identifiable {
        let port: Int
        var pid: Int?
        var program: String?
        /// The full command line, when the host would say. This is what
        /// separates two `node` servers from each other.
        var command: String?

        var id: Int { port }

        /// A PORT IS AN IDENTIFIER, NOT A QUANTITY, and every string below
        /// is built rather than interpolated into a `Text` for that reason.
        /// `Text("port \(anInt)")` resolves to the LocalizedStringKey
        /// initialiser, which formats the number for the locale — so port
        /// 9090 rendered as "9,090", a string that will not connect to
        /// anything and that a human reading it back has to mentally strip.
        /// A pid is an identifier for the same reason.
        var portText: String { "port \(port)" }

        /// What to call it. The port is the fallback, never the lead: the
        /// program is the thing the human recognises.
        var title: String {
            guard let program else { return portText }
            return "\(program) · port \(port)"
        }

        /// The row's first line.
        var name: String { program ?? portText }

        /// The row's second line, and NOTHING where the first line already
        /// said it. A listener the host would not name leads with `port
        /// 3000`, and a second line reading `port 3000` under it is the
        /// number twice and the answer never.
        ///
        /// THE PID IS THERE TO BE ACTED ON. A human deciding whether to
        /// open a port has one more question after "what is it" — "is that
        /// the one I started" — and a pid is what they take to `ps`.
        var detail: String? {
            guard program != nil else { return nil }
            guard let pid else { return portText }
            return "\(portText) · pid \(String(pid))"
        }

        /// The row's third line: the command line, when it says something
        /// the name above does not. Two `node` servers are told apart by
        /// their arguments and by nothing else; a process whose command
        /// line is just its own name would only repeat the line above it.
        var arguments: String? {
            guard let command, command != program else { return nil }
            return command
        }
    }

    /// Where the listener table stops and the process table starts.
    ///
    /// A SEPARATOR RATHER THAN A SHAPE TEST, because a command line can
    /// contain anything a listener line can — `curl http://127.0.0.1:8080`
    /// parses as a listener on port 8080 by every rule below, and would
    /// have added a port nothing is listening on.
    static let marker = "---synapty-processes---"

    /// Where the command lines stop and the executables start.
    ///
    /// A SECOND TABLE BECAUSE THE FIRST ONE CANNOT ANSWER THIS. A command
    /// line begins with a path that may contain spaces, so no rule over
    /// `args` recovers the executable — and the column the LISTENER tools
    /// print is worse: macOS's is space-separated from its neighbours and
    /// the name itself may contain spaces, so `Cursor Helper (P:38945`
    /// splits into three fields and the program reads as `(P`
    /// ([[WI-2026-09-08-016]]).
    static let pathMarker = "---synapty-paths---"

    /// One shell line that works on both kinds of host this project
    /// reaches, in a single round trip.
    ///
    /// `ss` is Linux's and absent on macOS; `netstat` is on both but prints
    /// a different shape, so the parser accepts either rather than the
    /// command choosing for it.
    ///
    /// WHY `-p` AND `-v`: both make the tool name the process holding the
    /// socket, which is the whole point of this. `ss -p` needs no privilege
    /// and simply says nothing about other users' processes; macOS
    /// `netstat -v` carries a `process:pid` column for EVERY listener,
    /// root's included.
    ///
    /// WHY NOT `lsof`, which is the obvious way to do this on macOS: it
    /// reports only the caller's own processes, and measured against
    /// `netstat` on a real Mac it missed ten of seventy-six listeners —
    /// among them the ones on 7890 and 9090. Naming ports by losing ports
    /// is a bad trade.
    ///
    /// WHY `ps` AS WELL: both tools truncate the name — Linux at the
    /// kernel's 15-character `comm`, macOS at 16 — so a real host answers
    /// `openclaw-gatewa` and `com.metacubex.Cl`. `ps` gives the untruncated
    /// command line for every process on either kind of machine, and rides
    /// the same shell line, so it costs no second connection.
    static let command =
        "if command -v ss >/dev/null 2>&1; then ss -tlnpH; "
        + "else netstat -anv -p tcp 2>/dev/null | grep LISTEN; fi; "
        + "echo '\(marker)'; ps -eo pid=,args= 2>/dev/null; "
        + "echo '\(pathMarker)'; ps -eo pid=,comm= 2>/dev/null"

    /// Listeners parsed out of either tool's output, sorted and
    /// deduplicated by port.
    ///
    /// A PURE FUNCTION OVER TEXT, so the shapes can be tested without a
    /// host — and the shapes it is tested against are captures from real
    /// machines, because the ones that were invented offline have twice
    /// missed a form that a real one prints.
    static func parse(_ output: String) -> [Listener] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let split = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == marker }
        let paths = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == pathMarker }
        let listenerLines = lines[..<(split ?? paths ?? lines.endIndex)]
        let processLines = split.map { lines[lines.index(after: $0)..<(paths ?? lines.endIndex)] }
            ?? lines[lines.endIndex...]
        let pathLines = paths.map { lines[lines.index(after: $0)...] } ?? lines[lines.endIndex...]

        let commands = processTable(processLines)
        let executables = processTable(pathLines)

        // Deduplicated by port, keeping the first row that named an owner:
        // a port appears once per address family, and only one of the two
        // rows may carry the process.
        var byPort: [Int: Listener] = [:]
        for line in listenerLines {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let port = port(in: fields) else { continue }
            var listener = Listener(port: port)
            if let owner = owner(in: fields) {
                listener.pid = owner.pid
                listener.command = commands[owner.pid]
                // THE EXECUTABLE, ASKED BY PID. The name in the listener
                // column is whatever survived that tool's truncation and
                // this parser's field splitting, and on macOS a program
                // whose name contains a space survives as a fragment. The
                // PID does survive — it is the digits after the last colon
                // — so it is what the question is asked with.
                listener.program = executables[owner.pid].map(programName(of:))
                    ?? (owner.name.isEmpty ? nil : owner.name)
            }
            if let existing = byPort[port], existing.program != nil { continue }
            byPort[port] = listener
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    /// pid to full command line, from `ps -eo pid=,args=`.
    private static func processTable(_ lines: ArraySlice<Substring>) -> [Int: String] {
        var table: [Int: String] = [:]
        for line in lines {
            let trimmed = line.drop(while: \.isWhitespace)
            guard let gap = trimmed.firstIndex(where: \.isWhitespace),
                  let pid = Int(trimmed[..<gap]) else { continue }
            let args = trimmed[gap...].trimmingCharacters(in: .whitespaces)
            guard !args.isEmpty else { continue }
            table[pid] = args
        }
        return table
    }

    // MARK: - The port

    private static func port(in fields: [Substring]) -> Int? {
        for field in fields {
            guard field.contains(":") || field.contains(".") else { continue }
            if let port = port(from: String(field)) { return port }
        }
        return nil
    }

    /// The port at the end of a local-address field.
    ///
    /// FOUR SHAPES, and the obvious rule handles only three of them.
    ///
    ///     127.0.0.1:8931    ss, IPv4      — port after the last colon
    ///     [::1]:8931        ss, IPv6      — port after the last colon
    ///     127.0.0.1.8931    netstat, IPv4 — port after the last dot
    ///     ::1.18789         netstat, IPv6 — port after the last DOT,
    ///                                       in a field full of colons
    ///
    /// "Split on a colon if there is one, otherwise a dot" gets the first
    /// three and drops the fourth, reading `::1.18789` as the unparseable
    /// `1.18789`. Caught against a real macOS host, whose listener list the
    /// offline cases did not resemble.
    ///
    /// So: try the DOT first, and fall back to the colon. Every shape above
    /// lands correctly, because a Linux field's last dot leaves `1:8931`,
    /// which is not a number, and the colon rule then takes it.
    static func port(from field: String) -> Int? {
        if let value = trailingNumber(of: field, after: ".") { return value }
        return trailingNumber(of: field, after: ":")
    }

    private static func trailingNumber(of field: String, after separator: Character) -> Int? {
        guard let index = field.lastIndex(of: separator) else { return nil }
        // A wildcard peer column (`*.*`, `0.0.0.0:*`) carries no port and
        // must not be made to yield one.
        guard let value = Int(field[field.index(after: index)...]),
              (1...65535).contains(value) else { return nil }
        // AND NEITHER MAY A PROCESS NAME. `netstat -v`'s column reads
        // `WeChat:88684`, `launchd:1`, `com.metacubex.Cl:33407` — every one
        // of which ends in a number inside the port range, and the last two
        // of which contain the separator as well. Requiring what precedes
        // the number to look like an address is what keeps a pid from being
        // offered as a port.
        guard isAddress(field[..<index]) else { return nil }
        return value
    }

    /// Whether this could be a network address rather than a program name.
    ///
    /// The test is the CHARACTER SET and not merely the presence of a dot,
    /// because the names that collide here are dotted: `com.metacubex.Cl`
    /// and `io.tailscale.ipn` are both real, both on this operator's Mac.
    /// An address is hex digits, dots, colons and brackets; those two are
    /// disqualified by their letters.
    ///
    /// A ZONE IS EXEMPT. `127.0.0.53%lo` is what systemd-resolved's stub
    /// looks like on a real Linux host, and an interface name is an
    /// arbitrary word, so anything after `%` is not examined.
    ///
    /// A program named entirely out of hex — `beef`, `cafe` — would pass.
    /// It is worth naming rather than hiding: the cost is one offered port
    /// that nothing answers on, and the alternative is fixing the column
    /// index of a tool whose column count we do not control.
    private static func isAddress(_ text: Substring) -> Bool {
        if text == "*" { return true }
        let head = text.prefix(while: { $0 != "%" })
        guard head.contains(".") || head.contains(":") else { return false }
        return head.allSatisfy {
            $0.isHexDigit || $0 == "." || $0 == ":" || $0 == "*" || $0 == "[" || $0 == "]"
        }
    }

    // MARK: - The process

    /// The name and pid holding the socket, in whichever shape the host's
    /// tool prints them.
    static func owner(in fields: [Substring]) -> (name: String, pid: Int)? {
        for field in fields {
            if field.hasPrefix("users:(") {
                if let owner = ssOwner(field) { return owner }
                continue
            }
            if let owner = netstatOwner(field) { return owner }
        }
        return nil
    }

    /// Linux: `users:(("openclaw-gatewa",pid=839,fd=21))`, absent entirely
    /// on a process belonging to somebody else.
    private static func ssOwner(_ field: Substring) -> (name: String, pid: Int)? {
        guard let open = field.firstIndex(of: "\""),
              let close = field[field.index(after: open)...].firstIndex(of: "\""),
              let pidMark = field.range(of: "pid=") else { return nil }
        let name = String(field[field.index(after: open)..<close])
        let digits = field[pidMark.upperBound...].prefix(while: \.isNumber)
        guard !name.isEmpty, let pid = Int(digits) else { return nil }
        return (name, pid)
    }

    /// macOS: a `process:pid` column, present for every listener including
    /// root's. It is told from an address column by the same test that
    /// keeps its pid from being read as a port.
    private static func netstatOwner(_ field: Substring) -> (name: String, pid: Int)? {
        guard let mark = field.lastIndex(of: ":") else { return nil }
        let name = field[..<mark]
        let digits = field[field.index(after: mark)...]
        guard !name.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let pid = Int(digits), !isAddress(name) else { return nil }
        return (String(name), pid)
    }

    /// The program, from the path its process is running.
    ///
    /// THIS REPLACES A HEURISTIC THAT SEARCHED THE COMMAND LINE for a
    /// token beginning with the truncated name, and both examples in that
    /// function's own comment failed when they were finally executed:
    /// `openclaw-gatewa` found `openclaw-gateway-production.yml`, and
    /// `com.metacubex.Cl` found `com.metacubex.ClashX.config.yaml` — the
    /// CONFIGURATION FILES, not the programs. A guess over arguments is
    /// not needed when the executable can be asked for
    /// ([[WI-2026-09-08-016]]).
    ///
    /// THE BASENAME, AND WHAT IT IS NOT. macOS answers with a path for
    /// most processes and with a rewritten process title for some; the
    /// last path component is the program in the first case and the whole
    /// title in the second, which is long but true. Neither is invented.
    static func programName(of executable: String) -> String {
        let trimmed = executable.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        let base = String(trimmed[trimmed.index(after: slash)...])
        return base.isEmpty ? trimmed : base
    }

    // MARK: - What is worth offering

    /// Ports worth OFFERING, which is a smaller set than ports in use.
    ///
    /// Dropped: anything under 1024, because a privileged port on someone
    /// else's machine is infrastructure rather than something an agent is
    /// showing — sshd above all, which is how we got there. And anything
    /// already exposed, so the same service is not offered twice under two
    /// different labels.
    static func offerable(_ listeners: [Listener], alreadyExposed: Set<Int>) -> [Listener] {
        listeners.filter { $0.port >= 1024 && !alreadyExposed.contains($0.port) }
    }
}
