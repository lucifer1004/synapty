import Foundation

/// Where on an exposed service an agent is pointing.
///
/// AN AGENT OWNS THE PATH; WE OWN SCHEME, HOST AND PORT. That split is the
/// whole of it. A service worth showing is rarely at `/` — Jupyter without
/// its `?token=` is a login page, a Grafana board lives at `/d/abc123`, a
/// report is a file — so refusing paths would leave the human on a 404
/// while the agent says "look at this".
///
/// WHY THIS IS A TYPE AND NOT AN INTERPOLATION. Building the URL by
/// appending a string is not merely untidy; it hands the authority away:
///
///     "http://127.0.0.1:39000" + "@evil.com/"  →  http://127.0.0.1:39000@evil.com/
///
/// where `127.0.0.1:39000` has quietly become userinfo and the host is now
/// somebody else's. Assembling through `URLComponents`, with the authority
/// assigned rather than parsed, makes that unrepresentable. The checks
/// below are not defence in depth on top of that — they are what lets us
/// reject a bad input with a REASON instead of silently normalising it into
/// something the agent did not ask for.
///
/// [[WI-2026-08-15-011]]
enum ExposedPath {

    static let root = "/"

    enum Rejection: Error, Equatable {
        case notAbsolute
        case carriesAuthority
        case malformed

        /// The agent is the reader here: it gets this back from the CLI and
        /// has to fix its own call.
        var message: String {
            switch self {
            case .notAbsolute:
                return "a path must begin with / — expose takes a path, not a URL"
            case .carriesAuthority:
                return "a path may not name a scheme, host or port; those are the workbench's"
            case .malformed:
                return "that is not a usable path"
            }
        }
    }

    /// The agent's string, reduced to the parts it is allowed to choose.
    struct Parts: Equatable {
        var path: String
        var query: String?
        var fragment: String?
    }

    static func parse(_ raw: String?) -> Result<Parts, Rejection> {
        guard let raw, !raw.isEmpty else {
            return .success(Parts(path: root, query: nil, fragment: nil))
        }
        // A backslash is not a path separator here, and treating it as one
        // is a documented way past a leading-slash check: several browsers
        // normalise `/\` exactly as they do `//`, which is an authority.
        // Nothing legitimate needs one.
        guard !raw.contains("\\") else { return .failure(.notAbsolute) }
        guard !raw.contains(where: { $0.asciiValue.map { $0 < 0x20 || $0 == 0x7F } ?? false })
        else { return .failure(.malformed) }

        guard raw.hasPrefix("/") else { return .failure(.notAbsolute) }
        // `//host/x` IS an authority, not a path that happens to start with
        // two slashes — the one case where the leading-slash rule alone is
        // not enough.
        guard !raw.hasPrefix("//") else { return .failure(.carriesAuthority) }

        guard let parsed = URLComponents(string: raw) else { return .failure(.malformed) }
        guard parsed.scheme == nil, parsed.host == nil, parsed.port == nil,
              parsed.user == nil, parsed.password == nil
        else { return .failure(.carriesAuthority) }

        return .success(Parts(
            path: parsed.percentEncodedPath.isEmpty ? root : parsed.percentEncodedPath,
            query: parsed.percentEncodedQuery,
            fragment: parsed.percentEncodedFragment))
    }

    /// The address the human's browser or web view is sent to.
    ///
    /// ALWAYS LOOPBACK, and assigned rather than parsed: this function is
    /// the only place the authority is decided, so there is one place to
    /// look when asking whether an agent could ever move it.
    static func url(localPort: Int, path raw: String?) -> URL? {
        guard case .success(let parts) = parse(raw) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = localPort
        components.percentEncodedPath = parts.path
        components.percentEncodedQuery = parts.query
        components.percentEncodedFragment = parts.fragment
        return components.url
    }

    /// What a human is shown before they click. The whole address, because
    /// the point of showing it is that they can see where they are going.
    static func display(localPort: Int, path raw: String?) -> String {
        url(localPort: localPort, path: raw)?.absoluteString
            ?? "127.0.0.1:\(localPort)"
    }
}
