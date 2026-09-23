import XCTest
@testable import Synapty

/// WHETHER A HOST IS RUNNING THE BINARY THIS BUILD DEPLOYS.
///
/// `synapty host-setup` compares and uploads, and it does so on every run
/// — a master that is already up is reused for the comparison, not taken
/// as evidence that it is unnecessary. The caller does not run it every
/// time: [[TunnelManager]]'s fast path opens a session on an
/// already-connected host without invoking host-setup at all, and
/// ControlPersist=yes keeps that master alive indefinitely. So a host
/// stays on whatever binary it had when it was first dialled, and nothing
/// says so.
final class HostBinaryTests: XCTestCase {

    // MARK: - What the answer means

    func testMatchingBuildsAreCurrent() {
        XCTAssertEqual(HostBinary.verdict(remote: "6efe08d31e4c", local: "6efe08d31e4c"),
                       .current)
    }

    func testADifferentBuildIsStale() {
        XCTAssertEqual(HostBinary.verdict(remote: "aaaa1111bbbb", local: "6efe08d31e4c"),
                       .stale)
    }

    /// A HOST THAT DID NOT ANSWER HAS NOT SAID IT IS STALE. Marking it
    /// would tell a human to fix something that may be perfectly current,
    /// and offering to upload over a link that just failed is worse.
    func testNoAnswerIsUnknownRatherThanStale() {
        XCTAssertEqual(HostBinary.verdict(remote: nil, local: "6efe08d31e4c"), .unknown)
        XCTAssertEqual(HostBinary.verdict(remote: "", local: "6efe08d31e4c"), .unknown)
    }

    /// NEITHER IS A BUILD THIS APP CAN COMPARE AGAINST. `expectedBuild`
    /// answers "unknown" when it cannot resolve its own binary, and
    /// comparing against that string would call every host stale.
    func testAnUnknownLocalBuildComparesToNothing() {
        XCTAssertEqual(HostBinary.verdict(remote: "aaaa1111bbbb", local: "unknown"), .unknown)
        XCTAssertEqual(HostBinary.verdict(remote: "aaaa1111bbbb", local: ""), .unknown)
    }

    func testWhitespaceAroundTheAnswerIsNotADifference() {
        XCTAssertEqual(HostBinary.verdict(remote: " 6efe08d31e4c\n", local: "6efe08d31e4c"),
                       .current)
    }

    // MARK: - Which hosts are asked

    /// NOT EAGER. Asking a host that is not connected means dialling it —
    /// an ssh, an authentication, and a wait, for a machine the human is
    /// not using. The question is only cheap where the master is already
    /// up, which is exactly where it is also worth asking.
    func testOnlyConnectedHostsAreAsked() {
        XCTAssertTrue(HostBinary.worthAsking(connected: true, alreadyAsking: false))
        XCTAssertFalse(HostBinary.worthAsking(connected: false, alreadyAsking: false))
    }

    func testAHostAlreadyBeingAskedIsNotAskedAgain() {
        XCTAssertFalse(HostBinary.worthAsking(connected: true, alreadyAsking: true))
    }

    /// THE WRITER AND THE READERS NAME ONE PATH.
    ///
    /// `HostBinary` installs the binary — `mkdir -p`, the scp
    /// destination, `chmod +x` — and four other files run commands at it.
    /// The path was written out eight times with no owner, and every
    /// reader fails quietly by construction if it moves: `nameSession`
    /// discards its completion, and `sessions`/`end`/`version` parse
    /// stdout, so an absent binary reads as "no sessions"
    /// ([[WI-2026-09-11-010]]).
    func testTheRemotePathIsRelativeToTheLoginDirectory() {
        // Relative, because every remote command this workbench sends runs
        // from the login directory and an absolute path would have to know
        // the remote home.
        XCTAssertFalse(HostBinary.remotePath.hasPrefix("/"),
                       "an absolute remote path would have to know the far side's home")
        XCTAssertTrue(HostBinary.remotePath.hasPrefix(HostBinary.remoteDir + "/"),
                      "the directory the installer creates must be the one the binary lands in")
    }

    // MARK: - Which binary a machine takes

    /// THE SAME FIVE `synapty host-setup` MAPS. A sixth spelled only here
    /// would send one of them a binary for another architecture.
    func testEveryPlatformTheDeployPathBuildsForIsMapped() {
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Linux aarch64"), "linux-aarch64")
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Linux x86_64"), "linux-x86_64")
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Linux riscv64"), "linux-riscv64")
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Darwin arm64"), "macos-aarch64")
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Darwin x86_64"), "macos-x86_64")
    }

    /// AND EVERY TARGET THE BUILD ACTUALLY PRODUCED, whatever this file
    /// happens to name.
    ///
    /// THE ABOVE CANNOT NOTICE A SIXTH. It asserts a fixed five, as did
    /// its counterpart in `host.zig`, so a target added to
    /// `src/deploy_targets.zig` and missed here left both suites green
    /// while `synapty host-setup` deployed to that machine from the
    /// terminal and the workbench offered it nothing —
    /// `WorkspaceManager` takes the nil branch, `ok` stays false, and
    /// nothing anywhere says why ([[WI-2026-09-11-003]]).
    ///
    /// ASKED OF THE ARTIFACT, because that is what the two sides share.
    /// The build writes the names it produced; a name this map does not
    /// know is a machine the workbench will silently skip.
    func testEveryTargetTheBuildProducedIsMapped() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = repo.appendingPathComponent("zig-out/deploy-targets.txt")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
            throw XCTSkip("no zig-out/deploy-targets.txt — run `just deploy-all`")
        }
        // `<directory>\t<uname -sm>`, so this test keeps neither list.
        let produced: [(dir: String, uname: String)] = text
            .split(separator: "\n")
            .compactMap { line in
                let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
                return f.count == 2 ? (dir: f[0], uname: f[1]) : nil
            }
        XCTAssertFalse(produced.isEmpty, "the build named no deploy targets")

        for t in produced {
            XCTAssertEqual(HostBinary.deployTarget(unameSM: t.uname), t.dir,
                           "the build produced \(t.dir) for a machine reporting "
                               + "\(t.uname), and this map does not send it there")
        }
    }

    /// AN UNSUPPORTED MACHINE IS OFFERED NOTHING, which is honest: there
    /// is no binary for it in the bundle either.
    func testAnUnsupportedPlatformMapsToNothing() {
        XCTAssertNil(HostBinary.deployTarget(unameSM: "SunOS sun4v"))
        XCTAssertNil(HostBinary.deployTarget(unameSM: ""))
    }

    func testTheAnswerIsTrimmedBeforeItIsMatched() {
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Linux x86_64\n"), "linux-x86_64")
    }

    // MARK: - Parsing

    func testTheVersionIsReadFromTheOutput() {
        XCTAssertEqual(HostBinary.parse(stdout: "6efe08d31e4c\n", exitCode: 0), "6efe08d31e4c")
    }

    func testAFailedCallReadsAsNoAnswer() {
        XCTAssertNil(HostBinary.parse(stdout: "", exitCode: 127))
        XCTAssertNil(HostBinary.parse(stdout: "", exitCode: nil))
    }

    /// A HOST WITH NO BINARY AT ALL answers nothing on stdout and fails,
    /// which is the same "cannot say" as an unreachable one — and both
    /// are fixed by the same act.
    func testAMissingBinaryReadsAsNoAnswer() {
        XCTAssertNil(HostBinary.parse(
            stdout: "", exitCode: 127))
    }
}

/// THE VERDICT IS ORDERED BY WHEN IT WAS ASKED, not by when it arrived
/// ([[WI-2026-09-23-006]]). The minute's poll and the human's Update both
/// ask over ssh and both wrote the answer on return, so a poll that left
/// before an update could land after it.
@MainActor
final class HostBinaryVerdictOrderTests: XCTestCase {

    private let host = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000)

    /// THE DEFECT: `stale` put back over `current` right after the human
    /// brought the host up to date — offering the Update button, and
    /// another scp, for the minute until the next poll.
    func testAPollThatLeftBeforeAnUpdateCannotUndoIt() {
        let manager = WorkspaceManager()
        let pollLeft = t0
        let updateAsked = t0.addingTimeInterval(5)

        manager.noteHostBinary(.current, for: host, asOf: updateAsked)
        manager.noteHostBinary(.stale, for: host, asOf: pollLeft)

        XCTAssertEqual(manager.hostBinary[host], .current,
                       "a verdict asked for before the update overwrote the one asked after it")
    }

    /// A LATER QUESTION STILL WINS. The rule is ordering, not stickiness:
    /// a host that really did go back to an old binary must be seen to.
    func testAnAnswerToALaterQuestionReplacesAnEarlierOne() {
        let manager = WorkspaceManager()

        manager.noteHostBinary(.current, for: host, asOf: t0)
        manager.noteHostBinary(.stale, for: host, asOf: t0.addingTimeInterval(60))

        XCTAssertEqual(manager.hostBinary[host], .stale)
    }

    /// AND ONE HOST'S ORDER IS ITS OWN.
    func testAnotherHostsLaterAnswerDoesNotShadowThisOne() {
        let manager = WorkspaceManager()
        let other = UUID()

        manager.noteHostBinary(.current, for: other, asOf: t0.addingTimeInterval(60))
        manager.noteHostBinary(.stale, for: host, asOf: t0)

        XCTAssertEqual(manager.hostBinary[host], .stale)
        XCTAssertEqual(manager.hostBinary[other], .current)
    }
}
