import XCTest
@testable import Synapty

/// Unit tests for AgentMonitor's pure output parsers (WI-2026-08-08-021).
/// The parsers accept three shapes: IPC-wrapped, direct hub response, and
/// hub envelope — plus garbage/empty input which must yield [].
final class AgentMonitorParserTests: XCTestCase {

    private func agentsJSON(_ agents: [[String: String]]) -> String {
        let json = """
        {"ok":true,"agents":[
        \(agents.map { """
            {"id":"\($0["id"]!)","tool":"\($0["tool"] ?? "-")","project":"\($0["project"] ?? "-")","session":"\($0["session"] ?? "-")"}
        """ }.joined(separator: ",\n"))
        ]}
        """
        return json
    }

    // MARK: - Shape 1: IPC-wrapped {"success":true,"data":"<hub-response>"}

    func testParseIpcWrappedShape() {
        let inner = agentsJSON([["id": "agent-1", "tool": "claude"]])
        // IPC envelope: {"success":true,"data":"<hub-response-json-string>"}.
        // Raw newlines are illegal inside a JSON string — escape them too.
        let escaped = inner
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let ipc = "{\"success\":true,\"data\":\"\(escaped)\"}"
        let parsed = AgentMonitor.parseAgentsOutput(ipc)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "agent-1")
        XCTAssertEqual(parsed[0].tool, .claude)
    }

    // MARK: - Shape 2: direct hub response {"ok":true,"agents":[...]}

    func testParseDirectHubShape() {
        let output = agentsJSON([
            ["id": "a1", "tool": "codex", "project": "synapty", "session": "s1"],
            ["id": "a2", "tool": "gemini"],
        ])
        let parsed = AgentMonitor.parseAgentsOutput(output)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "a1")
        XCTAssertEqual(parsed[0].tool, .codex)
        XCTAssertEqual(parsed[0].project, "synapty")
        XCTAssertEqual(parsed[1].tool, .gemini)
        XCTAssertEqual(parsed[1].project, "-")
    }

    // MARK: - Shape 3: hub envelope {"type":"response","payload":{...}}

    func testParseEnvelopeShape() {
        // Hub envelope: {"type":"response","payload":{...}} — payload is a
        // DICT (Shape 3 in parseAgentsJSON), not an escaped string.
        let envelope = """
        {"type":"response","payload":{"ok":true,"agents":[{"id":"a9","tool":"unknown"}]}}
        """
        let parsed = AgentMonitor.parseAgentsOutput(envelope)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "a9")
        XCTAssertEqual(parsed[0].tool, .unknown)
    }

    // MARK: - Robustness

    func testParseEmptyOutput() {
        XCTAssertTrue(AgentMonitor.parseAgentsOutput("").isEmpty)
        XCTAssertTrue(AgentMonitor.parseAgentsOutput("\n  \n").isEmpty)
    }

    func testParseGarbageOutput() {
        XCTAssertTrue(AgentMonitor.parseAgentsOutput("not json at all").isEmpty)
        XCTAssertTrue(AgentMonitor.parseAgentsOutput("{\"broken\": ").isEmpty)
    }

    func testParseMalformedAgentEntriesAreSkipped() {
        // One entry missing "id" must be skipped, not crash the parser.
        let output = """
        {"ok":true,"agents":[
            {"tool":"claude","project":"p","session":"s"},
            {"id":"ok-1","tool":"claude"}
        ]}
        """
        let parsed = AgentMonitor.parseAgentsOutput(output)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "ok-1")
    }

    // MARK: - Tool type mapping

    func testToolTypeParsing() {
        XCTAssertEqual(ToolType(from: "Claude"), .claude)
        XCTAssertEqual(ToolType(from: "CODEX"), .codex)
        XCTAssertEqual(ToolType(from: "gemini"), .gemini)
        XCTAssertEqual(ToolType(from: "human"), .human)
        XCTAssertEqual(ToolType(from: "weird-thing"), .unknown)
        XCTAssertEqual(ToolType(from: "-"), .unknown)
    }
}
