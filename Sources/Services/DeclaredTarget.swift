import Foundation

/// WHETHER A HYPERLINK GOES WHERE ITS TEXT SAYS IT DOES.
///
/// A hyperlink escape lets a child print one thing and open another. Almost
/// always that is abbreviation, and it is what the escape is for: `ls
/// --hyperlink` prints `main.zig` and links the full path, `gh` prints
/// `#412`. Refusing those protects nobody and disables the feature.
///
/// The deception is narrower and worth stopping: characters that THEMSELVES
/// read as a destination, naming somewhere other than where the link goes.
/// A human reading their own screen cannot detect it, which is the one
/// thing that separates it from every other thing untrusted text can do to
/// them ([[RFC-0015]] C-DERIVED).
enum DeclaredTarget {

    enum Verdict: Equatable {
        /// The text claimed nothing, or claimed the same place. Open it.
        case follow
        /// The text claimed somewhere else. Show the human both first.
        case ask
    }

    /// THE LINK MAY BE MORE SPECIFIC THAN ITS TEXT. IT MAY NOT CONTRADICT
    /// IT.
    ///
    /// That one sentence is the whole rule, and it needs no list of public
    /// suffixes to tell `docs.company.test` from `main.zig` — a question
    /// that cannot be answered from the string alone, and whose answer
    /// would go stale. What can be answered is whether the destination
    /// still contains what the human read.
    static func verdict(shown: String, target: String) -> Verdict {
        let shown = shown.trimmingCharacters(in: .whitespaces)
        guard let actual = destination(of: target) else {
            // Nothing readable can be shown to agree with anything.
            return .ask
        }
        guard !shown.isEmpty else { return .follow }

        // THE TEXT CLAIMS A DESTINATION OF ITS OWN when it carries a
        // scheme or a leading separator. Then the two are compared as
        // destinations, and a claim of a different KIND is already a
        // contradiction: text reading as a file while an address opens is
        // the same lie as text reading as one host while another does.
        if scheme(of: shown) != nil || shown.hasPrefix("/") {
            guard let claimed = destination(of: shown) else { return .ask }
            switch (claimed, actual) {
            case (.host(let a), .host(let b)):
                // The HOST and not the path: a link that adds a path or a
                // query to the host the text named has not lied about
                // where it goes. A different host always has, including
                // one that merely begins with it.
                return a == b ? .follow : .ask
            case (.file(let a), .file(let b)):
                // FOLDED FIRST, BECAUSE WHOEVER OPENS IT WILL FOLD IT.
                // `/tmp/safe/../../../etc/passwd` starts with `/tmp/safe/`
                // and opens `/etc/passwd`; on this platform that also
                // launches an application when the target is a bundle.
                // Comparing raw strings compares something no filesystem
                // will ever act on.
                guard let a = normalise(a), let b = normalise(b) else { return .ask }
                // THEN AN ANCESTOR OR SOMEWHERE ELSE. Containment would
                // let `/tmp/a` stand for `/evil/tmp/a`, a different file
                // wearing part of the name, and would let `/etc` swallow
                // `/etcetera`. The separator makes it a boundary rather
                // than a prefix of a word.
                let ancestor = a.hasSuffix("/") ? a : a + "/"
                return a == b || b.hasPrefix(ancestor) ? .follow : .ask
            default:
                return .ask
            }
        }

        // A LABEL CLAIMS NOTHING — `#412`, `the docs` — and a label cannot
        // misdescribe a destination. The exception is a dotted label,
        // because `docs.company.test` reads as a place to go. Rather than
        // decide whether it IS one, ask whether the destination still
        // NAMES it: an abbreviation is the host or a path segment, while
        // a name pointing somewhere else is neither.
        //
        // A COMPONENT AND NOT A SUBSTRING. Anywhere-in-the-string would
        // hand an attacker `follow` for the price of appending the
        // displayed name to their own query.
        guard shown.contains(".") else { return .follow }
        return components(of: target).contains(shown.lowercased()) ? .follow : .ask
    }

    /// THE PARTS OF A TARGET THAT NAME WHERE IT GOES: the host and the
    /// path segments. A query and a fragment are carried TO a destination
    /// rather than being one, so nothing in them can stand for the place
    /// the human was reading.
    private static func components(of target: String) -> [String] {
        var rest = Substring(target)
        var host: String?
        if let scheme = scheme(of: target) {
            rest = rest.dropFirst(scheme.count + 1)
            if rest.hasPrefix("//") {
                rest = rest.dropFirst(2)
                let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
                rest = rest.dropFirst(authority.count)
                let name = authority.split(separator: "@").last ?? authority
                if scheme != "file", !name.isEmpty { host = String(name).lowercased() }
            }
        }
        let path = rest.prefix { $0 != "?" && $0 != "#" }
        return (host.map { [$0] } ?? [])
            + path.split(separator: "/").map { $0.lowercased() }
    }

    /// WHAT A STRING NAMES, reduced to the part a human is deceived about.
    ///
    /// For an address that is the HOST: a different path on the host the
    /// text named is not the deception this rule is about — a tracking
    /// query is not a lie about where you are going — while a different
    /// host always is. For a file it is the path itself, since there is no
    /// host to stand in for it.
    private enum Destination: Equatable {
        case host(String)
        case file(String)
    }

    private static func destination(of text: String) -> Destination? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let scheme = scheme(of: trimmed) {
            let rest = trimmed.dropFirst(scheme.count + 1)
            if scheme == "file" {
                var path = rest.hasPrefix("//") ? rest.dropFirst(2) : rest
                // A QUERY IS NOT PART OF A FILE. Foundation drops it
                // before opening, so keeping it here would compare a name
                // no one will ever open.
                path = path.prefix { $0 != "?" && $0 != "#" }
                return .file(String(path))
            }
            guard rest.hasPrefix("//") else { return nil }
            let authority = rest.dropFirst(2).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            // Credentials are not part of where it goes, and are the
            // classic way to make one host read as another.
            let host = authority.split(separator: "@").last ?? authority
            return host.isEmpty ? nil : .host(withoutPort(String(host)).lowercased())
        }

        if trimmed.hasPrefix("/") { return .file(trimmed) }

        return nil
    }

    /// A DIFFERENT PORT IS A DIFFERENT SERVICE, NOT A DIFFERENT PLACE.
    /// The preview says which one; asking about every tool that prints an
    /// explicit port would spend the dialog where nothing was misdescribed.
    /// An IPv6 literal keeps its brackets, so the colons inside are not
    /// mistaken for one.
    private static func withoutPort(_ host: String) -> String {
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            return String(host[...close])
        }
        guard let colon = host.lastIndex(of: ":"),
              host[host.index(after: colon)...].allSatisfy(\.isNumber)
        else { return host }
        return String(host[..<colon])
    }

    /// Fold `.` and `..`. Nil when the walk leaves the root, which names
    /// nothing to compare against.
    private static func normalise(_ path: String) -> String? {
        var stack: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default: stack.append(part)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    private static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[text.startIndex..<colon].lowercased()
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) })
        else { return nil }
        return scheme
    }

}
