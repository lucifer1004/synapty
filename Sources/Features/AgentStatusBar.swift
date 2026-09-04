import SwiftUI

/// Bottom context bar — what the focused PANE is: its machine, its agent,
/// and what is waiting. Agents live in the sidebar; this bar answers "what
/// am I looking at right now?"
struct ContextStatusBar: View {
    var paneManager: WorkspaceManager
    var agentMonitor: AgentMonitor
    var hubManager: HubManager
    var taskMonitor: TaskMonitor
    /// RFC-0007 exec: armed in Settings → Agents; the standing armed mark
    /// (and its one-click disarm) is drawn on this bar.
    var execController: ExecController? = nil
    /// Transfers in flight ([[WI-2026-08-15-009]]). Shown HERE because the
    /// panel that starts one can be switched to another view or closed
    /// while the file is still moving, and a transfer nobody can see is one
    /// nobody can cancel ([[RFC-0013]] C-CONTROL-PLANE).
    var transfers: TransferService? = nil
    /// Views agents have put on offer ([[WI-2026-08-15-011]]). A COUNT,
    /// not the content: an exposure must not open the panel, switch what
    /// it shows, or take focus — it waits here until the human goes and
    /// looks ([[RFC-0013]] C-REQUEST-NOT-SEIZE).
    var forwards: PortForwardService? = nil
    /// Agents waiting on a human to allow a route ([[WI-2026-08-15-012]]).
    /// A badge, never a prompt: a request that put itself in front of
    /// someone would let an agent seize the screen by asking.
    var authority: TransferAuthority? = nil
    var questions: QuestionService? = nil
    /// Only to NAME machines. The globe counts exposures on every one of
    /// them, so it has to be able to say which ([[WI-2026-08-28-009]]).
    var hostStore: HostStore? = nil

    /// Hub service popover (WI-2026-08-09-007) — the router's status and
    /// agents live here, not on a page.
    @State private var showHubPopover = false
    @State private var showTransfers = false
    @State private var isHubHovered = false

    /// THE ONE THING ON THIS BAR THAT SOMEONE IS BLOCKED ON, so it is the
    /// one drawn in the warning colour — an agent is stopped until it is
    /// answered, which differs in kind from a view merely on offer.
    @ViewBuilder
    private var approvalSummary: some View {
        // ONE COUNT, DEFINED IN ONE PLACE. It means "you have to act" and
        // nothing else — a delivery that succeeded must never raise it
        // ([[AppNotifications]]).
        let waiting = AppNotifications.waitingCount(
            authority: authority, questions: questions, transfers: transfers)
        if waiting > 0 {
            Button {
                NotificationCenter.default.post(name: .synaptyShowApprovals, object: nil)
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(DS.Icon.mark)
                        .foregroundStyle(DS.warning)
                    Text("\(waiting)")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // THE SAME LIST THE NUMBER IS COUNTED FROM
            // ([[AppNotifications.waitingLines]]).
            .help(AppNotifications.waitingLines(
                authority: authority, questions: questions, transfers: transfers)
                .joined(separator: "\n"))
            zoneDivider
        }
    }

    /// UNPROMPTED IS NOT UNAVAILABLE. Nothing about an exposure interrupts,
    /// but a human who is never told has an agent talking to a wall.
    ///
    /// IT COUNTS EVERY MACHINE, so it has to be able to REACH every
    /// machine. It used to open a services pane bound to whichever machine
    /// the focused pane was on, which shows only that machine's exposures
    /// — so a human working locally, with an agent on `builder`, read 1,
    /// clicked, and got "Nothing exposed on this Mac"
    /// ([[WI-2026-08-28-009]]).
    @ViewBuilder
    private var exposureSummary: some View {
        if let forwards, !forwards.exposures.isEmpty {
            let machines = exposureMachines(forwards)
            if machines.count == 1 {
                Button { showExposures(on: machines[0].hostID) } label: { globe(forwards) }
                    .buttonStyle(.plain)
                    .help(exposureHelp(forwards))
                zoneDivider
            } else {
                // MORE THAN ONE MACHINE HAS SOMETHING, and a pane names one
                // connection ([[RFC-0015]] C-CONTENT) — so the human picks
                // rather than the workbench guessing which they meant.
                Menu { exposureMenu(machines) } label: { globe(forwards) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(exposureHelp(forwards))
                zoneDivider
            }
        }
    }

    private func globe(_ forwards: PortForwardService) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "globe")
                .font(DS.Icon.mark)
                .foregroundStyle(DS.accent)
            Text(String(forwards.exposures.count))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func exposureMenu(_ machines: [ExposureMachine]) -> some View {
        ForEach(machines, id: \.hostID) { machine in
            Button("\(machine.name) — \(machine.count)") { showExposures(on: machine.hostID) }
        }
    }

    /// EVERY LINE SAYS WHICH MACHINE. Without it the count named no place
    /// and the human had nothing to go on but the number.
    private func exposureHelp(_ forwards: PortForwardService) -> String {
        forwards.exposures
            .map { "\(machineName($0.hostID)) — \($0.agent): \($0.title ?? "port \($0.remotePort)")" }
            .joined(separator: "\n")
    }

    struct ExposureMachine: Equatable {
        let hostID: UUID?
        let name: String
        let count: Int
    }

    private func exposureMachines(_ forwards: PortForwardService) -> [ExposureMachine] {
        Self.exposureMachines(forwards.exposures, name: machineName)
    }

    /// The machines with something on them, most-exposed first and then by
    /// name — a fixed order, because a Dictionary has none and a menu that
    /// reorders itself between two looks is one a human cannot aim at.
    static func exposureMachines(_ exposures: [PortForwardService.Exposure],
                                 name: (UUID?) -> String) -> [ExposureMachine] {
        Dictionary(grouping: exposures, by: \.hostID)
            .map { ExposureMachine(hostID: $0.key, name: name($0.key), count: $0.value.count) }
            .sorted {
                $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
            }
    }

    private func machineName(_ hostID: UUID?) -> String {
        hostStore?.displayName(of: hostID) ?? (hostID == nil ? "This Mac" : "a host")
    }

    private func showExposures(on hostID: UUID?) {
        NotificationCenter.default.post(name: .synaptyShowExposures,
                                        object: ExposureDestination(hostID: hostID))
    }

    /// A COUNT THAT OPENS WHAT IT COUNTS.
    ///
    /// This was a label with a tooltip and no way in, while
    /// [[TransferStrip]] — file, destination, progress, cancel — already
    /// existed at the foot of the host panel. That strip's own doc says
    /// it "cannot be the only place: the panel can be switched to another
    /// view or closed entirely while a file is still moving, and a
    /// transfer nobody can see is one nobody can cancel" ([[RFC-0013]]
    /// C-CONTROL-PLANE). This is the other place, and it was the half
    /// that was never built ([[WI-2026-08-29-003]]).
    @ViewBuilder
    private var transferSummary: some View {
        if let transfers, !transfers.inFlight.isEmpty, let hostStore {
            let count = transfers.inFlight.count
            Button { showTransfers.toggle() } label: {
                HStack(spacing: DS.Space.xs) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(count == 1 ? "1 file" : "\(count) files")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.pill)
                        .fill(showTransfers ? DS.hover : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(count == 1 ? "One file moving. Click to see it."
                             : "\(count) files moving. Click to see them.")
            .accessibilityLabel("\(count) files moving. Activate to see them.")
            .popover(isPresented: $showTransfers, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    TransferStrip(transfers: transfers, hostStore: hostStore)
                }
                .frame(minWidth: DS.scaled(340))
                .padding(.vertical, DS.Space.sm)
            }
            zoneDivider
        }
    }

    /// KEYS TYPED HERE GO TO SEVERAL MACHINES, said on every frame it is
    /// true ([[WI-2026-09-02-010]]). The count in the danger colour, on
    /// the bar every page shows; clicking it is the one act that stops
    /// it. It lived in the titlebar accessory first and was clipped to a
    /// red sliver there — a switch nobody can read is not a switch.
    @ViewBuilder
    private var broadcastMarker: some View {
        if paneManager.isBroadcasting {
            let n = paneManager.activeWorkspace?.armedBroadcastPanes.count ?? 0
            Button {
                paneManager.toggleBroadcast()
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(DS.Icon.control)
                    Text("Broadcasting to \(n) panes")
                        .font(DS.Typography.captionStrong)
                }
                .foregroundStyle(DS.danger)
            }
            .buttonStyle(.plain)
            .help(CommandHint.help("Keys typed in any armed pane reach all of them. Stop broadcasting",
                                   for: "layout.broadcast"))
            .accessibilityLabel("Broadcasting to \(n) panes. Activate to stop.")
            zoneDivider
        }
    }

    @ViewBuilder
    private var configRootMarker: some View {
        if ConfigPaths.isRedirected {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "flask")
                    .font(DS.Icon.control)
                Text("scratch config")
                    .font(DS.Typography.captionStrong)
            }
            .foregroundStyle(DS.warning)
            .help("\(ConfigPaths.environmentKey) is set — this window reads and writes "
                  + ConfigPaths.root.path + ", not your own config.")
            zoneDivider
        }
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            // Left: focused session context
            focusedSessionInfo
                .frame(maxWidth: .infinity, alignment: .leading)

            broadcastMarker
            configRootMarker

            // Middle-right: per-project task badges (RFC-0003 C-UI)
            projectBadges

            // Zone separators (WI-2026-08-09-010): tasks | service |
            // appearance read as distinct clusters instead of one loose
            // string of glyphs.
            if !taskMonitor.projectCounts.isEmpty {
                zoneDivider
            }

            transferSummary
            exposureSummary
            approvalSummary

            // Service cluster: bridge state + Hub popover.
            bridgeStatusView
            hubSummary
            // THE APPEARANCE TOGGLE IS IN THE TITLE BAR NOW
            // ([[WorkspaceControlsAccessory]]). It came here because the
            // version before it was a button FLOATING in the titlebar band
            // (WI-2026-08-09-006) — floating was the fault, not the band,
            // and as an accessory AppKit owns its place. This bar reports
            // what is going on; that toggle is a thing to press.
        }
        // Gutters aligned with the page content (WI-2026-08-09-006).
        .padding(.horizontal, DS.Space.xl)
        .frame(height: DS.Layout.statusBarHeight)
        // Chrome: it frames the content rather than being any.
        .background(DSChromeBackground())
        .overlay(alignment: .top) { DSHairline() }
        .onAppear {
            // `--hub-popover` opens the popover at launch (DevLaunchArgs).
            // Deferred: presenting during the first layout pass detaches
            // the popover into a stray unanchored window, and the transient
            // popover dies if the app is not yet frontmost — 3s gives the
            // activation dance room.
            if DevLaunchArgs.hubPopover {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    showHubPopover = true
                }
            }
        }
    }

    // MARK: - Focused session info

    @ViewBuilder
    private var focusedSessionInfo: some View {
        if let session = paneManager.activeWorkspace {
            // THE PANE THE HUMAN IS LOOKING AT, not the container. A
            // workspace has no machine and no agent of its own — one can
            // hold panes on several hosts — so the bar describes the
            // focused leaf ([[RFC-0015]] C-LEAF-BINDING).
            let focused = paneManager.visibleFocusedLeafID
            let leafAgent = focused.flatMap { paneManager.agentID(forLeaf: $0) }
            HStack(spacing: DS.Space.sm) {
                DSStatusDot(
                    color: focused.map { paneManager.isLocalLeaf($0) } ?? true ? DS.success : DS.info,
                    size: 7
                )

                // Agent info if registered, otherwise workspace label
                if let agentID = leafAgent,
                   let agent = agentMonitor.agents.first(where: {
                       AgentMonitor.namesSameAgent($0.id, agentID)
                   }) {
                    // Ghost unknown-status agents (WI-2026-08-11-016):
                    // the harness may be gone; the color must not lie.
                    Image(systemName: agent.tool.sfSymbol)
                        .font(DS.Typography.detailStrong)
                        .foregroundStyle(agent.status == "unknown" ? DS.textTertiary : agent.tool.accentColor)
                        .opacity(agent.status == "unknown" ? 0.55 : 1.0)
                        // WHY IT IS GHOSTED, when there is a reason worth
                        // giving. A greyed agent and a greyed agent whose
                        // machine simply does not report status look
                        // identical, and reading the second as the first
                        // is what [[RFC-0010]] C-DIAGNOSABILITY was
                        // written about — a missing capability presented
                        // as a broken one. The sentence has existed on
                        // `unknownExplanation` since that clause landed
                        // and nothing showed it.
                        .help(agent.unknownExplanation ?? "")
                    Text(agent.tool.displayName)
                        .font(DS.Typography.detailStrong)
                    if agent.session != "-" {
                        Text("·")
                            .foregroundStyle(DS.textTertiary)
                        Text(agent.session)
                            .font(DS.Typography.detail)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(session.label)
                        .font(DS.Typography.detailStrong)
                    if let agentID = leafAgent {
                        Text(agentID)
                            .font(DS.Typography.monoCaption)
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }
        } else {
            Text("No active session")
                .font(DS.Typography.detail)
                .foregroundStyle(DS.textSecondary)
        }
    }

    // MARK: - Project task badges (RFC-0003 C-UI)

    /// ORDERED BY ACTIVITY, NOT BY NAME. With a cap, the ordering decides
    /// what the human sees, and alphabetical is the one ordering that
    /// carries no information — a project with twelve tasks in flight
    /// drops behind an idle one whose name starts earlier. In-progress
    /// outranks queued; the name breaks ties so the row does not reshuffle
    /// between polls when the counts are equal.
    /// Which projects the capped row shows, and how many it hides. Pure,
    /// so the ordering rule is testable without a view.
    static func ranked(
        _ counts: [String: ProjectCounts], limit: Int
    ) -> (visible: [String], overflow: Int) {
        let ordered = counts.keys.sorted { a, b in
            let x = counts[a], y = counts[b]
            let xd = x?.doing ?? 0, yd = y?.doing ?? 0
            if xd != yd { return xd > yd }
            let xt = x?.todo ?? 0, yt = y?.todo ?? 0
            if xt != yt { return xt > yt }
            // Name last, and only as a TIE-BREAK: equal counts must not
            // reshuffle the row between polls.
            return a < b
        }
        return (Array(ordered.prefix(limit)), max(0, ordered.count - limit))
    }

    private var projectBadges: some View {
        let counts = taskMonitor.projectCounts
        let (visible, overflow) = Self.ranked(counts, limit: 3)
        return HStack(spacing: DS.Space.sm) {
            ForEach(visible, id: \.self) { project in
                if let c = counts[project] {
                    Button {
                        NotificationCenter.default.post(
                            name: .synaptyShowPage,
                            object: nil,
                            userInfo: ["page": AppPage.tasks.rawValue]
                        )
                    } label: {
                        HStack(spacing: DS.Space.sm) {
                            Text(project.replacingOccurrences(of: "p:", with: ""))
                                .font(DS.Typography.captionStrong)
                            // Symbol-prefixed counts (WI-2026-08-09-010) —
                            // bare "1✓" read as noise; ●=doing ○=todo ✓=done.
                            if c.doing > 0 {
                                statusCount("circle.fill", c.doing, DS.info)
                            }
                            if c.todo > 0 {
                                statusCount("circle", c.todo, DS.textSecondary)
                            }
                            if c.done > 0 {
                                statusCount("checkmark", c.done, DS.success)
                            }
                        }
                        .padding(.horizontal, DS.Space.sm)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.pill)
                                .fill(DS.hover)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open Tasks")
                    .accessibilityLabel("\(project) tasks — open Tasks page")
                }
            }
            if overflow > 0 {
                // A button, like the badges beside it. It said "open the
                // Tasks page" in its tooltip while being the one pill that
                // could not.
                Button {
                    NotificationCenter.default.post(
                        name: .synaptyShowPage,
                        object: nil,
                        userInfo: ["page": AppPage.tasks.rawValue]
                    )
                } label: {
                    Text("+\(overflow)")
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(DS.textTertiary)
                        .padding(.horizontal, DS.Space.sm)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.pill)
                                .fill(DS.hover)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(overflow) more projects — open the Tasks page")
                .accessibilityLabel("\(overflow) more projects — open Tasks page")
            }
        }
    }

    /// One symbol + count pair inside a project badge.
    private func statusCount(_ symbol: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
                .font(DS.Icon.mark)
            Text("\(count)")
                .font(DS.Typography.caption)
        }
        .foregroundStyle(color)
    }

    // MARK: - Bridge state (C-AUTH)

    @ViewBuilder
    private var bridgeStatusView: some View {
        switch taskMonitor.bridgeStatus {
        case .unknown, .configured:
            EmptyView()
        case .notConfigured:
            Button {
                openSettingsPage()
            } label: {
                Image(systemName: "link.badge.plus")
                    .font(DS.Icon.control)
                    .foregroundColor(DS.warning)
            }
            .buttonStyle(.plain)
            .help("GitHub bridge not configured — connect in Settings → GitHub")
        case .error:
            Button {
                // Settings → GitHub owns bridge config (WI-2026-08-09-007):
                // it shows the binding AND offers Connect/Change/Disconnect.
                openSettingsPage()
            } label: {
                Image(systemName: "exclamationmark.triangle")
                    .font(DS.Icon.control)
                    .foregroundColor(DS.danger)
            }
            .buttonStyle(.plain)
            .help(taskMonitor.lastError ?? "GitHub bridge error — open Settings")
        }
    }

    private var zoneDivider: some View {
        DSHairline(axis: .vertical).frame(height: DS.scaled(14))
    }

    private func openSettingsPage() {
        NotificationCenter.default.post(
            name: .synaptyShowPage,
            object: nil,
            userInfo: ["page": AppPage.settings.rawValue]
        )
    }

    // MARK: - Hub summary → service popover (WI-2026-08-09-007)

    @ViewBuilder
    private var hubSummary: some View {
        // ARMED EXEC, IN THE STATUS BAR. [[RFC-0007]] C-EXEC-AUTHORITY:
        // "While armed, the armed state MUST be visible (status-bar
        // affordance)". A popover dismisses when you look away, which is
        // too weak for a STANDING grant to run shell commands as the
        // human.
        //
        // The mark is also the disarm control. That is stronger than the
        // toggle it replaces on both counts: always visible while it
        // matters, and one click to revoke rather than two.
        if let exec = execController, exec.armed {
            Button { exec.setArmed(false) } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "terminal.fill")
                        .font(DS.Typography.caption)
                    Text("exec armed")
                        .font(DS.Typography.caption)
                }
                .foregroundStyle(DS.warning)
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.pill)
                        .fill(DS.warning.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .help("Agents can open scratch panes and run shell commands as you. Click to disarm.")
            .accessibilityLabel("Agent exec is armed. Activate to disarm.")
        }

        Button {
            showHubPopover.toggle()
        } label: {
            HStack(spacing: DS.Space.xs) {
                DSStatusDot(
                    color: hubManager.status.isRunning ? DS.success
                        : hubManager.status.isRecovering ? DS.warning : DS.danger,
                    size: 6
                )
                // AGENTS, not registrations. This read registeredCount,
                // which includes bare terminal panes — so three open
                // shells announced "Hub: 3 agents" with no agent running
                // anywhere. The raw count is still reachable in the
                // popover, where it can say what those registrations are
                // instead of mislabelling them.
                let count = agentMonitor.agents.count
                // REFUSED IS NOT DOWN ([[WI-2026-09-04-001]]). A hub of
                // a build this workbench may not adopt IS running, and
                // calling that "down" sent the human to wait or restart —
                // the two things that cannot resolve it.
                Text(hubManager.status.isRunning ? "Hub: \(count) agent\(count == 1 ? "" : "s")"
                     : hubManager.status.isRecovering ? "Hub: restarting…"
                     : hubManager.status.isRefused ? "Hub: refused" : "Hub: down")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.pill)
                    .fill(isHubHovered || showHubPopover ? DS.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHubHovered = hovering }
        .help("Hub service — status, agents, logs")
        .accessibilityLabel("Hub service popover")
        .popover(isPresented: $showHubPopover, arrowEdge: .top) {
            HubStatusPopover(
                hubManager: hubManager, agentMonitor: agentMonitor,
                execController: execController, tunnelManager: TunnelManager.shared,
                syncMonitor: SyncMonitor.shared)
        }
    }
}

// MARK: - Pulse Animation (used by sidebar AgentRow)

struct PulseAnimation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            // Under Reduce Motion the pulse is disabled entirely — the dot
            // must stay FULLY visible, not stuck at the dimmed pulse value
            // (the nil animation applies the onAppear change instantly;
            // WI-2026-08-08-024).
            .opacity(reduceMotion ? 1.0 : (isPulsing ? 0.4 : 1.0))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
