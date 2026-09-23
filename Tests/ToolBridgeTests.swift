import XCTest
@testable import Synapty

/// WI-2026-08-12-005: [[ADR-0008]] decision 6 — the hub routes, the
/// workbench executes. These cover the workbench half's parsing, which is
/// where a wrong answer would be relayed back to an agent as if it were
/// GitHub's.
final class ToolBridgeTests: XCTestCase {

    // MARK: - Request parsing

    func testRequestRequiresToolAndRequestID() {
        // A frame missing either is unanswerable: without request_id the
        // hub cannot route the reply, so there is no agent to tell.
        XCTAssertNil(ToolBridge.Request(["request_id": "r1"]))
        XCTAssertNil(ToolBridge.Request(["tool": "task.list"]))
        XCTAssertNotNil(ToolBridge.Request(["tool": "task.list", "request_id": "r1"]))
    }

    func testRequestSerializesArgsAndDefaultsToEmptyObject() {
        let req = ToolBridge.Request([
            "tool": "task.claim",
            "request_id": "r1",
            "requester": "claude-abc12345",
            "args": ["number": 7],
        ])
        XCTAssertEqual(req?.tool, "task.claim")
        XCTAssertEqual(req?.requester, "claude-abc12345")
        XCTAssertEqual(req?.argsJSON, "{\"number\":7}")

        let noArgs = ToolBridge.Request(["tool": "task.list", "request_id": "r2"])
        XCTAssertEqual(noArgs?.argsJSON, "{}")
        // An absent requester must not make the request undeliverable —
        // the hub knows who asked; this side only echoes it back.
        XCTAssertEqual(noArgs?.requester, "")
    }

    // MARK: - Executor output

    func testToolFailureIsRelayedWithItsReason() {
        // `tools exec` exits 0 EVEN WHEN THE TOOL FAILS, because the reason
        // has to survive back to the agent. Reading the exit code instead
        // of the body would turn "github token not found" into a generic
        // failure the agent cannot act on.
        let out = SubprocessRunner.Output(
            stdout: "{\"ok\":false,\"error\":\"github token not found: run `synapty github login`\"}",
            stderr: "", timedOut: false, error: nil)
        let result = ToolBridge.parseResult(out)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "github token not found: run `synapty github login`")
    }

    func testSuccessCarriesTheDataThrough() {
        let out = SubprocessRunner.Output(
            stdout: "{\"ok\":true,\"data\":[{\"number\":7,\"title\":\"fix it\"}]}",
            stderr: "", timedOut: false, error: nil)
        let result = ToolBridge.parseResult(out)
        XCTAssertTrue(result.ok)
        let rows = result.data as? [[String: Any]]
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?["title"] as? String, "fix it")
        XCTAssertNil(result.error)
    }

    func testProcessFailureIsDistinctFromToolFailure() {
        // No parseable body means the PROCESS failed, not the tool — a
        // different report, and one that must never read as `ok`.
        let crashed = ToolBridge.parseResult(
            SubprocessRunner.Output(stdout: "", stderr: "Segmentation fault", timedOut: false, error: nil))
        XCTAssertFalse(crashed.ok)
        XCTAssertTrue(crashed.error?.contains("Segmentation fault") == true)

        let timedOut = ToolBridge.parseResult(
            SubprocessRunner.Output(stdout: "", stderr: "", timedOut: true, error: nil))
        XCTAssertFalse(timedOut.ok)
        XCTAssertTrue(timedOut.error?.contains("timed out") == true)

        let launchFailed = ToolBridge.parseResult(
            SubprocessRunner.Output(stdout: "", stderr: "", timedOut: false, error: "No such file"))
        XCTAssertFalse(launchFailed.ok)
        XCTAssertTrue(launchFailed.error?.contains("No such file") == true)

        // Garbage on stdout is the same class of failure — never silently
        // reported as an empty success.
        let garbage = ToolBridge.parseResult(
            SubprocessRunner.Output(stdout: "not json at all", stderr: "", timedOut: false, error: nil))
        XCTAssertFalse(garbage.ok)
    }
}

/// THE INNERMOST RUNG OF THE DEADLINE LADDER, HELD IN TWO LANGUAGES
/// ([[WI-2026-08-30-010]]).
///
/// A caller must outlast what it waits on at every hop, or it gives up
/// while the work is still running and the answer lands on nobody. Three
/// processes hold a rung; each stated its own number with prose explaining
/// how it related to the others, and prose is not a relation. The Zig half
/// derives the outer two from this one; Swift cannot import it, so this is
/// what keeps the two equal.
@MainActor
final class ToolLadderTests: XCTestCase {

    /// THE RUNG THAT CROSSES, ASKED OF THE BUILD.
    ///
    /// This asserted the literal 60, which pins this side to itself. Drop
    /// `tool_exec_budget_ms` and `tool_park_slack_ms` together and the Zig
    /// test still passes — its three rungs are still ordered — and this
    /// one still passes, because 60 is still 60. Meanwhile the hub
    /// un-parks the requester and reports expiry with the workbench's
    /// subprocess still running: the agent is told "expired", the issue
    /// gets claimed anyway, and nobody attributed it. That is the failure
    /// the ladder exists to prevent, one rung out from where it was
    /// checked ([[WI-2026-09-11-015]]).
    func testTheBudgetAgreesWithTheLadder() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = repo.appendingPathComponent("zig-out/tool-ladder.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw XCTSkip("no zig-out/tool-ladder.txt — run `zig build`")
        }
        var ladder: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "=", maxSplits: 1)
            if f.count == 2, let v = Double(f[1]) { ladder[String(f[0])] = v }
        }
        let budget = try XCTUnwrap(ladder["tool_exec_budget_ms"])
        let park = try XCTUnwrap(ladder["tool_park_ms"])

        XCTAssertEqual(ToolBridge.execBudgetSeconds * 1000, budget,
                       "the workbench's tool budget no longer matches protocol.tool_exec_budget_ms")
        // AND THE RELATION, which is what the numbers are for: the hub
        // must outlast the workbench, or it reports expiry on work that is
        // still running.
        XCTAssertLessThan(ToolBridge.execBudgetSeconds * 1000, park,
                          "the hub un-parks the requester before the workbench gives up")
    }
}
