import XCTest
@testable import Synapty

/// [[RFC-0015]] C-PANE-WRITES, as rules rather than as dialogs — each of
/// these is a sentence in the clause that a view could quietly fail to
/// honour, and none of those failures look like anything on screen.
final class PaneWritesTests: XCTestCase {

    // MARK: - Where a deletion goes

    /// THE LOCAL PATH IS RECOVERABLE AND IS NOT CONFIRMED. Not an
    /// oversight to tighten later: a confirmation on a reversible act is
    /// what teaches a human to dismiss the one that matters.
    func testALocalDeletionGoesToTheTrashAndIsNotConfirmed() {
        let disposal = PaneWrites.disposal(isLocal: true)
        XCTAssertEqual(disposal, .trash)
        XCTAssertFalse(PaneWrites.confirms(disposal))
    }

    /// EVERY OTHER CONNECTION IS CONFIRMED — and the implementation may
    /// not exempt one because the far machine has a trash of its own.
    func testARemoteDeletionIsUnrecoverableAndIsConfirmed() {
        let disposal = PaneWrites.disposal(isLocal: false)
        XCTAssertEqual(disposal, .unrecoverable)
        XCTAssertTrue(PaneWrites.confirms(disposal))
    }

    /// A LINUX DESKTOP HAS A TRASH AND IT CHANGES NOTHING. The rule turns
    /// on whether THIS application can restore, and it cannot — a rule
    /// that turned on the far machine's trash would skip the confirmation
    /// on exactly the machines that need it.
    func testARemoteTrashDoesNotEarnAnExemption() {
        XCTAssertEqual(PaneWrites.disposal(isLocal: false), .unrecoverable)
    }


    // MARK: - What the question says

    /// THE MACHINE IS NAMED IN THE SENTENCE. "Delete 3 items?" tells a
    /// human with three file panes open nothing at all.
    func testTheDeletionQuestionNamesTheMachine() {
        let question = PaneWrites.deletionQuestion(count: 3, machine: "remotehost")
        XCTAssertTrue(question.contains("remotehost"), question)
        XCTAssertTrue(question.contains("3"), question)
    }

    func testTheDeletionQuestionIsSingularForOneItem() {
        let question = PaneWrites.deletionQuestion(count: 1, machine: "remotehost")
        XCTAssertFalse(question.contains("1 items"), question)
    }

    /// THE ABSENCE OF A RECOVERABLE COPY IS STATED, not implied by the
    /// presence of a dialog.
    func testTheDetailSaysWhatCannotBeUndone() {
        let detail = PaneWrites.deletionDetail(machine: "remotehost")
        XCTAssertTrue(detail.lowercased().contains("cannot be undone"), detail)
        XCTAssertTrue(detail.contains("remotehost"), detail)
    }

    // MARK: - Replacement

    /// A COLLISION IS NOT RESOLVED SILENTLY, and what the human is told
    /// differs by where the replaced bytes go.
    func testAReplacementSaysWhereTheOldBytesGo() {
        let local = PaneWrites.replacementDetail(disposal: .trash, machine: "this Mac")
        XCTAssertTrue(local.contains("Trash"), local)

        let remote = PaneWrites.replacementDetail(disposal: .unrecoverable, machine: "remotehost")
        XCTAssertTrue(remote.lowercased().contains("cannot be undone"), remote)
        XCTAssertFalse(remote.contains("Trash"),
                       "there is no Trash on the far side to promise")
    }

    func testTheReplacementQuestionNamesBothTheFileAndTheMachine() {
        let question = PaneWrites.replacementQuestion(name: "notes.md", machine: "remotehost")
        XCTAssertTrue(question.contains("notes.md"), question)
        XCTAssertTrue(question.contains("remotehost"), question)
    }

    /// THE SAFE OUTCOME IS THE DEFAULT. A dialog whose default button
    /// destroys something destroys things whenever a human presses Return
    /// out of habit.
    func testTheSafeAnswerIsNotTheDestructiveOne() {
        XCTAssertNotEqual(PaneWrites.safeAnswer, PaneWrites.destructiveAnswer)
        XCTAssertNotEqual(PaneWrites.safeAnswer, PaneWrites.deleteAnswer)
    }
}

/// The write verbs are protocol packets, not shell commands — which is
/// what makes a hostile file name an ordinary string.
final class RemoteWriteEncodingTests: XCTestCase {

    /// A REAL NAME FROM A REAL HOST. `%s\n"` was found in a home directory
    /// on one of these machines; a name like it, or `; rm -rf ~`, must
    /// travel as bytes with a length in front of them.
    func testAHostileNameIsALengthPrefixedStringAndNotACommand() {
        let name = #"%s\n"; rm -rf ~"#
        let packet = SFTPWire.request(.remove, id: 7, string: "/home/operator/" + name)

        // Length-prefixed: the name's bytes appear verbatim, and nothing in
        // the packet could be read as a word by a shell, because no shell
        // ever sees it.
        let payload = String(decoding: packet, as: UTF8.self)
        XCTAssertTrue(payload.contains(name), "the name is carried verbatim")
        XCTAssertEqual(packet[4], SFTPWire.PacketType.remove.rawValue,
                       "and it is a REMOVE packet rather than a command line")
    }

    /// A DIRECTORY AND A FILE ARE DIFFERENT PACKETS: REMOVE on a directory
    /// fails everywhere, and the failure reads as a permission problem
    /// rather than as the wrong verb.
    func testDirectoriesAndFilesUseDifferentVerbs() {
        let file = SFTPWire.request(.remove, id: 1, string: "/tmp/a")
        let dir = SFTPWire.request(.rmdir, id: 1, string: "/tmp/a")
        XCTAssertNotEqual(file[4], dir[4])
    }

    func testRenameCarriesBothPaths() {
        let packet = SFTPWire.request(.rename, id: 3, from: "/tmp/a", to: "/tmp/b")
        let payload = String(decoding: packet, as: UTF8.self)
        XCTAssertTrue(payload.contains("/tmp/a"))
        XCTAssertTrue(payload.contains("/tmp/b"))
    }

    /// REPLACE DISPOSES OF THE DESTINATION FIRST.
    ///
    /// SFTP v3 makes `rename` an error when newpath exists, so the sheet
    /// asked "Replace it?", was answered yes, described what would happen
    /// to the existing file, and then sent a packet the server had to
    /// refuse — with the file still there ([[WI-2026-08-28-008]]).
    func testReplacingRemotelyDisposesOfTheDestinationBeforeRenaming() {
        XCTAssertEqual(
            RemoteFS.steps(of: .replace(from: "/tmp/a", to: "/tmp/b",
                                        destinationIsDirectory: false)),
            [.delete("/tmp/b", isDirectory: false), .rename(from: "/tmp/a", to: "/tmp/b")])
    }

    /// AND A DIRECTORY IS A DIFFERENT PACKET, as it is for a plain delete.
    func testReplacingADirectoryDisposesOfItAsADirectory() {
        XCTAssertEqual(
            RemoteFS.steps(of: .replace(from: "/tmp/a", to: "/tmp/b",
                                        destinationIsDirectory: true)).first,
            .delete("/tmp/b", isDirectory: true))
    }

    /// A PLAIN RENAME STILL DELETES NOTHING. The disposal is the answer a
    /// human gave, not something every rename does.
    func testAPlainRemoteRenameDisposesOfNothing() {
        XCTAssertEqual(RemoteFS.steps(of: .rename(from: "/tmp/a", to: "/tmp/b")),
                       [.rename(from: "/tmp/a", to: "/tmp/b")])
    }

    /// THE SAME ON THIS MAC, where `moveItem` throws over an existing
    /// destination and the sheet promised the Trash.
    func testReplacingLocallyTrashesTheDestinationBeforeMoving() {
        XCTAssertEqual(
            PaneWrites.renameSteps(from: "/tmp/a", to: "/tmp/b", replacing: true),
            [.trash("/tmp/b"), .move(from: "/tmp/a", to: "/tmp/b")])
        XCTAssertEqual(
            PaneWrites.renameSteps(from: "/tmp/a", to: "/tmp/b", replacing: false),
            [.move(from: "/tmp/a", to: "/tmp/b")])
    }
}

/// A page nobody can reach is a page that does not exist — Activity was
/// rendered and routed before anything offered a way in.
final class PageNavigationTests: XCTestCase {

    /// EVERY PAGE HAS A CHORD, because the table generates them from the
    /// same list the rail is built from ([[RFC-0016]] C-TABLE).
    @MainActor
    func testEveryPageHasACommandInTheKeyTable() {
        for page in AppPage.allCases {
            XCTAssertNotNil(KeyCommandTable.command("page.\(page.rawValue)"),
                            "\(page.rawValue) has no command, so it has no shortcut and no menu item")
        }
    }
}

/// The round trips a navigation costs are what a human feels
/// ([[WI-2026-08-19-002]]). On a host 247ms away, each one is a quarter of
/// a second of waiting.
final class RemoteFSLatencyTests: XCTestCase {

    /// AN ABSOLUTE PATH IS ALREADY THE ANSWER, so asking the host to
    /// canonicalise it is a round trip bought for nothing.
    func testAnAbsolutePathNeedsNoRealpath() {
        XCTAssertTrue(RemoteFS.isCanonical("/home/operator/camp"))
        XCTAssertTrue(RemoteFS.isCanonical("/"))
    }

    /// ANYTHING DOUBTFUL STILL ASKS. A relative path, a `..`, a `~` or a
    /// doubled slash is the host's to resolve — guessing at a filesystem
    /// we cannot see is how a pane ends up somewhere the human did not go.
    func testAnythingResolvableIsLeftToTheHost() {
        XCTAssertFalse(RemoteFS.isCanonical("camp"))
        XCTAssertFalse(RemoteFS.isCanonical("/home/operator/../root"))
        XCTAssertFalse(RemoteFS.isCanonical("/home/./operator"))
        XCTAssertFalse(RemoteFS.isCanonical("/home//operator"))
        XCTAssertFalse(RemoteFS.isCanonical("~/camp"),
                       "a tilde is a shell's idea and SFTP has no shell")
    }

    /// A SYMLINK STILL RESOLVES ELSEWHERE, and this test says so out loud:
    /// the shortcut is a claim about SYNTAX, not about the filesystem. The
    /// canonical path the host returns for a symlinked directory differs,
    /// and the pane takes the host's answer whenever it asks.
    func testTheShortcutIsAboutSyntaxAndNotAboutTheFilesystem() {
        XCTAssertTrue(RemoteFS.isCanonical("/var/link-to-somewhere"),
                      "syntactically canonical — the pane shows what it asked for, "
                      + "which is the accepted cost of not asking")
    }

    /// A pane opened from a path an agent printed can land on a directory
    /// that is not there, and the human must not be left checking the
    /// wrong computer ([[RFC-0015]] C-DERIVED).
    func testAFailedListingNamesTheMachine() {
        XCTAssertEqual(PaneWrites.listingFailureTitle(machine: "remotehost"),
                       "Cannot read this folder on remotehost")
    }

    func testALocalFailureNamesNoMachineBecauseThereIsOnlyOne() {
        XCTAssertEqual(PaneWrites.listingFailureTitle(machine: nil),
                       "Cannot read this folder")
    }
}
