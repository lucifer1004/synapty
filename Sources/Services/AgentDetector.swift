import Foundation
import AppKit
import os

// MARK: - Manifests (ADR-0005)

/// Classifier input: the pane's OSC title plus the active-screen tail —
/// the two rule surfaces C-PASSIVE-DETECTION names ("the read region
/// plus the OSC title").
struct DetectInput {
    var title: String = ""
    var screen: String = ""
}

/// One declarative classification rule (schema v2, WI-2026-08-11-001;
/// rule design ported from herdr's battle-tested manifests, Apache-2.0).
///
/// `state`: working|waiting|done (RFC-0004 C-OWNERSHIP passive set) or
/// "skip" — recognized-but-uninformative UI (e.g. the transcript viewer)
/// that halts evaluation without asserting anything. Other states are
/// dropped at compile.
///
/// `region` selects the text the rule sees (default "screen"):
///   title       — the pane's OSC title
///   screen      — the active-screen tail
///   after_rule  — text after the last full-width ─ horizontal rule
///                 (where claude renders modals)
///   prompt_box  — the ❯ input-box body between its two border rules
///   bottom(N)   — the last N non-empty screen lines
///
/// Positive conditions (a rule needs at least one; ALL specified must
/// hold): `contains` (one substring), `all` (every substring), `any`
/// (at least one substring), `regex`, `lineRegex` (regex with per-line
/// ^/$ anchors). Negative vetoes: `not` (substrings), `notRegex`.
/// The contains family is case-insensitive; regexes are as written.
struct DetectRule: Decodable {
    let id: String?
    let state: String
    let region: String?
    let contains: String?
    let all: [String]?
    let any: [String]?
    let regex: String?
    let lineRegex: String?
    let not: [String]?
    let notRegex: [String]?
}

/// Evidence of one classification pass — which rule fired, on what text.
/// LOCAL DIAGNOSTICS ONLY: the preview is screen text, which
/// C-PASSIVE-DETECTION forbids forwarding — evidence must never cross
/// the hub boundary or ride any signal.
struct DetectionEvidence: Equatable {
    enum Outcome: Equatable {
        case state(String)   // a passive state was proposed
        case skip            // a skip rule recognized uninformative UI
        case noMatch         // no rule matched
    }
    let outcome: Outcome
    let ruleID: String?      // nil only for noMatch
    let region: String?      // region name of the matched rule
    /// Bounded TAIL of the text the matched rule saw (prompts live at
    /// the bottom); for noMatch, the tail of the screen itself.
    let preview: String

    static let previewLimit = 160

    static func boundedPreview(_ text: String) -> String {
        String(text.suffix(previewLimit))
    }
}

/// A per-tool manifest: ordered rules, first match wins.
struct DetectManifest: Decodable {
    let tool: String
    let rules: [DetectRule]
}

/// Compiled manifest — pure matcher over pane text. The classifier's
/// ONLY output is a state string from the passive set: screen text is
/// untrusted input and must never be forwarded or interpreted beyond
/// this enum-like classification (RFC-0004 C-PASSIVE-DETECTION).
struct CompiledManifest {
    let tool: String

    /// Passive-proposable states only (RFC-0004 C-OWNERSHIP). "skip" is
    /// additionally accepted at compile but never leaves the classifier.
    static let passiveStates: Set<String> = ["working", "waiting", "done"]

    private enum Region {
        case title, screen, afterRule, promptBox
        case bottom(Int)
        case top(Int)

        init?(_ raw: String?) {
            switch raw {
            case nil, "screen": self = .screen
            case "title": self = .title
            case "after_rule": self = .afterRule
            case "prompt_box": self = .promptBox
            default:
                guard let raw else { return nil }
                if raw.hasPrefix("bottom("), raw.hasSuffix(")"),
                   let n = Int(raw.dropFirst(7).dropLast()), n > 0 {
                    self = .bottom(n)
                } else if raw.hasPrefix("top("), raw.hasSuffix(")"),
                          let n = Int(raw.dropFirst(4).dropLast()), n > 0 {
                    self = .top(n)
                } else {
                    return nil
                }
            }
        }
    }

    private struct Rule {
        let id: String
        let state: String
        let region: Region
        let regionName: String
        let allNeedles: [String]   // lowercased; every one must appear
        let anyNeedles: [String]   // lowercased; at least one must appear
        let regexes: [NSRegularExpression]
        let notNeedles: [String]
        let notRegexes: [NSRegularExpression]

        func matches(_ text: String) -> Bool {
            let lower = text.lowercased()
            for needle in allNeedles where !lower.contains(needle) { return false }
            if !anyNeedles.isEmpty, !anyNeedles.contains(where: { lower.contains($0) }) {
                return false
            }
            for re in regexes where !Self.hits(re, text) { return false }
            for needle in notNeedles where lower.contains(needle) { return false }
            for re in notRegexes where Self.hits(re, text) { return false }
            return true
        }

        private static func hits(_ re: NSRegularExpression, _ text: String) -> Bool {
            re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    private let rules: [Rule]

    init(_ manifest: DetectManifest) {
        self.tool = manifest.tool
        var out: [Rule] = []
        for (index, rule) in manifest.rules.enumerated() {
            guard Self.passiveStates.contains(rule.state) || rule.state == "skip",
                  let region = Region(rule.region)
            else { continue }

            var allNeedles = (rule.all ?? []).map { $0.lowercased() }
            if let one = rule.contains, !one.isEmpty { allNeedles.append(one.lowercased()) }
            let anyNeedles = (rule.any ?? []).compactMap { $0.isEmpty ? nil : $0.lowercased() }

            var regexes: [NSRegularExpression] = []
            var invalid = false
            if let pattern = rule.regex {
                if let re = try? NSRegularExpression(pattern: pattern) { regexes.append(re) }
                else { invalid = true }
            }
            if let pattern = rule.lineRegex {
                if let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                    regexes.append(re)
                } else { invalid = true }
            }
            var notRegexes: [NSRegularExpression] = []
            for pattern in rule.notRegex ?? [] {
                if let re = try? NSRegularExpression(pattern: pattern) { notRegexes.append(re) }
                else { invalid = true }
            }
            // An invalid regex or a rule with no positive condition is
            // dropped — a broken rule must fail closed, not match wide.
            guard !invalid,
                  !allNeedles.isEmpty || !anyNeedles.isEmpty || !regexes.isEmpty
            else { continue }

            out.append(Rule(
                id: rule.id ?? "\(manifest.tool)#\(index)",
                state: rule.state, region: region,
                regionName: rule.region ?? "screen",
                allNeedles: allNeedles, anyNeedles: anyNeedles, regexes: regexes,
                notNeedles: (rule.not ?? []).map { $0.lowercased() },
                notRegexes: notRegexes))
        }
        self.rules = out
    }

    /// First matching rule wins; a "skip" match halts with nil; no match
    /// returns nil (inert — C-PRECEDENCE rule 5: absence of evidence is
    /// not evidence of absence).
    func classify(_ input: DetectInput) -> String? {
        if case .state(let s) = classifyEvidence(input).outcome { return s }
        return nil
    }

    /// Classification with full match evidence (WI-2026-08-11-002).
    func classifyEvidence(_ input: DetectInput) -> DetectionEvidence {
        let afterRule = Self.afterLastHorizontalRule(input.screen)
        let promptBox = Self.promptBoxBody(input.screen)
        for rule in rules {
            let text: String?
            switch rule.region {
            case .title: text = input.title
            case .screen: text = input.screen
            case .afterRule: text = afterRule
            case .promptBox: text = promptBox
            case .bottom(let n): text = Self.bottomNonEmptyLines(input.screen, n)
            case .top(let n): text = Self.topNonEmptyLines(input.screen, n)
            }
            guard let text, rule.matches(text) else { continue }
            return DetectionEvidence(
                outcome: rule.state == "skip" ? .skip : .state(rule.state),
                ruleID: rule.id, region: rule.regionName,
                preview: DetectionEvidence.boundedPreview(text))
        }
        return DetectionEvidence(
            outcome: .noMatch, ruleID: nil, region: nil,
            preview: DetectionEvidence.boundedPreview(input.screen))
    }

    /// Screen-only convenience (v1 manifests and tests).
    func classify(_ screen: String) -> String? {
        classify(DetectInput(screen: screen))
    }

    // MARK: Structural region parsers (ported from herdr, Apache-2.0)

    /// A full-width ─ horizontal rule line: leading ─ run, then either
    /// nothing (a short pure rule) or ≥3 rule chars (rule with a label).
    /// Box borders (╭─╮) do NOT count — they start with a corner char.
    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let ruleChars = trimmed.prefix(while: { $0 == "─" }).count
        guard ruleChars > 0 else { return false }
        let suffix = trimmed.dropFirst(ruleChars).drop(while: { $0 == " " || $0 == "\t" })
        return suffix.isEmpty || ruleChars >= 3
    }

    /// Text after the last horizontal rule — where claude renders live
    /// modals. No rule on screen → the whole content.
    static func afterLastHorizontalRule(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var lastRule: Int? = nil
        for (i, line) in lines.enumerated() where isHorizontalRule(line) { lastRule = i }
        guard let lastRule else { return content }
        return lines[(lastRule + 1)...].joined(separator: "\n")
    }

    /// Body of the ❯ input box: the lines between the second horizontal
    /// rule from the bottom (top border) and the next rule below it.
    /// Fewer than two rules on screen → nil (region inapplicable).
    static func promptBoxBody(_ content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        var borderCount = 0
        var top: Int? = nil
        for i in stride(from: lines.count - 1, through: 0, by: -1) where isHorizontalRule(lines[i]) {
            borderCount += 1
            if borderCount == 2 { top = i; break }
        }
        guard let top else { return nil }
        var body: [String] = []
        for line in lines[(top + 1)...] {
            if isHorizontalRule(line) { break }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    /// The last `n` non-empty lines, joined.
    static func bottomNonEmptyLines(_ content: String, _ n: Int) -> String {
        content.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(n)
            .joined(separator: "\n")
    }

    /// The first `n` non-empty lines, joined (pinned app chrome — e.g.
    /// grok's background-task chip lives on the top row).
    static func topNonEmptyLines(_ content: String, _ n: Int) -> String {
        content.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(n)
            .joined(separator: "\n")
    }
}

/// Manifest discovery: every *.json in the bundled detect/ dir plus the
/// user override dir (~/.config/synapty/detect/), keyed by the
/// manifest's own "tool" field — override beats bundle per tool
/// (WI-2026-08-11-004: adding a CLI is a data change, not a code
/// change). The override dir hot-reloads (ADR-0005 as amended
/// 2026-08-11); bundled copies load once at launch.
enum DetectManifestLoader {
    static var defaultOverrideDir: URL {
        // Through the classification, so a redirected root takes the
        // manifests with it ([[ConfigPaths]], [[WI-2026-08-30-004]]).
        ConfigPaths.detect
    }

    static var defaultBundledDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("detect")
    }

    static func loadAll(
        bundledDir: URL? = defaultBundledDir,
        overrideDir: URL = defaultOverrideDir
    ) -> [String: CompiledManifest] {
        loadAllReporting(bundledDir: bundledDir, overrideDir: overrideDir).manifests
    }

    struct LoadResult {
        var manifests: [String: CompiledManifest] = [:]
        /// Filename stems of override *.json files that failed to decode.
        var failedOverrideStems: [String] = []
    }

    static func loadAllReporting(
        bundledDir: URL? = defaultBundledDir,
        overrideDir: URL = defaultOverrideDir
    ) -> LoadResult {
        var result = LoadResult()
        // Bundle first, then overrides — later wins per tool key.
        for dir in [bundledDir, overrideDir].compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let manifest = try? JSONDecoder().decode(DetectManifest.self, from: data) {
                    result.manifests[manifest.tool] = CompiledManifest(manifest)
                } else if dir == overrideDir {
                    result.failedOverrideStems.append(url.deletingPathExtension().lastPathComponent)
                }
                // Malformed bundled files are ignored, not fatal.
            }
        }
        return result
    }

    /// Hot-reload step (ADR-0005 as amended): rescan both dirs, but a
    /// MALFORMED override keeps the previous compiled manifest for its
    /// tool (filename-stem convention <tool>.json) — a half-saved edit
    /// must fail closed, not silently flip rules back to the bundled
    /// copy. A DELETED override genuinely falls back to bundled.
    static func reload(
        previous: [String: CompiledManifest],
        bundledDir: URL? = defaultBundledDir,
        overrideDir: URL = defaultOverrideDir
    ) -> [String: CompiledManifest] {
        let fresh = loadAllReporting(bundledDir: bundledDir, overrideDir: overrideDir)
        var out = fresh.manifests
        for stem in fresh.failedOverrideStems {
            if let kept = previous[stem] { out[stem] = kept }
        }
        return out
    }
}

// MARK: - Edge tracking (RFC-0004 C-PRECEDENCE rule 2)

/// Edge-triggered emission: a signal fires only when the classification
/// CHANGES from the detector's own previous classification of that agent.
/// The first classification of a never-classified agent is an edge, and
/// memory is scoped to the registration generation — a new occupant's
/// first state is an edge even if it matches the previous occupant's
/// last. No-match (nil) is inert and leaves memory untouched, so an
/// unchanged completion banner can never re-assert itself.
struct DetectionEdgeTracker {
    private var last: [String: (generation: UInt64, state: String)] = [:]

    mutating func edge(agent: String, generation: UInt64, classification: String?) -> String? {
        guard let classification else { return nil }
        if let prev = last[agent], prev.generation == generation, prev.state == classification {
            return nil
        }
        last[agent] = (generation, classification)
        return classification
    }

    mutating func forget(agent: String) {
        last.removeValue(forKey: agent)
    }
}

// MARK: - Detector service

/// Samples every agent-bearing pane's screen every ~2s, classifies it
/// with the tool's manifest, and submits classification EDGES to the hub
/// as passive signals (RFC-0004 C-PASSIVE-DETECTION; locus per ADR-0005).
/// The read targets the final rows of the ACTIVE screen — never the
/// user's scrolled viewport. Reads are local memory only; hub traffic
/// happens exclusively on edges.
@MainActor @Observable final class AgentDetector {
    private weak var paneManager: WorkspaceManager?
    private weak var agentMonitor: AgentMonitor?
    private var port: Int = 9000
    private var timer: Timer?
    private var tracker = DetectionEdgeTracker()
    private var manifests: [String: CompiledManifest] = [:]
    /// Lifecycle-unknown already sent, keyed "agent#generation" — the
    /// process-exit signal fires once per registration.
    private var lifecycleSent: Set<String> = []
    static let lifecycleSentKept = 1000
    /// Last classification evidence per agent — LOCAL diagnostics only
    /// (WI-2026-08-11-002); never forwarded (C-PASSIVE-DETECTION).
    private(set) var lastEvidence: [String: DetectionEvidence] = [:]
    /// Override-directory watcher (WI-2026-08-11-003, ADR-0005 as
    /// amended): rule edits take effect without an app restart.
    private var overrideWatch: DispatchSourceFileSystemObject?
    /// Local-only diagnostic log; previews carry screen text, so they
    /// log at .private privacy (redacted unless the device opts in).
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "synapty", category: "detect")

    /// Rows of the active screen the classifier sees. 40 (up from 15)
    /// so the structural regions (prompt box, last horizontal rule) have
    /// their anchors in view; still the final rows of the ACTIVE screen
    /// per C-PASSIVE-DETECTION.
    static let readRows: UInt32 = 40
    /// Sampling cadence (RFC-0004 C-PASSIVE-DETECTION: SHOULD ~2s).
    static let interval: TimeInterval = 2.0

    func start(paneManager: WorkspaceManager, agentMonitor: AgentMonitor, port: Int) {
        self.paneManager = paneManager
        self.agentMonitor = agentMonitor
        self.port = port
        if manifests.isEmpty {
            manifests = DetectManifestLoader.loadAll()
        }
        startWatchingOverrides()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        overrideWatch?.cancel()
        overrideWatch = nil
    }

    /// Watch ~/.config/synapty/detect/ for rule edits. Limitation: if the
    /// directory does not exist at start, creating it later needs an app
    /// restart to be noticed (we do not watch the parent).
    private func startWatchingOverrides() {
        overrideWatch?.cancel()
        overrideWatch = nil
        let dir = DetectManifestLoader.defaultOverrideDir
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.reloadManifests() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        overrideWatch = source
    }

    /// Swap compiled manifests atomically and reset edge memory: a rule
    /// change is a new observer, so its first classification is a
    /// legitimate edge (the hub's acceptance rules absorb duplicates).
    func reloadManifests() {
        manifests = DetectManifestLoader.reload(previous: manifests)
        tracker = DetectionEdgeTracker()
        lastEvidence = [:]
        Self.log.debug("manifests hot-reloaded (\(self.manifests.count, privacy: .public) tools)")
    }

    private func sample() {
        guard let paneManager, let agentMonitor else { return }
        for (leafID, leaf) in paneManager.facts {
            guard let agentID = leaf.agent else { continue }
            guard let info = agentMonitor.agents.first(where: { $0.id == agentID }),
                  let manifest = manifests[info.tool.rawValue],
                  let surface = GhosttyApp.shared?.surface(forLeaf: leafID)
            else { continue }

            // Pane process gone → lifecycle unknown, once per generation
            // (RFC-0004 C-OWNERSHIP lifecycle signal class).
            if ghostty_surface_process_exited(surface) {
                let key = "\(agentID)#\(info.generation)"
                if !lifecycleSent.contains(key) {
                    // A dedupe set keyed by generation; a generation that
                    // is long gone will not be asked about again, so the
                    // set is emptied rather than kept forever
                    // ([[WI-2026-09-02-034]]).
                    if lifecycleSent.count >= Self.lifecycleSentKept { lifecycleSent.removeAll() }
                    lifecycleSent.insert(key)
                    tracker.forget(agent: agentID)
                    HubEventClient.sendStatusSignal(
                        port: port, agent: agentID, state: "unknown", signalClass: "lifecycle")
                }
                continue
            }

            guard let text = Self.readBottomRows(surface: surface) else { continue }
            let input = DetectInput(
                title: paneManager.reportedTitle(ofLeaf: leafID) ?? "", screen: text)
            let evidence = manifest.classifyEvidence(input)
            if evidence != lastEvidence[agentID] {
                Self.log.debug("""
                agent=\(agentID, privacy: .public) tool=\(manifest.tool, privacy: .public) \
                outcome=\(String(describing: evidence.outcome), privacy: .public) \
                rule=\(evidence.ruleID ?? "-", privacy: .public) \
                region=\(evidence.region ?? "-", privacy: .public) \
                preview=\(evidence.preview, privacy: .private)
                """)
            }
            lastEvidence[agentID] = evidence
            let classification: String? =
                if case .state(let s) = evidence.outcome { s } else { nil }
            if let edge = tracker.edge(
                agent: agentID, generation: info.generation, classification: classification)
            {
                HubEventClient.sendStatusSignal(
                    port: port, agent: agentID, state: edge, signalClass: "passive")
            }
        }
    }

    /// One targeted, fresh classification for the wake gate (RFC-0005
    /// C-STATE-GATE: the status used for the gate decision MUST be
    /// re-derived immediately before injection, never a cached sample).
    /// nil when the pane, surface, manifest, or match is missing —
    /// "cannot see clearly → do not act".
    func freshClassification(agentID: String) -> String? {
        guard let paneManager, let agentMonitor,
              let leafID = paneManager.leafID(forAgent: agentID),
              let info = agentMonitor.agents.first(where: { $0.id == agentID }),
              let manifest = manifests[info.tool.rawValue],
              let surface = GhosttyApp.shared?.surface(forLeaf: leafID),
              !ghostty_surface_process_exited(surface),
              let text = Self.readBottomRows(surface: surface)
        else { return nil }
        return manifest.classify(
            DetectInput(title: paneManager.reportedTitle(ofLeaf: leafID) ?? "", screen: text))
    }

    /// Last `rows` lines that actually CARRY CONTENT, for exec read /
    /// wait-output (RFC-0007 C-PRIMITIVES).
    ///
    /// Why this exists instead of readBottomRows: that helper reads a
    /// fixed bottom-anchored window of the active screen, which suits
    /// harnesses (Claude Code and friends render their prompt box at the
    /// bottom). A freshly spawned shell prints at the TOP of a tall pane,
    /// so the bottom-40 window is pure blank space — the first armed
    /// exec smoke showed a command visibly execute while read returned ""
    /// and wait-output matched nothing. Read the whole screen, drop the
    /// trailing blanks, then take the tail.
    static func readScreenTail(surface: ghostty_surface_t, rows: Int) -> String? {
        guard let full = readBottomRows(surface: surface, rows: .max) else { return nil }
        return tailLines(full, rows: rows)
    }

    /// Pure tail extraction (unit-testable half of readScreenTail).
    nonisolated static func tailLines(_ text: String, rows: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if rows > 0, lines.count > rows {
            lines = Array(lines.suffix(rows))
        }
        return lines.joined(separator: "\n")
    }

    /// Read the final rows of the ACTIVE screen (screen-not-viewport:
    /// GHOSTTY_POINT_ACTIVE coordinates are unaffected by scrollback).
    /// `rows: .max` reads the whole active screen.
    static func readBottomRows(surface: ghostty_surface_t, rows: UInt32 = AgentDetector.readRows) -> String? {
        let size = ghostty_surface_size(surface)
        guard size.rows > 0, size.columns > 0 else { return nil }
        let total = UInt32(size.rows)
        let startY = total > rows ? total - rows : 0
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: startY),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(size.columns) - 1, y: total - 1),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer {
            withUnsafeMutablePointer(to: &text) { ghostty_surface_free_text(surface, $0) }
        }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        let buffer = UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len))
        return String(decoding: buffer, as: UTF8.self)
    }
}
