import XCTest
@testable import Synapty

/// WI-2026-08-11-015: RFC-0007 exec — pure ownership/bounds/outcome/
/// validation logic. (Ghostty pane execution is live-verified.)
final class ExecControllerTests: XCTestCase {

    /// Regression for the first-armed-smoke read defect: a freshly
    /// spawned shell prints at the TOP of a tall pane, so the detector's
    /// bottom-anchored window read pure blank space — a command visibly
    /// executed while read returned "" and wait-output matched nothing.
    /// The tail must be taken from CONTENT, not from trailing blanks.
    func testTailLinesIgnoresTrailingBlankRows() {
        // 4 content rows at the top, 75 blank rows below (a ~79-row pane).
        let screen = (["Last login: Tue Aug 11", "→ /tmp echo HOLD-MARKER-4242",
                       "HOLD-MARKER-4242", "→ /tmp"]
                      + Array(repeating: "", count: 75)).joined(separator: "\n")
        let tail = AgentDetector.tailLines(screen, rows: 40)
        XCTAssertTrue(tail.contains("HOLD-MARKER-4242"),
                      "content above the blank tail must survive; got: \(tail)")
        XCTAssertFalse(tail.hasSuffix("\n"))
        // Whitespace-only rows count as blank too (shells pad with spaces).
        let padded = (["MARKER"] + Array(repeating: "    ", count: 50)).joined(separator: "\n")
        XCTAssertEqual(AgentDetector.tailLines(padded, rows: 10), "MARKER")
    }

    func testTailLinesKeepsOnlyTheLastNContentRows() {
        let screen = (1...100).map { "line\($0)" }.joined(separator: "\n")
        let tail = AgentDetector.tailLines(screen, rows: 3)
        XCTAssertEqual(tail, "line98\nline99\nline100")
    }


    // MARK: - C-PRIMITIVES run validation (mirrors protocol.isValidExecCommand)

    func testCommandValidatorMirrorsHubRule() {
        XCTAssertTrue(ExecCommandValidator.isValid("ls -la && echo DONE-42"))
        XCTAssertTrue(ExecCommandValidator.isValid("echo café"))
        XCTAssertFalse(ExecCommandValidator.isValid(""))
        XCTAssertFalse(ExecCommandValidator.isValid("a\nb"))   // LF
        XCTAssertFalse(ExecCommandValidator.isValid("a\rb"))   // CR
        XCTAssertFalse(ExecCommandValidator.isValid("a\tb"))   // TAB
        XCTAssertFalse(ExecCommandValidator.isValid("a\u{1b}b")) // ESC
        XCTAssertFalse(ExecCommandValidator.isValid("a\u{7f}b")) // DEL
    }

    // MARK: - C-EXEC-SCOPE ownership by id + generation

    private func record(_ handle: String, _ owner: String, _ gen: UInt64) -> ExecPaneRecord {
        ExecPaneRecord(handle: handle, ownerAgentID: owner, generation: gen, leafID: UUID())
    }

    func testAccessOwnershipAndGeneration() {
        var reg = ExecPaneRegistry()
        reg.add(record("exec-1", "claude-a", 5))

        // Owner + matching live generation → ok.
        if case .ok(let r) = reg.access(handle: "exec-1", requester: "claude-a", liveGeneration: 5) {
            XCTAssertEqual(r.handle, "exec-1")
        } else { XCTFail("expected ok") }

        // Unknown pane.
        XCTAssertEqual(reg.access(handle: "nope", requester: "claude-a", liveGeneration: 5), .noSuchPane)
        // Another agent's pane.
        XCTAssertEqual(reg.access(handle: "exec-1", requester: "claude-b", liveGeneration: 9), .notOwner)
        // Same owner, generation ended (re-registered under a new gen).
        XCTAssertEqual(reg.access(handle: "exec-1", requester: "claude-a", liveGeneration: 6), .ownershipLost)
        // Owner unregistered entirely (nil live generation).
        XCTAssertEqual(reg.access(handle: "exec-1", requester: "claude-a", liveGeneration: nil), .ownershipLost)
    }

    // MARK: - C-EXEC-AUTHORITY per-owner bounds

    func testPaneBoundsPerOwner() {
        var reg = ExecPaneRegistry()
        XCTAssertTrue(reg.canOpen(owner: "claude-a"))
        for i in 0..<ExecPaneRegistry.maxPanesPerOwner {
            reg.add(record("exec-\(i)", "claude-a", 1))
        }
        // At the bound: no more for this owner…
        XCTAssertFalse(reg.canOpen(owner: "claude-a"))
        // …but a different owner is independent.
        XCTAssertTrue(reg.canOpen(owner: "claude-b"))
        // Closing one frees a slot.
        reg.remove(handle: "exec-0")
        XCTAssertTrue(reg.canOpen(owner: "claude-a"))
    }

    /// AN ORPHANED EXEC PANE IS ONE NOBODY MAY DRIVE AND EVERYBODY CAN
    /// SEE, which is what [[RFC-0007]] C-EXEC-SCOPE asks for: "its
    /// orphaned exec panes remain visible to the human with their
    /// machine-operated marker until closed."
    ///
    /// `handles(owner:)` stood here, documented "for generation-end orphan
    /// marking", with these two assertions and no caller. There is no
    /// marking to do: the marker the clause names is the one the pane
    /// already wears, and the clause requires it to STAY. What generation
    /// end changes is access, and access is checked per request against
    /// the live registration — so the property is asserted where it is
    /// enforced rather than through a query nobody makes.
    func testAnEndedGenerationLosesAccessWhileThePaneStays() {
        var reg = ExecPaneRegistry()
        reg.add(record("e1", "a", 1))
        reg.add(record("e2", "a", 1))
        reg.add(record("e3", "b", 1))

        // The owner's registration ended and a newcomer took the id.
        XCTAssertEqual(reg.access(handle: "e1", requester: "a", liveGeneration: 2),
                       .ownershipLost)
        // And with nothing registered under it at all.
        XCTAssertEqual(reg.access(handle: "e2", requester: "a", liveGeneration: nil),
                       .ownershipLost)
        // ANOTHER OWNER IS UNDISTURBED — a generation is per registration,
        // not per machine.
        guard case .ok = reg.access(handle: "e3", requester: "b", liveGeneration: 1) else {
            return XCTFail("b's pane went with a's generation")
        }
        // THE PANES ARE STILL THERE. Losing access is not closing: the
        // human closes them, and until they do the marker is what says
        // what the pane is.
        guard case .ok = reg.access(handle: "e1", requester: "a", liveGeneration: 1) else {
            return XCTFail("the record went away, so there is nothing left to mark")
        }
    }

    // MARK: - Request parsing

    func testExecRequestParsing() {
        let payload: [String: Any] = [
            "verb": "run", "owner": "claude-a", "requester": "claude-a",
            "request_id": "exec-1", "pane": "exec-x", "command": "make",
            "follow_up": true,
        ]
        let req = ExecRequest(payload)
        XCTAssertEqual(req?.verb, .run)
        XCTAssertEqual(req?.pane, "exec-x")
        XCTAssertEqual(req?.command, "make")
        XCTAssertEqual(req?.followUp, true)
        // Missing owner → nil (unparseable).
        XCTAssertNil(ExecRequest(["verb": "run", "requester": "x"]))
        // Unknown verb → nil.
        XCTAssertNil(ExecRequest(["verb": "nuke", "owner": "a", "requester": "a"]))
    }

    // MARK: - wait-output matching (literal-first, then regex)

    func testWaitMatchLiteralThenRegex() {
        let re = try? NSRegularExpression(pattern: "DONE-[0-9]+")
        XCTAssertTrue(ExecController.matches("...\nBUILD DONE-42\n", pattern: "DONE-42", regex: nil))
        XCTAssertTrue(ExecController.matches("tail DONE-99 here", pattern: "DONE-[0-9]+", regex: re))
        XCTAssertFalse(ExecController.matches("still building", pattern: "DONE-[0-9]+", regex: re))
    }

    // MARK: - Outcome wire strings (hub/CLI exit-code contract)

    func testOutcomeWireStrings() {
        XCTAssertEqual(ExecOutcome.matched.rawValue, "matched")
        XCTAssertEqual(ExecOutcome.timedOut.rawValue, "timed-out")
        XCTAssertEqual(ExecOutcome.targetGone.rawValue, "target-gone")
        XCTAssertEqual(ExecOutcome.ownershipLost.rawValue, "ownership-lost")
        XCTAssertEqual(ExecOutcome.disarmed.rawValue, "disarmed")
        XCTAssertEqual(ExecOutcome.refused.rawValue, "refused")
    }

    // MARK: - C-EXEC-AUTHORITY arming default + disarm cancels waits

    @MainActor
    func testArmDefaultOff() {
        let exec = ExecController()
        XCTAssertFalse(exec.armed)
        exec.setArmed(true)
        XCTAssertTrue(exec.armed)
        exec.setArmed(false)
        XCTAssertFalse(exec.armed)
    }
}

/// WHOEVER ENDS A WAIT OWES THE AGENT A RECEIPT ([[RFC-0007]]
/// C-EXEC-AUTHORITY, [[WI-2026-08-28-003]]).
///
/// These drive the real intake — `handleHubEvent` with an `exec_request`
/// — rather than calling the private handlers, because the defect was
/// exactly that a branch inside the wait loop could not be reached: the
/// loop's only suspension point is its poll sleep, so cancelling it
/// leaves at `while !Task.isCancelled` without going round again.
@MainActor
final class ExecWaitTerminationTests: XCTestCase {

    private var receipts: [(kind: String, outcome: String)] = []
    /// HELD BY THE TEST CASE, NOT BY THE CONTROLLER. `paneManager`,
    /// `agentMonitor` and `TunnelManager.shared` are all weak, so a helper
    /// that made them locally left every ownership check answering
    /// "unregistered" the instant it returned — and a close was refused
    /// while reading as though it had run.
    private var heldTunnels: TunnelManager!
    private var heldMonitor: AgentMonitor!
    private var heldPanes: WorkspaceManager!

    override func setUp() {
        super.setUp()
        receipts = []
        HubEventClient.execReceiptSink = { [self] kind, _, _, data in
            receipts.append((kind, data["outcome"] as? String ?? "?"))
        }
    }

    override func tearDown() {
        HubEventClient.execReceiptSink = nil
        super.tearDown()
    }

    /// An armed controller with one open exec pane and one wait in flight
    /// that will never match.
    private func controllerWithAWaitInFlight() async throws -> (ExecController, String) {
        heldMonitor = AgentMonitor()
        heldMonitor.applySnapshot([["id": "api-7f3c", "tool": "claude"]])
        heldPanes = WorkspaceManager()
        heldPanes.addLocalWorkspace()
        // `newExecTab` builds the pane's command from the local connection,
        // which is the manager's to give; it is a weak global, so the test
        // holds it.
        heldTunnels = TunnelManager()
        TunnelManager.shared = heldTunnels
        let controller = ExecController()
        controller.start(paneManager: heldPanes, agentMonitor: heldMonitor,
                         detector: AgentDetector(), port: 0)
        // The pane shows something, and it is not the pattern — so the
        // wait polls rather than ending on its own.
        controller.screenOfLeaf = { _ in "still building\n" }
        controller.setArmed(true)

        controller.handleHubEvent(request(verb: "open"))
        try await until { !controller.registry.panes.isEmpty }
        let handle = try XCTUnwrap(controller.registry.panes.keys.first)

        controller.handleHubEvent(request(verb: "wait-output", pane: handle,
                                          extra: ["pattern": "DONE-42", "timeout_secs": 300]))
        try await until { !controller.registry.panes.isEmpty }
        // One turn for the dispatch Task to register the wait.
        try await Task.sleep(nanoseconds: 50_000_000)
        return (controller, handle)
    }

    private func request(verb: String, pane: String? = nil,
                         extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = [
            "verb": verb, "owner": "api-7f3c", "requester": "api-7f3c",
            "request_id": "r-\(verb)",
        ]
        if let pane { payload["pane"] = pane }
        for (k, v) in extra { payload[k] = v }
        return ["type": "exec_request", "payload": payload]
    }

    private func until(_ condition: () -> Bool, tries: Int = 60) async throws {
        for _ in 0..<tries {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition never held")
    }

    /// DISARMING ANSWERS THE WAIT. Without this an agent sitting in
    /// `wait-output --timeout 300` got nothing at all when the human
    /// flipped the switch off, and blocked to its own deadline.
    func testDisarmingAnswersAWaitThatIsInFlight() async throws {
        let (controller, _) = try await controllerWithAWaitInFlight()
        receipts = []

        controller.setArmed(false)

        XCTAssertEqual(receipts.filter { $0.kind == "exec_wait_completed" }.map(\.outcome),
                       ["disarmed"],
                       "disarming cancelled the wait and told the agent nothing")
    }

    /// CLOSING THE PANE ANSWERS IT TOO, and the close's own receipt is a
    /// different answer to a different request.
    func testClosingThePaneAnswersAWaitThatIsInFlight() async throws {
        let (controller, handle) = try await controllerWithAWaitInFlight()
        receipts = []

        controller.handleHubEvent(request(verb: "close", pane: handle))
        try await until { self.receipts.contains { $0.kind == "exec_pane_closed" } }

        XCTAssertEqual(receipts.filter { $0.kind == "exec_wait_completed" }.map(\.outcome),
                       ["target-gone"],
                       "the pane went away under a waiting agent and nobody told it")
    }
}

/// THE SAME BOUNDARIES [[protocol.isValidExecCommand]] ASSERTS
/// ([[RFC-0007]] C-PRIMITIVES, [[WI-2026-08-30-009]]).
///
/// The rule is written twice because Swift cannot import Zig. What can be
/// shared is the list of cases: these are the same ones that function's
/// own test holds,
/// so tightening one side without the other takes the other red.
final class ExecValidationTests: XCTestCase {

    func testWhatIsAccepted() {
        XCTAssertTrue(ExecCommandValidator.isValid("ls -la && echo DONE-42"))
        XCTAssertTrue(ExecCommandValidator.isValid("cargo build"))
        XCTAssertTrue(ExecCommandValidator.isValid("echo café"), "UTF-8 is text, not a control")
    }

    func testWhatIsRefused() {
        XCTAssertFalse(ExecCommandValidator.isValid(""))
        XCTAssertFalse(ExecCommandValidator.isValid("a\nb"), "LF")
        XCTAssertFalse(ExecCommandValidator.isValid("a\rb"), "CR")
        XCTAssertFalse(ExecCommandValidator.isValid("a\tb"), "TAB")
        XCTAssertFalse(ExecCommandValidator.isValid("a\u{1b}b"), "ESC")
        XCTAssertFalse(ExecCommandValidator.isValid("a\u{07}b"), "BEL")
        XCTAssertFalse(ExecCommandValidator.isValid("a\u{7f}b"), "DEL")
    }

    /// STATED BECAUSE IT IS A DECISION AND NOT AN OVERSIGHT: C1 passes,
    /// on both sides, for the reason both comments give.
    func testC1PassesOnBothSidesByDesign() {
        XCTAssertTrue(ExecCommandValidator.isValid("a\u{9b}b"))
    }
}
