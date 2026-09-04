import Foundation

/// WHAT A BROWSER LEAF WILL LOAD, and what it refuses out loud
/// ([[RFC-0015]] C-CONTENT, [[WI-2026-08-19-004]]).
///
/// AN ALLOW-LIST AND NOT A BLOCKLIST. The difference is which way the
/// unknown falls: a blocklist admits every scheme nobody thought of, and
/// the schemes nobody thinks of are the interesting ones. Two are allowed
/// here and everything else is refused with the reason said out loud.
///
/// `file:` IS NAMED SEPARATELY even though the list would refuse it
/// anyway. It is the one a human types by accident — dragging a path in,
/// pasting from a file manager — and "not an address this pane will load"
/// tells them nothing they can act on, while "this pane does not open
/// files on your machine" tells them where to go instead. A refusal that
/// does not say what to do is a refusal that gets worked around.
///
/// WHY A TYPE RATHER THAN A CHECK AT THE CALL SITE. The same reasoning
/// [[ExposedPath]] records: a check somewhere is a check that some other
/// caller does not do, and this one gates a WKWebView — the content most
/// able to imitate the window it is drawn in ([[ADR-0010]] rule d).
enum BrowserAddress {

    /// The whole of it. Two entries, documented here and nowhere else.
    static let allowedSchemes = ["http", "https"]

    enum Rejection: Error, Equatable {
        case empty
        case localFile
        case refusedScheme(String)
        case noHost

        /// SAID TO A HUMAN, so it names the thing they typed and what the
        /// pane will take instead.
        var message: String {
            switch self {
            case .empty:
                return "Type a web address."
            case .localFile:
                return "This pane shows web pages, not files on your machine. "
                    + "Open a file pane for those."
            case .refusedScheme(let scheme):
                return "\"\(scheme):\" is not an address this pane will open. "
                    + "It opens \(allowedSchemes.joined(separator: " and ")) pages."
            case .noHost:
                return "That does not name a site."
            }
        }
    }

    /// WHAT THE HUMAN TYPED, TURNED INTO WHAT WILL BE FETCHED — or a
    /// refusal that says why.
    ///
    /// A SCHEME IS ONLY A SCHEME WHEN IT IS ONE. `localhost:3000` parses
    /// as scheme `localhost` under RFC 3986 and would be refused as an
    /// unknown scheme, which is nonsense to a human typing the commonest
    /// address there is. The rule that separates them: what follows the
    /// colon is all digits, so it is a port and the word before it is a
    /// HOST. Nothing else about the string is guessed.
    static func parse(_ typed: String) -> Result<URL, Rejection> {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }

        var candidate = text
        if let scheme = declaredScheme(of: text) {
            let lowered = scheme.lowercased()
            if lowered == "file" { return .failure(.localFile) }
            guard allowedSchemes.contains(lowered) else {
                return .failure(.refusedScheme(lowered))
            }
        } else {
            // NO SCHEME MEANS THE HUMAN OMITTED IT, and the one to supply
            // is not always the safer one: a development server on this
            // machine speaks http, and defaulting it to https puts a
            // handshake failure in front of the commonest address a
            // workbench is pointed at. Loopback gets http; everything
            // else gets https, because for a real site the transport is
            // not ours to downgrade.
            candidate = (isLoopback(text) ? "http://" : "https://") + text
        }

        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else {
            return .failure(.noHost)
        }
        return .success(url)
    }

    /// The scheme the text actually declares, or nil where the colon
    /// introduces a port.
    private static func declaredScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let head = String(text[text.startIndex..<colon])
        guard !head.isEmpty,
              head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
              head.first?.isLetter == true
        else { return nil }
        let rest = String(text[text.index(after: colon)...])
        // `host:8080` and `host:8080/path` are ports; `scheme:` anything
        // else is a scheme.
        let port = rest.prefix { $0.isNumber }
        if !port.isEmpty, rest.dropFirst(port.count).first.map({ $0 == "/" }) ?? true,
           !rest.hasPrefix("//") {
            return nil
        }
        return head
    }

    private static func isLoopback(_ text: String) -> Bool {
        let host = text.prefix { $0 != ":" && $0 != "/" }.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
    }
}
