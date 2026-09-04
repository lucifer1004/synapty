import Foundation

/// What a remote host is listening on, so a human can reach a service no
/// agent thought to expose.
///
/// THE FALLBACK, NOT THE MAIN PATH ([[RFC-0013]] C-PRIMITIVES). An agent
/// that runs `synapty expose` says what its service is and gets a title;
/// discovery can only say that something is listening on a number. It
/// exists for the processes that know nothing about this application —
/// a dev server someone started by hand, a dashboard that predates the
/// agent — which would otherwise be unreachable from here.
///
/// [[WI-2026-08-15-011]]
enum PortDiscovery {

    /// One shell line that works on both kinds of host this project
    /// reaches. `ss` is Linux's and absent on macOS; `netstat` is on both
    /// but prints a different shape, so the parser accepts either rather
    /// than the command choosing for it.
    static let command =
        "if command -v ss >/dev/null 2>&1; then ss -tlnH; else netstat -an -p tcp 2>/dev/null | grep LISTEN; fi"

    /// Ports parsed out of either tool's output, sorted and deduplicated.
    ///
    /// A PURE FUNCTION OVER TEXT, so the shapes can be tested without a
    /// host. Both formats put the local address in a field of their own and
    /// both separate the port with the LAST colon in it — which is what
    /// makes an IPv6 address parse correctly, since it is full of colons.
    static func parse(_ output: String) -> [Int] {
        var found = Set<Int>()
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            for field in fields {
                guard field.contains(":") || field.contains(".") else { continue }
                guard let port = port(from: String(field)) else { continue }
                found.insert(port)
            }
        }
        return found.sorted()
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
        return value
    }

    /// Ports worth OFFERING, which is a smaller set than ports in use.
    ///
    /// Dropped: anything under 1024, because a privileged port on someone
    /// else's machine is infrastructure rather than something an agent is
    /// showing — sshd above all, which is how we got there. And anything
    /// already exposed, so the same service is not offered twice under two
    /// different labels.
    static func offerable(_ ports: [Int], alreadyExposed: Set<Int>) -> [Int] {
        ports.filter { $0 >= 1024 && !alreadyExposed.contains($0) }
    }
}
