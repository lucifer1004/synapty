import Foundation
import os

/// Whether the human is mid-command in the pane a resume is about to be
/// typed into ([[RFC-0006]] C-RESUME-RESTORE, [[WI-2026-08-27-001]]).
///
/// A PURE FUNCTION FOR THE SAME REASON [[WakeGate]] IS ONE: the caller is
/// machinery with no judgement at the moment it acts, and a rule that can
/// be read on its own is a rule that can be shown to be right.
enum ResumeGate {
    /// THE SAME WINDOW C-STATE-GATE ALREADY ASKED FOR, taken from
    /// [[WakeGate]] rather than restated. Two paths typing into one pane
    /// with two ideas of "recently" is how one of them becomes wrong
    /// without anyone editing it.
    static var humanBackoff: TimeInterval { WakeGate.humanBackoff }

    /// nil means the human has never typed into this pane, which is the
    /// ordinary case for a restored one — reading an absent timestamp as
    /// "just now" would refuse every offer this feature exists to make.
    static func mayType(secondsSinceHumanInput: TimeInterval?) -> Bool {
        guard let since = secondsSinceHumanInput else { return true }
        return since > humanBackoff
    }
}

// MARK: - Per-tool lifecycle specs per [[RFC-0006]] (data, not code)

/// One tool's resume template. Extending
/// the fleet is a data change — same discipline as detection manifests
/// (bundled defaults + user override).
struct ToolLifecycleSpec: Codable, Equatable {
    var tool: String
    /// argv template for resume; the "{resume_ref}" element is
    /// substituted after allowlist validation (C-RESUME-PLAN: template
    /// application is substitution from a fixed field set only).
    var resumeArgv: [String]?
}

enum LifecycleSpecLoader {
    static var defaultOverrideDir: URL {
        // Through the classification, so a redirected root takes the
        // specs with it ([[ConfigPaths]], [[WI-2026-08-30-004]]).
        ConfigPaths.lifecycle
    }

    static var defaultBundledDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("lifecycle")
    }

    static func loadAll(
        bundledDir: URL? = defaultBundledDir,
        overrideDir: URL = defaultOverrideDir
    ) -> [String: ToolLifecycleSpec] {
        var specs: [String: ToolLifecycleSpec] = [:]
        // Bundle first, then overrides — later wins per tool key.
        for dir in [bundledDir, overrideDir].compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let spec = try? JSONDecoder().decode(ToolLifecycleSpec.self, from: data)
                else { continue }
                specs[spec.tool] = spec
            }
        }
        return specs
    }
}

// MARK: - Plan composition (pure, testable)

enum ResumePlanComposer {
    /// Compose a plan from live facts. resume_ref goes through the
    /// C-RESUME-PLAN allowlist; missing/invalid/no-template degrades the
    /// plan to launch-fresh (incantation nil) — honesty over pretense.
    static func compose(
        tool: String, resumeRef: String?, cwd: String?, host: String?,
        spec: ToolLifecycleSpec?
    ) -> ResumePlan {
        var plan = ResumePlan(tool: tool, cwd: cwd, host: host)
        guard let raw = resumeRef,
              let valid = ResumeRefValidator.validate(raw),
              let template = spec?.resumeArgv, !template.isEmpty
        else { return plan }
        plan.resumeRef = valid
        let argv = template.map { $0 == "{resume_ref}" ? valid : $0 }
        let line = argv.joined(separator: " ")
        // C-RESUME-PLAN: the composed incantation MUST be a single line.
        guard !line.contains("\n"), !line.contains("\r") else { return plan }
        plan.incantation = line
        return plan
    }
}

// MARK: - Resume coordinator (plans + restore engine)

/// Owns resume plans keyed by LEAF, records them from registration
/// events while agents are alive, persists them via the session
/// snapshot, and hands them to the ONE act that may use them: a human's
/// click on a pane that has already been reported as restarted.
///
/// NOTHING HERE FIRES BY ITSELF ([[RFC-0006]] C-RESUME-RESTORE, as
/// amended). Auto-resume's whole safety argument was that an incantation
/// 'only re-attaches the harness' — which was never a property of the
/// incantation, but of the incantation AND what receives it. At a shell
/// prompt `claude --resume <id>` re-attaches; typed into a claude that is
/// already running it is a PROMPT. Before [[RFC-0014]] a workbench
/// restart implied a dead child, so the receiving state was guaranteed;
/// with holders a restored pane rejoins a child that never stopped, and
/// the guarantee is gone.
///
/// A MACHINE RESTART WAS THE WORST CASE, not the harmless one: every
/// holder gone, every pane restarted, every plan firing at once — a turn
/// per agent, started while nobody is at the machine.
@MainActor @Observable final class ResumeCoordinator {
    private weak var paneManager: WorkspaceManager?
    private var specs: [String: ToolLifecycleSpec] = [:]
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "synapty", category: "lifecycle")

    /// Plans by leaf. Drop triggers are OBSERVABLE only: pane close
    /// (onLeafClosed) — never connection loss or shutdown
    /// (C-RESUME-PLAN).
    private(set) var plans: [UUID: ResumePlan] = [:]



    func start(paneManager: WorkspaceManager) {
        self.paneManager = paneManager
        if specs.isEmpty { specs = LifecycleSpecLoader.loadAll() }
        paneManager.onLeafClosed = { [weak self] leafID in
            self?.plans.removeValue(forKey: leafID)
        }
    }

    func spec(for tool: String) -> ToolLifecycleSpec? { specs[tool] }

    /// Record/refresh the plan for a registration event (wired to
    /// AgentMonitor.onHubEvent). Captured while the agent is alive —
    /// later connection loss cannot erase it.
    func handleHubEvent(_ payload: [String: Any]) {
        guard let kind = payload["kind"] as? String, kind == "agent_registered",
              let agentID = payload["agent"] as? String,
              let tool = payload["tool"] as? String, tool != "-", tool != "human",
              let paneManager,
              let leafID = paneManager.leafID(forAgent: agentID)
        else { return }
        plans[leafID] = ResumePlanComposer.compose(
            tool: tool,
            resumeRef: payload["resume_ref"] as? String,
            cwd: paneManager.pwd(ofLeaf: leafID),
            // The leaf's own machine ([[RFC-0015]] C-LEAF-BINDING): a
            // resume plan records where the agent WAS, and the container
            // it sat in is not that.
            host: paneManager.host(ofLeaf: leafID)?.label,
            spec: specs[tool])
    }

    // MARK: - The human's own act ([[RFC-0006]] C-RESUME-RESTORE)

    /// Type the incantation, once, because the human asked.
    ///
    /// WHAT MAY BE TYPED IS THE LEAF'S CAPTURED OFFER, not this
    /// coordinator's live plans, and the difference is the whole safety
    /// argument. `plans` is composed from `agent_registered`, so every
    /// entry in it describes a harness that was alive in that pane at the
    /// moment it was written; reading it here would type the live
    /// session's own id back into the live session. The leaf's offer is
    /// fixed when the notice goes up and nilled by any registration
    /// ([[LeafFacts]]), so "there is something to type" and "an agent
    /// registered here" cannot both hold ([[RFC-0014]] C-LIVE-CHILD).
    ///
    /// The affordance is still the condition rather than a check made
    /// here: a check can be skipped, defaulted the wrong way on a
    /// timeout, or forgotten by the next caller, and this reads the same
    /// value the button was drawn from.
    ///
    /// WHETHER THIS MOMENT IS SAFE IS A DIFFERENT QUESTION, and it is
    /// checked here because no affordance can answer it. The offer being
    /// on screen says the agent is gone; it says nothing about whether
    /// the human has half a command on the line right now, and the
    /// incantation lands in the middle of it — `make bui` becomes
    /// `make buiclaude --resume <id>`, and C-RESUME-RESTORE's one attempt
    /// is spent on the way out. Both other paths that type into a pane
    /// already consult this window.
    func resumeNow(leafID: UUID) {
        guard let incantation = paneManager?.rejoinOffer(leafID)?.incantation,
              let surface = GhosttyApp.shared?.surface(forLeaf: leafID) else { return }
        guard ResumeGate.mayType(
            secondsSinceHumanInput: GhosttyApp.shared?.secondsSinceHumanInput(forLeaf: leafID)
        ) else {
            // THE OFFER SURVIVES. Nothing was attempted, so nothing was
            // spent: "one attempt per act of the human's" counts attempts,
            // and this is a refusal to make one.
            Self.log.info(
                "resume held for \(leafID, privacy: .public): the human is typing in that pane")
            return
        }
        WakeInjector.type(incantation, into: surface)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(WakeInjector.enterDelay * 1_000_000_000))
            if let live = GhosttyApp.shared?.surface(forLeaf: leafID) {
                WakeInjector.pressEnter(live)
            }
        }
        Self.log.info("resume typed for \(leafID, privacy: .public) at the human\'s request")
    }

}
