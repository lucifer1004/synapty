import XCTest
@testable import Synapty

/// RFC-0004 C-PASSIVE-DETECTION / ADR-0005 (WI-2026-08-09-027): the
/// declarative classifier and the edge-triggered emission semantics.
final class AgentDetectorTests: XCTestCase {

    private func manifest(_ json: String) -> CompiledManifest {
        let decoded = try! JSONDecoder().decode(DetectManifest.self, from: json.data(using: .utf8)!)
        return CompiledManifest(decoded)
    }

    // MARK: - Classifier

    func testContainsAndRegexRulesFirstMatchWins() {
        let m = manifest("""
        {"tool":"claude","rules":[
            {"state":"waiting","contains":"Do you want"},
            {"state":"working","regex":"esc to interrupt|Thinking"},
            {"state":"done","contains":"? for shortcuts"}
        ]}
        """)
        XCTAssertEqual(m.classify("│ Do you want to proceed? │\n❯ 1. Yes"), "waiting")
        XCTAssertEqual(m.classify("✻ Churning… (esc to interrupt)"), "working")
        XCTAssertEqual(m.classify("❯ \n  ? for shortcuts"), "done")
        // Order decides when several rules match: waiting outranks done.
        XCTAssertEqual(m.classify("Do you want …  ? for shortcuts"), "waiting")
        // No rule matches → nil (inert).
        XCTAssertNil(m.classify("just some scrollback output"))
    }

    func testNonPassiveStatesAreDroppedAtCompile() {
        // idle/unknown are not passively proposable (C-OWNERSHIP); a
        // manifest trying to propose them is ignored, not honored.
        let m = manifest("""
        {"tool":"x","rules":[
            {"state":"idle","contains":"prompt"},
            {"state":"unknown","contains":"prompt"},
            {"state":"done","contains":"prompt"}
        ]}
        """)
        XCTAssertEqual(m.classify("prompt"), "done")
    }

    func testInvalidRegexIsSkipped() {
        let m = manifest("""
        {"tool":"x","rules":[
            {"state":"working","regex":"([unclosed"},
            {"state":"waiting","contains":"ask"}
        ]}
        """)
        XCTAssertEqual(m.classify("ask me"), "waiting")
    }

    // MARK: - Edge tracker (C-PRECEDENCE rule 2)

    func testFirstClassificationIsAnEdgeAndRepeatsAreNot() {
        var t = DetectionEdgeTracker()
        XCTAssertEqual(t.edge(agent: "a", generation: 1, classification: "working"), "working")
        XCTAssertNil(t.edge(agent: "a", generation: 1, classification: "working"))
        XCTAssertEqual(t.edge(agent: "a", generation: 1, classification: "waiting"), "waiting")
        XCTAssertNil(t.edge(agent: "a", generation: 1, classification: "waiting"))
    }

    func testNoMatchIsInertAndPreservesMemory() {
        var t = DetectionEdgeTracker()
        XCTAssertEqual(t.edge(agent: "a", generation: 1, classification: "done"), "done")
        // A brief unclassifiable frame emits nothing…
        XCTAssertNil(t.edge(agent: "a", generation: 1, classification: nil))
        // …and the unchanged banner afterwards must NOT re-assert done
        // (this is what keeps focus-to-clear stable).
        XCTAssertNil(t.edge(agent: "a", generation: 1, classification: "done"))
    }

    func testGenerationChangeResetsMemory() {
        var t = DetectionEdgeTracker()
        XCTAssertEqual(t.edge(agent: "a", generation: 1, classification: "working"), "working")
        // Same agent id, NEW registration generation: the newcomer's first
        // state is an edge even though it matches the previous occupant's.
        XCTAssertEqual(t.edge(agent: "a", generation: 5, classification: "working"), "working")
        XCTAssertNil(t.edge(agent: "a", generation: 5, classification: "working"))
    }

    func testForgetClearsAgentMemory() {
        var t = DetectionEdgeTracker()
        XCTAssertEqual(t.edge(agent: "a", generation: 1, classification: "done"), "done")
        t.forget(agent: "a")
        XCTAssertEqual(t.edge(agent: "a", generation: 1, classification: "done"), "done")
    }

    // MARK: - Schema v2: regions, combinators, skip (WI-2026-08-11-001)

    func testTitleRegionRules() {
        let m = manifest("""
        {"tool":"claude","rules":[
            {"state":"working","region":"title","regex":"^[⠀-⣿] "},
            {"state":"done","region":"title","regex":"^✳ "},
            {"state":"waiting","contains":"do you want"}
        ]}
        """)
        XCTAssertEqual(m.classify(DetectInput(title: "⠋ synapty · fixing tests", screen: "")), "working")
        XCTAssertEqual(m.classify(DetectInput(title: "✳ synapty", screen: "")), "done")
        // Screen rules never read the title and title rules never read the screen.
        XCTAssertEqual(m.classify(DetectInput(title: "", screen: "Do you want to proceed?")), "waiting")
        XCTAssertNil(m.classify(DetectInput(title: "Do you want", screen: "")))
    }

    func testAfterRuleScopesModalChrome() {
        let m = manifest("""
        {"tool":"x","rules":[
            {"state":"waiting","region":"after_rule","all":["do you want to proceed?","esc to cancel"]}
        ]}
        """)
        // The same chrome text ABOVE the last horizontal rule (scrollback
        // echo) must NOT classify — this is the false-positive class the
        // structural region exists to kill.
        let above = "Do you want to proceed? esc to cancel\n──────────\n ready"
        XCTAssertNil(m.classify(DetectInput(screen: above)))
        let below = "old output\n──────────\n Do you want to proceed?\n esc to cancel"
        XCTAssertEqual(m.classify(DetectInput(screen: below)), "waiting")
    }

    func testPromptBoxRegion() {
        let m = manifest("""
        {"tool":"x","rules":[
            {"state":"done","region":"prompt_box","lineRegex":"^\\\\s*❯","not":["enter to select"]}
        ]}
        """)
        let idle = "some output\n─────\n ❯ \n─────\n ? for shortcuts"
        XCTAssertEqual(m.classify(DetectInput(screen: idle)), "done")
        // A selector menu's ❯ cursor is not an idle prompt.
        let menu = "─────\n ❯ 1. Yes  enter to select\n─────"
        XCTAssertNil(m.classify(DetectInput(screen: menu)))
        // No box borders at all → prompt_box rules are inapplicable.
        XCTAssertNil(m.classify(DetectInput(screen: " ❯ ")))
    }

    func testSkipRuleHaltsEvaluation() {
        // "skip" = recognized-but-uninformative UI (transcript viewer):
        // halt evaluation, assert nothing — replayed transcript content
        // must not reach lower rules.
        let m = manifest("""
        {"tool":"claude","rules":[
            {"state":"skip","all":["showing detailed transcript"]},
            {"state":"done","contains":"? for shortcuts"}
        ]}
        """)
        XCTAssertNil(m.classify(DetectInput(screen: "Showing detailed transcript\n ? for shortcuts")))
        XCTAssertEqual(m.classify(DetectInput(screen: " ? for shortcuts")), "done")
    }

    func testAllAnyNotCombinators() {
        let m = manifest("""
        {"tool":"x","rules":[
            {"state":"waiting","all":["do you want to proceed?"],"any":["bash command","tab to amend"],"notRegex":["(?m)^\\\\s*❯\\\\s*$"]}
        ]}
        """)
        XCTAssertEqual(m.classify(DetectInput(screen: "Bash command\nDo you want to proceed?")), "waiting")
        XCTAssertEqual(m.classify(DetectInput(screen: "tab to amend · Do you want to proceed?")), "waiting")
        // all-needle absent
        XCTAssertNil(m.classify(DetectInput(screen: "Bash command")))
        // no any-needle present
        XCTAssertNil(m.classify(DetectInput(screen: "Do you want to proceed?")))
        // notRegex veto: an empty ❯ prompt line means no live question
        XCTAssertNil(m.classify(DetectInput(screen: "Bash command\nDo you want to proceed?\n ❯ ")))
    }

    func testContainsFamilyIsCaseInsensitiveAndNegativeOnlyRulesDrop() {
        let m = manifest("""
        {"tool":"x","rules":[
            {"state":"waiting","not":["nope"]},
            {"state":"done","contains":"Type YOUR message"}
        ]}
        """)
        XCTAssertEqual(m.classify(DetectInput(screen: "type your MESSAGE here")), "done")
        // A rule with no positive condition is dropped at compile.
        XCTAssertNil(m.classify(DetectInput(screen: "anything")))
    }

    func testBottomRegionSeesOnlyLastNonEmptyLines() {
        let m = manifest("""
        {"tool":"x","rules":[{"state":"working","region":"bottom(2)","contains":"esc to interrupt"}]}
        """)
        XCTAssertEqual(
            m.classify(DetectInput(screen: "junk\n✻ Pondering… (esc to interrupt)\n\n ❯ ")), "working")
        XCTAssertNil(m.classify(DetectInput(screen: "esc to interrupt\nline\nline2\nline3")))
    }

    func testLineRegexMatchesPerLine() {
        let m = manifest("""
        {"tool":"x","rules":[{"state":"waiting","lineRegex":"(?i)^\\\\s*❯?\\\\s*1\\\\.\\\\s*yes\\\\b"}]}
        """)
        XCTAssertEqual(m.classify(DetectInput(screen: "Do you want?\n ❯ 1. Yes\n 2. No")), "waiting")
        XCTAssertNil(m.classify(DetectInput(screen: "mentions 1. yesterday plans")))
    }

    func testStructuralParsers() {
        XCTAssertTrue(CompiledManifest.isHorizontalRule("──────"))
        XCTAssertTrue(CompiledManifest.isHorizontalRule("  ── "))
        XCTAssertTrue(CompiledManifest.isHorizontalRule("─── section ───"))
        XCTAssertFalse(CompiledManifest.isHorizontalRule("── text"))
        XCTAssertFalse(CompiledManifest.isHorizontalRule("╭──────╮"))
        XCTAssertFalse(CompiledManifest.isHorizontalRule(""))
        XCTAssertEqual(CompiledManifest.afterLastHorizontalRule("a\n───\nb\nc"), "b\nc")
        XCTAssertEqual(CompiledManifest.afterLastHorizontalRule("a\nb"), "a\nb")
        XCTAssertEqual(CompiledManifest.promptBoxBody("x\n───\n ❯ hi\n───\nfooter"), " ❯ hi")
        XCTAssertNil(CompiledManifest.promptBoxBody("no rules here"))
        XCTAssertEqual(CompiledManifest.bottomNonEmptyLines("a\n\nb\nc\n", 2), "b\nc")
    }

    // MARK: - Match evidence (WI-2026-08-11-002)

    func testEvidenceOnStateHit() {
        let m = manifest("""
        {"tool":"x","rules":[
            {"id":"w1","state":"waiting","contains":"do you want"},
            {"id":"d1","state":"done","region":"bottom(2)","contains":"? for shortcuts"}
        ]}
        """)
        let ev = m.classifyEvidence(DetectInput(screen: "Do you want to proceed?"))
        XCTAssertEqual(ev.outcome, .state("waiting"))
        XCTAssertEqual(ev.ruleID, "w1")
        XCTAssertEqual(ev.region, "screen")
        XCTAssertTrue(ev.preview.contains("Do you want"))
    }

    func testEvidenceOnSkipAndNoMatch() {
        let m = manifest("""
        {"tool":"x","rules":[
            {"id":"viewer","state":"skip","contains":"showing detailed transcript"},
            {"state":"done","contains":"? for shortcuts"}
        ]}
        """)
        // A skip hit is distinguishable from a state hit AND from no-match.
        let skip = m.classifyEvidence(DetectInput(screen: "Showing detailed transcript"))
        XCTAssertEqual(skip.outcome, .skip)
        XCTAssertEqual(skip.ruleID, "viewer")
        let none = m.classifyEvidence(DetectInput(screen: "nothing relevant"))
        XCTAssertEqual(none.outcome, .noMatch)
        XCTAssertNil(none.ruleID)
        XCTAssertNil(none.region)
    }

    func testEvidenceFallbackIDAndBoundedPreview() {
        let m = manifest("""
        {"tool":"x","rules":[{"state":"working","contains":"esc to interrupt"}]}
        """)
        let long = String(repeating: "pad ", count: 100) + "esc to interrupt"
        let ev = m.classifyEvidence(DetectInput(screen: long))
        XCTAssertEqual(ev.ruleID, "x#0")
        XCTAssertLessThanOrEqual(ev.preview.count, DetectionEvidence.previewLimit)
        // The preview keeps the TAIL — that's where prompts live.
        XCTAssertTrue(ev.preview.hasSuffix("esc to interrupt"))
    }

    // MARK: - Open manifest discovery (WI-2026-08-11-004)

    func testLoaderDiscoveryAndOverridePrecedence() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-detect-\(UUID().uuidString)")
        let bundled = tmp.appendingPathComponent("bundled")
        let override = tmp.appendingPathComponent("override")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try #"{"tool":"cursor","rules":[{"state":"working","contains":"generating"}]}"#
            .write(to: bundled.appendingPathComponent("cursor.json"), atomically: true, encoding: .utf8)
        try #"{"tool":"claude","rules":[{"state":"done","contains":"bundled-claude"}]}"#
            .write(to: bundled.appendingPathComponent("claude.json"), atomically: true, encoding: .utf8)
        try #"{"tool":"claude","rules":[{"state":"done","contains":"override-claude"}]}"#
            .write(to: override.appendingPathComponent("claude.json"), atomically: true, encoding: .utf8)
        // Non-JSON and malformed files are ignored, not fatal.
        try "junk".write(to: bundled.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try "{broken".write(to: override.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        let all = DetectManifestLoader.loadAll(bundledDir: bundled, overrideDir: override)
        XCTAssertEqual(all["cursor"]?.classify("generating tests…"), "working")
        // Override beats bundle for the same tool.
        XCTAssertEqual(all["claude"]?.classify("override-claude here"), "done")
        XCTAssertNil(all["claude"]?.classify("bundled-claude here"))
        XCTAssertNil(all["broken"])
    }

    // MARK: - Hot reload (WI-2026-08-11-003, ADR-0005 as amended)

    func testReloadSemantics() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-reload-\(UUID().uuidString)")
        let bundled = tmp.appendingPathComponent("bundled")
        let override = tmp.appendingPathComponent("override")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let overrideClaude = override.appendingPathComponent("claude.json")

        try #"{"tool":"claude","rules":[{"state":"done","contains":"bundled-marker"}]}"#
            .write(to: bundled.appendingPathComponent("claude.json"), atomically: true, encoding: .utf8)
        try #"{"tool":"claude","rules":[{"state":"working","contains":"v1-marker"}]}"#
            .write(to: overrideClaude, atomically: true, encoding: .utf8)

        var current = DetectManifestLoader.loadAll(bundledDir: bundled, overrideDir: override)
        XCTAssertEqual(current["claude"]?.classify("v1-marker"), "working")

        // Edited override takes effect on reload.
        try #"{"tool":"claude","rules":[{"state":"waiting","contains":"v2-marker"}]}"#
            .write(to: overrideClaude, atomically: true, encoding: .utf8)
        current = DetectManifestLoader.reload(
            previous: current, bundledDir: bundled, overrideDir: override)
        XCTAssertEqual(current["claude"]?.classify("v2-marker"), "waiting")
        XCTAssertNil(current["claude"]?.classify("v1-marker"))

        // Malformed override keeps the PREVIOUS compiled manifest (fail
        // closed — a half-saved file must not flip rules to bundled).
        try "{broken".write(to: overrideClaude, atomically: true, encoding: .utf8)
        current = DetectManifestLoader.reload(
            previous: current, bundledDir: bundled, overrideDir: override)
        XCTAssertEqual(current["claude"]?.classify("v2-marker"), "waiting")
        XCTAssertNil(current["claude"]?.classify("bundled-marker"))

        // Deleted override falls back to the bundled copy.
        try FileManager.default.removeItem(at: overrideClaude)
        current = DetectManifestLoader.reload(
            previous: current, bundledDir: bundled, overrideDir: override)
        XCTAssertEqual(current["claude"]?.classify("bundled-marker"), "done")
        XCTAssertNil(current["claude"]?.classify("v2-marker"))
    }

    func testTopRegion() {
        let m = manifest("""
        {"tool":"grok","rules":[{"state":"working","region":"top(1)","contains":"3 │"}]}
        """)
        XCTAssertEqual(m.classify(DetectInput(screen: "⸬ 3 │ chrome row\nbody\nfooter")), "working")
        // The same text NOT on the first non-empty line does not match.
        XCTAssertNil(m.classify(DetectInput(screen: "chrome row\n3 │ body")))
    }

    // MARK: - Bundled manifests (herdr-calibrated ports)

    func testBundledManifestsDecodeAndClassifyFixtures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
        func load(_ tool: String) throws -> CompiledManifest {
            let url = root.appendingPathComponent("detect/\(tool).json")
            let m = try JSONDecoder().decode(DetectManifest.self, from: Data(contentsOf: url))
            return CompiledManifest(m)
        }

        let claude = try load("claude")
        // Title is the primary working/idle channel.
        XCTAssertEqual(claude.classify(DetectInput(title: "⠧ synapty · writing code", screen: "")), "working")
        XCTAssertEqual(claude.classify(DetectInput(title: "✳ synapty", screen: "")), "done")
        // Permission modal after a horizontal rule → waiting.
        let modal = """
        ● Running…
        ──────────────────────────────
         Do you want to proceed?
         ❯ 1. Yes
           2. No, and tell Claude what to do differently
         esc to cancel
        """
        XCTAssertEqual(claude.classify(DetectInput(screen: modal)), "waiting")
        // Working footer fallback when no title is available.
        XCTAssertEqual(
            claude.classify(DetectInput(screen: "✻ Pondering… (esc to interrupt)")), "working")
        // Idle prompt box → done.
        let idle = """
        ● Done.
        ──────────────────────────────
         ❯
        ──────────────────────────────
          ? for shortcuts
        """
        XCTAssertEqual(claude.classify(DetectInput(screen: idle)), "done")
        // Transcript viewer is recognized-but-uninformative, even when the
        // replayed content contains chrome-looking text.
        let viewer = "Do you want to proceed? (replayed)\nShowing detailed transcript (ctrl+o to toggle)\n ? for shortcuts"
        XCTAssertNil(claude.classify(DetectInput(screen: viewer)))

        let codex = try load("codex")
        XCTAssertEqual(codex.classify(DetectInput(title: "⠙ codex", screen: "")), "working")
        XCTAssertEqual(codex.classify(DetectInput(title: "Action Required — codex", screen: "")), "waiting")
        XCTAssertEqual(codex.classify(DetectInput(title: "codex — ~/proj", screen: "")), "done")
        XCTAssertEqual(
            codex.classify(DetectInput(screen: "• Working (2m 10s · esc to interrupt)")), "working")
        XCTAssertEqual(codex.classify(DetectInput(screen: "Allow command? …")), "waiting")

        let gemini = try load("gemini")
        XCTAssertEqual(gemini.classify(DetectInput(screen: "│ Apply this change? …")), "waiting")
        XCTAssertEqual(gemini.classify(DetectInput(screen: "(esc to cancel)")), "working")
        XCTAssertEqual(gemini.classify(DetectInput(screen: "Type your message")), "done")

        // Spot-checks for three of the newly ported tools (WI-2026-08-11-004).
        let grok = try load("grok")
        XCTAssertEqual(grok.classify(DetectInput(title: "⚠ Action Required — grok", screen: "")), "waiting")
        XCTAssertEqual(grok.classify(DetectInput(title: "synapty - grok", screen: "")), "done")
        XCTAssertEqual(
            grok.classify(DetectInput(screen: "⠧ Waiting on subagent… 2.8s   13s ⇣29.7k [stop]")),
            "working")

        let cursor = try load("cursor")
        XCTAssertEqual(
            cursor.classify(DetectInput(screen: "Waiting for approval\nRun this command?\n run (once) (y)")),
            "waiting")
        XCTAssertEqual(cursor.classify(DetectInput(screen: "thinking…\nctrl+c to stop")), "working")

        let opencode = try load("opencode")
        XCTAssertEqual(opencode.classify(DetectInput(screen: "△ Permission required")), "waiting")
        XCTAssertEqual(opencode.classify(DetectInput(screen: "working… esc to interrupt")), "working")
    }

    // MARK: - Generation plumbing

    func testSnapshotAndRegisteredEventCarryGeneration() {
        let infos = AgentMonitor.agentInfos(from: [
            ["id": "a1", "tool": "claude", "project": "p", "session": "s", "status": "working", "generation": 7],
        ])
        XCTAssertEqual(infos.first?.generation, 7)

        let ev: [String: Any] = ["kind": "agent_registered", "agent": "a2", "generation": 9, "tool": "codex"]
        let out = AgentMonitor.applying(event: ev, to: [])
        XCTAssertEqual(out?.first?.generation, 9)
    }

    /// The shipped cline manifest must be INERT on an ordinary screen.
    ///
    /// It was the only manifest with a catch-all — `(?s).+` mapped to
    /// state `working` — because the herdr rule it was ported from is
    /// scoped to `whole_recent` and this engine has no recency-scoped
    /// region. Unscoped, it matches any non-empty terminal, so a cline
    /// pane read `working` for as long as it existed (WI-2026-08-14-005).
    /// Reading the SHIPPED file rather than an inline copy is the point:
    /// an inline manifest would still pass if the real one regressed.
    func testShippedClineManifestIsInertWithoutEvidence() throws {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("detect/cline.json"),
            let data = try? Data(contentsOf: url)
        else { throw XCTSkip("detect/cline.json is not in this bundle") }

        let m = CompiledManifest(try JSONDecoder().decode(DetectManifest.self, from: data))
        XCTAssertNil(
            m.classify("$ ls\nREADME.md  src\n$ "),
            "an ordinary shell screen must assert nothing")
        XCTAssertNil(m.classify("cline v3.2.1\nready\n"), "an idle cline must assert nothing")
        // The evidence-bearing rules still fire.
        XCTAssertEqual(m.classify("Cline wants to run a command\nLet Cline use this tool?"), "waiting")
    }
}
