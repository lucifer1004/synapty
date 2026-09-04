import SwiftUI

/// Hub service popover — anchored to the status-bar Hub item
/// (WI-2026-08-09-007). The A2A router is plumbing, not a workspace:
/// its status and its connected agents live here instead of on a
/// first-class page (the log is Console's and `just hub-log`'s).
struct HubStatusPopover: View {
    var hubManager: HubManager
    var agentMonitor: AgentMonitor
    /// RFC-0007 exec arming (WI-2026-08-11-015): the ONE per-session
    /// switch. Optional so existing call sites stay valid.
    var execController: ExecController? = nil
    /// Optional so existing call sites stay valid; supplies the
    /// gave-up-retrying state for peers (WI-2026-08-12-010).
    var tunnelManager: TunnelManager? = nil
    /// iCloud config sync (WI-2026-08-13-005). Optional so every existing
    /// construction site keeps compiling with sync simply absent.
    var syncMonitor: SyncMonitor? = nil

    var body: some View {
        // WHAT THE CHIP COUNTS, AND THEN WHAT IS WRONG. The chip reads
        // "Hub: N agents", which is a count and therefore an invitation;
        // this used to open a problem list that never mentioned an agent,
        // so the number and the destination were about different things
        // ([[WI-2026-08-29-003]]). The sidebar does not answer it either:
        // it shows WORKSPACES and, under Elsewhere, only the remote agents
        // no pane here is showing.
        //
        // STILL NOTHING DURABLE. A popover dismisses when you look away,
        // so this is a look and not a control surface: exec arming stays
        // in Settings and on the status bar ([[RFC-0007]] C-EXEC-AUTHORITY
        // needs a standing grant to be standing), logs are Console and
        // `just hub-log`, and Stop/Restart is absent because restarting
        // severs A2A for every agent on this machine. A list of who is
        // registered is not state anyone loses by looking away.
        //
        // AND THE ROWS DO NOT PRETEND TO BE BUTTONS. A local agent is
        // reached by its pane and a remote one from the sidebar; a row
        // here that looked tappable and did nothing is the failure the
        // Elsewhere list already guards against.
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if !agentMonitor.agents.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    DSSectionLabel(text: "Agents", count: agentMonitor.agents.count)
                    ForEach(registered, id: \.id) { agent in
                        HStack(spacing: DS.Space.sm) {
                            DSStatusDot(color: agent.statusColor, size: 6)
                            Image(systemName: agent.tool.sfSymbol)
                                .font(DS.Icon.mark)
                                .foregroundStyle(DS.textTertiary)
                                .frame(width: DS.scaled(14))
                            Text(agent.bareID)
                                .font(DS.Typography.detail)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: DS.Space.sm)
                            // WHERE, and "this Mac" said out loud. An empty
                            // machine is this one, and leaving the column
                            // blank would read as "unknown" — which is a
                            // different fact ([[RFC-0010]] C-DIAGNOSABILITY).
                            Text(agent.machine.isEmpty ? "this Mac" : agent.machine)
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !problems.isEmpty { DSHairline() }
            }
            if problems.isEmpty {
                HStack(spacing: DS.Space.sm) {
                    DSStatusDot(color: DS.success, size: 7)
                    Text("Hub running on port \(hubManager.boundPort.map(String.init) ?? "—")")
                        .font(DS.Typography.body)
                }
            } else {
                ForEach(problems, id: \.message) { problem in
                    HStack(alignment: .top, spacing: DS.Space.sm) {
                        DSStatusDot(color: problem.isFailure ? DS.danger : DS.warning, size: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.message)
                                .font(DS.Typography.body)
                                .fixedSize(horizontal: false, vertical: true)
                            if let action = problem.action {
                                Button(action.label, action: action.perform)
                                    .controlSize(.small)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(problem.message)
                }
            }
        }
        .padding(DS.Space.lg)
        .frame(minWidth: 320, maxWidth: 420, alignment: .leading)
    }

    /// The agents the chip counts, in a fixed order: this machine first,
    /// then by machine and name. A list that reorders itself between two
    /// looks is one nobody can read.
    private var registered: [AgentInfo] { Self.registered(agentMonitor.agents) }

    /// THIS MACHINE FIRST, then by machine and name — and the first of
    /// those needs no clause of its own: an agent here carries an EMPTY
    /// machine, and the empty string sorts before every name. A comparison
    /// that cannot change an outcome is one the next reader has to work
    /// out anyway, so it is not written.
    static func registered(_ agents: [AgentInfo]) -> [AgentInfo] {
        agents.sorted {
            if $0.machine != $1.machine { return $0.machine < $1.machine }
            return $0.bareID < $1.bareID
        }
    }

    // MARK: - Problems

    struct Problem {
        let message: String
        let isFailure: Bool
        var action: (label: String, perform: () -> Void)?
    }

    /// Only what is wrong RIGHT NOW. Anything that is working contributes
    /// nothing — a capability that works is invisible by working
    /// ([[RFC-0010]] C-DIAGNOSABILITY), and chrome that says "everything
    /// is fine" trains people to stop reading it.
    private var problems: [Problem] {
        var out: [Problem] = []

        switch hubManager.status {
        case .lost(let why, let attempt):
            out.append(Problem(
                message: "The hub went away: \(why). Restarting (attempt \(attempt + 1) of \(HubManager.recoveryAttempts))…",
                isFailure: false,
                action: ("Restart now", { hubManager.restartNow() })))
        case .running:
            break
        case .conflict(let why):
            // NO "START" BUTTON HERE, and its absence is the point. A hub
            // is already on the port; starting another cannot happen, and
            // a control that must fail is worse than none. What resolves
            // this is lining the two builds up, so that is what it says
            // ([[WI-2026-09-04-001]]).
            out.append(Problem(
                message: "Another hub holds this machine's port and this workbench may not use it: "
                    + "\(why). Agents here cannot exchange messages until the two builds match — "
                    + "reinstall the app, or redeploy the binary, so both are the same build.",
                isFailure: true))
        default:
            out.append(Problem(
                message: "The hub is not running. Agents on this Mac cannot exchange messages.",
                isFailure: true,
                action: ("Start", { hubManager.restartNow() })))
        }

        if let sync = syncMonitor, !sync.isSyncing {
            out.append(Problem(message: sync.status.humanDescription, isFailure: false))
        }

        if let tm = tunnelManager {
            for peer in tm.peerSummaries where peer.linkFailed {
                out.append(Problem(
                    message: "\(peer.hostLabel): lost contact with that machine's hub and stopped retrying.",
                    isFailure: true))
            }
            // WHAT A LINKED PEER DOES NOT PROVIDE.
            //
            // A capability the peer never declared is not a feature that
            // FAILED, and saying so is the whole of [[RFC-0010]]
            // C-DIAGNOSABILITY — which requires that any surface listing
            // peers render the absences, not only the presences. This one
            // has listed peers since it was written and rendered only
            // whether the link died; `missing` was computed all along and
            // read by nobody, which is the same shape as the version
            // number the clause was written about.
            //
            // NOT A FAILURE: the link works and everything else about the
            // machine works. Rendering it in the failure colour would
            // teach the human to ignore the colour.
            for peer in tm.peerSummaries {
                guard let missing = peer.missing, !missing.isEmpty else { continue }
                out.append(Problem(
                    message: "\(peer.hostLabel): that machine's build does not provide "
                        + missing.joined(separator: ", ")
                        + " — anything relying on it is unavailable there, not broken.",
                    isFailure: false))
            }
        }

        // Deliberately absent: a terminal with no agent in it is A
        // TERMINAL, not a problem ([[WI-2026-08-14-005]]). Reporting the
        // ordinary case trains the human to ignore this list.

        return out
    }
}
