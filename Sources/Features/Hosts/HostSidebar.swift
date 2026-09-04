import SwiftUI
import UniformTypeIdentifiers

/// What a dragged session row carries ([[WI-2026-08-17-023]]).
///
/// ITS OWN TYPE, not the tab's: dropping a tab into the session list and a
/// session onto the tab bar are both nonsense, and a shared identifier
/// would make them acceptable to each other.
extension UTType {
    static let sessionDragPayload = UTType(exportedAs: "dev.synapty.session-drag")
}

/// A WORKSPACE PICKED UP IN THE SIDEBAR ([[WI-2026-08-17-023]]).
///
/// The same shape the tab bar has always used — a `Codable` payload
/// through `.draggable` to a `.dropDestination` — which is now possible
/// here because these rows no longer live in a `List`
/// ([[WI-2026-08-17-028]]).
struct WorkspaceDragPayload: Codable, Transferable {
    let workspaceID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sessionDragPayload)
    }
}

/// Session-based sidebar with layered navigation.
/// Top: grouped navigation (workspace / infrastructure / collaboration /
/// system). Bottom: active workspaces (always visible so you can jump back
/// to the terminal from any page).
struct HostSidebar: View {
    var hostStore: HostStore
    var paneManager: WorkspaceManager
    var tunnelManager: TunnelManager
    var agentMonitor: AgentMonitor
    /// Live badge sources (WI-2026-08-09-005): Tasks shows the doing
    /// count, Hub shows connected agents.
    var taskMonitor: TaskMonitor
    /// ⌘-hold session hints (WI-2026-08-09-015).
    var hintState: ModifierHintState? = nil

    /// Currently displayed application page (navigation selection).
    @Binding var page: AppPage
    /// The session under the cursor while it is being dragged
    /// ([[WI-2026-08-17-023]]).
    ///
    /// THE DROP DOES NOT DEPEND ON READING THE PROVIDER BACK. The item
    /// travels so that the platform has something to drag, but both ends
    /// of this gesture are this view — so what was picked up is simply
    /// remembered, and a drop that never manages to decode an item
    /// provider still lands.


    /// ID of the session currently being renamed inline.
    @State private var editingWorkspaceID: UUID?
    /// The workspace the human has been asked about and has not yet
    /// answered for ([[WorkspaceDestruction]]).
    @State private var closingWorkspace: WorkspaceManager.Workspace?

    /// WHAT IS OVER WHICH ROW ([[WI-2026-08-17-028]]). A row is two
    /// receivers: a workspace dropped on it lands BEFORE it, and a pane
    /// dropped on it joins it — an insertion and a container, which the
    /// human has to be able to tell apart before they let go. One of each
    /// id, because a pointer is in one place at a time.
    @State private var reorderTargetID: UUID?
    @State private var paneTargetID: UUID?
    @State private var endTargeted = false
    /// ONE shared ticker for all session rows (WI-2026-08-08-039) — the
    /// per-row Timer.publish churned a timer per row per parent render.
    @State private var sessionNow = Date()

    /// FOLDED SECTIONS STAY FOLDED. A human who put a long list away did
    /// not put it away until the next launch, and re-opening every time
    /// is what makes a fold not worth using.
    @AppStorage("synapty.sidebarStillRunningCollapsed") private var runningCollapsed = false


    /// AN AGENT ON ANOTHER MACHINE, OPENED HERE. This parameter lived on
    /// the hub popover and travelled two views without ever being
    /// invoked; the popover has been a problem list since the Machines
    /// section came out of it, and the rows are here now.
    var onOpenRemoteAgent: ((String, String) -> Void)?
    /// OPEN A SESSION A HOST REPORTED, by the name that host gave it —
    /// the same name `connect` reattaches a holder by.
    var onOpenSession: ((HostEntry, String) -> Void)?
    /// Called when the user selects a session in the list (switch to terminal page).
    var onSessionSelect: (() -> Void)?

    /// Navigation items, grouped by layer (WI-2026-08-08-053): workspace /
    /// management / configuration. Vertical LABELED list — the native
    /// macOS source-list idiom (WI-2026-08-09-005); the icon-only rail
    /// read as a cramped toolbar.
    private static let navGroups: [[(page: AppPage, icon: String, label: String)]] = [
        // Workspace
        [(.terminal, "terminal", "Terminal")],
        // Management — domains only (WI-2026-08-09-007). Activity was a
        // Tasks tab under that rule and is a domain of its own now: the
        // stream carries what agents asked for, the files this workbench
        // moved, and what a human did to a machine's files from a pane
        // ([[RFC-0015]] C-PANE-WRITES), and only the first is a task. The
        // Hub service is still the status-bar popover.
        [
            (.hosts, "server.rack", "Hosts"),
            (.tasks, "checklist", "Tasks"),
            (.activity, "list.bullet.rectangle", "Activity"),
        ],
        // Configuration
        [(.settings, "gearshape", "Settings")],
    ]

    /// Live badge per page (WI-2026-08-09-005); nil = no badge. The agent
    /// count lives in the status bar's Hub item (WI-2026-08-09-007).
    private func badge(for target: AppPage) -> Int? {
        switch target {
        case .terminal:
            // Panes waiting for human input (WI-2026-08-09-021).
            let waiting = paneManager.attentionCount
            return waiting > 0 ? waiting : nil
        case .tasks:
            let doing = taskMonitor.projectCounts.values.reduce(0) { $0 + $1.doing }
            return doing > 0 ? doing : nil
        default:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // No manual titlebar strip: the window safe area already
            // clears the traffic-light band, and the old Color.clear
            // doubled the inset (WI-2026-08-09-011). The transparent
            // titlebar keeps handling window dragging regardless.



            // Labeled navigation list — groups separated by breathing
            // space, not hairlines (WI-2026-08-09-005).
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                ForEach(Self.navGroups.indices, id: \.self) { groupIndex in
                    if groupIndex > 0 {
                        Color.clear.frame(height: DS.Space.md)
                    }
                    ForEach(Self.navGroups[groupIndex], id: \.page) { item in
                        NavListRow(
                            icon: item.icon,
                            label: item.label,
                            isActive: page == item.page,
                            badge: badge(for: item.page)
                        ) {
                            page = item.page
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)

            DSHairline()
                .padding(.horizontal, DS.Space.md)

            // Workspaces — always visible; tapping one returns to Terminal.
            workspacesSection

            // EVERYTHING RUNNING THAT NOTHING ON SCREEN SHOWS.
            if runningCount > 0 { stillRunningSection }
        }
        // NO FOCUS RINGS ANYWHERE IN THE SIDEBAR. Keyboard scope is grids
        // and forms by decision (2026-08-16); the sidebar is pointer
        // territory. Without this, launching onto any page whose content
        // does not seize first responder let AppKit hand initial key focus
        // to the first button in the window — this sidebar's Terminal row
        // — which then wore a system focus ring nobody asked for, on
        // every such launch (measured on Tasks, Settings and Activity).
        .focusEffectDisabled()
        // Behind-window vibrancy instead of a flat fill — the native macOS
        // sidebar look (WI-2026-08-08-090). Runs under the titlebar strip.
        // PAINT, NOT A TARGET. This reaches into the title-bar strip —
        // the traffic lights sit on it — and a hit-testable background
        // there swallows the double-click the strip owes the human
        // ([[TitlebarDoubleClickCatcher]]). Nothing in the sidebar draws
        // its behaviour from this layer; the rows have their own.
        .background(DSChromeBackground().allowsHitTesting(false))
    }

    /// Agents on other machines that nothing else in this list already
    /// names.
    ///
    /// AN AGENT WITH A PANE HERE IS NOT LISTED — it already has a row —
    /// and neither is one a session row above names. Setting a pane aside
    /// forgets its leaf, so `leafShowing` stops answering for it and the
    /// same work appeared twice under one heading, once as the pane the
    /// human closed and once as an agent nothing shows. Two rows for one
    /// thing is worse than the silence this list replaces.
    private var runningAgents: [AgentInfo] {
        agentMonitor.agents
            // ASKED, NOT RECORDED. This is a view body ([[WI-2026-08-29-001]]).
            .filter { $0.isRemote && paneManager.leafShowing(agent: $0.id) == nil }
            .filter { !paneManager.stillRunningNames($0.bareID, onPeer: $0.machine) }
            .sorted { ($0.machine, $0.bareID) < ($1.machine, $1.bareID) }
    }

    /// WHETHER THIS MACHINE CAN BE OPENED FROM HERE. The peer name is
    /// resolved to a host through the loopback port the workbench
    /// assigned when IT dialled that machine — so an agent on a machine
    /// this Mac has never connected to has no host to dial, and a row
    /// that looked tappable would do nothing at all.
    private func reachable(_ agent: AgentInfo) -> Bool {
        !agent.machine.isEmpty && TunnelManager.shared?.host(forPeer: agent.machine) != nil
    }

    /// EVERYTHING RUNNING THAT NOTHING ON SCREEN SHOWS.
    ///
    /// ONE QUESTION, ASKED ONCE. Three things feed this list — a pane the
    /// human archived ([[RFC-0015]] C-PANE-ARCHIVE), a holder a host
    /// reported ([[RFC-0014]] C-END), an agent the hub knows of on
    /// another machine ([[RFC-0011]] C-VISIBILITY) — and they used to be
    /// two sections. The split was along where the fact CAME FROM, which
    /// is an implementation fact: a holder listing, a hub registration.
    /// The human's question is one, "what of mine is running that I
    /// cannot see", and this list's own reasoning already said what
    /// follows from that — "two lists would ask it twice". That argument
    /// merged the first two; it never stopped applying to the third.
    ///
    /// AND THE SPLIT COULD SHOW ONE THING TWICE. Setting a pane aside
    /// forgets its leaf, so its agent stopped being "shown by a pane
    /// here" and appeared BOTH as an archived-pane row and, if the hub still
    /// knew it, as an agent on another machine. Nothing subtracted one
    /// from the other. Under one heading the subtraction has an obvious
    /// place, and `runningAgents` is it.
    ///
    /// NOT NAMED "SESSIONS", AND NOT "ELSEWHERE". This app already spends
    /// the word session on what a workspace holds, so a SESSIONS heading
    /// under WORKSPACES read as a subdivision of one. "Elsewhere" named a
    /// place, when place is not the line the rows differ on — every
    /// holder in this list is elsewhere too. What is true of every row,
    /// and is the reason to look, is that it is running and nobody is
    /// watching it.
    private var stillRunningSection: some View {
        VStack(spacing: 0) {
            HStack {
                DSSectionDisclosure(text: "Still Running", count: runningCount,
                                    collapsed: $runningCollapsed)
                Spacer()
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.top, DS.Space.sm)
            .padding(.bottom, DS.Space.xxs)

            if !runningCollapsed {
                // SCROLLING, BECAUSE NOTHING HERE BOUNDS THE LENGTH. This
                // list is every archived pane plus every holder every
                // connected host reports plus every agent the hub knows
                // elsewhere, and the human chooses none of those numbers.
                // In a bare stack the rows past the fold were drawn and
                // could not be reached (hub issue #4,
                // [[WI-2026-09-03-013]]).
                //
                // ITS OWN, RATHER THAN ONE OUTER SCROLLVIEW OVER THE
                // SIDEBAR. That is the ordinary macOS shape and it is not
                // what is done here: the workspaces list's ScrollView
                // carries `.scrollContentBackground`, the `.task` ticker
                // that drives `refreshRemoteSessions`, and a
                // `.confirmationDialog`, and moving three load-bearing
                // modifiers across a view with this much recorded history
                // about drop targets and key focus is out of proportion
                // to making a list reachable.
                ScrollView {
                    LazyVStack(spacing: DS.Space.xxs) {
                        // IN THE ORDER EACH SOURCE DECIDED, and grouped by
                        // source rather than re-sorted across them. What the
                        // human closed last is what they are likeliest to
                        // want back, so those lead; a host has already
                        // ordered its own listing, and re-ordering it here
                        // would be a second answer to a settled question.
                        ForEach(paneManager.archivedPanes) { row in
                            ArchivedPaneRow(
                                row: row,
                                machine: paneManager.host(ofArchivedPane: row.id)?.label,
                                onReturn: { paneManager.unarchivePane(row.id) },
                                onEnd: { paneManager.endArchivedPane(row.id) })
                        }
                        ForEach(hostsWithSessions, id: \.0.id) { host, sessions in
                            ForEach(sessions) { session in
                                RemoteSessionRow(
                                    session: session,
                                    machine: host.label,
                                    onOpen: { onOpenSession?(host, session.name) },
                                    onEnd: { Task { await paneManager.endRemoteSession(session.name, on: host) } })
                            }
                        }
                        // LAST, BECAUSE THEY KNOW LEAST. A holder row carries
                        // where the work is and how long nobody has watched
                        // it; what crosses a relay is identity, peer, status
                        // and reachability and nothing else.
                        ForEach(runningAgents) { agent in
                            RemoteAgentRow(
                                agent: agent,
                                openable: reachable(agent),
                                // THE BARE IDENTITY, NOT THE MERGED LIST'S KEY.
                                // `id` carries the routing qualifier this
                                // workbench minted at ITS relay boundary
                                // ([[RFC-0009]] C-IDENTITY-SCOPE), and the far
                                // side knows the session by the name it minted —
                                // so `attach --relay --id local-1a2b@deskmac-2630`
                                // would look for a session that machine has never
                                // heard of. `bareID`'s own doc says it: anything
                                // handing the name onward AS AN IDENTITY wants
                                // this one.
                                onOpen: { onOpenRemoteAgent?(agent.machine, agent.bareID) })
                        }
                    }
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.bottom, DS.Space.sm)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// Hosts that answered, and what they answered — hosts with nothing
    /// on them contribute no rows.
    private var hostsWithSessions: [(HostEntry, [RemoteSessions.Session])] {
        paneManager.remoteSessions.compactMap { hostID, sessions in
            guard !sessions.isEmpty,
                  let host = hostStore.hosts.first(where: { $0.id == hostID })
            else { return nil }
            return (host, sessions)
        }
        .sorted { $0.0.label < $1.0.label }
    }

    private var runningCount: Int {
        paneManager.archivedPanes.count
            + paneManager.remoteSessions.values.reduce(0) { $0 + $1.count }
            + runningAgents.count
    }

    /// The workspaces list with the "+" new-session action.
    private var workspacesSection: some View {
        VStack(spacing: 0) {
            HStack {
                DSSectionLabel(text: "Workspaces", count: paneManager.workspaces.isEmpty ? nil : paneManager.workspaces.count)
                Spacer()
                // Borderless icon button — the Mail/Notes sidebar-action
                // idiom (WI-2026-08-08-090). Opens the quick-connect
                // palette: ONE choose-and-connect surface instead of a
                // duplicate picker popover (WI-2026-08-09-004).
                DSIconButton(icon: "plus",
                             help: CommandHint.help("New workspace", for: "palette.quick-connect"),
                             size: 22) {
                    // A WORKSPACE OF ITS OWN, because that is what this
                    // button is for. The chip in the title bar is the one
                    // that lands a machine in the workspace you are in.
                    NotificationCenter.default.post(name: .synaptyQuickConnect, object: false)
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.md)
            .padding(.bottom, DS.Space.sm)

            // NOT A LIST, AND THAT IS THE POINT ([[WI-2026-08-17-028]]).
            //
            // A `List` delivers a drop to neither its rows nor anything
            // around it. WI-2026-08-17-023 measured the first half of
            // that and worked around it with the list's own `onInsert`;
            // a pane dropped on a workspace needs the second half, and
            // there is no list-shaped substitute for "onto THIS row".
            //
            // What the List was providing here is scrolling. It brought
            // no selection (WI-2026-08-09-009: the system highlight flips
            // between accent and gray with keyboard focus, clashing with
            // the stable pill), and WorkspaceRow already draws its own
            // pill, hover, padding and tap. So the rows move into a
            // scrolling stack and BOTH drags become the one mechanism the
            // tab bar has used all along — `.draggable` to a
            // `.dropDestination`, which the manager has had an API
            // shaped for since WI-2026-08-17-023 and could not reach.
            ScrollView {
                if paneManager.workspaces.isEmpty {
                    VStack(spacing: DS.Space.sm) {
                        Image(systemName: "terminal")
                            .font(DS.Icon.feature)
                            .foregroundStyle(DS.textTertiary)
                        Text("No active workspaces")
                            .font(DS.Typography.detail)
                            .foregroundStyle(DS.textSecondary)
                        Text("Press + to start a local or remote session")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.xxl)
                } else {
                    // Agent lookup once per body — O(agents) total, not
                    // O(agents) per row (WI-2026-08-08-040).
                    // A SHELL THAT REGISTERED FOR ROUTING IS NOT AN AGENT
                    // ([[AgentInfo.isAgent]]). Without this every plain
                    // terminal drew a question mark beside its workspace.
                    let agentsByID = Dictionary(
                        uniqueKeysWithValues: agentMonitor.agents
                            .filter(\.isAgent).map { ($0.id, $0) }
                    )
                    LazyVStack(spacing: DS.Space.xxs) {
                        ForEach(Array(paneManager.orderedWorkspaces.enumerated()), id: \.element.id) { index, session in
                            // An agent in this workspace, if any. A
                            // workspace has no agent of its own — the ids
                            // are the leaves' ([[RFC-0015]]
                            // C-LEAF-BINDING).
                            let agent = session.panes
                                .compactMap { paneManager.agentID(forLeaf: $0.id) }
                                .compactMap { agentsByID[$0] }.first
                            let attention = agent.map { agentMonitor.needsAttention.contains($0.id) } ?? false
                            WorkspaceRow(
                                session: session,
                                paneManager: paneManager,
                                hostStore: hostStore,
                                editingWorkspaceID: $editingWorkspaceID,
                                closing: $closingWorkspace,
                                agent: agent,
                                agentNeedsAttention: attention,
                                isActive: paneManager.activeWorkspaceID == session.id,
                                isDropTarget: paneTargetID == session.id,
                                needsAttention: paneManager.workspaceNeedsAttention(session),
                                hintIndex: (hintState?.level == .session && index < 9) ? index + 1 : nil,
                                now: sessionNow,
                                onTap: {
                                    // A RENAME ENDS WHEN THE HUMAN GOES
                                    // ELSEWHERE. The field used to lose
                                    // focus to the scroll container, which
                                    // committed it; the container stopped
                                    // being focusable when its Return
                                    // handler was removed, so nothing took
                                    // focus and a row could be left sitting
                                    // in edit state after the human had
                                    // moved on.
                                    if let editing = editingWorkspaceID, editing != session.id {
                                        editingWorkspaceID = nil
                                    }
                                    // TAKEN BACK OUT BY BEING OPENED. A
                                    // separate "reopen" gesture would
                                    // make an archived row a thing you
                                    // cannot click, which is not what a
                                    // row that is still listed means
                                    // ([[RFC-0015]] C-ARCHIVE).
                                    if session.isArchived {
                                        paneManager.unarchiveWorkspace(session.id,
                                                                       hostStore: hostStore)
                                    }
                                    // THE AGENT IS A PANE'S, NOT THE
                                    // WORKSPACE'S ([[RFC-0015]]
                                    // C-LEAF-BINDING). Selecting the
                                    // container lands on whichever leaf
                                    // was focused last, which is the
                                    // agent's only by luck — and a row
                                    // wearing an attention mark is a
                                    // request to be taken to the pane that
                                    // raised it, not near it.
                                    if let agent,
                                       paneManager.leafShowing(agent: agent.id) != nil {
                                        paneManager.focusAgent(agent.id)
                                        agentMonitor.clearAttention(agent.id)
                                    } else {
                                        // Always select + switch — works even when
                                        // the row is already the active session.
                                        paneManager.activeWorkspaceID = session.id
                                    }
                                    onSessionSelect?()
                                }
                            )
                            .draggable(WorkspaceDragPayload(workspaceID: session.id))
                            // A WORKSPACE DROPPED ON THIS ONE takes its
                            // place, exactly as a tab dropped on a tab
                            // does ([[WI-2026-08-17-023]]).
                            .dropDestination(for: WorkspaceDragPayload.self) { payloads, _ in
                                guard let payload = payloads.first else { return false }
                                paneManager.moveWorkspace(payload.workspaceID, before: session.id)
                                return true
                            } isTargeted: { over in
                                reorderTargetID = over ? session.id
                                    : (reorderTargetID == session.id ? nil : reorderTargetID)
                            }
                            // AND A PANE DROPPED ON IT JOINS IT
                            // ([[WI-2026-08-17-028]]). The human is not
                            // taken there: sending a pane away is not a
                            // request to follow it, and switching the
                            // sidebar under a drag would move the layout
                            // out from under the next one.
                            .dropDestination(for: TabDragPayload.self) { payloads, _ in
                                guard let payload = payloads.first else { return false }
                                paneManager.movePane(payload.paneID, toWorkspace: session.id)
                                return true
                            } isTargeted: { over in
                                paneTargetID = over ? session.id
                                    : (paneTargetID == session.id ? nil : paneTargetID)
                            }
                            // A WORKSPACE lands BEFORE this row, so the
                            // caret goes in the GAP above it, centred in
                            // the 2pt the stack leaves between rows and
                            // inset from both ends — a rule the full
                            // width of a row is a separator, and a caret
                            // is shorter than what it sits between for
                            // the same reason a text cursor is shorter
                            // than its line.
                            //
                            // A VERTICAL LIST GETS A CARET AND A TAB
                            // STRIP OPENS A SLOT, which is not an
                            // inconsistency: it is what Finder and Chrome
                            // respectively do, because a row's height is
                            // uniform and a tab's width is not.
                            .dropCaret(reorderTargetID == session.id, on: .top,
                                       gap: DS.Space.xxs, inset: DS.Space.sm)
                            .contextMenu {
                                Button("Rename") {
                                    editingWorkspaceID = session.id
                                }
                                Button(session.isPinned ? "Unpin" : "Pin") {
                                    paneManager.setPinned(session.id, !session.isPinned)
                                }
                                DSHairline()
                                // PUTTING WORK AWAY IS NOT CLOSING IT, so
                                // it is not behind the same question: the
                                // arrangement is kept and the row stays
                                // ([[RFC-0015]] C-ARCHIVE).
                                if session.isArchived {
                                    Button("Reopen") {
                                        paneManager.unarchiveWorkspace(session.id,
                                                                       hostStore: hostStore)
                                        paneManager.activeWorkspaceID = session.id
                                    }
                                } else {
                                    Button("Archive") {
                                        paneManager.archiveWorkspace(session.id)
                                    }
                                }
                                DSHairline()
                                Button("Close Session") {
                                    closingWorkspace = session
                                }
                            }
                        }

                        // PAST THE LAST ROW, so a workspace can be made
                        // last — the one destination a row cannot offer,
                        // and the same trailing target the tab bar draws.
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: DS.Space.xl)
                            .contentShape(Rectangle())
                            .dropDestination(for: WorkspaceDragPayload.self) { payloads, _ in
                                guard let payload = payloads.first else { return false }
                                paneManager.moveWorkspaceToEnd(payload.workspaceID)
                                return true
                            } isTargeted: { endTargeted = $0 }
                            .dropCaret(endTargeted, on: .top,
                                       gap: DS.Space.xxs, inset: DS.Space.sm)
                    }
                    .padding(.horizontal, DS.Space.md)
                }
            }
            .scrollContentBackground(.hidden)
            // NO CONTAINER-LEVEL RETURN HANDLER, and its removal is the
            // fix rather than a loss. It renamed the active workspace,
            // and it rode on `.focusable()` — which a List absorbed and a
            // ScrollView does not: the scroll container took key focus
            // and held it, so Return pressed ANYWHERE, including in the
            // ⌘K palette, renamed a workspace in the sidebar instead of
            // doing what the human was looking at.
            //
            // A shortcut on a scroll container was the wrong shape for a
            // per-row act in the first place. Renaming keeps its three
            // real entry points: the row's context menu, a second click
            // on a selected row, and the accessibility action.
            // ONE shared ticker for every session row's live duration
            // (WI-2026-08-08-039): one Timer-style loop, not one Timer per
            // row per render.
            .task {
                // AND WHAT THE HOSTS ARE HOLDING, on the same ticker.
                //
                // ASKED RATHER THAN ASSUMED ([[RFC-0014]] C-END): a
                // holder no pane here names is invisible from this side
                // until something asks the host, and nothing ever did.
                // Once at the start so the list is populated by the time
                // a human looks, and then rarely — it is a round trip per
                // host, and a session that has been alone for two days is
                // not one a faster poll would have caught in time.
                paneManager.refreshRemoteSessions()
                // AND WHETHER THOSE HOSTS RUN WHAT THIS BUILD DEPLOYS.
                // Only the connected ones are asked ([[HostBinary]]): on a
                // live master it is one round trip, and on a host that is
                // not connected it would mean dialling one.
                paneManager.refreshHostBinaries()
                var ticks = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    sessionNow = Date()
                    ticks += 1
                    if ticks % 6 == 0 {
                        paneManager.refreshRemoteSessions()
                        paneManager.refreshHostBinaries()
                    }
                }
            }
            // A WORKSPACE IS DESTROYED ONLY BY AN EXPLICIT HUMAN ACT, AND
            // THAT ACT IS CONFIRMED ([[RFC-0015]] C-WORKSPACE). The
            // sentences are [[WorkspaceDestruction]]'s rather than this
            // view's: a question is exactly the obligation that gets
            // quietly dropped by one of several call sites drawing its own
            // dialog, and a rule kept in a value has a test that can ask
            // it something.
            .confirmationDialog(
                closingWorkspace.map { WorkspaceDestruction.question(name: $0.label) } ?? "",
                isPresented: Binding(get: { closingWorkspace != nil },
                                     set: { if !$0 { closingWorkspace = nil } }),
                titleVisibility: .visible
            ) {
                Button(WorkspaceDestruction.destructiveAnswer, role: .destructive) {
                    if let closing = closingWorkspace { paneManager.removeWorkspace(closing) }
                    closingWorkspace = nil
                }
                Button(WorkspaceDestruction.safeAnswer, role: .cancel) { closingWorkspace = nil }
            } message: {
                if let closing = closingWorkspace {
                    Text(WorkspaceDestruction.detail(
                        panes: closing.panes.count,
                        machines: paneManager.machineCount(ofWorkspace: closing)))
                }
            }
        }
    }
}


// MARK: - Navigation list row

/// Labeled sidebar navigation row (WI-2026-08-09-005): accent-tinted icon
/// (the Finder sidebar convention), 13pt label, selection pill, optional
/// live count badge.
private struct NavListRow: View {
    let icon: String
    let label: String
    let isActive: Bool
    var badge: Int? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: icon)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.accent)
                    .frame(width: 20)
                Text(label)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: 0)
                if let badge {
                    Text("\(badge)")
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(DS.textSecondary)
                        .padding(.horizontal, DS.Space.sm)
                        .padding(.vertical, 1)
                        .background(DS.hover, in: Capsule())
                }
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(isActive ? DS.selection : (isHovered ? DS.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Session Row

struct WorkspaceRow: View {
    let session: WorkspaceManager.Workspace
    var paneManager: WorkspaceManager
    var hostStore: HostStore
    @Binding var editingWorkspaceID: UUID?
    /// EVERY PATH THAT CAN DESTROY THIS WORKSPACE GOES THROUGH HERE
    /// ([[RFC-0015]] C-WORKSPACE, [[WorkspaceDestruction]]). The hover ×,
    /// the context menu and the accessibility action each used to destroy
    /// it outright, and three call sites is exactly how one of them comes
    /// to skip the question.
    @Binding var closing: WorkspaceManager.Workspace?
    /// Agent registered on this session, if any.
    let agent: AgentInfo?
    let agentNeedsAttention: Bool
    /// Stable custom selection pill (WI-2026-08-09-009) — replaces the
    /// focus-dependent system List highlight.
    var isActive: Bool = false
    /// A PANE IS ABOUT TO BE DROPPED INTO THIS WORKSPACE
    /// ([[WI-2026-08-17-028]]).
    ///
    /// THE ROW CHANGES CLOTHES; IT IS NOT VEILED. A translucent block laid
    /// over the row put a second rounded rectangle on top of the one the
    /// row already draws for being selected, and tinted its text through
    /// the gap between them. Finder does not do that to a folder you are
    /// about to drop into — the row takes the selected treatment outright,
    /// with the foreground that was chosen to be legible on it.
    var isDropTarget: Bool = false
    /// A pane in this session wants human input (WI-2026-08-09-021) —
    /// leaf-based, works with or without a registered agent.
    var needsAttention: Bool = false
    /// ⌘-hold hint number (WI-2026-08-09-015); nil = no badge.
    var hintIndex: Int? = nil
    /// Shared sidebar ticker value (WI-2026-08-08-039) — one ticker for
    /// all rows instead of a per-row Timer.publish that churned on every
    /// parent render.
    let now: Date
    /// Fired on row tap (selects session + returns to terminal page).
    var onTap: (() -> Void)? = nil

    @State private var editText = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var isHovered = false
    /// Manual double-click detection (WI-2026-08-08-076 pattern):
    /// double-click renames inline — no right-click required.
    @State private var lastTapTime = Date.distantPast

    private var isEditing: Bool { editingWorkspaceID == session.id }

    private func commitRename() {
        if !editText.isEmpty {
            paneManager.renameWorkspace(session.id, to: editText)
        }
        editingWorkspaceID = nil
    }

    // MARK: - Derived display values

    /// The machines this workspace has work on. One gets an address;
    /// several get a count, because a workspace holding two machines has
    /// no single address to show ([[RFC-0015]] C-WORKSPACE).
    private var hosts: [HostEntry] { paneManager.hosts(ofWorkspace: session) }

    /// THIS MAC IS A MACHINE. Counted here rather than only where it has
    /// a host RECORD, because a connection to it has none — `host` is nil
    /// for the local one ([[RFC-0015]] C-CONNECTION) — and counting
    /// records instead of machines made a workspace holding a local pane
    /// AND a remote one look like it held only the remote. It then showed
    /// that remote's address as the WORKSPACE's, which is the container
    /// answering "which machine is this?" that [[RFC-0015]] C-LEAF-BINDING
    /// exists to forbid, and answering it wrongly at that.
    private var machineCount: Int {
        paneManager.connections(ofWorkspace: session).count
    }

    /// The machines, named, for the one channel that has room for them.
    private var machineSummary: String {
        let names = paneManager.connections(ofWorkspace: session).map { connection -> String in
            guard let host = connection.host else { return "this Mac" }
            return host.label.isEmpty ? host.address : host.label
        }
        return names.isEmpty ? "nothing open" : names.joined(separator: " · ")
    }


    /// True when a host record changed AFTER the connection was opened —
    /// the live connection still holds the copy it was dialled with
    /// (WI-2026-08-08-045).
    private var configDrifted: Bool {
        hosts.contains { dialled in
            guard let current = hostStore.hosts.first(where: { $0.id == dialled.id })
            else { return false }
            return current.address != dialled.address
                || current.port != dialled.port
                || current.username != dialled.username
                || current.sshKeyPath != dialled.sshKeyPath
        }
    }

    /// Tab + split count summary, e.g. "2 tabs · 3 splits", "1 tab", "2 tabs"
    /// A ROW IS A WORKSPACE, NOT A LOGIN ([[RFC-0015]] C-WORKSPACE,
    /// [[WI-2026-08-17-026]]).
    ///
    /// The dot used to carry the workspace's aggregate connection state —
    /// one colour for a container whose panes may be on three machines in
    /// three different states, which is a number that cannot be right.
    /// Connectedness belongs to a pane, and the pane draws it
    /// ([[LeafConnectionView]], [[RFC-0015]] C-DIAL).
    ///
    /// WHAT SURVIVES THE MOVE IS FAILURE, deliberately: work put aside
    /// that has broken must be visible without opening it, or it is
    /// discovered on return ([[RFC-0015]] C-FAILURE). That is one bit
    /// about the workspace — something in here needs you — rather than a
    /// state it does not have.
    private var statusColor: Color {
        // THE MACHINE'S COLOUR WHERE THERE IS A MACHINE ([[HostTint]]):
        // the row's dot was one grey for every workspace, and the sidebar
        // is the one place all of them sit side by side. Failure keeps its
        // own colour; a local workspace has no machine to be coloured by.
        if paneManager.hasFailedConnection(session) { return DS.danger }
        if let host = paneManager.hosts(ofWorkspace: session).first { return HostTint.color(for: host.label) }
        return DS.textTertiary
    }

    // MARK: - Body

    /// ONE line for every session (WI-2026-08-08-077): uniform height —
    /// dot, label, agent icon, drift warning, then right-aligned address /
    /// count / duration (or the failure message).
    var body: some View {
        // Bound once: every branch below reads it, and asking the manager
        // inline pushed this body past the type-checker's budget.
        return HStack(spacing: DS.Space.sm) {
            // PUT AWAY LOOKS PUT AWAY. An archived workspace that draws
            // the same row as an open one is a row the human clicks
            // expecting live work ([[RFC-0015]] C-ARCHIVE) — and it holds
            // no connections, so the dot would be reporting on nothing.
            if session.isArchived {
                Image(systemName: "archivebox")
                    .font(DS.Icon.control)
                    .foregroundStyle(DS.textTertiary)
                    .help("Archived — click to reopen")
                    .accessibilityLabel("Archived")
            } else {
                DSStatusDot(color: statusColor, size: 8, pulsing: false)
            }

            // Label (or inline edit field)
            // THE SUBJECT OF THE ROW, so it takes its width before the
            // metadata beside it. Without this the address demanded its
            // ideal size and the LABEL truncated — the host name turning
            // into an ellipsis while the sidebar still had room.
            labelView
                .layoutPriority(1)
                .opacity(session.isArchived ? 0.6 : 1)

            if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(DS.Icon.control)
                    .foregroundStyle(DS.textTertiary)
                    .accessibilityLabel("Pinned")
            }

            // Leaf-based attention pulse (WI-2026-08-09-021) — agent or
            // not, a bell in this session shows here.
            if needsAttention {
                DSStatusDot(color: DS.warning, size: 6, pulsing: true)
            }

            // Agent — compact icon, attention via color + pulse
            if let agent {
                Image(systemName: agent.tool.sfSymbol)
                    .font(DS.Icon.control)
                    .foregroundStyle(agentNeedsAttention ? DS.warning : agent.tool.accentColor)
                    // The reason an unknown status is unknown belongs
                    // wherever that status is shown, not only in one of
                    // the two places ([[RFC-0010]] C-DIAGNOSABILITY).
                    .help([
                        agent.session != "-" ? "\(agent.tool.displayName) · \(agent.session)"
                                             : agent.tool.displayName,
                        agent.unknownExplanation,
                    ].compactMap { $0 }.joined(separator: " — "))
                    .accessibilityLabel(agent.tool.displayName)
                if agentNeedsAttention {
                    DSStatusDot(color: DS.warning, size: 5, pulsing: true)
                }
            }

            // Config drift warning
            if configDrifted {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(DS.Icon.control)
                    .foregroundStyle(DS.warning)
                    .help("Host config changed after this session started — reconnect to apply")
            }

            Spacer(minLength: DS.Space.xs)

            // Right side: what is WRONG in here, and nothing about the
            // link. A row is a workspace ([[WI-2026-08-17-026]]); the
            // address it used to show was the answer to "which machine is
            // this?", asked of a container that has no single one.
            if session.isArchived {
                // WHAT IS IN IT, since the point of leaving it listed is
                // that the human need not remember.
                Text(paneManager.archivedSummary(session))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
            } else if let why = paneManager.firstFailure(session) {
                Text(why)
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.danger)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, DS.Space.sm)
        .padding(.horizontal, DS.Space.sm)
        // ROOM FOR THE OVERLAY, WHILE THE OVERLAY IS THERE.
        //
        // The close button and the ⌘-hold badge are drawn OVER the trailing
        // edge. The row used to make room by hiding the duration, which
        // worked only where the duration was rightmost — a REMOTE session
        // also puts the host address there, nothing hid it, and the × landed
        // on top of it.
        //
        // Reserving it permanently would spend the width on every row for a
        // control that is visible on one. Taken only on hover, and the
        // address then DROPS rather than truncating (ViewThatFits above), so
        // what the human loses for the moment is a value they can still read
        // in the tooltip — not a row that reflows into an ellipsis.
        .padding(.trailing, isHovered || hintIndex != nil ? DS.scaled(20) : 0)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(isDropTarget ? DS.selectionAccent
                        : (isActive ? DS.selection : (isHovered ? DS.hover : Color.clear)))
        )
        .animation(DropMark.fade, value: isDropTarget)
        // Hover close — no right-click required (WI-2026-08-08-090).
        .overlay(alignment: .trailing) {
            if let hintIndex {
                // ⌘-hold hint (WI-2026-08-09-015): this row answers ⌘N.
                DSKeycap("\(hintIndex)")
                    .padding(.trailing, DS.Space.xs)
            } else if isHovered && !isEditing {
                DSIconButton(icon: "xmark", help: "Close Session", size: 18) {
                    closing = session
                }
                .padding(.trailing, DS.Space.xs)
            }
        }
        .contentShape(Rectangle())
        // The whole value, at any width — this is where it lives once the
        // row stops being wide enough to show it.
        // THE MACHINES THIS WORKSPACE HAS WORK ON, which is a fact about
        // the workspace — unlike an address, which was one machine
        // answering for a container that may hold three.
        .help(machineSummary)
        .onHover { hovering in isHovered = hovering }
        .onTapGesture {
            // Always fires, even when the row is already the selected
            // session (List selection set: would not). Ensures returning
            // to the terminal page works from any page. Second click
            // within the double-click window renames inline.
            let now = Date()
            if now.timeIntervalSince(lastTapTime) < NSEvent.doubleClickInterval {
                lastTapTime = .distantPast
                editingWorkspaceID = session.id
            } else {
                lastTapTime = now
                onTap?()
            }
        }

        // One spoken element per row with the state in words — the dot is
        // color-only (WI-2026-08-09-020).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(named: "Close Session") { closing = session }
        .accessibilityAction(named: "Rename") { editingWorkspaceID = session.id }
    }

    /// WHAT THIS ROW IS, SPOKEN. A workspace and, where something in it
    /// has broken, what — the same two facts the row draws, because a
    /// screen reader is a channel and not a summary ([[RFC-0015]]
    /// C-FAILURE, [[WI-2026-08-17-026]]).
    ///
    /// No connection state and no address: they were the container
    /// answering "which machine is this?", which is the leaf's question
    /// ([[RFC-0015]] C-LEAF-BINDING). How many machines the workspace has
    /// work on is still said, because that IS a fact about the workspace.
    private var accessibilityDescription: String {
        let machines: String?
        switch machineCount {
        case 0: machines = "empty"
        case 1: machines = nil
        default: machines = "\(machineCount) machines"
        }
        return [session.label, machines, paneManager.firstFailure(session).map { "failed: \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: - Subviews

    @ViewBuilder
    private var labelView: some View {
        if isEditing {
            TextField("Name", text: $editText)
                .textFieldStyle(.plain)
                .font(DS.Typography.bodyStrong)
                .frame(minWidth: 80, alignment: .leading)
                .focused($isTextFieldFocused)
                .onAppear {
                    editText = session.label
                    DispatchQueue.main.async { isTextFieldFocused = true }
                }
                .onSubmit { commitRename() }
                .onExitCommand { editingWorkspaceID = nil }
                .onChange(of: isTextFieldFocused) { _, focused in
                    if !focused {
                        Task { @MainActor in commitRename() }
                    }
                }
        } else {
            Text(session.label)
                .font(DS.Typography.bodyStrong)
                .foregroundStyle(isDropTarget ? DS.textOnSelection : DS.textPrimary)
                .lineLimit(1)
        }
    }
}

/// AN AGENT THAT IS NOT HERE. One line, the same vocabulary a workspace
/// row uses.
///
/// TAPPABLE ONLY WHERE IT CAN BE OPENED. The peer name resolves to a host
/// through the loopback port the workbench assigned when IT dialled that
/// machine, so an agent on a machine this Mac has never connected to has
/// no host to dial — and a row that looks tappable and does nothing is
/// worse than one that does not ([[RFC-0011]] C-VISIBILITY). Those rows
/// take no hover and no click, and say which machine to connect to.
/// THE SHAPE EVERY ROW OF STILL RUNNING TAKES.
///
/// Three sources feed that list — a pane the human archived, a holder a
/// host reported, an agent the hub knows of — and each used to draw
/// itself. Under one heading that showed: two of them were two lines and
/// one was one, two had a hover control and one had none, and the eye
/// read the difference as a difference in KIND when it was only a
/// difference in which file the row was written in.
///
/// WHAT VARIES IS WHAT THE SOURCE ACTUALLY KNOWS: the glyph, the two
/// lines of text, whether there is an act at the trailing edge, and
/// whether the row can be opened at all. Everything else is here, once.
private struct StillRunningRow<Leading: View>: View {
    @ViewBuilder let leading: Leading
    let title: String
    let subtitle: String
    /// False for a row that cannot be opened — a holder that is running
    /// and not answering, an agent on a machine this Mac has never
    /// dialled. An affordance that does nothing teaches people to stop
    /// trying it.
    var openable: Bool = true
    /// MISSING EVIDENCE IS NEVER EVIDENCE OF ABSENCE, so a row whose
    /// facts are stale is dimmed rather than dropped.
    var dimmed: Bool = false
    let help: String
    var accessibilityHint: String? = nil
    /// The destructive act, where the source offers one. Hover-revealed
    /// and differently coloured, because [[RFC-0014]] C-DETACH requires a
    /// gesture to say which act it performs before it performs it.
    var endHelp: String? = nil
    var onEnd: (() -> Void)? = nil
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            leading
                .frame(width: DS.scaled(14))

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(DS.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DS.Space.xs)

            if isHovered, let onEnd, let endHelp {
                DSIconButton(icon: "xmark.circle", help: endHelp, size: 18,
                             role: .destructive) { onEnd() }
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .fill(isHovered ? DS.surfaceRaised : .clear))
        .onHover { isHovered = $0 }
        .onTapGesture { if openable { onOpen() } }
        .opacity(dimmed ? 0.55 : 1)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .accessibilityHint(accessibilityHint ?? "")
    }
}

private struct RemoteAgentRow: View {
    let agent: AgentInfo
    /// Whether this Mac has a host to dial for that machine. A row that
    /// cannot be opened is NOT made to look as though it can: an
    /// affordance that does nothing teaches people to stop trying it.
    let openable: Bool
    let onOpen: () -> Void

    var body: some View {
        StillRunningRow(
            leading: {
                // THE STATUS DOT AND NOT A TOOL GLYPH. Only identity,
                // hosting peer, status and reachability cross a relay
                // link ([[RFC-0009]] C-DIRECTORY), so the tool is usually
                // unknown and its glyph was drawing the same shrug on
                // nearly every row. The dot carries what did arrive, and
                // a waiting agent pulses.
                DSStatusDot(color: agent.statusColor, size: 6,
                            pulsing: agent.status == "waiting")
            },
            title: title,
            subtitle: subtitle,
            openable: openable,
            // AN UNREACHABLE PEER'S ROW STAYS, GHOSTED. Missing evidence
            // is never presented as evidence of absence — dropping the
            // row would read as "that agent is gone".
            dimmed: !agent.reachable || agent.status == "unknown",
            help: helpText,
            accessibilityHint: openable ? "Opens this agent's terminal" : nil,
            // NO ENDING FROM HERE. What a relay carries is a report, not
            // a handle: this row names an agent, and ending belongs to
            // the holder its work runs in — which is the row above when
            // this machine has one.
            onOpen: onOpen)
    }

    /// THE MACHINE FIRST, as every row in this list does — a human
    /// narrows to a machine and then to a piece of work.
    private var title: String {
        let where_ = agent.machine.isEmpty ? "another machine" : agent.machine
        return "\(where_) · \(agent.bareID)"
    }

    private var subtitle: String {
        var parts: [String] = [agent.statusPhrase]
        if agent.tool != .unknown { parts.insert(agent.tool.displayName, at: 0) }
        if !agent.reachable { parts.append("machine not reachable from here") }
        else if !openable { parts.append("connect to \(agent.machine) to open it") }
        return parts.joined(separator: " · ")
    }

    private var helpText: String {
        var parts = [agent.statusPhrase]
        if !agent.reachable { parts.append("that machine is not reachable from here") }
        // WHY THE ROW DOES NOTHING, said where the human is looking. The
        // alternative is a row that ignores a click and explains nothing,
        // which is the shape that teaches people the list is decoration.
        parts.append(openable
            ? "click to open this agent's terminal"
            : "connect to \(agent.machine) to open this agent's terminal")
        return parts.joined(separator: " — ")
    }
}

/// ONE PANE THE HUMAN CLOSED, WITH ITS WORK STILL RUNNING.
///
/// THE ROW SAYS WHAT IT IS, WHERE, AND SINCE WHEN, because those are what
/// [[RFC-0015]] C-PANE-ARCHIVE requires it to carry — a row a human cannot
/// tell from another is a list that names nothing.
///
/// TWO ACTS, AND THEY ARE NOT THE SAME ONE. [[RFC-0014]] C-DETACH requires
/// leaving and ending to be distinct and requires the interface to say
/// which a gesture performs BEFORE it performs it. Unarchiving is the row's
/// own tap, because it is the safe one and the one meant most often;
/// ending is a deliberate, differently-coloured control that says so.
private struct ArchivedPaneRow: View {
    let row: WorkspaceManager.ArchivedPane
    let machine: String?
    let onReturn: () -> Void
    let onEnd: () -> Void

    var body: some View {
        StillRunningRow(
            leading: {
                Image(systemName: "tray.full")
                    .font(DS.Icon.control)
                    .foregroundStyle(DS.textTertiary)
            },
            title: title,
            subtitle: subtitle,
            help: "Unarchive: return this pane to its workspace",
            accessibilityHint: "Unarchives it into its workspace",
            endHelp: "End this session",
            onEnd: onEnd,
            onOpen: onReturn)
    }

    /// THE MACHINE AND WHAT THE TAB WAS SHOWING.
    ///
    /// The label first, because it is what the human was actually looking
    /// at and a shell that titles itself names the command rather than the
    /// folder. The folder is the fallback for a pane that never had a
    /// title of its own — which is all a host's own listing can offer, the
    /// holder having no notion of a title at all ([[RFC-0011]]
    /// C-HEADLESS-GATE).
    private var title: String {
        let where_ = machine ?? "this Mac"
        if let label = row.title, !label.isEmpty, label != "Shell" {
            return "\(where_) · \(label)"
        }
        guard let directory = row.pane.workingDirectory else {
            return "\(where_) · \(row.agent ?? row.pane.label)"
        }
        let leaf = (directory as NSString).lastPathComponent
        return "\(where_) · \(leaf.isEmpty ? directory : leaf)"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let agent = row.agent { parts.append(agent) }
        if let directory = row.pane.workingDirectory { parts.append(directory) }
        parts.append("archived \(Self.since.localizedString(for: row.at, relativeTo: Date()))")
        return parts.joined(separator: " · ")
    }

    private static let since: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// ONE SESSION A HOST SAYS IT IS HOLDING, that no pane here names.
///
/// WHY IT IS BESIDE THE SET-ASIDE ONES rather than in a list of its own:
/// a human looking for work they left does not know, or care, whether
/// this workbench was the client that left it. A session from a crashed
/// run, from another Mac, or from before a reinstall is the same question
/// — is this still wanted — and two lists would ask it twice.
private struct RemoteSessionRow: View {
    let session: RemoteSessions.Session
    let machine: String
    /// OPENING IT IS THE POINT OF THE LIST. Ending was the only act this
    /// row offered, which made a surface for finding work you left into
    /// one for destroying it — and [[RFC-0014]] C-END's own reasoning
    /// runs the other way: a human shown something and denied the useful
    /// act has been shown a problem, not given a remedy.
    let onOpen: () -> Void
    let onEnd: () -> Void

    /// A HOLDER THAT IS RUNNING AND NOT ANSWERING CAN BE ENDED AND NOT
    /// ATTACHED, which C-END requires to be told apart rather than
    /// offered alike.
    private var openable: Bool { !session.unreachable }

    var body: some View {
        StillRunningRow(
            leading: {
                Image(systemName: session.unreachable ? "questionmark.circle" : "tray")
                    .font(DS.Icon.control)
                    .foregroundStyle(DS.textTertiary)
            },
            title: title,
            subtitle: subtitle,
            openable: openable,
            help: openable ? "Open this session in a pane"
                : "This session is running but not answering — it can be ended, not opened",
            accessibilityHint: openable ? "Opens it in a pane"
                                        : "Cannot be opened; it is not answering",
            endHelp: "End this session",
            onEnd: onEnd,
            onOpen: onOpen)
    }

    /// WHAT A HUMAN DECIDES ON ([[RFC-0014]] C-END names these): where it
    /// is, what it is running, and how long nobody has been watching.
    /// "A listing without them shows sessions and withholds the grounds."
    /// THE MACHINE AND THE FOLDER, in that order.
    ///
    /// Both, because either alone is ambiguous: the name is `local-XXXX`
    /// for every session on every host, and two hosts with the same
    /// project have the same folder. The machine is the coarser of the
    /// two, so it leads — a human narrows to a machine and then to a
    /// piece of work, not the other way round.
    private var title: String {
        guard let directory = session.directory else { return "\(machine) · \(session.name)" }
        let leaf = (directory as NSString).lastPathComponent
        return "\(machine) · \(leaf.isEmpty ? directory : leaf)"
    }

    private var subtitle: String {
        if session.unreachable {
            return "\(machine) · running, not answering — can be ended, not opened"
        }
        // THE NAME BELONGS HERE, because it is what `synapty end --id` and
        // `synapty attach --id` take, and a human copying one out of this
        // list needs it exactly. The machine is not repeated; it is in the
        // title, where it is scanned.
        var parts = [session.name]
        if let directory = session.directory { parts.append(directory) }
        if let command = session.command { parts.append(command) }
        if session.childExited {
            parts.append("child exited")
        } else if session.attached {
            parts.append("attached")
        } else if !session.everAttached {
            parts.append("never opened")
        } else {
            parts.append("alone \(Self.spell(session.unattached))")
        }
        return parts.joined(separator: " · ")
    }

    private static func spell(_ seconds: Int) -> String {
        if seconds < 90 { return "\(seconds)s" }
        if seconds < 5400 { return "\(seconds / 60)m" }
        if seconds < 172_800 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}
