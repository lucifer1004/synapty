import XCTest
@testable import Synapty

/// RFC-0004 C-SUBSCRIPTION on the GUI side (WI-2026-08-09-025): pure
/// event application plus a live reconnect-resubscribe pass against a
/// mock hub speaking the wire protocol.
final class HubEventApplyTests: XCTestCase {

    private func base(_ id: String, tool: String = "claude", status: String = "unknown") -> AgentInfo {
        var info = AgentInfo(id: id, tool: ToolType(from: tool), project: "p", session: "s")
        info.status = status
        return info
    }

    func testRegisteredEventAddsAgentWithMetadata() {
        let ev: [String: Any] = [
            "kind": "agent_registered", "agent": "a1", "generation": 1,
            "tool": "codex", "project": "synapty", "session": "wi-025",
        ]
        let out = AgentMonitor.applying(event: ev, to: [])
        XCTAssertEqual(out?.count, 1)
        XCTAssertEqual(out?[0].tool, .codex)
        XCTAssertEqual(out?[0].project, "synapty")
        XCTAssertEqual(out?[0].status, "unknown")
    }

    func testRegisteredEventWithoutMetadataDoesNotClobber() {
        // The initial routing register carries no metadata — it must not
        // wipe fields learned from an earlier agent_update.
        let ev: [String: Any] = ["kind": "agent_registered", "agent": "a1", "generation": 1]
        let out = AgentMonitor.applying(event: ev, to: [base("a1", tool: "claude", status: "waiting")])
        XCTAssertEqual(out?[0].tool, .claude)
        XCTAssertEqual(out?[0].project, "p")
        XCTAssertEqual(out?[0].status, "waiting")
    }

    func testStatusChangedUpdatesStatus() {
        let ev: [String: Any] = [
            "kind": "agent_status_changed", "agent": "a1",
            "old": "working", "new": "waiting", "class": "explicit",
        ]
        let out = AgentMonitor.applying(event: ev, to: [base("a1", status: "working")])
        XCTAssertEqual(out?[0].status, "waiting")
    }

    func testUnregisteredRemovesAgentAndUnknownKindIsNoop() {
        let agents = [base("a1"), base("a2")]
        let out = AgentMonitor.applying(event: ["kind": "agent_unregistered", "agent": "a1"], to: agents)
        XCTAssertEqual(out?.map(\.id), ["a2"])
        // Unknown kinds and message_routed change nothing.
        XCTAssertNil(AgentMonitor.applying(event: ["kind": "message_routed", "agent": "a1", "peer": "a2"], to: agents))
        XCTAssertNil(AgentMonitor.applying(event: ["kind": "mystery", "agent": "a1"], to: agents))
        XCTAssertNil(AgentMonitor.applying(event: ["kind": "agent_unregistered", "agent": "ghost"], to: agents))
    }

    func testSnapshotParsingDefaultsToUnknown() {
        let dicts: [[String: Any]] = [
            ["id": "a1", "tool": "claude", "project": "p", "session": "s", "status": "done", "generation": 3],
            ["id": "a2", "tool": "gemini", "project": "-", "session": "-"],
        ]
        let infos = AgentMonitor.agentInfos(from: dicts)
        XCTAssertEqual(infos.count, 2)
        XCTAssertEqual(infos[0].status, "done")
        XCTAssertEqual(infos[1].status, "unknown")
    }
}

// MARK: - Mock hub (wire-level)

/// Minimal loopback TCP server speaking just enough of the hub protocol:
/// accepts a connection, captures the subscribe line, and lets the test
/// script snapshot/event lines and disconnects.
private final class MockHub: @unchecked Sendable {
    let listenFD: Int32
    let port: Int

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        var bound_addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &bound_addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard got == 0 else {
            close(fd)
            return nil
        }
        listenFD = fd
        port = Int(UInt16(bigEndian: bound_addr.sin_port))
        // Non-blocking accept so a failed test times out instead of hanging.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    }

    deinit { close(listenFD) }

    /// Accept one connection within `timeout` seconds (polling; the
    /// listener is non-blocking).
    func accept(timeout: TimeInterval = 10) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let c = Darwin.accept(listenFD, nil, nil)
            if c >= 0 {
                _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL, 0) | O_NONBLOCK)
                return c
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip.neverThrown("accept timed out")
    }

    /// Read one newline-terminated line within `timeout` seconds.
    func readLine(_ fd: Int32, timeout: TimeInterval = 10) async throws -> String {
        var buf: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buf.append(contentsOf: chunk[0..<n])
                if let nl = buf.firstIndex(of: 0x0A) {
                    return String(decoding: buf[..<nl], as: UTF8.self)
                }
            } else if n == 0 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip.neverThrown("readLine timed out")
    }

    func writeLine(_ fd: Int32, _ line: String) {
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            if n <= 0 { return }
            offset += n
        }
    }
}

private enum XCTSkip: Error {
    // Helper to throw descriptive errors without a custom Error boilerplate.
    static func neverThrown(_ msg: String) -> NSError {
        NSError(domain: "MockHub", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

@MainActor
final class HubEventLiveTests: XCTestCase {

    private func waitUntil(
        _ timeout: TimeInterval = 5,
        _ message: String,
        _ cond: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(message)
    }

    /// One pass over the full client lifecycle: subscribe → snapshot →
    /// pushed event → hub death → automatic reconnect + RE-subscribe →
    /// fresh snapshot resyncs state.
    func testSubscribeSnapshotEventAndReconnectResubscribe() async throws {
        guard let mock = MockHub() else {
            XCTFail("mock hub listener failed")
            return
        }
        let monitor = AgentMonitor()
        monitor.startMonitoring(port: mock.port)
        defer { monitor.stopMonitoring() }

        // --- 1st connection: subscribe line, then snapshot. ---
        let c1 = try await mock.accept()
        let sub1 = try await mock.readLine(c1)
        XCTAssertTrue(sub1.contains("\"subscribe\""), "first message must be the subscribe envelope")
        mock.writeLine(c1, #"{"type":"response","id":"gui-0","source":"hub","target":"workbench","payload":{"ok":true,"data":{"agents":[{"id":"a1","tool":"claude","project":"p","session":"s","status":"working","generation":1}],"seq":4}}}"#)
        try await waitUntil(5, "snapshot never applied") {
            monitor.agents.first?.id == "a1" && monitor.agents.first?.status == "working"
        }
        XCTAssertTrue(monitor.hubConnected)

        // --- Pushed status event updates without any poll. ---
        mock.writeLine(c1, #"{"type":"event","id":"evt-5","source":"hub","target":"","payload":{"seq":5,"ts":0,"kind":"agent_status_changed","agent":"a1","old":"working","new":"done","class":"explicit"}}"#)
        try await waitUntil(5, "pushed event never applied") {
            monitor.agents.first?.status == "done"
        }

        // --- Hub dies: the monitor reconnects and RE-subscribes. ---
        close(c1)
        let c2 = try await mock.accept()
        let sub2 = try await mock.readLine(c2)
        XCTAssertTrue(sub2.contains("\"subscribe\""), "reconnect must re-subscribe")
        mock.writeLine(c2, #"{"type":"response","id":"gui-0","source":"hub","target":"workbench","payload":{"ok":true,"data":{"agents":[{"id":"a1","tool":"claude","project":"p","session":"s","status":"idle","generation":1}],"seq":9}}}"#)
        try await waitUntil(5, "resync snapshot never applied") {
            monitor.agents.first?.status == "idle"
        }
        close(c2)
    }
}

/// A HUB THIS WORKBENCH REACHES IS TOLD WHAT THE HUMAN SET
/// ([[RFC-0012]] C-LEVEL-CONTROL, [[WI-2026-08-30-008]]).
///
/// Two comments in HubLogLevel promised this — `operatedPorts` said a peer
/// linked later "must still receive the level", and `apply` justified not
/// retrying a failed send by "the level is re-sent whenever a hub is
/// (re)connected". Nothing re-sent it. The only caller was `logLevel`'s
/// didSet, which `isLoading` suppresses at launch, so a human who set debug
/// and relaunched had a hub that outlived the workbench sitting at its
/// default for as long as it ran.
@MainActor
final class HubLevelOnReachTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try setUpSettingsStorage()
    }

    override func tearDownWithError() throws {
        SynaptySettings.shared.flushPersistence()
        restoreStorageOverrides(tempDir)
        try super.tearDownWithError()
    }

    func testAHubReachedIsToldTheLevelWithoutTheHumanTouchingAnything() async throws {
        guard let mock = MockHub() else { return XCTFail("no loopback listener") }
        SynaptySettings.shared.logLevel = "debug"

        HubLogLevel.applyCurrent(port: mock.port)

        let fd = try await mock.accept()
        defer { close(fd) }
        let line = try await mock.readLine(fd)
        XCTAssertTrue(line.contains("set_log_level"), "not a level frame: \(line)")
        XCTAssertTrue(line.contains("\"debug\""), "the human's level was not the one sent: \(line)")
    }

    /// AND THE MOMENT IS THE HUB ARRIVING. Assigning the port is what says
    /// this workbench has one.
    func testAssigningTheLocalHubPortTellsIt() async throws {
        guard let mock = MockHub() else { return XCTFail("no loopback listener") }
        SynaptySettings.shared.logLevel = "warn"

        let manager = TunnelManager()
        manager.hubPort = mock.port

        let fd = try await mock.accept()
        defer { close(fd) }
        let line = try await mock.readLine(fd)
        XCTAssertTrue(line.contains("set_log_level") && line.contains("\"warn\""),
                      "reaching a hub did not tell it the level: \(line)")
    }
}
