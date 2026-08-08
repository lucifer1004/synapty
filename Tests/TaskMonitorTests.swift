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
