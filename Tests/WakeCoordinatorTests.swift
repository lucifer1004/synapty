import XCTest
@testable import Synapty

/// WI-2026-08-11-013: RFC-0005 wake — pure gate, fixed template, and the
/// pending-candidate/ack state machine. (Injection itself is ghostty
/// surface integration, verified live; everything decidable is pure and
/// tested here.)
final class WakeCoordinatorTests: XCTestCase {

    // MARK: - C-TEMPLATE

    func testTemplateIsFixedAndSingleLine() {
        XCTAssertEqual(
            WakeTemplate.line,
            "[synapty] You have unread A2A messages. Run: synapty recv")
        XCTAssertFalse(WakeTemplate.line.contains("\n"))
        XCTAssertFalse(WakeTemplate.line.contains("\r"))
        // Zero interpolation: the template is a compile-time constant; no
        // format placeholders may survive in it.
        XCTAssertFalse(WakeTemplate.line.contains("%"))
        XCTAssertFalse(WakeTemplate.line.contains("\\("))
    }

    // MARK: - C-STATE-GATE

    private func openInput() -> WakeGateInput {
        WakeGateInput(
            armed: true,
            mergedStatus: "idle",
            freshSample: "idle",
            processExited: false,
            secondsSinceHumanInput: nil,
            injectionInFlight: false)
    }

    func testGateOpensOnlyAtRest() {
        XCTAssertEqual(WakeGate.decide(openInput()), .open)
        var input = openInput()
        input.mergedStatus = "done"
        input.freshSample = "done"
        XCTAssertEqual(WakeGate.decide(input), .open)
    }

    func testGateMergedUnknownWithFreshRestEvidenceOpens() {
        // C-STATE-GATE as amended (2026-08-11): C-PRECEDENCE parks a
        // freshly registered at-rest agent at merged `unknown` (passive
        // done needs a working/waiting prior; passive idle is inert), so
        // merged unknown must not block when the fresh sample sees rest —
        // otherwise the fresh-edge wake scenario is undeliverable.
        var input = openInput()
        input.mergedStatus = "unknown"
        input.freshSample = "done"
        XCTAssertEqual(WakeGate.decide(input), .open)
        // But unknown + NO fresh evidence stays closed (cannot see).
        input.freshSample = nil
        XCTAssertEqual(WakeGate.decide(input), .closed("no fresh classification"))
    }

    func testGateClosedWhenDisarmed() {
        var input = openInput()
        input.armed = false
        XCTAssertEqual(WakeGate.decide(input), .closed("not armed"))
    }

    func testGateWaitingIsAbsolutelyProhibited() {
        // A modal question on screen — injected text could answer it on
        // the human's behalf. Both channels must block independently.
        var input = openInput()
        input.mergedStatus = "waiting"
        XCTAssertEqual(WakeGate.decide(input), .closed("merged status waiting"))
        input = openInput()
        input.freshSample = "waiting"
        XCTAssertEqual(WakeGate.decide(input), .closed("fresh sample waiting"))
    }

    func testGateClosedForWorkingAndUnknown() {
        // Merged channel: working vetoes (the hub may know more than the
        // screen); unknown does NOT (see the amended-gate test above).
        var input = openInput()
        input.mergedStatus = "working"
        XCTAssertEqual(WakeGate.decide(input), .closed("merged status working"))
        // Fresh channel: only idle/done are rest evidence.
        for status in ["working", "unknown"] {
            input = openInput()
            input.freshSample = status
            XCTAssertEqual(WakeGate.decide(input), .closed("fresh sample \(status)"))
        }
    }

    func testGateClosedWithoutFreshClassification() {
        // No manifest / no rule matched = cannot see clearly → do not act.
        var input = openInput()
        input.freshSample = nil
        XCTAssertEqual(WakeGate.decide(input), .closed("no fresh classification"))
    }

    func testGateClosedWhenPaneProcessExited() {
        var input = openInput()
        input.processExited = true
        XCTAssertEqual(WakeGate.decide(input), .closed("pane process exited"))
    }

    func testGateHumanTypingBackoff() {
        var input = openInput()
        input.secondsSinceHumanInput = 1.0
        XCTAssertEqual(WakeGate.decide(input), .closed("human typed 1.0s ago"))
        // Outside the window → open again.
        input.secondsSinceHumanInput = 4.0
        XCTAssertEqual(WakeGate.decide(input), .open)
    }

    func testGateClosedWhileInjectionInFlight() {
        var input = openInput()
        input.injectionInFlight = true
        XCTAssertEqual(WakeGate.decide(input), .closed("injection in flight"))
    }

    // MARK: - C-WAKE-TRIGGER / C-WAKE-ACK state machine

    func testCandidateUpsertAndGenerationReset() {
        var store = WakePendingStore()
        store.candidate(agent: "claude-abc", generation: 5)
        XCTAssertEqual(store.entries["claude-abc"]?.generation, 5)

        // First stall survives, awaiting retry.
        store.markInjected(agent: "claude-abc")
        XCTAssertEqual(store.stalled(agent: "claude-abc"), .retryLater)
        XCTAssertEqual(store.entries["claude-abc"]?.stalls, 1)

        // Duplicate push for the SAME generation leaves state untouched.
        store.candidate(agent: "claude-abc", generation: 5)
        XCTAssertEqual(store.entries["claude-abc"]?.stalls, 1)

        // A NEW generation starts clean — no inherited wake debt.
        store.candidate(agent: "claude-abc", generation: 9)
        XCTAssertEqual(store.entries["claude-abc"]?.stalls, 0)
        XCTAssertEqual(store.entries["claude-abc"]?.generation, 9)
    }

    func testDeliveredFlow() {
        var store = WakePendingStore()
        store.candidate(agent: "claude-abc", generation: 5)
        XCTAssertEqual(store.injectable.count, 1)

        store.markInjected(agent: "claude-abc")
        // In flight: not eligible for another attempt.
        XCTAssertTrue(store.injectable.isEmpty)

        // Working edge inside the window → delivered, entry resolves.
        let acked = store.acked(agent: "claude-abc")
        XCTAssertEqual(acked?.generation, 5)
        XCTAssertTrue(store.entries.isEmpty)

        // Edges with nothing awaiting are not receipts.
        XCTAssertNil(store.acked(agent: "claude-abc"))
    }

    func testAckRequiresInjection() {
        var store = WakePendingStore()
        store.candidate(agent: "claude-abc", generation: 5)
        // A working edge BEFORE any injection (agent started on its own)
        // must not count as a wake receipt.
        XCTAssertNil(store.acked(agent: "claude-abc"))
        XCTAssertNotNil(store.entries["claude-abc"])
    }

    func testStallRetryOnceThenExhausted() {
        var store = WakePendingStore()
        store.candidate(agent: "claude-abc", generation: 5)

        store.markInjected(agent: "claude-abc")
        XCTAssertEqual(store.stalled(agent: "claude-abc"), .retryLater)
        // Candidate survives the first stall and is injectable again.
        XCTAssertEqual(store.injectable.count, 1)

        store.markInjected(agent: "claude-abc")
        XCTAssertEqual(store.stalled(agent: "claude-abc"), .exhausted)
        // Second stall: stop — never loop. Entry stays (mail is still
        // waiting; the hub cancels it on drain) but is not injectable.
        XCTAssertTrue(store.injectable.isEmpty)
        XCTAssertEqual(store.entries["claude-abc"]?.exhausted, true)

        // A stall for an entry that was cancelled meanwhile reports nothing.
        store.cancel(agent: "claude-abc")
        XCTAssertNil(store.stalled(agent: "claude-abc"))
    }

    func testCancelDropsEntryEvenMidAck() {
        var store = WakePendingStore()
        store.candidate(agent: "claude-abc", generation: 5)
        store.markInjected(agent: "claude-abc")
        // Hub cancelled (agent drained its mail on its own).
        store.cancel(agent: "claude-abc")
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.stalled(agent: "claude-abc"))
    }

    // MARK: - C-AUTHORITY (arming lives on the pane manager)

    /// addLocalWorkspace() consults TunnelManager.shared for the local
    /// command; without it the session has no panes (same trap
    /// TerminalPaneManagerTests documents — WI-2026-08-08-020).
    @MainActor
    private func makeManager() -> (WorkspaceManager, TunnelManager) {
        let tunnel = TunnelManager()
        TunnelManager.shared = tunnel
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        return (manager, tunnel)
    }

    @MainActor
    func testWakeArmingDefaultOffAndDisarmCancels() {
        let (manager, tunnel) = makeManager()
        defer { TunnelManager.shared = nil; _ = tunnel }
        let leafID = manager.workspaces[0].panes[0].id

        // Default OFF (C-AUTHORITY).
        XCTAssertFalse(manager.isWakeArmed(leafID))

        var disarmed: [String] = []
        manager.onWakeDisarmed = { disarmed.append($0) }

        manager.setWakeArmed(leafID, true)
        XCTAssertTrue(manager.isWakeArmed(leafID))

        // Associate an agent, then disarm → immediate cancellation hook.
        manager.remapLeafAgent(from: manager.agentID(forLeaf: leafID) ?? "", to: "claude-abc")
        manager.setWakeArmed(leafID, false)
        XCTAssertFalse(manager.isWakeArmed(leafID))

        // Disarming an already-disarmed leaf fires nothing.
        manager.setWakeArmed(leafID, false)

        // The hook fired exactly once, with the leaf's agent (when one
        // was associated).
        if manager.agentID(forLeaf: leafID) != nil {
            XCTAssertEqual(disarmed, ["claude-abc"])
        } else {
            XCTAssertTrue(disarmed.isEmpty)
        }
    }

    @MainActor
    func testLeafCloseDisarms() {
        let (manager, tunnel) = makeManager()
        defer { TunnelManager.shared = nil; _ = tunnel }
        // Split so a leaf can close without tearing down the session
        // (closing the LAST leaf exercises app teardown, out of scope).
        manager.splitFocusedLeaf(direction: .horizontal)
        let leafID = manager.workspaces[0].panes[0].id
        manager.setWakeArmed(leafID, true)
        XCTAssertTrue(manager.isWakeArmed(leafID))
        manager.leafDidClose(leafID)
        XCTAssertFalse(manager.isWakeArmed(leafID))
    }
}
