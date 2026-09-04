import XCTest
@testable import Synapty

/// Unit tests for TaskMonitor's pure logic: TaskItem decoding/status
/// mapping, projectCounts aggregation, envelope payload parsing, and the
/// cli-tmp- activity noise filter (WI-2026-08-08-021).
@MainActor
final class TaskMonitorTests: XCTestCase {

    // MARK: - TaskItem decode + status mapping

    private func makeTask(number: Int, title: String, labels: [String], assignee: String? = nil) throws -> TaskItem {
        var dict: [String: Any] = [
            "number": number,
            "title": title,
            "state": "open",
            "url": "https://github.com/o/r/issues/\(number)",
            "labels": labels,
        ]
        if let assignee { dict["assignee"] = assignee }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(TaskItem.self, from: data)
    }

    func testTaskItemDecodeAndStatusMapping() throws {
        let doing = try makeTask(number: 1, title: "t1", labels: ["p:synapty", "s:doing"])
        XCTAssertEqual(doing.status, .doing)
        XCTAssertEqual(doing.projectLabel, "p:synapty")

        let done = try makeTask(number: 2, title: "t2", labels: ["p:synapty", "s:done"])
        XCTAssertEqual(done.status, .done)

        let todo = try makeTask(number: 3, title: "t3", labels: ["p:other"])
        XCTAssertEqual(todo.status, .todo)
        XCTAssertNil(todo.statusLabel)
    }

    func testTaskItemWithoutProjectLabel() throws {
        let task = try makeTask(number: 4, title: "no project", labels: ["s:doing"])
        XCTAssertNil(task.projectLabel)
    }

    // MARK: - projectCounts aggregation

    func testProjectCountsAggregation() throws {
        let monitor = TaskMonitor()
        monitor.tasks = [
            try makeTask(number: 1, title: "a", labels: ["p:synapty", "s:todo"]),
            try makeTask(number: 2, title: "b", labels: ["p:synapty", "s:doing"]),
            try makeTask(number: 3, title: "c", labels: ["p:synapty", "s:doing"]),
            try makeTask(number: 4, title: "d", labels: ["p:synapty", "s:done"]),
            try makeTask(number: 5, title: "e", labels: ["p:ghostty", "s:todo"]),
            try makeTask(number: 6, title: "f", labels: ["s:todo"]), // no project label
        ]
        let counts = monitor.projectCounts
        // Keys are the raw project labels (with the "p:" prefix).
        XCTAssertEqual(counts["p:synapty"]?.todo, 1)
        XCTAssertEqual(counts["p:synapty"]?.doing, 2)
        XCTAssertEqual(counts["p:synapty"]?.done, 1)
        XCTAssertEqual(counts["p:synapty"]?.total, 4)
        XCTAssertEqual(counts["p:ghostty"]?.total, 1)
        XCTAssertNil(counts[""])
    }

    func testProjectCountsEmpty() {
        let monitor = TaskMonitor()
        XCTAssertTrue(monitor.projectCounts.isEmpty)
    }

    // MARK: - parseEnvelopePayload

    func testParseEnvelopePayload() {
        let monitor = TaskMonitor()
        let output = """
        {"type":"response","id":"req-1","payload":{"ok":true,"data":[{"number":1}]}}
        """
        let payload = monitor.parseEnvelopePayload(output)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?["ok"] as? Bool, true)
    }

    func testParseEnvelopePayloadRejectsNonEnvelope() {
        let monitor = TaskMonitor()
        XCTAssertNil(monitor.parseEnvelopePayload("not json"))
        XCTAssertNil(monitor.parseEnvelopePayload("{\"ok\":true}")) // no payload key
        XCTAssertNil(monitor.parseEnvelopePayload("{\"payload\": 42}"))
    }

    // MARK: - Activity noise filter

    private func activity(agent: String, tool: String) -> ActivityItem {
        ActivityItem(ts: Int64.random(in: 1...1_000_000), agent: agent, tool: tool, detail: "-")
    }

    func testFilterActivityNoise() {
        let items = [
            activity(agent: "cli-tmp-123", tool: "activity.list"),
            activity(agent: "cli-tmp-123", tool: "task.list"),
            activity(agent: "cli-tmp-123", tool: "task.claim"), // real agent action
            activity(agent: "agent-real", tool: "activity.list"), // real agent, list is genuine
        ]
        let filtered = TaskMonitor.filterActivityNoise(items)
        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered[0].tool, "task.claim")
        XCTAssertEqual(filtered[1].agent, "agent-real")
    }

    func testFilterActivityNoiseEmpty() {
        XCTAssertTrue(TaskMonitor.filterActivityNoise([]).isEmpty)
    }
}

extension TaskMonitorTests {

    /// WI-2026-08-12-005: the workbench executes task tools locally, so its
    /// own poll reads the FLAT `{ok,data}` the executor prints — not the
    /// hub envelope. Confusing the two shapes would silently yield an
    /// empty task list with no error anywhere.
    func testParseToolsExecResultReadsTheFlatExecutorShape() {
        let ok = TaskMonitor.parseToolsExecResult(
            "{\"ok\":true,\"data\":[{\"number\":7,\"title\":\"fix it\"}]}\n")
        XCTAssertEqual(ok?["ok"] as? Bool, true)
        XCTAssertEqual((ok?["data"] as? [[String: Any]])?.count, 1)

        let failed = TaskMonitor.parseToolsExecResult(
            "{\"ok\":false,\"error\":\"github token not found\"}")
        XCTAssertEqual(failed?["ok"] as? Bool, false)
        XCTAssertEqual(failed?["error"] as? String, "github token not found")

        // A hub ENVELOPE is not this shape and must not parse as one — it
        // has no top-level `ok`, so treating it as a result would report
        // zero tasks rather than a mismatch.
        XCTAssertNil(TaskMonitor.parseToolsExecResult(
            "{\"type\":\"tool_response\",\"payload\":{\"ok\":true,\"data\":[]}}"))
        XCTAssertNil(TaskMonitor.parseToolsExecResult(""))
        XCTAssertNil(TaskMonitor.parseToolsExecResult("not json"))
    }

    /// The status bar caps the project pills, so the ORDER decides what
    /// the human sees. Alphabetical carries no information: a project with
    /// work in flight must not drop behind an idle one whose name sorts
    /// earlier.
    @MainActor
    func testProjectPillsRankByActivityNotName() {
        let counts: [String: ProjectCounts] = [
            "p:aaa": ProjectCounts(todo: 0, doing: 0, done: 9),
            "p:bbb": ProjectCounts(todo: 1, doing: 0, done: 0),
            "p:ccc": ProjectCounts(todo: 0, doing: 5, done: 0),
            "p:ddd": ProjectCounts(todo: 3, doing: 0, done: 0),
        ]
        let (visible, overflow) = ContextStatusBar.ranked(counts, limit: 3)
        XCTAssertEqual(visible, ["p:ccc", "p:ddd", "p:bbb"],
                       "in-progress first, then queued by depth")
        XCTAssertEqual(overflow, 1, "the idle project is the one hidden")
    }

    /// Equal counts must not reshuffle the row between polls.
    @MainActor
    func testEqualCountsFallBackToAStableNameOrder() {
        let counts: [String: ProjectCounts] = [
            "p:zeta": ProjectCounts(todo: 2, doing: 1, done: 0),
            "p:alpha": ProjectCounts(todo: 2, doing: 1, done: 0),
        ]
        let (visible, overflow) = ContextStatusBar.ranked(counts, limit: 3)
        XCTAssertEqual(visible, ["p:alpha", "p:zeta"])
        XCTAssertEqual(overflow, 0)
    }
}
