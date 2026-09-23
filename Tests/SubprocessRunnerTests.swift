import XCTest
@testable import Synapty

/// [[WI-2026-09-07-001]]. What comes back from a subprocess is bytes off
/// somebody else's machine, and it only has to be nearly text.
final class SubprocessRunnerTests: XCTestCase {

    /// ONE BAD BYTE USED TO COST THE WHOLE OUTPUT.
    ///
    /// `String(data:encoding:.utf8)` is all-or-nothing: it returns nil for a
    /// single malformed byte anywhere in the stream, and the `?? ""` behind
    /// it turned a command that answered in full into one that appeared to
    /// say nothing at all. `PortDiscovery` made that reachable by asking a
    /// host for its command lines, where a path in some other encoding is
    /// enough to do it.
    func testOneMalformedByteDoesNotDiscardTheOutput() throws {
        let out = SubprocessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", #"printf 'before\n\377\nafter\n'"#],
            timeout: 10)
        XCTAssertNil(out.error)
        XCTAssertTrue(out.stdout.contains("before"), "got: \(out.stdout.debugDescription)")
        XCTAssertTrue(out.stdout.contains("after"),
                      "the lines around the bad byte are the ones worth keeping")
    }

    /// The ordinary case is unchanged: valid UTF-8 comes back exactly.
    func testValidTextIsUnchanged() {
        let out = SubprocessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "printf '端口 3000\\n'"], timeout: 10)
        XCTAssertEqual(out.stdout, "端口 3000\n")
        XCTAssertEqual(out.exitCode, 0)
    }

    /// HOW ssh ACTUALLY FAILS, measured rather than assumed — because the
    /// two tests below are only meaningful if `error` and `timedOut` really
    /// do stay clear when a connection is refused.
    func testAFailedSshSetsNeitherLaunchErrorNorTimeout() {
        // Port 1 on the loopback: nothing listens, and the refusal is
        // immediate, so this needs no network and cannot hang.
        let out = SubprocessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                        "-p", "1", "nobody@127.0.0.1", "true"],
            timeout: 20)
        XCTAssertNil(out.error, "ssh launched fine — `error` is a LAUNCH failure")
        XCTAssertFalse(out.timedOut, "it exited on its own, well inside the budget")
        XCTAssertNotEqual(out.exitCode, 0, "and the status is the only field that says so")
    }

    /// TEST CONNECTION SHOWED A GREEN TICK FOR EVERY FAILURE IT EXISTS TO
    /// DETECT.
    ///
    /// It asked `output.error == nil && !output.timedOut` — the launch
    /// check [[WI-2026-09-10-001]] corrected in `setupSucceeded` and did
    /// not reach here. `/usr/bin/ssh` launches perfectly well and exits
    /// 255 for all four refusals below, setting neither field.
    ///
    /// The case that matters most is the one this card is built around: a
    /// host synced from another Mac whose key did not travel. The human
    /// presses Test Connection to check whether the key warning beside it
    /// is stale, gets a tick, and concludes it is.
    func testAConnectionThatFailedIsNotReportedAsOK() {
        // The four measured shapes, all exit 255 with an empty stdout.
        let refusals = [
            "nobody@127.0.0.1: Permission denied (publickey).",
            "Host key verification failed.",
            "ssh: Could not resolve hostname nosuchhost: nodename nor servname provided",
            "ssh: connect to host 127.0.0.1 port 22: Connection refused",
        ]
        for said in refusals {
            let outcome = HostBlockView.testOutcome(SubprocessRunner.Output(
                stdout: "", stderr: said + "\n",
                timedOut: false, error: nil, exitCode: 255))
            guard case .failed(let why) = outcome else {
                return XCTFail("`\(said)` was reported as a working connection")
            }
            // AND IT CARRIES THE REASON. A red cross reading "Connection
            // failed" is a failure a human cannot act on ([[RFC-0015]]
            // C-FAILURE); the sentence was sitting in stderr, read by
            // nothing.
            XCTAssertEqual(why, said)
        }

        // A probe that reached the far side and answered still succeeds,
        // so the fix is not "refuse everything".
        guard case .ok(let out) = HostBlockView.testOutcome(SubprocessRunner.Output(
            stdout: "Linux\n", stderr: "", timedOut: false, error: nil, exitCode: 0))
        else { return XCTFail("a probe that answered was reported as a failure") }
        XCTAssertEqual(OSProbe.parse(out), OSProbe.parse("Linux\n"))

        // A host that never answered, and a binary that would not launch.
        guard case .failed = HostBlockView.testOutcome(SubprocessRunner.Output(
            stdout: "", stderr: "", timedOut: true, error: nil, exitCode: nil))
        else { return XCTFail("a probe killed at the timeout was reported as OK") }
        guard case .failed = HostBlockView.testOutcome(SubprocessRunner.Output(
            stdout: "", stderr: "", timedOut: false, error: "no such file", exitCode: nil))
        else { return XCTFail("a probe that never ran was reported as OK") }
    }

    /// A GITHUB LOGIN THAT FAILED CLOSED THE SHEET AND WIPED THE TOKEN.
    ///
    /// The sheet asked STDOUT for "error:", and `synapty github login`
    /// writes every refusal to STDERR before exiting 1 — so on a bad or
    /// under-scoped PAT it took the SUCCESS branch: sheet dismissed,
    /// `onConnected()` fired, and nothing written to the Keychain or the
    /// config, because the CLI exits before either. The token was cleared
    /// on the way out, so retrying meant minting a new one on GitHub.
    func testAGithubLoginThatFailedIsNotReportedAsConnected() {
        // Exactly what `runGithubLogin` produces for its four refusals:
        // the sentence on stderr, an empty stdout, exit 1.
        for said in ["error: owner required", "error: repo required",
                     "error: token required",
                     "error: token verification failed — check the token scope and repo name"] {
            XCTAssertFalse(
                GithubConnectSheet.loginSucceeded(SubprocessRunner.Output(
                    stdout: "", stderr: said + "\n",
                    timedOut: false, error: nil, exitCode: 1)),
                "`\(said)` dismissed the sheet and discarded the token")
        }

        // The success the CLI actually prints, on stdout, exit 0.
        XCTAssertTrue(GithubConnectSheet.loginSucceeded(SubprocessRunner.Output(
            stdout: "Saved. Hub repo: someone/hub\n", stderr: "",
            timedOut: false, error: nil, exitCode: 0)))
    }
}
