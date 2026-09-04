import XCTest
@testable import Synapty

/// WHETHER A HOST IS RUNNING THE BINARY THIS BUILD DEPLOYS.
///
/// `setup-host.sh` compares and uploads, and its own header promises the
/// check "ALWAYS runs — even when a ControlMaster is already active". The
/// caller does not: [[TunnelManager]]'s fast path opens a session on an
/// already-connected host without running the script at all, and
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

    // MARK: - Which binary a machine takes

    /// THE SAME FIVE `setup-host.sh` MAPS. A sixth spelled only here
    /// would send one of them a binary for another architecture.
    func testEveryPlatformTheDeployPathBuildsForIsMapped() {
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Linux aarch64"), "linux-aarch64")
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Linux x86_64"), "linux-x86_64")
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Linux riscv64"), "linux-riscv64")
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Darwin arm64"), "macos-aarch64")
        XCTAssertEqual(HostBinary.deployTarget(unameSM: "Darwin x86_64"), "macos-x86_64")
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
