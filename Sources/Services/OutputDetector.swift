import Foundation

/// SOMETHING THE WORKBENCH RECOGNISED IN A PANE'S OUTPUT.
///
/// The characters are what the human is reading; the kind is what they
/// resolve to. Both halves are carried because [[RFC-0015]] C-DERIVED
/// requires the affordance to be derived from what is on the screen and
/// the resolved target to be shown before anything is taken — a display
/// text that differs from what it opens is the mechanism the clause exists
/// to close.
struct OutputDetection: Equatable {

    enum Kind: Equatable {
        /// An absolute path ON THE PANE'S MACHINE. A relative name has
        /// already been resolved by the time it wears this.
        case path(String)

        /// An address. RECOGNISED HERE, MARKED AND OPENED BY GHOSTTY,
        /// whose url matcher handles one wrapped across lines. This kind
        /// exists so that `https://h/p` is never taken for a relative
        /// name and resolved against a working directory.
        case address(String)
    }

    /// The characters on the screen, unmodified.
    let text: String

    /// Where they sit in the line they were found in.
    let range: Range<String.Index>

    let kind: Kind
}

/// WHAT A LINE OF OUTPUT NAMES, WITHOUT ASKING ANYTHING ABOUT IT.
///
/// A pure function of a string: it cannot stat, fetch or probe, because it
/// has nothing to do it with. That is [[RFC-0015]] C-DERIVED's requirement
/// made unrepresentable rather than merely obeyed — a resolution that
/// touched what it names would let an agent cause a filesystem access, or
/// a network request, by printing a string, with the human never having
/// acted at all.
///
/// It also means an offer is made for a path that does not exist. That is
/// the honest trade: the alternative is a probe, and the failure a human
/// meets on taking a dead path is bounded and reported ([[RFC-0015]]
/// C-DERIVED), while the probe is not bounded by anything.
enum OutputDetector {

    /// Trailing characters that end a sentence rather than a path. `/` is
    /// absent deliberately: a trailing slash names a directory.
    private static let trailingNoise = CharacterSet(charactersIn: ",.;:!?)]}>\"'`")

    /// Leading characters that open a quotation rather than a path.
    private static let leadingNoise = CharacterSet(charactersIn: "([{<\"'`")

    /// Everything this line names, in the order it names it.
    ///
    /// `base` is the directory a RELATIVE name resolves against, and it
    /// MUST be one the holder reported rather than one the child announced
    /// ([[RFC-0014]] C-PWD). Nil means unknown, and an unknown base is not
    /// a reason to guess: relative names simply produce nothing, while
    /// absolute ones are unaffected.
    static func detect(in line: String, base: String?) -> [OutputDetection] {
        var found: [OutputDetection] = []
        for token in tokens(of: line) {
            // THE SPAN SHRINKS TO WHAT OPENS. `App.swift:42:7` names a
            // line, and the line is not part of the name of the file — so
            // the affordance covers the file and the digits stay ordinary
            // text, rather than being underlined by something that will
            // not act on them.
            let whole = String(line[token.trimmed])
            let named = schemeOf(whole) == nil ? withoutLineAndColumn(whole) : whole
            guard let kind = classify(named, base: base) else { continue }
            let end = line.index(token.trimmed.lowerBound, offsetBy: named.count)
            found.append(
                OutputDetection(text: named, range: token.trimmed.lowerBound..<end, kind: kind))
        }
        return found
    }

    // MARK: - Cells

    /// WHICH CELLS A DETECTION COVERS, which is not which characters.
    ///
    /// A terminal lays text out in fixed cells and a CJK glyph takes two
    /// of them. The underline is drawn over this range and the pointer is
    /// tested against it, so both sides of "what the human is looking at"
    /// come from one function and cannot disagree with each other.
    static func cells(of detection: OutputDetection, in line: String) -> Range<Int> {
        let start = width(of: line[line.startIndex..<detection.range.lowerBound])
        return start..<(start + width(of: line[detection.range]))
    }

    /// THE WHITESPACE-DELIMITED CHARACTERS AT A CELL, whatever they are.
    ///
    /// Recognition plays no part: what a hyperlink's display text says
    /// has to be readable even when it is a bare name, because that is
    /// what it is compared against ([[RFC-0015]] C-DERIVED rule two).
    static func token(in line: String, atCell cell: Int) -> String? {
        for token in tokens(of: line) {
            let start = width(of: line[line.startIndex..<token.trimmed.lowerBound])
            let span = start..<(start + width(of: line[token.trimmed]))
            if span.contains(cell) { return String(line[token.trimmed]) }
        }
        return nil
    }

    /// What this line names under the pointer, or nothing.
    static func detection(in line: String, base: String?, atCell cell: Int) -> OutputDetection? {
        detect(in: line, base: base).first { cells(of: $0, in: line).contains(cell) }
    }

    private static func width(of text: Substring) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    /// EAST ASIAN WIDE AND FULLWIDTH TAKE TWO CELLS, everything else one.
    ///
    /// The ranges are Unicode's `East_Asian_Width=W|F`, which is what the
    /// terminal emitting these cells lays out by. This does not model
    /// combining marks or emoji sequences, both of which would need the
    /// grapheme segmentation the renderer does — an error there moves the
    /// underline, and is bounded by the length of one line.
    private static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        switch scalar.value {
        case 0x1100...0x115F,       // Hangul Jamo initial consonants
             0x2E80...0x303E,       // CJK radicals, Kangxi, CJK symbols
             0x3041...0x33FF,       // Hiragana through CJK compatibility
             0x3400...0x4DBF,       // CJK extension A
             0x4E00...0x9FFF,       // CJK unified ideographs
             0xA000...0xA4CF,       // Yi
             0xAC00...0xD7A3,       // Hangul syllables
             0xF900...0xFAFF,       // CJK compatibility ideographs
             0xFE10...0xFE19,       // Vertical forms
             0xFE30...0xFE6F,       // CJK compatibility forms
             0xFF00...0xFF60,       // Fullwidth forms
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,     // Emoji that terminals lay out wide
             0x1F900...0x1F9FF,
             0x20000...0x3FFFD:     // CJK extensions B and beyond
            return 2
        default:
            return 1
        }
    }

    // MARK: - Splitting

    private struct Token {
        /// The span left after the punctuation around it is dropped.
        let trimmed: Range<String.Index>
    }

    private static func tokens(of line: String) -> [Token] {
        var out: [Token] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard !line[index].isWhitespace else {
                index = line.index(after: index)
                continue
            }
            var end = index
            while end < line.endIndex, !line[end].isWhitespace { end = line.index(after: end) }
            if let trimmed = trim(line, from: index..<end) { out.append(Token(trimmed: trimmed)) }
            index = end
        }
        return out
    }

    private static func trim(
        _ line: String, from span: Range<String.Index>
    ) -> Range<String.Index>? {
        var lower = span.lowerBound
        var upper = span.upperBound
        while lower < upper, line[lower].unicodeScalars.allSatisfy(leadingNoise.contains) {
            lower = line.index(after: lower)
        }
        while lower < upper {
            let last = line.index(before: upper)
            guard line[last].unicodeScalars.allSatisfy(trailingNoise.contains) else { break }
            upper = last
        }
        return lower < upper ? lower..<upper : nil
    }

    // MARK: - Classification

    private static func classify(_ token: String, base: String?) -> OutputDetection.Kind? {
        if let scheme = schemeOf(token) {
            // A `file:` URL NAMES A PATH WHILE WEARING AN ADDRESS'S
            // CLOTHES. Admitting it as either would let the text pick
            // which rule it is judged under, so it is admitted as
            // neither.
            guard scheme != "file" else { return nil }
            return .address(token)
        }
        let path = token
        guard path.contains("/") else { return nil }
        if path.hasPrefix("/") {
            return normalise(path).map { .path($0) }
        }
        guard let base, base.hasPrefix("/") else { return nil }
        return normalise(base + "/" + path).map { .path($0) }
    }

    /// The `scheme://` a token opens with, if it opens with one.
    private static func schemeOf(_ token: String) -> String? {
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let scheme = token[token.startIndex..<colon].lowercased()
        guard !scheme.isEmpty, scheme.first!.isLetter else { return nil }
        guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) })
        else { return nil }
        // `file:///x` has no authority; every other scheme this admits
        // does, and `a:1` is a line number rather than a scheme.
        let rest = token[token.index(after: colon)...]
        guard rest.hasPrefix("//") else { return scheme == "file" ? scheme : nil }
        return scheme
    }

    /// `App.swift:42:7` is how a compiler points at a line. The line is
    /// not part of the name of the file.
    private static func withoutLineAndColumn(_ token: String) -> String {
        var parts = token.split(separator: ":", omittingEmptySubsequences: false)
        while parts.count > 1, let last = parts.last,
              !last.isEmpty, last.allSatisfy(\.isNumber)
        {
            parts.removeLast()
        }
        return parts.joined(separator: ":")
    }

    /// Fold `.` and `..` lexically. Nil when the walk leaves the root:
    /// there is no directory above `/` to answer with, and inventing one
    /// would open a place nobody named.
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
}
