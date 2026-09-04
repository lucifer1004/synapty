import AppKit
import SwiftUI

/// Top-level application pages. Terminal is the default workspace; the
/// management surfaces (hosts/tasks) are full pages, not modal popovers,
/// so they can use the whole window. First-class pages are DOMAINS
/// (WI-2026-08-09-007); the Hub service is plumbing and lives in the
/// status-bar popover, not on a page.
enum AppPage: String, CaseIterable, Hashable {
    case terminal
    case hosts
    case tasks
    /// WHAT HAPPENED ON THIS MACHINE — agents' requests, the files this
    /// workbench moved, and what a human did to a machine's files from a
    /// pane.
    ///
    /// IT WAS A TAB INSIDE TASKS, and [[WI-2026-08-09-007]] put it there
    /// on the rule that first-class pages are DOMAINS. The rule stands;
    /// what changed is that the stream stopped being one. It carried hub
    /// events when it was filed, then transfers a human drags — which
    /// reach no hub — and now the create, rename and delete a file pane
    /// performs ([[RFC-0015]] C-PANE-WRITES requires them to appear
    /// wherever transfers do). Of the three, one is a task.
    ///
    /// "What did I just delete" is not a question anybody thinks to ask a
    /// page called Tasks.
    case activity
    case settings

    /// Menu label — Go-to menu (WI-2026-08-08-053).
    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .hosts: return "Hosts"
        case .tasks: return "Tasks"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }
}

struct ContentView: View {
    @State private var hostStore = HostStore()
    @State private var agentMonitor = AgentMonitor()
    @State private var paneManager = WorkspaceManager()
    @State private var tunnelManager = TunnelManager()
    @State private var hubManager = HubManager()
    @State private var taskMonitor = TaskMonitor()
    @State private var settings = SynaptySettings.shared
    /// Modifier-hold hint badges (WI-2026-08-09-015): ⌘ workspaces,
    /// ⌘⌥ tabs, ⌘⌃ panes.
    @State private var hintState = ModifierHintState()
    @State private var agentDetector = AgentDetector()
    /// Agent wake (RFC-0005, WI-2026-08-11-013).
    @State private var wakeCoordinator = WakeCoordinator()
    /// Resume plans + restore engine (RFC-0006,
    /// WI-2026-08-11-014).
    @State private var resumeCoordinator = ResumeCoordinator()
    /// Agent-initiated pane execution (RFC-0007, WI-2026-08-11-015).
    @State private var execController = ExecController()
    /// [[ADR-0008]] decision 6: task tools execute HERE, because this is
    /// where the human's GitHub credential is.
    @State private var toolBridge = ToolBridge()
    /// Debounced session-snapshot autosave.
    @State private var snapshotTimer: Timer?
    /// The room the panel and the terminal share, in DESIGN points —
    /// the space `PanelModel.maxWidth(in:)` reasons about.
    private var panelAvailableWidth: Double {
        contentWidth / max(DS.uiFontScale, 0.01)
    }

    private var panelWidth: Double { panelModel.width(in: panelAvailableWidth) }

    @ViewBuilder
    private var contextPanel: some View {
        HostContextPanel(
            model: panelModel,
            hostStore: hostStore,
            tunnelManager: tunnelManager,
            transfers: transferService,
            forwards: forwardService,
            artifacts: artifactService,
            settings: settings,
            onClose: { panelModel.close() })

    }

    /// Initial page honors `--page <name>` (DevLaunchArgs).
    @State private var page: AppPage = {
        if let raw = DevLaunchArgs.page {
            if let target = AppPage(rawValue: raw) { return target }
            // The retired hub page (WI-2026-08-09-007) is the status-bar
            // popover now; a launch asking for it lands on Tasks.
            if raw == "hub" { return .tasks }
        }
        return .terminal
    }()
    /// The one bit the title-bar accessory cannot ask for — see
    /// [[TitlebarChrome]].
    @State private var titlebarChrome = TitlebarChrome()
    @State private var showApprovals = false
    @State private var showShortcuts = false
    /// Where the focused pane is, so the find bar can sit in its corner
    /// ([[FocusedPaneFramePreference]]).
    @State private var focusedPaneFrame: CGRect?
    /// Cmd+K quick-connect palette (WI-2026-08-09-003). Honors
    /// `--quick-connect` (DevLaunchArgs).
    @State private var showQuickConnect = DevLaunchArgs.quickConnect
    /// WHICH THING THE PALETTE IS BEING ASKED FOR. [[RFC-0015]]
    /// C-WORKSPACE says a connection opened from inside a workspace
    /// SHOULD place its pane there, and says in as many words that which
    /// entry point means which "is an interaction question this document
    /// does not settle". So it is settled here, once, rather than by each
    /// caller guessing: the sidebar's + is labelled New workspace and
    /// means one; ⌘K and the machine chip are invoked mid-work and mean
    /// here.
    @State private var quickConnectLandsHere = true
    /// Page-switch cross-fade honors Reduce Motion (WI-2026-08-09-006).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The right panel: which view it shows and how wide each one is
    /// ([[WI-2026-08-15-009]]). It was a Bool and one width when the panel
    /// could only ever be Appearance.
    @State private var panelModel = PanelModel()
    /// Transfers, owned here so they outlive the panel that starts them
    /// ([[ADR-0010]]).
    @State private var transferService = TransferService()
    /// Port forwards an agent asked for ([[WI-2026-08-15-011]]). Resident
    /// for the same reason transfers are: a forward outlives the view.
    @State private var forwardService = PortForwardService()
    /// Who may send where, held in memory so the capability dies with this
    /// process ([[RFC-0013]] C-AUTHORIZATION).
    @State private var transferAuthority = TransferAuthority()
    /// Artifacts agents handed over ([[RFC-0013]] C-PRIMITIVES).
    @State private var artifactService = ArtifactService()
    @State private var questionService = QuestionService()
    /// Outcomes that need saying once, and the badge for what is waiting
    /// ([[AppNotifications]]).
    @State private var notifications = AppNotifications()
    /// Left sidebar width — drag-resizable, persisted (WI-2026-08-08-080).
    @AppStorage("synapty.sidebarWidth") private var sidebarWidth: Double = 230
    /// The width of everything the sidebar is not, ON THE GLASS.
    /// `PanelModel`'s figures are DESIGN points and cross over through
    /// `DS.scaled` / `uiFontScale` exactly once.
    @State private var contentWidth: Double = 0
    /// Left sidebar hidden — persisted, so a workbench set up for one wide
    /// terminal stays that way across launches.
    @AppStorage("synapty.sidebarHidden") private var sidebarHidden = false
    /// The two divider drags, each an anchor and a live width in one value
    /// ([[EdgeDrag]]).
    @State private var sidebarDrag: EdgeDrag?
    @State private var panelDrag: EdgeDrag?
    /// Observed copy of GhosttyApp.shared — shared is a plain static var
    /// SwiftUI cannot track, so the readiness notification materializes it
    /// into @State (WI-2026-08-08-079).
    @State private var ghosttyAppState: GhosttyApp?
    /// A LATE SEARCH COUNT REPAINTS THROUGH THIS. GhosttyApp is not
    /// observable, so its per-leaf results cannot drive a view on their
    /// own; this observable ticker is bumped whenever a count arrives —
    /// including the background history result that lands after the first
    /// active-area report ([[WI-2026-09-02-001]]). Read in findBarOverlay
    /// so the bar re-evaluates and re-reads the results. Resolved on the
    /// same ready notification as `ghosttyAppState`, because `shared` is
    /// nil while this view initialises.
    @State private var searchTicker: GhosttyApp.SearchTicker?

    var body: some View {
        windowBody
        .onChange(of: page) { _, newPage in
            panelModel.collapse()
            titlebarChrome.isTerminalPage = newPage == .terminal
        }
        .onAppear {
            // Dev/test: `--tabs N` opens N-1 extra tabs in the first
            // session (multi-tab visual audits, DevLaunchArgs).
            if let n = DevLaunchArgs.tabs, n > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak paneManager] in
                    for _ in 1..<n { paneManager?.addPaneToActiveWorkspace() }
                }
            }
            // Dev/test: `--sync-preflight` answers the one question that
            // decides whether CloudKit is viable here at all — does it
            // work in a non-sandboxed app — and exits. Printed to stderr
            // AND logged, because the caller may be a shell reading the
            // pipe or a human reading Console.
            if DevLaunchArgs.syncPreflight {
                Task { @MainActor in
                    let status = await SyncPreflight.check()
                    let line = "SYNC-PREFLIGHT: \(status) | \(status.humanDescription) | isSyncing=\(status.isSyncing)"
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                    AppLog.sync.error("\(line, privacy: .public)")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    NSApplication.shared.terminate(nil)
                }
            }
            if DevLaunchArgs.toast {
                notifications.isActive = { true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    notifications.post(.done, "Delivered to remotehost", detail: "probe.txt")
                    notifications.post(.done, "Delivered to this Mac",
                                       detail: "a-rather-long-report-name-2026-08-16.html")
                    notifications.post(.failed, "Transfer failed",
                                       detail: "probe.txt — the host refused the request")
                }
            }
            // Dev/test: `--panel <view> [--panel-host <uuid>] [--expose
            // <port>]` drives the right panel from the command line. The
            // exposure goes through the SERVICE, so what a screenshot then
            // shows is a page reached by a real forward on a real master.
            if let raw = DevLaunchArgs.panel, let view = PanelOccupant(rawValue: raw) {
                panelModel.show(view)
            }
            // Dev/test: `--pane files|web|terminal` opens one at launch.
            // The other kinds are behind a press-and-hold menu, which
            // needs accessibility this machine does not grant.
            //
            // DEFERRED, like `--tabs`: there is no workspace to put a pane
            // in at onAppear, and asking for one then silently does
            // nothing — which is exactly how this first shipped and how
            // the screenshot came back showing no pane at all.
            if let raw = DevLaunchArgs.pane {
                let content: SplitNode.PaneContent? = switch raw {
                case "files": .files(directory: nil)
                case "services": .services
                case "browser": .browser(address: nil)
                case "terminal": .terminal(command: DevLaunchArgs.paneCommand)
                default: nil
                }
                if let content {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak paneManager] in
                        guard let workspace = paneManager?.activeWorkspace?.id else { return }
                        paneManager?.addPane(content: content, toWorkspace: workspace)
                    }
                }
            }
            // Dev/test: `--find <needle>` opens the bar the way ⌘F does and
            // runs the search the way typing does — the same code paths,
            // because a search driven any other way verifies nothing.
            if let needle = DevLaunchArgs.find {
                // POLLED, NOT TIMED. The pane's surface comes up whenever
                // it comes up — a fixed delay raced it and lost, and the
                // failure (search issued against no surface) is silent.
                @MainActor func attempt(_ remaining: Int) {
                    guard remaining > 0 else {
                        AppLog.search.error("FIND: gave up waiting for a surface")
                        return
                    }
                    guard let leaf = paneManager.activeWorkspace?.focusedPaneID,
                          GhosttyApp.shared?.surface(forLeaf: leaf) != nil,
                          paneManager.isFinding(leaf) || paneManager.beginFinding(leaf)
                    else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            attempt(remaining - 1)
                        }
                        return
                    }
                    paneManager.setFindQuery(leaf, needle)
                    runSearch(needle, in: leaf)
                    // And step to the first match ONCE THE COUNT IS IN —
                    // the background history search settles a few hundred
                    // ms later, and navigating before it lands is a no-op
                    // on an empty result. Poll the live count, then step.
                    func stepWhenReady(_ tries: Int) {
                        guard tries > 0 else { return }
                        if (GhosttyApp.shared?.searchResults(forLeaf: leaf).total ?? 0) > 0 {
                            navigateSearch(true, in: leaf)
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                stepWhenReady(tries - 1)
                            }
                        }
                    }
                    stepWhenReady(15)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { attempt(30) }
            }
            if let id = DevLaunchArgs.panelHost {
                UserDefaults.standard.set(id, forKey: "synapty.panelHostID")
            }
            if let port = DevLaunchArgs.expose {
                // After the connection settles: `ssh -O forward` needs the
                // ControlMaster, and at launch it may not be up yet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let raw = DevLaunchArgs.panelHost
                        ?? UserDefaults.standard.string(forKey: "synapty.panelHostID") ?? ""
                    guard let hostID = UUID(uuidString: raw) else {
                        FileHandle.standardError.write(Data("EXPOSE: no panel host\n".utf8))
                        return
                    }
                    Task { @MainActor in
                    let outcome = await forwardService.expose(
                        hostID: hostID, remotePort: port, agent: "dev", title: "port \(port)")
                    let line: String
                    switch outcome {
                    case .ok(let exposure): line = "EXPOSE: ok \(exposure.url)"
                    case .refused(let why): line = "EXPOSE: refused \(why)"
                    }
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                    }
                }
            }
            // Dev/test: `--attention` marks a non-visible leaf after the
            // tabs settle (WI-2026-08-09-021 cascade screenshots).
            if DevLaunchArgs.attention {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak paneManager] in
                    guard let pm = paneManager,
                          let session = pm.workspaces.first else { return }
                    let background = session.panes.first { $0.id != session.focusedPaneID }
                    if let background { pm.markLeafAttention(background.id) }
                }
            }
            // Dev/test: `--layout <preset>` builds a 3-leaf split and
            // applies the preset once the first surface is up
            // (WI-2026-08-09-012 screenshot affordance).
            if let raw = DevLaunchArgs.layout,
               let preset = SplitNode.LayoutPreset(rawValue: raw) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak paneManager] in
                    paneManager?.splitFocusedLeaf(direction: .horizontal)
                    paneManager?.splitFocusedLeaf(direction: .horizontal)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        paneManager?.applyLayout(preset)
                        if DevLaunchArgs.zoom { paneManager?.toggleZoom() }
                        if DevLaunchArgs.broadcast { paneManager?.toggleBroadcast() }
                    }
                }
            }
            hintState.install()
            // Workbench gaze (RFC-0004 C-OWNERSHIP): focusing a done
            // agent's pane emits the done→idle transition to the hub —
            // the only party that can observe the human asserts "seen".
            paneManager.onAgentGaze = { agentID in
                emitGazeIfDone(agentID)
            }
            // RFC-0008 identity upgrade: keep the pane association on the
            // renamed agent (detection + badges follow the durable id).
            agentMonitor.onIdentityUpgraded = { [weak paneManager] old, durable in
                paneManager?.remapLeafAgent(from: old, to: durable)
            }
            // RFC-0005 wake + RFC-0006 resume plans ride the same event
            // stream: candidates/cancellations/status edges for the wake
            // gate, registration metadata for plan capture.
            // Tool requests arrive on their own callback, from EVERY
            // machine, carrying the port to answer on.
            agentMonitor.onToolRequest = { [weak toolBridge] payload, replyPort in
                toolBridge?.handleHubEvent(payload, replyPort: replyPort)
            }
            agentMonitor.onHubEvent = { [weak wakeCoordinator, weak resumeCoordinator, weak execController, weak toolBridge] payload in
                wakeCoordinator?.handleHubEvent(payload)
                resumeCoordinator?.handleHubEvent(payload)
                execController?.handleHubEvent(payload)
                // [[ADR-0008]] decision 6: the hub forwards credential-bound
                // task tools here rather than executing them itself.

                // WI-2026-08-12-010: the hub reports a dropped relay link;
                // the workbench decides whether to redial, since only it
                // knows whether the SSH forward still exists.
                tunnelManager.handleHubEvent(payload)
            }
            // [[ADR-0008]] stage 5: a peer link also gets a subscription,
            // so the merged view has the peer's tool/session/status —
            // none of which crosses a relay link.
            tunnelManager.onPeerLinked = { [weak agentMonitor] machine, port in
                agentMonitor?.attachPeer(machine: machine, port: port)
            }
            tunnelManager.onPeerUnlinked = { [weak agentMonitor] machine in
                agentMonitor?.forgetPeer(machine)
            }
            TunnelManager.shared = tunnelManager
            tunnelManager.hostStore = hostStore
            // The transfer service resolves hosts and connections through
            // these; it owns the queue, not the lookup ([[ADR-0010]]).
            TransferService.shared = transferService
            transferService.hostStore = hostStore
            transferService.tunnelManager = tunnelManager
            PortForwardService.shared = forwardService
            AppNotifications.shared = notifications
            TransferAuthority.shared = transferAuthority
            // A withdrawal has to reach transfers the grant already
            // admitted, and the grant is consulted once at admission.
            transferAuthority.transfers = transferService
            ArtifactService.shared = artifactService
            QuestionService.shared = questionService
            artifactService.transfers = transferService
            forwardService.tunnelManager = tunnelManager
            // Establish the sync answer once, at launch, and keep it
            // current across sign-in and sign-out — a status fixed at
            // launch is wrong from the moment the human touches System
            // Settings.
            SyncMonitor.shared.start()
            // Config sync ([[WI-2026-08-13-005]]). It refuses to start
            // when the status is anything but available, so this is not a
            // "try and hope" — every reason it would not run is already a
            // state the human is being shown.
            Task { await SyncEngine.shared.start(hostStore: hostStore) }
            // So a "lost contact" notice can say what it COSTS rather
            // than merely that it happened. TunnelManager does not know
            // how presence is assembled and should not learn.
            tunnelManager.agentCountForPeer = { [weak agentMonitor] machine in
                agentMonitor?.agents.filter { $0.machine == machine }.count ?? 0
            }
            // Hub port is a runtime detail now (WI-2026-08-11-017): the
            // embedded hub binds in onStart and publishes boundPort;
            // only the tunnel port remains configuration.
            tunnelManager.tunnelPort = settings.tunnelPort
            TerminalCoordinatorRef.instance = paneManager
        }
        // A WORKSPACE THAT CAME BACK WITH RELEASED CONNECTIONS GETS
        // DIALLED, whoever brought it back. Restore calls the same
        // function directly at launch; the reopen gesture lives in the
        // sidebar, which owns no tunnel, so it records the need and this
        // is where it is met ([[RFC-0015]] C-UNARCHIVE).
        .onChange(of: paneManager.workspacesAwaitingDial) { _, awaiting in
            if !awaiting.isEmpty { dialWorkspacesAwaitingIt() }
        }
        // Dock badge mirrors panes waiting for input (WI-2026-08-09-021).
        .onChange(of: paneManager.attentionCount) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        // Semantic agent status → leaf attention (RFC-0004 C-VOCABULARY):
        // waiting/done demand attention; working/idle withdraw it; unknown
        // is a no-op (honest absence of signal must not clear a bell-driven
        // attention mark). Routed through the leaf↔agent map recorded at
        // spawn time.
        .onChange(of: agentMonitor.agents) { _, agents in
            for agent in agents {
                guard let leafID = paneManager.leafID(forAgent: agent.id) else { continue }
                switch agent.status {
                case "waiting", "done":
                    paneManager.markLeafAttention(leafID)
                    agentMonitor.markNeedsAttention(agent.id)
                case "working", "idle":
                    paneManager.clearLeafAttention(leafID)
                    agentMonitor.clearAttention(agent.id)
                default:
                    break
                }
            }
        }
        // Workbench gaze (RFC-0004 C-OWNERSHIP): returning to the app while
        // a done pane is focused counts as seeing it — same evidence as the
        // in-app focus hook installed in onAppear.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let agentID = paneManager.visibleAgentID() {
                emitGazeIfDone(agentID)
            }
        }
        // Tunnel port changes from Settings → Network apply on the next
        // tunnel connection. (The hub port setting is retired —
        // WI-2026-08-11-017: the embedded hub owns its port.)
        .onChange(of: settings.tunnelPort) { _, newPort in
            tunnelManager.tunnelPort = newPort
        }
        // THE MONITOR FOLLOWS THE PORT THE HUB ANSWERED ON, and nothing
        // else: with no hub adopted it subscribes to nothing. It used to
        // fall back to 9000 and subscribe to the very hub adoption had just
        // refused, so the agent list looked healthy under a status that
        // said conflict ([[WI-2026-09-02-029]]).
        .onChange(of: hubManager.boundPort) { _, port in
            if let port {
                tunnelManager.hubPort = port
                agentMonitor.startMonitoring(port: port)
            } else {
                agentMonitor.stopMonitoring()
            }
        }
        .modifier(WindowLifecycle(
            page: $page,
            taskMonitor: taskMonitor,
            ghosttyAppProvider: { GhosttyApp.shared },
            onStart: {
                // Wiring addLocalWorkspace depends on MUST precede it: the
                // first pane's `synapty run` wrapper comes from
                // TunnelManager.localCommand(), and onStart's ordering
                // against the main onAppear is not guaranteed. A nil
                // TunnelManager.shared silently degrades a cold launch's
                // first pane to a bare unwrapped shell
                // ([[WI-2026-08-09-025]]).
                TunnelManager.shared = tunnelManager
                tunnelManager.hostStore = hostStore
                // A connection nothing references has to be asked to go
                // ([[RFC-0015]] C-RELEASE) — the registry knows when one
                // is eligible and hangs up nothing on its own.
                paneManager.startReleasingIdleConnections()
                // The embedded hub starts FIRST and publishes the port
                // every downstream consumer uses (WI-2026-08-11-017:
                // the port is a runtime detail, never hand-aligned).
                // WIRED WHEN THE HUB HAS ANSWERED, NOT BEFORE
                // ([[WI-2026-09-02-022]]): the hub picks its own port via
                // the ladder, so everything below needs the confirmed
                // one — and waiting for it no longer blocks the main actor.
                agentMonitor.onHubDisconnect = { [hubManager] in hubManager.subscriberDisconnected() }
                Task { @MainActor in
                let hubPort = await hubManager.start() ?? 9000
                // AFTER the hub, and the ordering is the whole point: the
                // key is named after the peer id the hub MINTS, so running
                // this first publishes nothing on a machine whose hub has
                // never started — which is exactly a new Mac, the case
                // enrolment exists for ([[ADR-0009]]). Local and
                // idempotent; enrolment itself stays a human's act.
                MachineKey.publishLocal()
                tunnelManager.hubPort = hubPort
                // Passive detection (RFC-0004 C-PASSIVE-DETECTION, ADR-0005).
                agentDetector.start(paneManager: paneManager, agentMonitor: agentMonitor, port: hubPort)
                // Agent wake (RFC-0005): gate + inject + ack over the
                // detector's fresh classifications.
                wakeCoordinator.start(
                    paneManager: paneManager, agentMonitor: agentMonitor,
                    detector: agentDetector, port: hubPort)
                // Agent-initiated pane execution (RFC-0007).
                execController.start(
                    paneManager: paneManager, agentMonitor: agentMonitor,
                    detector: agentDetector, port: hubPort)
                // Task tools (RFC-0003 C-EVENTS as amended): the hub no
                // longer holds the GitHub credential, so it forwards
                // them here to be run against the Keychain.
                toolBridge.start(port: hubPort)
                // File verbs are served here, not by a subprocess
                // ([[WI-2026-08-15-010]]). A closure rather than stored
                // references so the bridge does not hold the workbench's
                // objects alive.
                toolBridge.fileServer = { [weak transferService, weak hostStore, weak paneManager] in
                    guard let transferService, let hostStore, let paneManager else { return nil }
                    return FileToolServer(
                        transfers: transferService, hostStore: hostStore,
                        paneManager: paneManager, authority: transferAuthority,
                        artifacts: artifactService, questions: questionService)
                }
                toolBridge.forwardService = { [weak forwardService] in forwardService }
                // The hub outlives us: adopt whatever it is already peered
                // with, instead of assuming a fresh launch starts alone.
                if let info = HubManager.queryHubInfo(port: hubPort) {
                    tunnelManager.adoptExistingPeers(info.peers, capabilities: info.peerCapabilities)
                }
                taskMonitor.start()
                tunnelManager.startHeartbeat()
                // [[RFC-0006]] C-RESUME-PLAN: plans are RECORDED here and
                // executed nowhere — a resume is a human's click on a pane
                // that has already been reported as restarted.
                resumeCoordinator.start(paneManager: paneManager)
                if paneManager.workspaces.isEmpty {
                    if let snap = WorkspaceStore.load(), !snap.workspaces.isEmpty {
                        paneManager.restore(from: snap, hostStore: hostStore)
                        if paneManager.workspaces.isEmpty {
                            // Snapshot restored nothing usable — fresh start.
                            paneManager.addLocalWorkspace()
                        }
                        // Dial the hosts that were open when we quit. One
                        // attempt each and no retry: a host that is asleep
                        // or gone lands on the session's own failure card,
                        // which is where the human already looks and where
                        // Reconnect already lives.
                        dialWorkspacesAwaitingIt()
                    } else {
                        paneManager.addLocalWorkspace()
                    }
                }
                // Snapshot autosave: the periodic write is a BACKSTOP for
                // drift the signature does not describe; the arrangement
                // itself is written the moment it changes (below).
                snapshotTimer?.invalidate()
                snapshotTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                    Task { @MainActor in saveArrangement() }
                }
                }
            },
            onStop: {
                snapshotTimer?.invalidate()
                snapshotTimer = nil
                // Quitting is an explicit act and skips the grace period
                // ([[RFC-0015]] C-RELEASE).
                paneManager.releaseAllConnections()
                // Snapshot BEFORE the monitors stop — plans and armed
                // bits must survive shutdown (C-RESUME-PLAN drop rules).
                saveArrangement()
                wakeCoordinator.stop()
                agentDetector.stop()
                agentMonitor.stopMonitoring()
                taskMonitor.stop()
                tunnelManager.stopHeartbeat()
                hubManager.shutdown()
                settings.flushPersistence()
            }
        ))
    }

    /// The window itself, before the handlers that watch it.
    ///
    /// SPLIT BECAUSE THE COMPILER GAVE UP. One chain of this length
    /// stopped type-checking in reasonable time the moment a pane kind
    /// gained an associated value, and the diagnostic named whichever
    /// expression it happened to abandon — four innocent ones in a row,
    /// each of which looked like the cause and was not. A body in two
    /// halves is not tidier; it is the difference between an error that
    /// points at the change and one that sends you hunting.
    @ViewBuilder
    private var windowBody: some View {
        // Plain HStack instead of NavigationSplitView: the split view adds
        // ~10+ levels of internal hosting/NSView nesting, making every
        // layout pass (page switches, display cycles) expensive — the
        // "whole UI feels heavy" symptom (WI-2026-08-07-006).
        HStack(spacing: 0) {
            if !sidebarHidden {
                HostSidebar(
                    hostStore: hostStore,
                    paneManager: paneManager,
                    tunnelManager: tunnelManager,
                    agentMonitor: agentMonitor,
                    taskMonitor: taskMonitor,
                    hintState: hintState,
                    page: $page,
                    onOpenRemoteAgent: { machine, agentID in
                        openRemoteAgent(machine: machine, agentID: agentID)
                    },
                    // BY THE NAME THE HOST GAVE, straight to the host it
                    // came from — no peer-name lookup, because this row
                    // already knows which machine reported it.
                    onOpenSession: { host, name in
                        connect(to: host, agentID: name)
                        page = .terminal
                    },
                    onSessionSelect: {
                        page = .terminal
                        panelModel.collapse()
                    }
                )

                .frame(width: sidebarDrag?.width ?? sidebarWidth)
                DSDragDivider(
                    onDrag: { delta in
                        var drag = sidebarDrag ?? EdgeDrag(from: sidebarWidth)
                        drag.slide(by: delta, within: DS.scaled(180)...DS.scaled(320))
                        sidebarDrag = drag
                    },
                    onEnded: {
                        if let width = sidebarDrag?.width { sidebarWidth = width }
                        sidebarDrag = nil
                    }
                )
                DSHairline(axis: .vertical)
            }
            // EVERYTHING THE SIDEBAR IS NOT — the room the terminal and
            // the panel share. Grouped so its width is a LAYOUT FACT rather
            // than a subtraction: the expanded panel covers exactly this,
            // and the ceiling is measured from exactly this, whether the
            // sidebar is showing, hidden or mid-drag.
            HStack(spacing: 0) {
            // Content column — terminal dock + management-page overlays,
            // with the context status bar GLOBAL at the bottom
            // ([[WI-2026-08-09-006]]).
            VStack(spacing: 0) {
            ZStack {
                terminalPage
                    .opacity(page == .terminal ? 1 : 0)
                    .allowsHitTesting(page == .terminal)
                    .accessibilityHidden(page != .terminal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay {
                // Management pages are lightweight; render only when active.
                // The window SAFE AREA already clears the hidden-titlebar
                // strip — the old extra titlebarInset padding double-inset
                // every page by 28pt (WI-2026-08-09-011). A 150ms cross-fade
                // keys on the page id (WI-2026-08-09-006); the terminal dock
                // stays instant (WI-2026-08-07-006 perf gate).
                if page != .terminal {
                    Group {
                        switch page {
                        case .hosts:
                            HostsPageView(
                                hostStore: hostStore,
                                tunnelManager: tunnelManager,
                                forwards: forwardService,
                                paneManager: paneManager,
                                onOpenTerminal: { host in
                                    // One-click terminal from the Hosts list
                                    // (WI-2026-08-08-064).
                                    handleHostConnect(host)
                                },
                                onOpenGroupAsGrid: { group in
                                    openGroupAsGrid(group)
                                }
                            )
                        case .tasks:
                            TaskListView(taskMonitor: taskMonitor)
                        case .activity:
                            ActivityPage(taskMonitor: taskMonitor, transfers: transferService)
                        case .settings:
                            SettingsPage(settings: settings, taskMonitor: taskMonitor,
                                         execController: execController,
                                         transferAuthority: transferAuthority,
                                         hostStore: hostStore)
                        case .terminal:
                            EmptyView()
                        }
                    }
                    .id(page)
                    .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.15),
                value: page
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Global context status bar (WI-2026-08-09-006) — also hosts
            // the Appearance-panel toggle, replacing the stray floating
            // button that sat in the titlebar band.
            statusBar
            }
            // RISING FROM THE STATUS BAR, where the badge for what is
            // waiting already lives — so "what is going on with me" has
            // one place to look rather than two.
            .overlay(alignment: .bottomTrailing) {
                NotificationStack(notifications: notifications)
                    .allowsHitTesting(!notifications.visible.isEmpty)
                    .padding(.bottom, DS.Layout.statusBarHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.background)

            // Right settings panel — DOCKED on every page so page content
            // reflows instead of being covered (WI-2026-08-08-090 follow-up;
            // replaces the floating overlay of WI-2026-08-08-052). Handle on
            // the panel's LEFT edge (WI-2026-08-08-081).
            if panelModel.isOpen {
                // THE LINE FIRST ON THIS SIDE ([[WI-2026-08-15-007]]).
                // The grab strip is 6pt of chrome, and it belongs with the
                // panel it resizes. Ordered as on the left it landed
                // between the TERMINAL and the line — a chrome band inside
                // the content, where the left one merges into the sidebar.
                DSHairline(axis: .vertical)
                DSDragDivider(
                    onDrag: { dragPanel(by: $0) },
                    onEnded: {
                        if let width = panelDrag?.width {
                            panelModel.setWidth(width / max(DS.uiFontScale, 0.01),
                                                in: panelAvailableWidth)
                        }
                        panelDrag = nil
                    }
                )
                contextPanelColumn
            }
            }
            // Measured, not derived. A width computed as "window minus
            // sidebar" was wrong the moment the sidebar could be hidden —
            // the expanded panel kept the missing rail's room and the
            // terminal showed through beside it.
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, w in contentWidth = w }
                }
            )
            // EXPANDED DRAWS OVER THIS GROUP, so it covers the terminal and
            // the space the docked panel is holding, and nothing else. The
            // left rail stays reachable and the pane underneath keeps the
            // size it had.
            .overlay(alignment: .trailing) {
                if panelModel.isOpen && panelModel.isExpanded {
                    contextPanel
                }
            }
        }
        // Double-clicking the title bar strip does what the human told
        // macOS it should do. The window is .hiddenTitleBar with
        // fullSizeContentView, so the system never sees that click — the
        // app's content occupies the strip. Behind the chrome, so a
        // double-click on a tab stays a double-click on a tab.
        // The toggle goes on the window this content is IN — see
        // WindowAccessor for why neither launch nor keyWindow works.
        // install() is idempotent, so repeated calls are free.
        // THE WHOLE WINDOW HAS A FLOOR ([[WI-2026-08-15-007]]).
        //
        // fullSizeContentView puts the strip behind the traffic lights
        // OUTSIDE the safe area. The sidebar painted it because its own
        // background ignores that edge; the content column did not, so the
        // raw white window showed above the pane tabs — the horizontal
        // twin of the seam beside it. Attaching it to the column does not
        // work: a background is clipped to the view it decorates, and
        // ignoring the edge there expands nothing.
        //
        // At the ROOT it does, and everything else paints over it, so no
        // surface has to remember to reach the corner.
        // CHROME, not the page colour ([[WI-2026-08-15-007]]). This floor
        // is only ever visible in the title-bar strip, which every other
        // surface then paints over — and that strip is chrome everywhere
        // else in macOS. On the page colour it changed tone when the human
        // switched pages: chrome on the terminal, where the tab bar's own
        // background reaches it, and page colour on Hosts, where nothing
        // does.
        // IN FRONT OF THE FLOOR, WHICH IS WHY IT NOW WORKS. A `background`
        // modifier applied later sits FURTHER BACK, so with the catcher
        // added after the chrome floor it was the backmost layer in the
        // window — and `DS.chrome` is a Color, which is hit-testable, so
        // every click in the strip stopped there and the catcher never saw
        // a double one. It was complete, correct, wired, and unreachable.
        .titlebarDoubleClickToZoom()
        // AND THE FLOOR TAKES NO CLICKS. It is paint: the strip it fills
        // is chrome, and a decorative layer that swallows events is how
        // this defect would come back the next time something is layered
        // behind it.
        .background(DS.chrome.ignoresSafeArea().allowsHitTesting(false))
        .background(WindowAccessor {
            SidebarToggleAccessory.install(in: $0)
            WorkspaceControlsAccessory.install(
                in: $0, paneManager: paneManager, hostStore: hostStore,
                chrome: titlebarChrome,
                onConnectHostHere: { connect(to: $0) })
        })
        .overlay { quickConnectOverlay }
        // THE ARRANGEMENT IS WRITTEN WHEN IT CHANGES, not on a timer
        // ([[RFC-0015]] C-PERSIST). Keyed on a signature rather than the
        // tree, so a title arriving from a shell or a cursor moving does
        // not rewrite the file — only a change a restore would notice.
        .onChange(of: paneManager.arrangementSignature) { _, _ in
            saveArrangement()
        }
        .coordinateSpace(name: "synaptyWindow")
        .onPreferenceChange(FocusedPaneFramePreference.self) { frame in
            focusedPaneFrame = frame
        }
        // THE SAME SHAPE THE PALETTE HAS — a plain overlay, aligned to the
        // top-leading corner and offset. Wrapped in a geometry reader
        // instead, the bar's text field never took keyboard focus.
        .overlay(alignment: .topLeading) { findBarOverlay }
        // A SHEET ONLY WHEN THE HUMAN OPENS IT. Nothing an agent does sets
        // this — the badge on the status bar is what an arriving request
        // reaches ([[RFC-0013]] C-REQUEST-NOT-SEIZE).
        .sheet(isPresented: $showApprovals) {
            ApprovalSheet(authority: transferAuthority, questions: questionService,
                          transfers: transferService, hostStore: hostStore,
                          agentMonitor: agentMonitor) {
                showApprovals = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyShowApprovals)) { _ in
            showApprovals = true
        }
        // THE REFERENCE SHEET WAS NEVER PRESENTED. `showShortcuts` was set
        // by the menu item and by ⇧⌘/ and read by nothing at all — the
        // view existed, complete, and was instantiated nowhere, so the one
        // surface [[RFC-0016]] C-DISCOVERY obliges the workbench to carry
        // could not be opened.
        .sheet(isPresented: $showShortcuts) { shortcutsSheet }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyToggleSidebar)) { _ in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                sidebarHidden.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .synaptyQuickConnect)) { note in
            // The caller says which it means; nil is ⌘K itself, which is
            // invoked mid-work and therefore means here.
            quickConnectLandsHere = (note.object as? Bool) ?? true
            // Toggle, so Cmd+K also CLOSES an open palette (Raycast-style).
            showQuickConnect.toggle()
        }
        .modifier(NotificationHandlers(
            page: $page,
            showShortcuts: $showShortcuts,
            panelModel: panelModel,
            ghosttyAppState: $ghosttyAppState,
            searchTicker: $searchTicker,
            paneManager: paneManager,
            taskMonitor: taskMonitor,
            hostStore: hostStore
        ))
        // ANY NAVIGATION TAKES THE EXPANDED PANEL DOWN. It covers the
        // content column, so arriving at a page underneath it is arriving
        // nowhere. Catches the rail and the Go-to menu; the two sidebar
        // taps that do not change `page` collapse at their own call sites.
    }

    // MARK: - Terminal page

    private var terminalPage: some View {
        VStack(spacing: 0) {
            if let ghosttyApp = ghosttyAppState {
                // NO CHROME ROW AT ALL. The tabs belong to the position
                // holding them ([[RFC-0015]] C-LAYOUT) and are drawn
                // inside the split tree; the workspace's own two controls
                // went up into the title bar
                // ([[WorkspaceControlsAccessory]]). What stood here was a
                // full-width band carrying two glyphs at its right edge,
                // between the title bar and the tabs — and with nothing in
                // it there is nothing to jump, which is what the stable
                // placeholder tab of WI-2026-08-08-056 was for.
                // Both the terminal surfaces and the placeholder stay in the
                // view tree; switching between them uses opacity, never
                // removal. Removing AllPanesSplitView (e.g. when the active
                // session is a connecting placeholder) would deinit every
                // ghostty surface — killing PTY children and clearing
                // workspaces (recurring bug).
                ZStack {
                    AllPanesSplitView(
                        paneManager: paneManager,
                        ghosttyApp: ghosttyApp,
                        hostStore: hostStore,
                        tunnelManager: tunnelManager,
                        transfers: transferService,
                        forwards: forwardService,
                        artifacts: artifactService,
                        isTerminalPageVisible: page == .terminal,
                        hintState: hintState,
                        dropCoordinator: TerminalDropCoordinator(
                            paneManager: paneManager,
                            hostStore: hostStore,
                            transfers: transferService),
                        agentMonitor: agentMonitor,
                        resumeCoordinator: resumeCoordinator,
                        onRetryLeaf: { retryLeaf($0) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(paneArea == .layout ? 1 : 0)
                    .allowsHitTesting(paneArea == .layout)

                    if paneArea == .empty {
                        // A RESTING WORKSPACE SAYS SO, and offers the way
                        // out ([[RFC-0015]] C-EMPTY): it must not be a
                        // blank rectangle and must not be mistaken for one
                        // still dialling.
                        DSEmptyState(
                            icon: "rectangle.split.2x1",
                            title: "Nothing open here",
                            message: "This workspace is empty. Its name and place are kept until you close it.")
                        {
                            // ONE ACT, ONE BUTTON. This was two — "New
                            // Pane" beside "Connect a machine…" — and the
                            // second contained the first: the palette's
                            // opening row is Local Terminal, so choosing
                            // it is one Enter away and gives exactly what
                            // the other button gave. Two controls where
                            // one is a superset of the other make the
                            // human decide something that has no answer.
                            //
                            // AND IT IS NOT "CONNECT". Picking the local
                            // row connects nothing. That word also speaks
                            // the model [[RFC-0015]] C-LEAF-BINDING
                            // retired, where a workspace WAS a connection
                            // to a machine; a connection is named by a
                            // leaf now, and what this offers is a pane.
                            //
                            // THE PALETTE, NOT A SECOND LIST OF MACHINES,
                            // for the reason the tab bar's chip gives: a
                            // flat menu of every host is unusable past a
                            // handful, and a searchable one built here
                            // would be a second machine picker to keep in
                            // step with the one ⌘K already is. It also
                            // satisfies C-EMPTY on its own — the picker
                            // is reachable from an empty workspace, which
                            // is what that clause requires of this state.
                            Button("Open a Pane…") {
                                NotificationCenter.default.post(
                                    name: .synaptyQuickConnect, object: true)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                }
                // The settings-panel toggle lives at ContentView level now
                // (WI-2026-08-08-052) — available on every page.
            } else {
                VStack(spacing: DS.Space.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DS.selectionAccent)
                    Text("Initializing terminal…")
                        .font(DS.Typography.detail)
                        .foregroundStyle(DS.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.background)
            }
        }
    }

    /// WRITTEN THE MOMENT THE ARRANGEMENT CHANGES ([[RFC-0015]]
    /// C-PERSIST: "writing on change rather than only at termination").
    ///
    /// The periodic write left a window: a pane opened and the workbench
    /// killed before the next tick left nothing on disk, and the human's
    /// panes came back as an empty workspace. A crash and a `kill` are
    /// exactly what a snapshot exists for, so the window cannot be small
    /// enough — it has to not exist.
    private func saveArrangement() {
        WorkspaceStore.save(paneManager.snapshot(planFor: { resumeCoordinator.plans[$0] }))
    }

    /// What the pane area shows, asked of the manager rather than decided
    /// here — this used to read `layout == nil` as "still dialling", which
    /// is the confusion [[RFC-0015]] C-EMPTY names.
    private var paneArea: WorkspaceManager.PaneArea {
        paneManager.activeWorkspace.map { paneManager.paneArea(of: $0) } ?? .empty
    }


    /// Emit the done→idle gaze transition (RFC-0004 C-OWNERSHIP) when the
    /// focused agent's merged status is `done` and the app is frontmost.
    /// The hub's conditional acceptance (idle only lands on a done prior)
    /// makes a stale-view emission harmless.
    private func emitGazeIfDone(_ agentID: String) {
        guard NSApp.isActive,
              agentMonitor.agents.first(where: {
                  AgentMonitor.namesSameAgent($0.id, agentID)
              })?.status == "done"
        else { return }
        HubEventClient.sendStatusSignal(port: hubManager.boundPort ?? 9000, agent: agentID, state: "idle")
    }

    /// Dial the hosts of every workspace that came back with released
    /// connections — a restore at launch, or an unarchive at any time.
    ///
    /// FAILURE IS NOT DETECTED HERE AND MUST NOT BE. `ensureTunnel`
    /// reports through the session's own state, so a host that cannot be
    /// reached shows the card it has always shown; inventing a second
    /// failure path would give the same event two voices.
    private func dialWorkspacesAwaitingIt() {
        // ONE DIAL PER HOST, however many workspaces and panes name it
        // ([[RFC-0015]] C-DIAL). A workspace no longer has a host of its
        // own, so the hosts to reach are asked of its panes.
        for workspaceID in paneManager.takeWorkspacesAwaitingDial() {
            guard let session = paneManager.workspaces.first(where: { $0.id == workspaceID })
            else { continue }
            for host in paneManager.hosts(ofWorkspace: session) {
                // The pane's own reattach already rode in on its restored
                // command; this opens the link that command needs.
                // MARKS THE CONNECTION UP, which nothing else on this
                // path does. A restored pane already carries its command,
                // so it never passes through `paneDidConnect` — and with
                // the dial now read from the CONNECTION ([[RFC-0015]]
                // C-DIAL), a link nobody marks stays `connecting` and its
                // panes show the dial forever.
                let dialledAs = tunnelManager.ensureTunnel(for: host) { [weak paneManager] _ in
                    paneManager?.markConnected(hostID: host.id)
                }
                // WATCHED PER LEAF, because the account is shown ON the
                // leaf now rather than over the workspace ([[RFC-0015]]
                // C-FAILURE). One host may serve several panes, and each
                // of them is waiting on this one dial.
                for pane in session.panes where paneManager.host(ofLeaf: pane.id)?.id == host.id {
                    paneManager.connectProgress.begin(session: pane.id, agentID: dialledAs)
                }
            }
        }
    }

    /// Re-dial the connection a leaf is bound to ([[RFC-0015]] C-DIAL:
    /// "Reconnecting a failed or released connection MUST be available
    /// from any leaf bound to it, and MUST re-dial the shared connection
    /// rather than creating a second one").
    private func retryLeaf(_ leafID: UUID) {
        guard let host = paneManager.host(ofLeaf: leafID) else { return }
        paneManager.markLeafConnecting(leafID)
        let dialledAs = tunnelManager.ensureTunnel(for: host) { [weak paneManager] result in
            paneManager?.paneDidConnect(leafID, command: result.command, agentID: result.agentID)
        }
        paneManager.connectProgress.begin(session: leafID, agentID: dialledAs)
    }

    /// Extracted from the main body: adding one closure argument to the
    /// inline call pushed an already-large expression past Swift's
    /// type-check budget. A computed property gives the checker a
    /// boundary to stop at.
    private var statusBar: some View {
        ContextStatusBar(
            paneManager: paneManager,
            agentMonitor: agentMonitor,
            hubManager: hubManager,
            taskMonitor: taskMonitor,
            execController: execController,
            transfers: transferService,
            forwards: forwardService,
            authority: transferAuthority,
            questions: questionService,
            hostStore: hostStore
        )
    }

    /// WHERE A NEW PANE GOES. [[RFC-0015]] C-WORKSPACE: "A connection
    /// opened from inside a workspace SHOULD place its pane there. The
    /// human is already somewhere, and putting the pane in a new
    /// container moves them out of the arrangement they were working
    /// in." A connection the human asked for from nowhere in particular
    /// — the host list, a quick connect — has no arrangement to stay in.
    private enum ConnectDestination { case activeWorkspace, ownWorkspace }

    /// ONE DIAL, THREE CALLERS. This was three copies of the same five
    /// lines — a workspace or a pane, `ensureTunnel`, `paneDidConnect`,
    /// `connectProgress.begin` — differing only in where the pane lands
    /// and whether an agent id rides along. The copies had already
    /// drifted: only one of them honoured C-WORKSPACE.
    ///
    /// `agentID` non-nil ATTACHES TO AN AGENT THAT IS ALREADY RUNNING
    /// rather than starting a fresh one: `connect.sh` runs `synapty
    /// attach --relay --id <that agent>` on the far side, and its exit 3
    /// is the held-name reattach.
    /// ONE FUNNEL FOR EVERY OFFER THAT ATTACHES, so the question below is
    /// asked wherever the offer is made — the sessions list, the agents
    /// list, a host row — rather than at whichever of them was noticed.
    private func connect(to host: HostEntry, agentID: String? = nil,
                         landing: ConnectDestination = .activeWorkspace) {
        // TAKING SOMEBODY ELSE'S SEAT IS NOT WHAT THIS OFFER SAYS IT
        // DOES ([[RFC-0014]] C-ONE-CLIENT). A row that lists a session as
        // somewhere to return to describes the ordinary case, where
        // nobody is there; when somebody is, accepting it disconnects a
        // person, and the human accepting has to be the one who decides.
        if let agentID, paneManager.attachWouldDisplace(agentID, on: host) {
            askBeforeDisplacing(agentID, on: host) {
                openPane(on: host, agentID: agentID, landing: landing)
            }
            return
        }
        openPane(on: host, agentID: agentID, landing: landing)
    }

    /// The alert is a SHEET on the window the human is looking at, not a
    /// free-floating panel: the act it is about happened in that window.
    private func askBeforeDisplacing(_ agentID: String, on host: HostEntry,
                                     then proceed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Somebody is attached to this session"
        // BY NAME WHEN THE FAR SIDE SAID ([[RFC-0014]] C-CLIENT-LABEL):
        // "gui@laptop:88 is attached" is a sentence the human can act on;
        // "a client" is not.
        let who = paneManager.attachedClient(agentID, on: host).map { "\($0) is attached to" }
            ?? "a client is attached to"
        alert.informativeText =
            "\(who) \(agentID) on \(host.label) — another Mac, or "
            + "someone working on the host itself. Opening it here disconnects them. "
            + "They will be told who took it, and they can take it back the same way."
        let go = alert.addButton(withTitle: "Open and Disconnect Them")
        go.hasDestructiveAction = true
        go.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let act: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: act)
        } else {
            act(alert.runModal())
        }
    }

    private func openPane(on host: HostEntry, agentID: String?,
                          landing: ConnectDestination) {
        page = .terminal
        let paneID: UUID
        if landing == .activeWorkspace, let workspaceID = paneManager.activeWorkspace?.id {
            paneID = paneManager.addRemotePane(
                toWorkspace: workspaceID, label: host.label, hostEntry: host)
        } else {
            let workspaceID = paneManager.addRemoteWorkspace(label: host.label, hostEntry: host)
            guard let first = paneManager.workspaces
                .first(where: { $0.id == workspaceID })?.panes.first?.id else { return }
            paneID = first
        }
        dial(paneID: paneID, on: host, agentID: agentID)
    }

    /// AN AGENT RUNNING ON ANOTHER MACHINE, OPENED HERE. Reachable only
    /// where the workbench has dialled that machine itself: the peer name
    /// is resolved to a host through the loopback port assignment, so an
    /// agent on a machine this Mac has never connected to has no host to
    /// dial and the row that names it is not offered as tappable.
    private func openRemoteAgent(machine: String, agentID: String) {
        // ASKED OF THE TUNNEL MANAGER, which knows the name each machine
        // reported for itself. This derived one from the human's label and
        // compared it against the reported one — two strings that differ
        // by construction ([[RFC-0010]] C-PEER-IDENTITY mints the name on
        // the machine being named), so opening an agent from the status
        // bar silently did nothing for every remote machine.
        guard let host = TunnelManager.shared?.host(forPeer: machine) else { return }
        connect(to: host, agentID: agentID)
    }

    private func handleHostConnect(_ host: HostEntry) {
        connect(to: host, landing: .ownWorkspace)
    }

    /// A GROUP AS A GRID ([[WI-2026-09-02-009]]): the workspace and its
    /// positions come from the manager in one act; each pane is then
    /// dialled exactly as a single remote pane is, so a member that fails
    /// shows the lost-link state in its own position and the rest come up.
    private func openGroupAsGrid(_ group: HostGroup) {
        let members = hostStore.hosts(inGroup: group.id).sorted { $0.label < $1.label }
        guard !members.isEmpty else { return }
        page = .terminal
        for (paneID, host) in paneManager.addRemoteGrid(label: group.label, hosts: members) {
            dial(paneID: paneID, on: host, agentID: nil)
        }
    }

    /// ONE DIAL for a pane already placed: the tail every connect path
    /// shares — the tunnel, the pane's command on answer, and the progress
    /// the pane shows meanwhile.
    private func dial(paneID: UUID, on host: HostEntry, agentID: String?) {
        let dialledAs = tunnelManager.ensureTunnel(for: host, agentID: agentID) { [weak paneManager] result in
            paneManager?.paneDidConnect(paneID, command: result.command, agentID: result.agentID)
        }
        paneManager.connectProgress.begin(session: paneID, agentID: dialledAs)
    }

    /// ONE COORDINATE SPACE, or the panel jumps on release. The stored
    /// width is in DESIGN points so it survives a UI-size change; the drag
    /// happens in the points on the glass. Clamping the drag against
    /// scaled bounds and then storing the result against unscaled ones
    /// meant the reachable range and the keepable range were different
    /// ranges at any UI size but 100%.
    ///
    /// A function rather than an inline closure because the body it lived
    /// in stopped type-checking in reasonable time.
    private func dragPanel(by delta: CGFloat) {
        var drag = panelDrag ?? EdgeDrag(from: DS.scaled(panelWidth))
        // NEGATED: this divider is on the panel's LEFT edge, so dragging
        // left widens it.
        drag.slide(by: -delta,
                   within: DS.scaled(PanelModel.minWidth)
                       ... DS.scaled(PanelModel.maxWidth(in: panelAvailableWidth)))
        panelDrag = drag
    }

    /// The column the context panel occupies.
    ///
    /// EXPANDED HOLDS THE SPACE IT WAS USING. Dropping the inline panel
    /// would hand its width back to the terminal, and a terminal that
    /// grows has been resized just as surely as one that shrinks — the
    /// SIGWINCH and the rewrap are the same either way. So the room stays
    /// occupied and the expanded copy is drawn over the top; the pane
    /// underneath keeps the size it had.
    @ViewBuilder
    private var contextPanelColumn: some View {
        Group {
            if panelModel.isExpanded {
                Color.clear
            } else {
                contextPanel
            }
        }
        .frame(width: max(panelDrag?.width ?? DS.scaled(panelWidth),
                          DS.scaled(PanelModel.minWidth)))
    }

    /// Extracted from the modifier chain: the compiler stopped
    /// type-checking that chain in reasonable time when a pane kind gained
    /// an associated value, and named this line while giving up.
    private var shortcutsSheet: some View {
        KeyboardShortcutsView(isPresented: $showShortcuts)
    }

    /// The find bar of the leaf the human is in, DOCKED TO THAT LEAF'S
    /// TOP-RIGHT CORNER ([[WI-2026-08-20-001]]).
    ///
    /// The position is the point: a bar floating over the middle of the
    /// window searches one pane and says nothing about which. Over the
    /// pane's own corner, it does not have to say.
    ///
    /// DRAWN AT THIS LEVEL AND POSITIONED FROM A PREFERENCE, because a
    /// ghostty pane is a Metal-backed NSView and SwiftUI content placed
    /// beside it in the split view is composited BEHIND it — the bar was
    /// in the accessibility tree, answered every query, and could not be
    /// seen ([[FocusedPaneFramePreference]]).
    @ViewBuilder
    private var findBarOverlay: some View {
        // ESTABLISH THE DEPENDENCY. Reading the observable generation here
        // is what makes SwiftUI re-run this view when a count arrives —
        // without it the read below sees the fresh dictionary but is never
        // asked to look again ([[WI-2026-09-02-001]]). `let _` rather than
        // a bare `_ =`, which a ViewBuilder rejects as a statement.
        let _ = searchTicker?.generation
        if page == .terminal,
           let leaf = paneManager.activeWorkspace?.focusedPaneID,
           paneManager.isFinding(leaf) {
            FindBarView(
                text: Binding(
                    get: { paneManager.findQuery(leaf) },
                    set: { paneManager.setFindQuery(leaf, $0) }),
                onTextChange: { runSearch($0, in: leaf) },
                onClose: {
                    runSearch("", in: leaf)
                    paneManager.endFinding(leaf)
                },
                // WHILE THIS FIELD HAS FOCUS the keystroke is row 2's
                // ([[RFC-0016]] C-DISPATCH), and the leaf it names is the
                // terminal a `terminal` command acts on. Reported on a
                // focus CHANGE — claiming it from `onAppear` mutates
                // shared state during a view update, which re-runs the
                // update and fires it again until the app never idles.
                onFocusChange: { hasFocus in
                    if hasFocus { KeyDispatcher.shared.claimTextEntry(leaf: leaf) }
                    else { KeyDispatcher.shared.releaseTextEntry(leaf: leaf) }
                },
                results: ghosttyAppState?.searchResults(forLeaf: leaf) ?? .init(),
                onNavigate: { forward in navigateSearch(forward, in: leaf) })
                .fixedSize()
                .offset(x: barOffset.x, y: barOffset.y)
        }
    }

    /// Top-right of the focused pane, inset by the gutter its content
    /// uses. The bar's own width is subtracted so its RIGHT edge lands on
    /// the pane's, which is what "docked to the corner" means.
    private var barOffset: CGPoint {
        guard let pane = focusedPaneFrame else { return CGPoint(x: 0, y: DS.scaled(60)) }
        let inset = DS.Space.md
        return CGPoint(x: pane.maxX - inset - DS.scaled(330),
                       y: pane.minY + inset)
    }

    private func navigateSearch(_ forward: Bool, in leafID: UUID) {
        guard let surface = GhosttyApp.shared?.surface(forLeaf: leafID) else { return }
        let action = forward ? "navigate_search:next" : "navigate_search:previous"
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    /// Ghostty's core does the searching; the bar is the embedder's half,
    /// and an empty needle ends the search rather than searching for
    /// nothing.
    private func runSearch(_ needle: String, in leafID: UUID) {
        guard let surface = GhosttyApp.shared?.surface(forLeaf: leafID) else {
            AppLog.search.error("search: no surface for leaf \(leafID, privacy: .public)")
            return
        }
        let action = needle.isEmpty ? "end_search" : "search:\(needle)"
        let performed = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
        // A SEARCH THAT SILENTLY DID NOTHING is what this looked like from
        // the outside — logging the action's fate is cheap insurance
        // against the next id-domain drift ([[WI-2026-09-02-001]]).
        AppLog.search.info(
            "search \(action, privacy: .public) performed=\(performed, privacy: .public)")
    }

    // MARK: - Quick connect (WI-2026-08-09-003)

    /// Cmd+K palette overlay: scrim + Spotlight-style panel.
    @ViewBuilder
    var quickConnectOverlay: some View {
        if showQuickConnect {
            ZStack(alignment: .top) {
                // Calm scrim; click outside dismisses.
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showQuickConnect = false }
                QuickConnectPalette(
                    hostStore: hostStore,
                    tunnelManager: tunnelManager,
                    onClose: { showQuickConnect = false },
                    onConnectHost: { host in
                        quickConnectLandsHere
                            ? connect(to: host)
                            : handleHostConnect(host)
                    },
                    onConnectTarget: { target in
                        // Ad-hoc session — the HostEntry is a value copy on
                        // the session, NOT persisted to the store.
                        //
                        // WHERE IT LANDS IS THE INVOCATION'S ANSWER, not
                        // the row's. Only the host row honoured this at
                        // first, so asking the machine chip for a machine
                        // and then typing an ssh target — or picking the
                        // local terminal — still made a workspace of its
                        // own, which is the thing the chip exists to stop.
                        let entry = adhocEntry(for: target)
                        quickConnectLandsHere
                            ? connect(to: entry)
                            : handleHostConnect(entry)
                    },
                    onSaveTarget: { target in
                        // "Save as Host…" saves immediately, then opens the
                        // editor on it for polishing.
                        let entry = adhocEntry(for: target)
                        hostStore.addHost(entry)
                        page = .hosts
                        NotificationCenter.default.post(
                            name: .synaptyEditHost,
                            object: nil,
                            userInfo: ["id": entry.id.uuidString]
                        )
                    },
                    onLocalTerminal: {
                        page = .terminal
                        if quickConnectLandsHere, let here = paneManager.activeWorkspace?.id {
                            paneManager.addPane(content: .terminal(command: nil), toWorkspace: here)
                        } else {
                            paneManager.addLocalWorkspace()
                        }
                    },
                    paneManager: paneManager,
                    onGoToPane: { leafID in
                        page = .terminal
                        paneManager.revealLeaf(leafID)
                    },
                    initialQuery: DevLaunchArgs.quickConnectQuery ?? ""
                )
                .padding(.top, DS.scaled(140))
            }
            // THE EXIT IS CLAIMED WHILE THE PALETTE EXISTS, not once its
            // field has focus — the field takes first responder
            // asynchronously, and an Escape pressed in that window went to
            // the terminal instead ([[KeyDispatcher.claimEscape]]).
            .onAppear { KeyDispatcher.shared.claimEscape { showQuickConnect = false } }
            .onDisappear { KeyDispatcher.shared.releaseEscape() }
        }
    }

    private func adhocEntry(for target: SSHTarget) -> HostEntry {
        HostEntry(
            label: target.host,
            address: target.host,
            port: target.port,
            username: target.username ?? ""
        )
    }
}


// MARK: - Window lifecycle + page-switch effects

/// Holds the window min-size enforcement, teardown, and page-switch side
/// effects (surface pausing + activity-poll gating) — extracted from the
/// main body to keep its expression type-checkable (WI-2026-08-08-043).
struct WindowLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Binding var page: AppPage
    let taskMonitor: TaskMonitor
    let ghosttyAppProvider: () -> GhosttyApp?
    let onStart: () -> Void
    let onStop: () -> Void
    /// Whether the services are up, so a phase that comes round twice
    /// starts them once and stops them once.
    @State private var running = false

    /// What a scenePhase transition means for the services, as a pure
    /// function of what the app can see about itself.
    ///
    /// MEASURED ON THE REAL APP ([[WI-2026-09-02-032]]): Cmd-Tab away and
    /// back produces no transition at all, so focus loss never reached
    /// this switch — the audit's hypothesis was false. HIDING the app
    /// (Cmd-H) goes active → background, and that DID fire onStop: every
    /// SSH connection released and the hub shut down for a glance at
    /// another app, then all of it restarted on unhide. So `.background`
    /// is read with the windows: a window that is hidden or minimised is
    /// a window the human is coming back to, and only a window that is
    /// gone — closed, or the app quitting — tears the services down.
    enum Decision: Equatable { case start, stop, none }

    static func decide(phase: ScenePhase, hidden: Bool, windowAlive: Bool, running: Bool) -> Decision {
        switch phase {
        case .active:
            return running ? .none : .start
        case .background, .inactive:
            guard running else { return .none }
            return (hidden || windowAlive) ? .none : .stop
        @unknown default:
            return .none
        }
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                // The SwiftUI WindowGroup window often does not exist yet
                // at applicationDidFinishLaunching — enforce the min size
                // on the real window here (WI-2026-08-08-033). Same timing
                // applies to the hidden-titlebar chrome (WI-2026-08-08-090).
                if let window = NSApp.keyWindow {
                    WindowChrome.apply(to: window)
                }
            }
            // Service start/stop is scenePhase-driven (WI-2026-08-08-050):
            // onDisappear timing is unreliable (window close, tree removal).
            .onChange(of: scenePhase) { was, phase in
                // SAID IN THE LOG, because what fires here decides whether
                // every SSH connection and the hub die when the human
                // glances at another app ([[WI-2026-09-02-032]]).
                let hidden = NSApp.isHidden
                let windowAlive = hidden || NSApp.windows.contains { $0.isMiniaturized || $0.isVisible }
                let decision = Self.decide(phase: phase, hidden: hidden, windowAlive: windowAlive, running: running)
                AppLog.lifecycle.info(
                    "scenePhase \(String(describing: was), privacy: .public) → \(String(describing: phase), privacy: .public); hidden=\(hidden) windowAlive=\(windowAlive) → \(String(describing: decision), privacy: .public)")
                switch decision {
                case .start:
                    running = true
                    onStart()
                case .stop:
                    AppLog.lifecycle.warning("onStop: releasing connections and shutting the hub down")
                    running = false
                    onStop()
                case .none:
                    break
                }
            }
            // Page switch: pause hidden terminal surfaces (WI-2026-08-07-006).
            .onChange(of: page) { _, newPage in
                ghosttyAppProvider()?.setSurfacesPaused(newPage != .terminal)
            }
    }
}


// MARK: - Notification handlers (extracted for type-checker headroom)

/// All NotificationCenter observers in one modifier — keeps the main body
/// expression small enough for the type-checker (WI-2026-08-08-043,
/// WI-2026-08-08-079).
private struct NotificationHandlers: ViewModifier {
    @Binding var page: AppPage
    @Binding var showShortcuts: Bool
    let panelModel: PanelModel
    @Binding var ghosttyAppState: GhosttyApp?
    @Binding var searchTicker: GhosttyApp.SearchTicker?
    let paneManager: WorkspaceManager
    let taskMonitor: TaskMonitor
    /// Only to turn the machine the human named into the host a pane is
    /// opened on ([[WI-2026-08-28-009]]).
    let hostStore: HostStore

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .synaptyNewSession)) { _ in
                page = .terminal
                paneManager.addLocalWorkspace()
            }
            .onReceive(NotificationCenter.default.publisher(for: .synaptyTunnelFailed)) { note in
                guard let hostID = note.userInfo?["hostID"] as? UUID,
                      let message = note.userInfo?["message"] as? String else { return }
                paneManager.markWorkspaceFailed(hostID: hostID, message: message)
            }
            .onReceive(NotificationCenter.default.publisher(for: .synaptyFind)) { _ in
                // ON THE FOCUSED LEAF, AND ONLY IF IT IS A TERMINAL.
                // `beginFinding` refuses anything else, so pressing ⌘F in
                // a file leaf opens nothing rather than a bar belonging to
                // no terminal ([[WI-2026-08-20-001]]).
                // ONLY WHEN IT IS NOT ALREADY OPEN, and that guard is
                // load-bearing: `start_search` makes ghostty report a
                // search action back to us, our handler posts this same
                // notification, and without the guard the two of them
                // open the search forever. `beginFinding` answers "is
                // this a terminal", not "was it shut" — so the question
                // has to be asked here.
                if let leaf = paneManager.activeWorkspace?.focusedPaneID,
                   !paneManager.isFinding(leaf),
                   paneManager.beginFinding(leaf) {
                    // OPEN THE ENGINE'S SEARCH SESSION, not just our bar.
                    // `search:<needle>` sets the terms; `start_search` is
                    // what tells ghostty a search is under way — and it is
                    // only then that it reports how many matches there are
                    // ([[GhosttyApp.SearchResults]]). With the bar alone,
                    // the field worked, the matches highlighted, and the
                    // count stayed empty.
                    if let surface = GhosttyApp.shared?.surface(forLeaf: leaf) {
                        _ = "start_search".withCString { ptr in
                            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                        }
                        // ⌘F WITH A SELECTION SEARCHES FOR IT — the platform
                        // convention, and what "search_selection" exists
                        // for in the core ([[WI-2026-09-02-002]]).
                        if let selected = GhosttyApp.shared?.selectedText(forLeaf: leaf),
                           !selected.contains("\n") {
                            paneManager.setFindQuery(leaf, selected)
                            _ = "search:\(selected)".withCString { ptr in
                                ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                            }
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .synaptyShowShortcuts)) { _ in
                showShortcuts = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .synaptyToggleSettingsPanel)) { _ in
                // The shortcut still means "the appearance panel", which is
                // what it has always opened.
                panelModel.toggle(.appearance)
            }
            .onReceive(NotificationCenter.default.publisher(for: .synaptyShowExposures)) { note in
                // A HUMAN'S CLICK, never an arriving exposure. This is the
                // only path that opens agent content, and it starts on the
                // status bar where the human chose to look ([[RFC-0013]]
                // C-REQUEST-NOT-SEIZE).
                //
                // It opens a PANE now rather than a panel, so what agents
                // exposed can sit beside the work it came out of.
                //
                // ON THE MACHINE THE HUMAN NAMED. A services pane shows one
                // connection's exposures, so opening it beside the focused
                // pane showed a different machine's than the badge counted
                // ([[WI-2026-08-28-009]]).
                if let workspace = paneManager.activeWorkspace?.id {
                    let machine: WorkspaceManager.PaneMachine
                    if let asked = note.object as? ExposureDestination {
                        machine = .machine(asked.hostID.flatMap { id in
                            hostStore.hosts.first { $0.id == id }
                        })
                    } else {
                        machine = .whereTheHumanIsLooking
                    }
                    paneManager.addPane(content: .services, toWorkspace: workspace, on: machine)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .synaptyShowPage)) { note in
                // Go-to menu / clickable status-bar badges (WI-2026-08-08-053).
                guard let raw = note.userInfo?["page"] as? String,
                      let target = AppPage(rawValue: raw) else { return }
                page = target
            }
            .onReceive(NotificationCenter.default.publisher(for: .synaptyGhosttyReady)) { _ in
                adoptGhostty()
            }
            // BOTH ORDERS HAPPEN. The delegate creates GhosttyApp in
            // applicationDidFinishLaunching and posts the notification
            // there. This view may mount BEFORE that (window restoration,
            // WI-2026-08-08-079 — the notification catches it) or AFTER
            // it — measured 2026-09-02 on a cold `open` of the Release
            // build: the window sat on "Initializing terminal…" with the
            // main thread idle, no surfaces and no ptys, because the
            // notification had gone to a view that did not exist yet.
            // Asking on appear covers that order ([[WI-2026-09-02-004]]).
            .onAppear { adoptGhostty() }
    }

    /// The one hookup, from whichever side arrives second. Idempotent:
    /// assigning the same state and the same closures twice changes
    /// nothing, so neither caller needs to know about the other.
    private func adoptGhostty() {
        guard let shared = GhosttyApp.shared else { return }
        ghosttyAppState = shared
        searchTicker = shared.searchTicker
        // What the core reports about a pane, routed to the model that
        // owns the pane ([[WI-2026-09-02-002]]).
        shared.onCommandFinished = { [weak paneManager] leaf, exit, seconds in
            paneManager?.leafCommandFinished(leaf, exitCode: exit, duration: seconds)
        }
        shared.onProgress = { [weak paneManager] leaf, progress in
            paneManager?.leafProgress(leaf, progress)
        }
        shared.broadcastTargets = { [weak paneManager] leaf in
            paneManager?.broadcastTargets(from: leaf) ?? []
        }
    }
}
