import CoreText
import XCTest
@testable import Synapty

/// WHAT A ROW LOOKS LIKE, tested as the pure question it is
/// ([[WI-2026-08-29-005]]).
final class FileKindTests: XCTestCase {

    // MARK: - The kind is the suffix, and a directory outranks it

    func testASuffixPicksTheCategory() {
        XCTAssertEqual(FileKind.of(name: "main.zig", isDirectory: false), .code)
        XCTAssertEqual(FileKind.of(name: "README.md", isDirectory: false), .text)
        XCTAssertEqual(FileKind.of(name: "hosts.json", isDirectory: false), .data)
        XCTAssertEqual(FileKind.of(name: "Synapty.dmg", isDirectory: false), .archive)
        XCTAssertEqual(FileKind.of(name: "shot.png", isDirectory: false), .image)
        XCTAssertEqual(FileKind.of(name: "clip.mov", isDirectory: false), .media)
    }

    func testTheSuffixIsReadWithoutRegardToCase() {
        XCTAssertEqual(FileKind.of(name: "SHOT.PNG", isDirectory: false), .image)
    }

    /// A directory named `assets.zip` is still a directory. The kind
    /// answers what the row IS, and being enterable settles it.
    func testADirectoryIsAFolderWhateverItIsNamed() {
        XCTAssertEqual(FileKind.of(name: "assets.zip", isDirectory: true), .folder)
        XCTAssertEqual(FileKind.of(name: "src", isDirectory: true), .folder)
    }

    /// A suffix neither the table nor the system knows is not a gap to
    /// fill later. `.file` is the answer.
    func testAnUnknownSuffixIsAFile() {
        XCTAssertEqual(FileKind.of(name: "core.7913", isDirectory: false), .file)
        XCTAssertEqual(FileKind.of(name: "notes.qqzzxx", isDirectory: false), .file)
    }

    // MARK: - The table answers first, the system answers the tail

    /// THE ANSWERS THIS FILE FIXES DO NOT MOVE. Every one of these is in
    /// the table, and `UTType` would answer differently or not at all for
    /// several: `.zig`, `.go` and `.rs` are unregistered on a stock
    /// machine, and `.md`'s identifier is whatever an installed editor
    /// claimed. Typing a REMOTE listing by the system alone would draw one
    /// directory two ways for two people.
    func testTheTableIsNotOverriddenByWhateverThisMachineHasInstalled() {
        // WHERE THE TWO GENUINELY DISAGREE, and so the only names that can
        // catch the two being consulted in the wrong order: this machine
        // types `.pdf` as composite content rather than an image, and
        // `.cfg` and `.ini` as prose rather than configuration.
        XCTAssertEqual(FileKind.of(name: "manual.pdf", isDirectory: false), .document)
        XCTAssertEqual(FileKind.of(name: "app.cfg", isDirectory: false), .data)
        XCTAssertEqual(FileKind.of(name: "app.ini", isDirectory: false), .data)

        XCTAssertEqual(FileKind.of(name: "main.zig", isDirectory: false), .code)
        XCTAssertEqual(FileKind.of(name: "main.go", isDirectory: false), .code)
        XCTAssertEqual(FileKind.of(name: "main.rs", isDirectory: false), .code)
        XCTAssertEqual(FileKind.of(name: "README.md", isDirectory: false), .text)
        XCTAssertEqual(FileKind.of(name: "hosts.json", isDirectory: false), .data)
    }

    /// AND THE SYSTEM FILLS IN WHAT THE TABLE NEVER WILL. None of these is
    /// in the table; copying the system's type database by hand is exactly
    /// the second owner this design avoids.
    func testTheSystemTypesTheTail() {
        XCTAssertEqual(FileKind.of(name: "portrait.psd", isDirectory: false), .image)
        XCTAssertEqual(FileKind.of(name: "take.aiff", isDirectory: false), .media)
        XCTAssertEqual(FileKind.of(name: "installer.iso", isDirectory: false), .archive)
        XCTAssertEqual(FileKind.of(name: "budget.xlsx", isDirectory: false), .data)
        XCTAssertEqual(FileKind.of(name: "letter.rtf", isDirectory: false), .text)
    }

    /// A `dyn.…` identifier is `UTType` saying it has no idea, and it
    /// conforms to `.data` like everything else. Reading it as an answer
    /// would file every unknown suffix under whichever check came last.
    func testAnUnregisteredSuffixIsNotAnAnswer() {
        XCTAssertEqual(FileKind.of(name: "a.qqzzxx", isDirectory: false), .file)
    }

    /// A dotfile needs no special case: `zshrc` is in no category, so the
    /// ordinary route already answers `.file`.
    func testADotfileWithNoKnownSuffixIsAFile() {
        XCTAssertEqual(FileKind.of(name: ".zshrc", isDirectory: false), .file)
        XCTAssertEqual(FileKind.of(name: ".gitignore", isDirectory: false), .file)
    }

    /// And where the whole dotfile IS a known suffix, the match is the
    /// right answer rather than an accident to be guarded against.
    func testADotfileThatIsItselfASuffixIsTypedByIt() {
        XCTAssertEqual(FileKind.of(name: ".env", isDirectory: false), .data)
    }

    /// The suffix is the LAST one; the ones before it are part of the name.
    func testTheLastSuffixWins() {
        XCTAssertEqual(FileKind.of(name: "archive.tar.gz", isDirectory: false), .archive)
        XCTAssertEqual(FileKind.of(name: "notes.md.bak", isDirectory: false), .file)
    }

    /// A dotfile that DOES carry a suffix is typed by that suffix.
    func testADotfileWithASuffixIsStillTyped() {
        XCTAssertEqual(FileKind.of(name: ".config.yaml", isDirectory: false), .data)
    }

    /// Only the folder is entered, so only the folder is drawn as somewhere
    /// to go.
    func testOnlyAFolderIsNavigable() {
        XCTAssertTrue(FileKind.folder.isNavigable)
        for kind in [FileKind.code, .text, .data, .archive, .image, .media, .file] {
            XCTAssertFalse(kind.isNavigable, "\(kind) is not somewhere to go")
        }
    }

    // MARK: - A link is typed by what it points at

    /// The listing already resolves a link to a folder into a row that can
    /// be entered ([[WI-2026-08-29-002]]); the icon follows that answer
    /// rather than inventing a second one.
    func testALinkToAFolderIsDrawnAsAFolder() {
        let link = BrowsedFile(name: "current", size: nil, modified: nil,
                               isDirectory: true, isSymlink: true)
        XCTAssertEqual(link.kind, .folder)
    }

    func testALinkToAFileIsDrawnAsThatFile() {
        let link = BrowsedFile(name: "log.txt", size: nil, modified: nil,
                               isDirectory: false, isSymlink: true)
        XCTAssertEqual(link.kind, .text)
    }

    /// A row with nothing on the end of it has no target to be typed by,
    /// and the icon must not claim otherwise.
    func testABrokenLinkIsNotSilentlyAPlainFile() {
        let broken = BrowsedFile(name: "gone.txt", size: nil, modified: nil,
                                 isDirectory: false, isSymlink: true, isBrokenLink: true)
        XCTAssertTrue(broken.isBrokenLink)
        XCTAssertTrue(broken.isSymlink, "a broken link is still a link")
    }

    /// The default keeps every existing construction site honest: a row
    /// nobody said anything about is not a link.
    func testARowIsNotALinkUnlessSaidToBe() {
        let plain = BrowsedFile(name: "notes.md", size: 1, modified: nil, isDirectory: false)
        XCTAssertFalse(plain.isSymlink)
        XCTAssertFalse(plain.isBrokenLink)
    }

    // MARK: - The mark, not just the category

    /// THE POINT OF THE WHOLE TABLE. A source tree is most of what this
    /// pane ever shows, and one category glyph for every language drew it
    /// as forty copies of one mark ([[WI-2026-08-29-007]]).
    func testEachLanguageHasItsOwnMark() {
        let marks = ["main.zig", "main.swift", "main.rs", "main.go", "main.py",
                     "main.c", "build.sh", "app.rb", "App.java", "app.ts"]
            .map { FileKind.type(of: $0, isDirectory: false).glyph }
        XCTAssertEqual(Set(marks).count, marks.count, "two languages share a mark")
    }

    /// A name with no suffix at all is unreachable from the extension
    /// table, and these are among the first a human scans a repository for.
    func testWholeNamesAreRecognised() {
        XCTAssertEqual(FileKind.type(of: "Dockerfile", isDirectory: false).glyph, Glyph.docker)
        XCTAssertEqual(FileKind.type(of: "Makefile", isDirectory: false).glyph, Glyph.makefile)
        XCTAssertEqual(FileKind.type(of: "LICENSE", isDirectory: false).glyph, Glyph.license)
    }

    /// A directory named `Dockerfile` is a directory. Being enterable
    /// outranks every name and every suffix.
    func testAWholeNameDoesNotOutrankBeingADirectory() {
        XCTAssertEqual(FileKind.type(of: "Dockerfile", isDirectory: true).glyph, Glyph.folder)
    }

    /// The tail the system typed has no mark of its own, so it wears its
    /// category's — which is what the category is for.
    func testTheSystemTypedTailWearsItsCategorysMark() {
        XCTAssertEqual(FileKind.type(of: "portrait.psd", isDirectory: false).glyph,
                       FileKind.image.glyph)
        XCTAssertEqual(FileKind.type(of: "core.7913", isDirectory: false).glyph,
                       FileKind.file.glyph)
    }

    /// EVERY MARK IS IN THE FONT THE BUNDLE SHIPS.
    ///
    /// A code point in this table is a number nobody can proofread, and a
    /// wrong one does not fail to build — it draws an empty box, or the
    /// wrong picture, in a pane a test never looks at. Asking the face
    /// itself is the only check that catches a typo, a font bump that
    /// moved a glyph, and a bundle that failed to register the font at all.
    func testEveryMarkExistsInTheBundledFont() {
        let font = CTFontCreateWithName(Glyph.fontFamily as CFString, 13, nil)
        XCTAssertEqual(CTFontCopyFamilyName(font) as String, Glyph.fontFamily,
                       "the bundled font is not registered; every row would draw a fallback")

        var marks = Set(FileKind.byExtension.values.map(\.glyph))
        marks.formUnion(FileKind.byName.values.map(\.glyph))
        marks.formUnion([FileKind.folder, .code, .text, .data, .archive,
                         .image, .media, .document, .file].map(\.glyph))
        marks.insert(Glyph.unknown)

        for mark in marks.sorted(by: { $0 < $1 }) {
            let units = Array(String(mark).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let found = CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
            XCTAssertTrue(found && glyphs.allSatisfy { $0 != 0 },
                          "U+\(String(format: "%04X", mark.unicodeScalars.first!.value)) is not in the font")
        }
    }
}
