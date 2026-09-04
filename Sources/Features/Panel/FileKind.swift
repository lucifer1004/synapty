import SwiftUI
import UniformTypeIdentifiers

/// WHAT A ROW OF A LISTING IS, for the one purpose an icon serves: telling
/// a human at a glance which of forty names is the one they came for.
///
/// THE CATEGORY IS NOT THE PICTURE. A kind decides how a row behaves —
/// whether it is somewhere to go — and stands in as a picture only when
/// nothing more specific is known. What is usually drawn is [[FileType]]'s
/// glyph, which is per-language: a source tree is most of what this pane
/// ever shows, and eight categories drew every file in one as the same
/// mark ([[WI-2026-08-29-007]]).
enum FileKind: Equatable {
    case folder
    case code
    case text
    case data
    case archive
    case image
    case media
    case document
    case file

    /// A folder is the one kind a human navigates INTO, so it is the one
    /// kind that earns the accent; everything else is content and is drawn
    /// as content.
    var isNavigable: Bool { self == .folder }

    /// The mark for a row whose suffix names no more specific one — the
    /// long tail the system typed, and everything unrecognised.
    var glyph: Character {
        switch self {
        case .folder: return Glyph.folder
        case .code: return Glyph.code
        case .text: return Glyph.text
        case .data: return Glyph.config
        case .archive: return Glyph.zip
        case .image: return Glyph.image
        case .media: return Glyph.video
        case .document: return Glyph.pdf
        case .file: return Glyph.file
        }
    }
}

/// What one suffix means: how the row behaves, and what it looks like.
struct FileType: Equatable {
    var kind: FileKind
    var glyph: Character
}

/// THE MARKS, BY THE NAME THEY CARRY UPSTREAM.
///
/// These are code points in the private-use area of Nerd Fonts' "Symbols
/// Only" face, which the bundle ships and macOS registers. A bare `\u{e6a9}`
/// in a table is unreadable and unverifiable; the upstream glyph name is
/// what a reader can look up and what a future bump can be checked against.
enum Glyph {
    // Seti-UI — the set VS Code, yazi and eza draw file trees with.
    static let zig: Character       = "\u{e6a9}"   // seti-zig
    static let swift: Character     = "\u{e699}"   // seti-swift
    static let rust: Character      = "\u{e68b}"   // seti-rust
    static let go: Character        = "\u{e627}"   // seti-go
    static let c: Character         = "\u{e649}"   // seti-c
    static let cpp: Character       = "\u{e646}"   // seti-cpp
    static let python: Character    = "\u{e606}"   // seti-python
    static let ruby: Character      = "\u{e605}"   // seti-ruby
    static let java: Character      = "\u{e66d}"   // seti-java
    static let kotlin: Character    = "\u{e634}"   // seti-kotlin
    static let javascript: Character = "\u{e60c}"  // seti-javascript
    static let typescript: Character = "\u{e628}"  // seti-typescript
    static let react: Character     = "\u{e625}"   // seti-react
    static let html: Character      = "\u{e60e}"   // seti-html
    static let css: Character       = "\u{e614}"   // seti-css
    static let shell: Character     = "\u{e691}"   // seti-shell
    static let php: Character       = "\u{e608}"   // seti-php
    static let lua: Character       = "\u{e620}"   // seti-lua
    static let perl: Character      = "\u{e67e}"   // seti-perl
    static let haskell: Character   = "\u{e61f}"   // seti-haskell
    static let elixir: Character    = "\u{e62d}"   // seti-elixir
    static let clojure: Character   = "\u{e642}"   // seti-clojure
    static let crystal: Character   = "\u{e62f}"   // seti-crystal
    static let markdown: Character  = "\u{e609}"   // seti-markdown
    static let text: Character      = "\u{e64e}"   // seti-text
    static let tex: Character       = "\u{e69b}"   // seti-tex
    static let license: Character   = "\u{e60a}"   // seti-license
    static let info: Character      = "\u{e66a}"   // seti-info
    static let yml: Character       = "\u{e6a8}"   // seti-yml
    static let xml: Character       = "\u{e619}"   // seti-xml
    static let csv: Character       = "\u{e64a}"   // seti-csv
    static let config: Character    = "\u{e615}"   // seti-config
    static let database: Character  = "\u{e64d}"   // seti-db
    static let lock: Character      = "\u{e672}"   // seti-lock
    static let docker: Character    = "\u{e650}"   // seti-docker
    static let makefile: Character  = "\u{e673}"   // seti-makefile
    static let image: Character     = "\u{e60d}"   // seti-image
    static let svg: Character       = "\u{e698}"   // seti-svg
    static let video: Character     = "\u{e69f}"   // seti-video
    static let audio: Character     = "\u{e638}"   // seti-audio
    static let zip: Character       = "\u{e6aa}"   // seti-zip
    static let pdf: Character       = "\u{e67d}"   // seti-pdf
    static let font: Character      = "\u{e659}"   // seti-font
    static let folder: Character    = "\u{e613}"   // seti-folder
    static let code: Character      = "\u{e64e}"   // seti-text, for source with no mark of its own

    // Codicons — for the questions Seti has no answer to.
    static let file: Character      = "\u{ea7b}"   // cod-file
    static let binary: Character    = "\u{eae8}"   // cod-file_binary
    static let json: Character      = "\u{eb0f}"   // cod-json
    static let symlink: Character   = "\u{eaee}"   // cod-file_symlink_file
    static let unknown: Character   = "\u{eb32}"   // cod-question

    /// The face the bundle ships and `ATSApplicationFontsPath` registers.
    static let fontFamily = "Symbols Nerd Font"
}

extension FileKind {
    /// THE ONE TABLE, and it is data rather than logic. One entry gives
    /// both halves of what a row needs, so a suffix cannot be typed one way
    /// and drawn another.
    ///
    /// A suffix that is not here is not a defect: the system is asked next,
    /// and after that `.file` is a real answer.
    static let byExtension: [String: FileType] = {
        var map: [String: FileType] = [:]
        func put(_ kind: FileKind, _ glyph: Character, _ suffixes: [String]) {
            for suffix in suffixes { map[suffix] = FileType(kind: kind, glyph: glyph) }
        }
        put(.code, Glyph.zig, ["zig", "zon"])
        put(.code, Glyph.swift, ["swift"])
        put(.code, Glyph.rust, ["rs"])
        put(.code, Glyph.go, ["go"])
        put(.code, Glyph.c, ["c", "h"])
        put(.code, Glyph.cpp, ["cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "cu"])
        put(.code, Glyph.python, ["py", "pyi"])
        put(.code, Glyph.ruby, ["rb", "gemspec"])
        put(.code, Glyph.java, ["java"])
        put(.code, Glyph.kotlin, ["kt", "kts"])
        put(.code, Glyph.javascript, ["js", "mjs", "cjs"])
        put(.code, Glyph.typescript, ["ts"])
        put(.code, Glyph.react, ["jsx", "tsx"])
        put(.code, Glyph.html, ["html", "htm"])
        put(.code, Glyph.css, ["css", "scss", "sass", "less"])
        put(.code, Glyph.shell, ["sh", "bash", "zsh", "fish", "ksh"])
        put(.code, Glyph.php, ["php"])
        put(.code, Glyph.lua, ["lua"])
        put(.code, Glyph.perl, ["pl", "pm"])
        put(.code, Glyph.haskell, ["hs"])
        put(.code, Glyph.elixir, ["ex", "exs"])
        put(.code, Glyph.clojure, ["clj", "cljs", "edn"])
        put(.code, Glyph.crystal, ["cr"])
        put(.code, Glyph.database, ["sql"])
        put(.code, Glyph.code, ["vim", "el", "nix", "dart", "scala", "r", "jl", "asm", "s"])

        put(.text, Glyph.markdown, ["md", "markdown", "mdx"])
        put(.text, Glyph.text, ["txt", "rst", "adoc", "org", "log"])
        put(.text, Glyph.tex, ["tex", "bib"])

        put(.data, Glyph.json, ["json", "jsonc", "json5"])
        put(.data, Glyph.yml, ["yaml", "yml"])
        put(.data, Glyph.xml, ["xml", "plist"])
        put(.data, Glyph.csv, ["csv", "tsv"])
        put(.data, Glyph.config, ["toml", "ini", "conf", "cfg", "env", "properties"])
        put(.data, Glyph.database, ["db", "sqlite", "sqlite3"])
        put(.data, Glyph.lock, ["lock"])

        put(.archive, Glyph.zip, ["zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar",
                                  "dmg", "pkg", "jar", "whl"])

        put(.image, Glyph.image, ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff",
                                  "ico", "icns"])
        put(.image, Glyph.svg, ["svg"])
        put(.document, Glyph.pdf, ["pdf"])
        put(.file, Glyph.font, ["ttf", "otf", "woff", "woff2"])
        put(.file, Glyph.binary, ["o", "a", "so", "dylib", "wasm", "bin"])

        put(.media, Glyph.video, ["mp4", "mov", "m4v", "mkv", "webm", "avi"])
        put(.media, Glyph.audio, ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus"])
        return map
    }()

    /// WHOLE NAMES, for the files a project's root is recognised by. These
    /// carry no suffix at all, so nothing above can reach them, and they
    /// are among the handful a human scanning a repository looks for first.
    static let byName: [String: FileType] = [
        "Dockerfile": FileType(kind: .code, glyph: Glyph.docker),
        "Containerfile": FileType(kind: .code, glyph: Glyph.docker),
        "Makefile": FileType(kind: .code, glyph: Glyph.makefile),
        "makefile": FileType(kind: .code, glyph: Glyph.makefile),
        "justfile": FileType(kind: .code, glyph: Glyph.makefile),
        "LICENSE": FileType(kind: .text, glyph: Glyph.license),
        "COPYING": FileType(kind: .text, glyph: Glyph.license),
        "README": FileType(kind: .text, glyph: Glyph.info),
    ]

    /// THE SUFFIX AND NOTHING ELSE. A listing is names and types; it does
    /// not read the file, and asking a remote host to sniff one to draw an
    /// icon would be a round trip per row.
    ///
    /// A DOTFILE NEEDS NO SPECIAL CASE. The leading dot is what makes
    /// `.zshrc` hidden, not what makes it a kind, and `zshrc` is in no
    /// category, so it lands on `.file` by the ordinary route. Excluding
    /// the leading dot by hand would only change the names where the whole
    /// dotfile IS a known suffix — `.env` — and there the match is right.
    ///
    /// THE TABLE ANSWERS FIRST, THEN THE SYSTEM. `UTType` knows a far
    /// larger set of suffixes than this file ever will, and pretending
    /// otherwise would be copying the system's database by hand. But what
    /// it knows DEPENDS ON THE MACHINE — `.zig`, `.rs` and `.go` all come
    /// back as unregistered `dyn.` types here, and `.json` resolves to
    /// whichever installed application claimed it — so a listing typed by
    /// `UTType` alone would draw the same REMOTE directory differently for
    /// two people. Consulting it only for suffixes the table does not name
    /// bounds that: machine variance can turn a `file` into something
    /// better and can never change an answer this file has fixed.
    static func type(of name: String, isDirectory: Bool) -> FileType {
        if isDirectory { return FileType(kind: .folder, glyph: Glyph.folder) }
        if let named = byName[name] { return named }
        guard let dot = name.lastIndex(of: ".") else {
            return FileType(kind: .file, glyph: Glyph.file)
        }
        let suffix = String(name[name.index(after: dot)...]).lowercased()
        if let known = byExtension[suffix] { return known }
        let kind = system(suffix) ?? .file
        return FileType(kind: kind, glyph: kind.glyph)
    }

    static func of(name: String, isDirectory: Bool) -> FileKind {
        type(of: name, isDirectory: isDirectory).kind
    }

    /// What the system's type database says, when it says anything.
    ///
    /// NOTHING BELOW MAY ASK `.data` OR `.item`. For a suffix nothing
    /// declared, `UTType` mints a `dyn.…` placeholder that conforms to
    /// `public.data` and to nothing else, so every question here misses it
    /// and it falls through as the non-answer it is. A branch on `.data`
    /// would file every unregistered suffix under that branch instead;
    /// `testAnUnregisteredSuffixIsNotAnAnswer` is what says so out loud,
    /// which is why there is no `isDynamic` check here doing it silently.
    ///
    /// ORDER IS THE WHOLE THING HERE, because conformance is a tree and
    /// most leaves reach several of these: `public.json` is text, `.svg`
    /// is XML and text and an image, `.dmg` is an archive and a disk
    /// image. The narrower question is asked first.
    private static func system(_ suffix: String) -> FileKind? {
        guard let type = UTType(filenameExtension: suffix) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .audio) { return .media }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
        if type.conforms(to: .json) || type.conforms(to: .yaml) || type.conforms(to: .propertyList)
            || type.conforms(to: .delimitedText) || type.conforms(to: .spreadsheet) { return .data }
        if type.conforms(to: .pdf) || type.conforms(to: .compositeContent) { return .document }
        if type.conforms(to: .text) { return .text }
        return nil
    }
}

/// The glyph for one row: what the thing IS, and whether it is the thing
/// or a name for it.
///
/// A LINK IS BADGED, NOT SUBSTITUTED. A link to a folder is drawn as a
/// folder, because that is what opening it gives you — the same rule the
/// listing follows when it decides the row can be entered
/// ([[WI-2026-08-29-002]]). The badge says the other half: that this name
/// stands for something kept somewhere else. The font has dedicated
/// symlink marks, and they are not used: substituting one would throw away
/// the answer to the first question to answer the second.
struct FileRowIcon: View {
    let file: BrowsedFile

    var body: some View {
        Text(String(glyph))
            .font(.custom(Glyph.fontFamily, size: DS.scaled(13)))
            .foregroundStyle(tint)
            .frame(width: DS.scaled(16))
            .overlay(alignment: .bottomLeading) {
                if file.isSymlink && !file.isBrokenLink {
                    // ON A DISC, because a bare glyph in the accent colour
                    // sat on an accent-coloured folder and vanished. The
                    // badge has to read against every icon it can land on.
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: DS.scaled(6), weight: .bold))
                        .foregroundStyle(DS.textPrimary)
                        .padding(DS.scaled(1.5))
                        .background(Circle().fill(DS.background))
                        .offset(x: -DS.scaled(3), y: DS.scaled(3))
                }
            }
            // ONE OWNER FOR THE WORDS. A `help` tooltip alongside this said
            // the same sentence a second time in the accessibility tree,
            // so every row announced its kind twice. A glyph carries no
            // name of its own, which is why this is not optional.
            .accessibilityLabel(description)
    }

    private var type: FileType { FileKind.type(of: file.name, isDirectory: file.isDirectory) }

    /// A BROKEN LINK CANNOT BE DRAWN AS WHAT IT POINTS AT, because nothing
    /// knows. It is drawn as a question rather than as a plain file, which
    /// would be a claim about a thing that is not there.
    private var glyph: Character { file.isBrokenLink ? Glyph.unknown : type.glyph }

    private var tint: Color {
        if file.isBrokenLink { return DS.warning }
        return type.kind.isNavigable ? DS.accent : DS.textTertiary
    }

    private var description: String {
        if file.isBrokenLink { return "A link with nothing on the end of it" }
        if file.isSymlink { return type.kind.isNavigable ? "A link to a folder" : "A link" }
        return type.kind.isNavigable ? "Folder" : "File"
    }
}
