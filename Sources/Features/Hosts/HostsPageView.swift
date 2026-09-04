import SwiftUI

/// Sub-panes of the Hosts page — the infrastructure workbench tabs
/// (WI-2026-08-09-008): Hosts | Identities | Forwarding. Raw values are
/// the persisted @AppStorage form.
enum HostsPane: String, Hashable {
    case hosts
    case identities
    case forwarding
}

/// Right-side inspector content (WI-2026-08-08-069): host editor or group
/// editor (nil = create) — one panel at a time. New Host and New Group use
/// the SAME surface (WI-2026-08-08-090; New Group was a one-field sheet).
enum HostsInspector: Identifiable {
    case host(HostEntry?)
    case group(HostGroup?)
    case identity(Identity?)

    var id: String {
        switch self {
        case .host(let host): return "host-\(host?.id.uuidString ?? "new")"
        case .group(let group): return "group-\(group?.id.uuidString ?? "new")"
        case .identity(let identity): return "identity-\(identity?.id.uuidString ?? "new")"
        }
    }
}

/// Host management page — Termius-style host management:
/// flat groups + block sections, searchable host list with tags, and full
/// CRUD for hosts, groups and reusable identities.
struct HostsPageView: View {
    var hostStore: HostStore
    var tunnelManager: TunnelManager
    /// Live agent exposures. THE OVERVIEW HAS TWO SOURCES because the
    /// thing it describes has two authors — see `forwardingSections`.
    var forwards: PortForwardService
    /// WHICH HOSTS RUN THE BINARY THIS BUILD DEPLOYS, and the act that
    /// puts it there ([[HostBinary]]). Held by the pane manager because
    /// it is the thing that knows which connections are live, and only
    /// those are asked.
    var paneManager: WorkspaceManager
    /// One-click terminal open from the host list (WI-2026-08-08-064).
    var onOpenTerminal: ((HostEntry) -> Void)? = nil
    /// Every member of a group, connected, one position each
    /// ([[WI-2026-09-02-009]]).
    var onOpenGroupAsGrid: ((HostGroup) -> Void)? = nil

    /// Currently selected host-list filter.
    @State private var selectedFilter: HostFilter = .all
    /// Host search text.
    @State private var searchText = ""
    /// Multi-selection for drag-and-drop (WI-2026-08-08-057): Cmd-click
    /// toggles; dragging a selected block drags the whole selection.
    @State private var selectedHostIDs: Set<UUID> = []
    /// Tag filter (WI-2026-08-08-059): hosts must have ALL selected tags.
    @State private var selectedTags: Set<String> = []
    /// Last block click time — manual double-click detection
    /// (WI-2026-08-08-076): a SINGLE onTapGesture keeps first-click response
    /// instant AND avoids the SwiftUI gesture-composition crash seen with
    /// .gesture/.simultaneousGesture stacked on .draggable blocks.
    @State private var lastBlockTapTime = Date.distantPast

    /// Which sub-pane of the Hosts page is shown — persisted like the
    /// grid/list toggle (WI-2026-08-09-008).
    @AppStorage("synapty.hostsPane") private var paneRaw = HostsPane.hosts.rawValue
    private var pane: HostsPane { HostsPane(rawValue: paneRaw) ?? .hosts }
    private var paneBinding: Binding<HostsPane> {
        Binding(get: { pane }, set: { paneRaw = $0.rawValue })
    }
    /// One-shot `--hosts-pane <tab>` override (DevLaunchArgs).
    @State private var launchPaneArg: String? = DevLaunchArgs.hostsPane
    /// Right-side inspector content: host editor (nil = new host) or group
    /// settings — one panel at a time (WI-2026-08-08-069). Honors
    /// `--hosts-inspector <panel>` (DevLaunchArgs).
    @State private var inspector: HostsInspector? = {
        switch DevLaunchArgs.hostsInspector {
        case "new-host": return .host(nil)
        case "new-group": return .group(nil)
        case "new-identity": return .identity(nil)
        default: return nil
        }
    }()
    /// WHAT THE HUMAN HAS BEEN ASKED TO CONFIRM DESTROYING, and there is
    /// at most one of it.
    ///
    /// THREE OPTIONALS EXPRESSED THAT BADLY: nothing stopped two of them
    /// being set, and two set is two alerts stacked on one another — the
    /// second asking about something the first has already destroyed.
    /// One value makes the second question replace the first, which is
    /// the behaviour the three were relying on the human not to reach.
    @State private var pendingDeletion: HostsDeletion?

    private var hostToDelete: HostEntry? {
        if case .host(let host) = pendingDeletion { return host }
        return nil
    }
    private var groupToDelete: HostGroup? {
        if case .group(let group) = pendingDeletion { return group }
        return nil
    }
    private var identityToDelete: Identity? {
        if case .identity(let identity) = pendingDeletion { return identity }
        return nil
    }
    /// Grid/list view + sort order — persisted (WI-2026-08-09-006).
    @AppStorage("synapty.hostsView") private var hostsView = "grid"
    @AppStorage("synapty.hostsSort") private var hostsSort = "recent"
    /// The grid's own width, so arrow keys can move by the row the human
    /// sees rather than by one item.
    @State private var gridWidth: Double = 0
    /// THE CURSOR IS A HOST, NOT AN INDEX. Filtering, sorting and a
    /// deleted host all renumber the grid; an index survives none of them
    /// and would silently point at a different machine.
    @State private var cursorHostID: UUID?
    /// The cursor when it is on a GROUP rather than a host. Two optionals
    /// rather than an enum because exactly one is ever set, and the views
    /// each ask about their own.
    @State private var cursorGroupID: UUID?
    @FocusState private var gridFocused: Bool

    /// The groups the arrows can reach, in the order they are drawn.
    ///
    /// GROUPS ARE A SECOND GRID, STACKED ABOVE THE HOSTS, and the cursor
    /// covered only the lower one — so half the page was unreachable by
    /// keyboard while looking exactly like the half that was not.
    /// Keyed off `selectedGroup` rather than off the filter, because that
    /// is the exact condition `groupsSection` is drawn under — INSIDE a
    /// group there is no groups grid, but the Ungrouped filter still shows
    /// one, and a cursor that can reach a card nobody drew is worse than
    /// one that cannot reach a card that is there.
    private var navigableGroups: [HostGroup] {
        guard selectedGroup == nil else { return [] }
        return hostStore.groups.sorted { $0.label < $1.label }
    }

    /// Where the cursor is, or nil for "not in the grid" — which is what
    /// tells the arithmetic to ENTER rather than to step.
    private var cursorPosition: GridCursor.Position? {
        if let cursorGroupID,
           let idx = navigableGroups.firstIndex(where: { $0.id == cursorGroupID }) {
            return GridCursor.Position(section: 0, item: idx)
        }
        if let cursorHostID,
           let idx = visibleHosts.firstIndex(where: { $0.id == cursorHostID }) {
            return GridCursor.Position(section: 1, item: idx)
        }
        return nil
    }

    /// Move the cursor, and move the SELECTION with it — the highlight is
    /// the only thing telling the human where they are.
    private func place(_ position: GridCursor.Position) {
        if position.section == 0 {
            guard position.item < navigableGroups.count else { return }
            cursorGroupID = navigableGroups[position.item].id
            cursorHostID = nil
            selectedHostIDs = []
        } else {
            guard position.item < visibleHosts.count else { return }
            cursorHostID = visibleHosts[position.item].id
            cursorGroupID = nil
            selectedHostIDs = [visibleHosts[position.item].id]
        }
    }

    /// SwiftUI's own arithmetic for `.adaptive(minimum:)`: as many as fit,
    /// each needing its minimum plus the spacing between. Derived from the
    /// measured width so it follows a resize and the UI scale exactly as
    /// the grid does.
    private var gridColumns: Int {
        max(1, Int((gridWidth + DS.Space.lg) / (DS.scaled(260) + DS.Space.lg)))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — primary CTA top-right, secondary actions in an
            // overflow menu; no bottom action bar (Termius layout,
            // WI-2026-08-08-090).
            DSPageHeader("Hosts", meta: headerMeta) {
                headerActions
            }
            DSHairline()

            // Control row: sub-navigation + search + tag filter + counts
            // (WI-2026-08-08-090).
            HStack(spacing: DS.Space.md) {
                DSSegmented(selection: paneBinding, options: [
                    (HostsPane.hosts, "Hosts"),
                    (.identities, "Identities"),
                    (.forwarding, "Forwarding"),
                ])

                if pane == .hosts {
                    searchField
                    tagsMenu
                }

                Spacer()

                if pane == .hosts {
                    // Sort + view mode (WI-2026-08-09-006).
                    DSDropdown(
                        selection: $hostsSort,
                        options: [("recent", "Sort: Recent"), ("name", "Sort: Name")],
                        width: DS.scaled(130)
                    )
                    DSSegmented(selection: $hostsView, iconOptions: [
                        ("grid", "square.grid.2x2", "Grid view"),
                        ("list", "list.bullet", "List view"),
                    ])
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.md)

            // Active tag chips (removable)
            if pane == .hosts && !selectedTags.isEmpty {
                activeTagChips
            }

            switch pane {
            case .hosts: hostsPane
            case .identities: identitiesPane
            case .forwarding: forwardingPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        // ARROWS ARE THE GRID'S ONLY WHILE THE GRID HAS FOCUS.
        //
        // This was a global NSEvent monitor: it saw every keystroke in the
        // application and had to decide by hand whether each was its own —
        // is the Hosts page showing, is an editor open, has the human used
        // the keyboard yet. Every new question added a condition, and three
        // bugs hid among them in one day. A view that receives keys only
        // when focused does not have to ask any of it, so the guards are
        // gone and the platform answers instead.
        //
        // A SEARCH PALETTE CANNOT DO THIS and keeps its monitor: a focused
        // TextField's field editor eats arrows before either
        // `onMoveCommand` or `onKeyPress` sees them. The grid has no text
        // field, which is the whole difference.
        .focusable()
        // NO RING AROUND THE WHOLE PAGE. The system draws one for any
        // focusable view, and here that is a border round the entire
        // pane — which says "this page has focus" and nothing a human
        // needs. What tells them where the cursor is, is the SELECTED
        // CARD, and that is already drawn.
        //
        // Focusability itself is kept: it is what makes the arrow keys
        // arrive at all.
        .focusEffectDisabled()
        .focused($gridFocused)
        .onMoveCommand { direction in
            guard let next = GridCursor.next(from: cursorPosition, direction: direction,
                                             sections: [navigableGroups.count, visibleHosts.count],
                                             columns: gridColumns)
            else { return }
            place(next)
        }
        .onKeyPress(.return) {
            // Return belongs to whoever has focus, which is the question
            // `canActivate` used to answer by hand.
            switch cursorPosition {
            case .some(let at) where at.section == 0:
                guard at.item < navigableGroups.count else { return .ignored }
                selectedFilter = .group(navigableGroups[at.item].id)
                return .handled
            case .some(let at):
                guard at.item < visibleHosts.count else { return .ignored }
                onOpenTerminal?(visibleHosts[at.item])
                return .handled
            case .none:
                return .ignored
            }
        }
        // THE PAGE WITH THE GRID TAKES THE KEYBOARD WHEN IT IS SHOWN.
        //
        // Keyboard navigation is scoped to the surfaces where it earns its
        // keep — a set of like items to choose among, and forms — rather
        // than to every control in the window. So there is no cycling
        // between window sections and no way to "walk" here from the
        // terminal: arriving at this page IS the way in, and leaving gives
        // the keys back.
        //
        // The terminal needs no guard against taking focus away, because
        // its own rule already covers this: it re-asserts first responder
        // only while the terminal page is visible.
        .onAppear { gridFocused = true }
        .onChange(of: pane) { _, current in gridFocused = (current == .hosts) }
        .onAppear {
            // Apply the one-shot launch-arg pane override.
            if let arg = launchPaneArg {
                launchPaneArg = nil
                if HostsPane(rawValue: arg) != nil { paneRaw = arg }
            }
        }
        // Right-side inspector for host/group settings (WI-2026-08-08-069).
        .inspector(isPresented: Binding(
            get: { inspector != nil },
            set: { if !$0 { inspector = nil } }
        )) {
            inspectorContent
            // The COLUMN owns the width — panels are flexible. A fixed
            // panel width clipped both edges once the UI font scale grew
            // the content (user report, WI-2026-08-08-090). Ideal width
            // tracks the scale so XL text gets a wider column.
            .inspectorColumnWidth(
                min: 340,
                ideal: 420 * DS.uiFontScale,
                max: 620
            )
        }
        .alert("Delete Group", isPresented: Binding(
            get: { groupToDelete != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let group = groupToDelete {
                    hostStore.removeGroup(group)
                    if case .group(let id) = selectedFilter, id == group.id {
                        selectedFilter = .all
                    }
                    pendingDeletion = nil
                }
            }
        } message: {
            Text("Delete \"\(groupToDelete?.label ?? "")\"? Hosts in the group become ungrouped.")
        }
        .alert("Delete Host", isPresented: Binding(
            get: { hostToDelete != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let host = hostToDelete {
                    tunnelManager.disconnectTunnel(for: host)
                    hostStore.removeHost(host)
                    pendingDeletion = nil
                }
            }
        } message: {
            if let host = hostToDelete {
                // Cascade warning (WI-2026-08-08-045): active tunnels for
                // this host will be disconnected.
                let active = hostStore.hosts
                    .filter { $0.id == host.id }
                    .filter { tunnelManager.status(for: $0).isActive }
                    .count
                Text(active > 0
                    ? "Are you sure you want to delete \"\(host.label)\"? \(active) active tunnel\(active == 1 ? "" : "s") will be disconnected."
                    : "Are you sure you want to delete \"\(host.label)\"?")
            }
        }
        .alert("Delete Identity", isPresented: Binding(
            get: { identityToDelete != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let identity = identityToDelete {
                    hostStore.removeIdentity(identity)
                    pendingDeletion = nil
                }
            }
        } message: {
            Text("Delete \"\(identityToDelete?.label ?? "")\"? Hosts referencing it fall back to their own fields.")
        }
        .alert("Import Hosts", isPresented: Binding(
            get: { !importPreview.isEmpty },
            set: { if !$0 { importPreview = [] } }
        )) {
            Button("Cancel", role: .cancel) { importPreview = [] }
            Button("Import \(importPreview.count)") {
                for host in importPreview {
                    hostStore.addHost(host)
                }
                importPreview = []
            }
        } message: {
            let labels = importPreview.prefix(8).map(\.label).joined(separator: ", ")
            Text("Import \(importPreview.count) hosts from ~/.ssh/config?\n\(labels)\(importPreview.count > 8 ? ", …" : "")")
        }
        .alert("SSH Config", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        // "Save as Host…" from the quick-connect palette opens the editor
        // on the just-saved host (WI-2026-08-09-003).
        .onReceive(NotificationCenter.default.publisher(for: .synaptyEditHost)) { note in
            if let idString = note.userInfo?["id"] as? String,
               let id = UUID(uuidString: idString),
               let host = hostStore.hosts.first(where: { $0.id == id }) {
                paneRaw = HostsPane.hosts.rawValue
                inspector = .host(host)
            }
        }
    }

    private var headerMeta: String {
        switch pane {
        case .hosts:
            return "\(hostStore.hosts.count) hosts · \(hostStore.groups.count) groups"
        case .identities:
            return "\(hostStore.identities.count) identities"
        case .forwarding:
            let rules = hostStore.forwardingOverview().count
            let live = forwards.exposures.count
            let base = "\(rules) rule\(rules == 1 ? "" : "s")"
            // Counted separately rather than summed: they have different
            // lifetimes, and a single number would let an agent's momentary
            // exposure read as something the human configured.
            return live == 0 ? base : base + " · \(live) exposed"
        }
    }

    // MARK: - Inspector content

    /// Inspector panel switch — extracted from the `.inspector` closure so
    /// the body expression stays type-checkable (WI-2026-08-08-090 pass 2).
    @ViewBuilder
    private var inspectorContent: some View {
        switch inspector {
        case .host(let host):
            HostEditorPanel(
                hostStore: hostStore,
                tunnelManager: tunnelManager,
                onClose: { inspector = nil },
                editingHost: host,
                presetGroupID: selectedGroup?.id
            )
        case .group(let group):
            GroupEditorPanel(
                hostStore: hostStore,
                onClose: { inspector = nil },
                editingGroup: group
            )
        case .identity(let identity):
            IdentityEditorPanel(
                hostStore: hostStore,
                onClose: { inspector = nil },
                editingIdentity: identity
            )
        case nil:
            EmptyView()
        }
    }

    // MARK: - Header actions

    /// Page-header trailing actions — extracted so the header expression
    /// stays type-checkable (the inline closure tipped the compiler's
    /// budget, WI-2026-08-08-090 pass 2).
    @ViewBuilder
    private var headerActions: some View {
        switch pane {
        case .forwarding:
            // Rules are owned by host/group editors — no page-level CTA
            // (WI-2026-08-09-008: overview, not a second editor).
            EmptyView()
        case .identities:
            Button {
                inspector = .identity(nil)
            } label: {
                Label("New Identity", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .hosts:
            Menu {
                Button {
                    importFromSSHConfig()
                } label: {
                    Label("Import from SSH Config…", systemImage: "square.and.arrow.down")
                }
                if let group = selectedGroup {
                    DSHairline()
                    // Hosts in the group become ungrouped — the
                    // confirmation alert documents this
                    // (WI-2026-08-08-025).
                    Button(role: .destructive) {
                        pendingDeletion = .group(group)
                    } label: {
                        Label("Delete Group…", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(DS.Icon.control)
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")

            Button {
                inspector = .host(nil)
            } label: {
                Label("New Host", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: - Group blocks section

    private var selectedGroup: HostGroup? {
        guard case .group(let id) = selectedFilter else { return nil }
        return hostStore.groups.first(where: { $0.id == id })
    }

    /// Block grid columns shared by the GROUPS and HOSTS sections — group
    /// and host blocks are the same size (WI-2026-08-08-065). Roomier
    /// Termius-style cards (WI-2026-08-08-090).
    /// COMPUTED, not stored: a `static let` freezes at first access, so
    /// the width would lock to whatever the UI scale happened to be then —
    /// possibly 1.0, before settings had loaded — and would never follow a
    /// change at runtime.
    private static var blockColumns: [GridItem] { [
        // Scaled, or a card at Extra Large is the same width holding a
        // third more text — which is where the truncated addresses came
        // from ([[WI-2026-08-15-002]]).
        GridItem(.adaptive(minimum: DS.scaled(260), maximum: DS.scaled(380)),
                 spacing: DS.Space.lg),
    ] }

    /// GROUPS section — rendered only in the default All Hosts view; inside
    /// a group it is hidden (WI-2026-08-08-068).
    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            // Section-scoped creation lives in the section header — the
            // sidebar SESSIONS "+" pattern; ONE entry per entity
            // (WI-2026-08-08-090, redundancy feedback).
            HStack(spacing: DS.Space.xs) {
                DSSectionLabel(text: "Groups", count: hostStore.groups.count)
                DSIconButton(icon: "plus", help: "New Group", size: 18) {
                    inspector = .group(nil)
                }
            }

            LazyVGrid(columns: Self.blockColumns, alignment: .leading, spacing: DS.Space.lg) {
                // Real groups — drop targets for host blocks.
                ForEach(hostStore.groups.sorted { $0.label < $1.label }) { group in
                    GroupBlockView(
                        label: group.label,
                        icon: "folder",
                        count: hostStore.hosts(inGroup: group.id).count,
                        // The cursor draws in the SAME chrome as a
                        // selected card. A cursor nobody can see is a
                        // cursor nobody can use, and pressing ↓ into an
                        // unmarked grid reads as the keys having died.
                        isSelected: selectedFilter == .group(group.id)
                            || cursorGroupID == group.id,
                        onSelect: {
                            cursorGroupID = group.id
                            cursorHostID = nil
                            selectedFilter = .group(group.id)
                        },
                        onDrop: { items in handleDrop(items, toGroup: group.id) },
                        onGroupSettings: { inspector = .group(group) },
                        onDelete: { pendingDeletion = .group(group) },
                        onOpenAsGrid: hostStore.hosts(inGroup: group.id).isEmpty ? nil : {
                            onOpenGroupAsGrid?(group)
                        }
                    )
                }
            }
        }
    }

    /// Breadcrumb shown inside a group (WI-2026-08-08-066/068):
    /// "All Hosts › Group"; clicking All Hosts returns to the default view.
    private func breadcrumb(_ group: HostGroup) -> some View {
        HStack(spacing: DS.Space.xs) {
            Button("All Hosts") { selectedFilter = .all }
                .buttonStyle(.plain)
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.accent)
                .help("Show all hosts")
                .accessibilityLabel("All Hosts")
            Image(systemName: "chevron.right")
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.textTertiary)
            Text(group.label)
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.textPrimary)
        }
    }

    // MARK: - Host list

    /// Hosts matching the group filter + search text + tag filter (AND),
    /// in the chosen sort order (WI-2026-08-09-006).
    private var visibleHosts: [HostEntry] {
        let base = hostStore.searchHosts(searchText, in: selectedFilter)
        let tagged = selectedTags.isEmpty ? base : base.filter { host in
            selectedTags.allSatisfy { host.tags.contains($0) }
        }
        if hostsSort == "recent" {
            return tagged.sorted(by: HostStore.byRecency)
        }
        return tagged.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// Bordered rounded search field — the Xcode/Finder filter-field look
    /// (WI-2026-08-08-059, WI-2026-08-08-090).
    private var searchField: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(DS.Typography.detail)
                .foregroundStyle(DS.textTertiary)
            TextField("Search hosts, addresses, tags", text: $searchText)
                .textFieldStyle(.plain)
                .font(DS.Typography.detail)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Icon.control)
                        .foregroundStyle(DS.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs + 1)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(DS.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(DS.border, lineWidth: 1)
        )
        .frame(maxWidth: DS.scaled(320))
    }

    /// Tags menu — multi-select AND filter (Termius parity).
    private var tagsMenu: some View {
        Menu {
            ForEach(hostStore.allTags, id: \.self) { tag in
                Button {
                    if selectedTags.contains(tag) {
                        selectedTags.remove(tag)
                    } else {
                        selectedTags.insert(tag)
                    }
                } label: {
                    if selectedTags.contains(tag) {
                        Label(tag, systemImage: "checkmark")
                    } else {
                        Text(tag)
                    }
                }
            }
            if !selectedTags.isEmpty {
                DSHairline()
                Button("Clear") { selectedTags = [] }
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "tag")
                    .font(DS.Typography.monoCaption)
                if !selectedTags.isEmpty {
                    Text("\(selectedTags.count)")
                        .font(DS.Typography.monoCaption)
                }
            }
            .foregroundStyle(selectedTags.isEmpty ? DS.textSecondary : DS.selectionAccent)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.pill)
                    .fill(selectedTags.isEmpty ? DS.hover : DS.selectionAccentSoft)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by tags")
        .accessibilityLabel("Filter by tags")
    }

    /// Active tag chips (removable).
    private var activeTagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xs) {
                ForEach(selectedTags.sorted(), id: \.self) { tag in
                    DSTag(text: tag) {
                        selectedTags.remove(tag)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.bottom, DS.Space.sm)
        }
    }

    /// HOSTS section — host blocks in the same grid as the GROUPS section
    /// (WI-2026-08-08-065).
    private var hostsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSSectionLabel(text: "Hosts", count: visibleHosts.count)
            if visibleHosts.isEmpty {
                VStack(spacing: DS.Space.sm) {
                    Image(systemName: "server.rack")
                        .font(DS.Icon.feature)
                        .foregroundStyle(DS.textTertiary)
                    Text(hostStore.hosts.isEmpty ? "No hosts yet — add one below." : "No hosts match the current filter.")
                        .font(DS.Typography.detail)
                        .foregroundStyle(DS.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.xl)
            } else if hostsView == "list" {
                // List view (WI-2026-08-09-006): card rows with the same
                // tap/double-click/drag semantics as the grid blocks.
                DSCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleHosts.enumerated()), id: \.element.id) { index, host in
                            HostListRow(
                                host: host,
                                store: hostStore,
                                tunnelStatus: tunnelManager.status(for: host),
                            peerState: tunnelManager.peerState(for: host),
                            hubBuilds: tunnelManager.hubBuilds(for: host),
                                isSelected: selectedHostIDs.contains(host.id),
                                onOpenTerminal: { onOpenTerminal?(host) },
                                onEdit: { inspector = .host(host) },
                                onDelete: { pendingDeletion = .host(host) },
                                onReconnect: { tunnelManager.reconnectTunnel(for: host) },
                                onDisconnect: { tunnelManager.disconnectTunnel(for: host) },
                            onUpdateBinary: { paneManager.updateHostBinary(host) },
                            binaryStale: paneManager.hostBinary[host.id] == .stale,
                            updatingBinary: paneManager.hostsUpdating.contains(host.id)
                            )
                            .onTapGesture { handleBlockTap(host) }
                            .draggable(HostDragPayload(hostIDs: dragIDs(for: host)))
                            if index < visibleHosts.count - 1 {
                                DSHairline().padding(.leading, DS.Space.xl)
                            }
                        }
                    }
                }
            } else {
                LazyVGrid(columns: Self.blockColumns, alignment: .leading, spacing: DS.Space.lg) {
                    ForEach(visibleHosts) { host in
                        HostBlockView(
                            host: host,
                            store: hostStore,
                            tunnelStatus: tunnelManager.status(for: host),
                            peerState: tunnelManager.peerState(for: host),
                            sshArgs: { timeout, remote in
                                tunnelManager.oneOffArgs(for: host, connectTimeout: timeout,
                                                         remote: remote)
                            },
                            hubBuilds: tunnelManager.hubBuilds(for: host),
                            isSelected: selectedHostIDs.contains(host.id),
                            onOpenTerminal: { onOpenTerminal?(host) },
                            onEdit: { inspector = .host(host) },
                            onDelete: { pendingDeletion = .host(host) },
                            onReconnect: { tunnelManager.reconnectTunnel(for: host) },
                            onDisconnect: { tunnelManager.disconnectTunnel(for: host) },
                            onUpdateBinary: { paneManager.updateHostBinary(host) },
                            binaryStale: paneManager.hostBinary[host.id] == .stale,
                            updatingBinary: paneManager.hostsUpdating.contains(host.id)
                        )
                        .onTapGesture { handleBlockTap(host) }
                        .draggable(HostDragPayload(hostIDs: dragIDs(for: host)))
                    }
                }
                // MEASURED, so a row means the row on screen. The count is
                // derived from this in `columns:` above using the grid's
                // own adaptive arithmetic.
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { gridWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, w in gridWidth = w }
                    }
                )
            }
        }
    }

    // MARK: - Block selection (drag-and-drop support)

    /// Single tap: select immediately. A second tap within the system
    /// double-click window opens the terminal (WI-2026-08-08-076).
    private func handleBlockTap(_ host: HostEntry) {
        let now = Date()
        if now.timeIntervalSince(lastBlockTapTime) < NSEvent.doubleClickInterval {
            lastBlockTapTime = .distantPast
            onOpenTerminal?(host)
        } else {
            selectHost(host.id)
            lastBlockTapTime = now
        }
    }

    /// Cmd-click toggles membership; plain click selects just this host.
    ///
    /// AND MOVES THE CURSOR THERE. The mouse and the keyboard were two
    /// stores of one fact: clicking set the selection while the keyboard
    /// index stayed at "not navigating", so the next arrow ENTERED the
    /// grid at zero — which, from the second card, looks exactly like
    /// moving left. Focus comes with it, or the arrow would go wherever
    /// focus happened to be.
    private func selectHost(_ id: UUID) {
        cursorHostID = id
        cursorGroupID = nil
        gridFocused = true
        if NSEvent.modifierFlags.contains(.command) {
            if selectedHostIDs.contains(id) {
                selectedHostIDs.remove(id)
            } else {
                selectedHostIDs.insert(id)
            }
        } else {
            selectedHostIDs = [id]
        }
    }

    /// Dragging a selected block carries the whole selection; an unselected
    /// block drags alone (WI-2026-08-08-057).
    private func dragIDs(for host: HostEntry) -> [UUID] {
        if selectedHostIDs.contains(host.id) {
            return Array(selectedHostIDs)
        }
        return [host.id]
    }

    /// Shared drop handler for group rows and the Ungrouped row.
    private func handleDrop(_ items: [HostDragPayload], toGroup groupID: UUID?) -> Bool {
        let ids = items.flatMap(\.hostIDs)
        guard !ids.isEmpty else { return false }
        hostStore.moveHosts(ids, toGroup: groupID)
        return true
    }

    // MARK: - Hosts pane (GROUPS + HOSTS block sections + footer)

    /// Two sections of equally sized blocks (WI-2026-08-08-065): GROUPS
    /// above, HOSTS below.
    private var hostsPane: some View {
        VStack(spacing: 0) {
            if hostStore.hosts.isEmpty && hostStore.groups.isEmpty {
                // First-run empty state (WI-2026-08-07-004).
                DSEmptyState(
                    icon: "server.rack",
                    title: "No hosts yet",
                    message: "Add hosts manually, or import them from your ~/.ssh/config."
                ) {
                    HStack(spacing: DS.Space.md) {
                        Button {
                            inspector = .host(nil)
                        } label: {
                            Label("New Host", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            importFromSSHConfig()
                        } label: {
                            Label("Import from ~/.ssh/config", systemImage: "square.and.arrow.down")
                        }
                        .help("Import hosts from ~/.ssh/config")
                    }
                }
            } else {
                DSHairline()

                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        if let group = selectedGroup {
                            // Inside a group: breadcrumb only — no GROUPS
                            // section (WI-2026-08-08-068).
                            breadcrumb(group)
                            hostsSection
                        } else {
                            // Default All Hosts view: GROUPS + HOSTS.
                            groupsSection
                            hostsSection
                        }
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.vertical, DS.Space.lg)
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedHostIDs = [] }
            }
        }
    }

    // MARK: - SSH config import

    @State private var importPreview: [HostEntry] = []

    private func importFromSSHConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.ssh/config"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            // No config file — show an alert with the path.
            importError = "No SSH config found at \(path)"
            return
        }
        let parsed = HostStore.parseSSHConfig(content)
        // Skip hosts that already exist (same address).
        let existing = Set(hostStore.hosts.map(\.address))
        importPreview = parsed.filter { !existing.contains($0.address) }
        if importPreview.isEmpty {
            importError = "No new hosts to import from \(path)"
        }
    }

    @State private var importError: String?

    // MARK: - Forwarding pane (WI-2026-08-09-008)

    struct ForwardingSection {
        let host: HostEntry
        var rules: [ForwardingOverviewEntry] = []
        var live: [PortForwardService.Exposure] = []
        var count: Int { rules.count + live.count }
    }

    /// Overview rows grouped by owning host, in overview (label) order.
    ///
    /// TWO SOURCES, ONE READER — the same shape the Activity tab needed for
    /// transfers, and for the same reason.
    ///
    /// A standing RULE and an agent's EXPOSURE are genuinely different
    /// things: one is configuration the human wrote, inheritable from a
    /// group and reapplied on every connect; the other is an event, held
    /// only in memory, and persisting it would turn a moment's request into
    /// config nobody agreed to. So the models stay apart.
    ///
    /// But they produce the SAME ARTIFACT — a listening port on this Mac
    /// that reaches a remote service — and this page is where a human comes
    /// to ask what those are. An overview that answered for only one of the
    /// two authors was worse than none, because a partial answer to that
    /// question reads as a complete one.
    private var forwardingSections: [ForwardingSection] {
        var sections: [ForwardingSection] = []
        func section(for hostID: UUID) -> Int? {
            if let idx = sections.firstIndex(where: { $0.host.id == hostID }) { return idx }
            guard let host = hostStore.hosts.first(where: { $0.id == hostID }) else { return nil }
            sections.append(ForwardingSection(host: host))
            return sections.count - 1
        }
        for entry in hostStore.forwardingOverview() {
            if let idx = section(for: entry.hostID) { sections[idx].rules.append(entry) }
        }
        // Appended after, so a host reached only by an agent still gets a
        // section rather than being invisible here.
        // A LOCAL EXPOSURE HAS NO HOST SECTION, and wants none: this page
        // is about the machines the human configured, and an agent's offer
        // on this Mac is not one of them. It is in that machine's services
        // pane, which is where it belongs.
        for exposure in forwards.exposures {
            guard let hostID = exposure.hostID else { continue }
            if let idx = section(for: hostID) { sections[idx].live.append(exposure) }
        }
        return sections
    }

    /// Read-focused global overview: rules grouped by host, active state
    /// from the tunnel, edit jumps to the OWNING host/group editor — no
    /// second editor surface.
    private var forwardingPane: some View {
        VStack(spacing: 0) {
            if forwardingSections.isEmpty {
                DSEmptyState(
                    icon: "arrow.left.arrow.right",
                    title: "No forwarding rules",
                    message: "Add local (-L) or remote (-R) forwards in a host's or group's editor. Rules apply when the tunnel is established."
                ) {
                    Button {
                        paneRaw = HostsPane.hosts.rawValue
                    } label: {
                        Label("Go to Hosts", systemImage: "server.rack")
                    }
                }
            } else {
                DSHairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        ForEach(forwardingSections, id: \.host.id) { section in
                            VStack(alignment: .leading, spacing: DS.Space.sm) {
                                DSSectionLabel(text: section.host.label, count: section.count, preserveCase: true)
                                DSCard(padding: 0) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(section.rules.enumerated()), id: \.element.id) { index, entry in
                                            ForwardingRow(
                                                entry: entry,
                                                isActive: tunnelManager.status(for: section.host).isActive,
                                                groupLabel: entry.inheritedFromGroupID.flatMap { gid in
                                                    hostStore.groups.first(where: { $0.id == gid })?.label
                                                },
                                                onEdit: {
                                                    if let gid = entry.inheritedFromGroupID,
                                                       let group = hostStore.groups.first(where: { $0.id == gid }) {
                                                        inspector = .group(group)
                                                    } else {
                                                        inspector = .host(section.host)
                                                    }
                                                }
                                            )
                                            if index < section.count - 1 {
                                                DSHairline().padding(.leading, DS.Space.xl)
                                            }
                                        }
                                        ForEach(Array(section.live.enumerated()), id: \.element.id) { index, exposure in
                                            ExposedForwardRow(exposure: exposure) {
                                                Task { @MainActor in await forwards.withdraw(exposure.id) }
                                            }
                                            if index < section.live.count - 1 {
                                                DSHairline().padding(.leading, DS.Space.xl)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.vertical, DS.Space.lg)
                    .frame(maxWidth: DS.scaled(760), alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    // MARK: - Identities pane

    private var identitiesPane: some View {
        VStack(spacing: 0) {
            if hostStore.identities.isEmpty {
                DSEmptyState(
                    icon: "key",
                    title: "No identities",
                    message: "Identities are reusable credentials (username + SSH key) shared across hosts and groups."
                ) {
                    Button {
                        inspector = .identity(nil)
                    } label: {
                        Label("New Identity", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                DSHairline()
                // Card grid — same visual family as the host blocks
                // (WI-2026-08-08-090).
                ScrollView {
                    LazyVGrid(columns: Self.blockColumns, alignment: .leading, spacing: DS.Space.lg) {
                        ForEach(hostStore.identities) { identity in
                            IdentityCardView(
                                identity: identity,
                                store: hostStore,
                                onEdit: { inspector = .identity(identity) },
                                onDelete: { pendingDeletion = .identity(identity) }
                            )
                        }
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.vertical, DS.Space.lg)
                }
            }
        }
    }

}

// MARK: - Exposed forward row ([[WI-2026-08-15-011]])

/// One live agent exposure, in the same overview as the standing rules.
///
/// IT READS AS A DIFFERENT KIND OF THING, because it is one. A rule is
/// edited and comes back on the next connect; this exists only while the
/// application is running and is withdrawn, not edited. So the action is
/// withdrawal, the origin is an agent rather than a host or group, and the
/// dot is not conditional — an exposure that is listed IS live.
struct ExposedForwardRow: View {
    let exposure: PortForwardService.Exposure
    let onWithdraw: () -> Void

    @State private var isHovered = false

    /// String(_:), not the Int: `Text("… \(anInt)")` would group-separate
    /// the port. Same reason as [[ServicesView]].
    private var routeText: String {
        "\(exposure.localPort) → 127.0.0.1:\(exposure.remotePort)\(pathSuffix)"
    }

    /// The path is shown here too: this page is where a human asks what
    /// the open ports on their machine reach, and "port 9090" and
    /// "port 9090's admin page" are different answers.
    private var pathSuffix: String {
        exposure.path == ExposedPath.root ? "" : exposure.path
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            DSStatusDot(color: DS.success, size: 7)
                .help("Open now — withdrawn when the agent or you close it")

            Text("-L")
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.info)
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 1)
                .background(DS.hover, in: Capsule())

            Text(routeText)
                .font(DS.Typography.monoCaption)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: DS.Space.xs) {
                Image(systemName: "cpu")
                    .font(DS.Typography.caption)
                Text(exposure.title.map { "\(exposure.agent) · \($0)" } ?? exposure.agent)
            }
            .font(DS.Typography.caption)
            .foregroundStyle(DS.textTertiary)
            .lineLimit(1)

            Spacer(minLength: DS.Space.md)

            DSIconButton(icon: "xmark", help: "Withdraw this forward", size: 22) { onWithdraw() }
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .background(isHovered ? DS.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Local forward, \(routeText), exposed by \(exposure.agent), open")
        .accessibilityAction(named: "Withdraw") { onWithdraw() }
    }
}

// MARK: - Forwarding row (WI-2026-08-09-008)

/// One rule of the global Forwarding overview: active dot (tunnel state),
/// kind pill, mono route, inheritance note, hover-revealed edit that jumps
/// to the owning editor.
struct ForwardingRow: View {
    let entry: ForwardingOverviewEntry
    /// Rules apply when the tunnel is up — active mirrors the host tunnel.
    let isActive: Bool
    /// Present when the rule is inherited from a group.
    let groupLabel: String?
    let onEdit: () -> Void

    @State private var isHovered = false

    private var routeText: String {
        let arrow = entry.rule.kind == .local ? "→" : "←"
        return "\(entry.rule.listenPort) \(arrow) \(entry.rule.targetHost):\(entry.rule.targetPort)"
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            DSStatusDot(color: isActive ? DS.success : DS.textTertiary, size: 7)
                .help(isActive ? "Tunnel up — rule active" : "Tunnel down — applies on next connect")

            Text(entry.rule.kind == .local ? "-L" : "-R")
                .font(DS.Typography.monoCaption)
                .foregroundStyle(entry.rule.kind == .local ? DS.info : DS.warning)
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 1)
                .background(DS.hover, in: Capsule())

            Text(routeText)
                .font(DS.Typography.monoCaption)
                .lineLimit(1)
                .truncationMode(.middle)

            if let groupLabel {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "folder")
                        .font(DS.Typography.caption)
                    Text("from \(groupLabel)")
                }
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textTertiary)
            }

            Spacer(minLength: DS.Space.md)

            DSIconButton(
                icon: "pencil",
                help: groupLabel == nil ? "Edit host rules" : "Edit group rules",
                size: 22
            ) { onEdit() }
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .background(isHovered ? DS.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        // Rule spoken in words; the dot and pills are visual shorthand
        // (WI-2026-08-09-020).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.rule.kind == .local ? "Local" : "Remote") forward, \(routeText)"
            + (groupLabel.map { ", from group \($0)" } ?? "")
            + (isActive ? ", active" : ", inactive")
        )
        .accessibilityAction(named: "Edit rules") { onEdit() }
    }
}

// MARK: - Identity card

/// Card block for one reusable identity — same visual family as the host
/// blocks: icon tile + label/detail, hover + right-click actions,
/// double-click to edit (WI-2026-08-08-090).
struct IdentityCardView: View {
    let identity: Identity
    var store: HostStore
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var lastTapTime = Date.distantPast

    /// "2 hosts · 1 group" — host AND group references
    /// (WI-2026-08-09-008; groups reuse identities since WI-2026-08-09-001).
    private var usageText: String? {
        let usage = store.identityUsage(for: identity.id)
        var parts: [String] = []
        if usage.hosts > 0 { parts.append("\(usage.hosts) host\(usage.hosts == 1 ? "" : "s")") }
        if usage.groups > 0 { parts.append("\(usage.groups) group\(usage.groups == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var cardActions: some View {
        Button {
            onEdit()
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            // Tile geometry parity with HostAvatar/group tiles
            // (WI-2026-08-09-010).
            RoundedRectangle(cornerRadius: DS.scaled(8), style: .continuous)
                .fill(DS.accentSoft)
                .frame(width: DS.scaled(32), height: DS.scaled(32))
                .overlay(
                    Image(systemName: "key.fill")
                        .font(DS.Icon.avatar)
                        .foregroundStyle(DS.accent)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(identity.label)
                    .font(DS.Typography.bodyStrong)
                    .lineLimit(1)
                HStack(spacing: DS.Space.xs) {
                    Text(identity.username)
                        .font(DS.Typography.monoCaption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                    if let key = identity.sshKeyPath {
                        Text(key)
                            .font(DS.Typography.monoCaption)
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(key)
                    }
                }
            }

            Spacer(minLength: DS.Space.xs)

            if let usageText, !isHovered {
                Text(usageText)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }

            HStack(spacing: DS.Space.xs) {
                DSIconButton(icon: "pencil", help: "Edit", size: 22) { onEdit() }
                DSOverflowMenu {
                    cardActions
                }
            }
            .opacity(isHovered ? 1 : 0)
            // Invisible controls must not swallow clicks (WI-2026-08-08-090).
            .allowsHitTesting(isHovered)
        }
        .padding(DS.Space.lg)
        .frame(minHeight: 56)
        .dsCardChrome(isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu { cardActions }
        // Double-click opens the editor — same timestamp approach as host
        // blocks (WI-2026-08-08-076).
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(lastTapTime) < NSEvent.doubleClickInterval {
                lastTapTime = .distantPast
                onEdit()
            } else {
                lastTapTime = now
            }
        }
    }
}


// MARK: - Group editor panel (create + defaults)

/// Right-side inspector panel for a group (WI-2026-08-08-067/069/090):
/// nil group = create. Hosts in the group fall back to the defaults when
/// they don't set their own values. Single-level groups: no parent, no
/// identity. Same surface as the host editor — New Host and New Group are
/// consistent (WI-2026-08-08-090).
struct GroupEditorPanel: View {
    var hostStore: HostStore
    var onClose: () -> Void = {}
    /// If set, we're editing an existing group; otherwise creating one.
    var editingGroup: HostGroup?

    @State private var label = ""
    @State private var portText = ""
    @State private var username = ""
    @State private var proxyJump = ""
    /// Group-level reusable credentials (WI-2026-08-09-001).
    @State private var identityID: UUID?
    /// Forwarding rules (WI-2026-08-08-067): on = the group defines rules,
    /// off = no rules from this group.
    @State private var setForwardings = false
    @State private var forwardings: [PortForward] = []
    @FocusState private var labelFocused: Bool

    private var isEditing: Bool { editingGroup != nil }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Panel header (inspector form, WI-2026-08-08-069).
            DSPanelHeader(
                title: isEditing ? "Group Settings" : "New Group",
                icon: isEditing ? "folder" : "folder.badge.plus"
            ) { onClose() }

            DSHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    DSSectionBlock(title: "Group") {
                        DSFormField("Name", density: .page) {
                            TextField("e.g. Production", text: $label)
                                .dsField()
                                .font(DS.Typography.body)
                                .focused($labelFocused)
                        }
                    }

                    // Group credentials (WI-2026-08-09-001): rotate one
                    // Identity, every member host follows. Parity with the
                    // host editor's Credentials section.
                    DSSectionBlock(
                        title: "Credentials",
                        help: "Hosts in this group inherit these unless they set their own (inline fields or a host-level Identity)."
                    ) {
                        DSFormField("Identity", density: .page) {
                            DSDropdown(
                                selection: $identityID,
                                options: [(Optional<UUID>.none, "None")]
                                    + hostStore.identities.map { (Optional($0.id), $0.label) }
                            )
                        }
                        if let id = identityID,
                           let identity = hostStore.identities.first(where: { $0.id == id }) {
                            // Resolved credential hint — same affordance as
                            // the host editor.
                            Text("\(identity.username)\(identity.sshKeyPath.map { " · \($0)" } ?? "")")
                                .font(DS.Typography.monoCaption)
                                .foregroundStyle(DS.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    DSSectionBlock(
                        title: "Defaults",
                        help: "Hosts in this group use these when they don't set their own values. The Identity above beats the username here."
                    ) {
                        DSFormField("Username", density: .page) {
                            TextField(identityID == nil ? "Optional" : "Unused while an Identity is set", text: $username)
                                .dsField()
                                .font(DS.Typography.body)
                        }
                        DSFormField("Port", density: .page) {
                            TextField("22", text: $portText)
                                .dsField()
                                .font(DS.Typography.body)
                                .frame(maxWidth: DS.scaled(90))
                        }
                        DSFormField("Jump host", density: .page) {
                            TextField("user@host:port (optional)", text: $proxyJump)
                                .dsField()
                                .font(DS.Typography.body)
                        }
                    }

                    // Port forwardings (WI-2026-08-08-060/067)
                    DSSectionBlock(title: "Port Forwarding") {
                        Toggle("Set forwarding rules for this group", isOn: $setForwardings)
                            .toggleStyle(.switch)
                            .font(DS.Typography.detail)
                        if setForwardings {
                            ForwardingsEditor(forwardings: $forwardings)
                        }
                    }
                }
                .padding(DS.Space.xl)
            }

            DSSheetFooter(confirm: isEditing ? "Save" : "Create",
                          canConfirm: canSave,
                          onCancel: onClose,
                          onConfirm: save)
        }
        // Flexible — the inspector column decides the width
        // (WI-2026-08-08-090; fixed 400 clipped at large UI scales).
        .frame(minWidth: 320, maxWidth: .infinity)
        .background(DS.background)
        .onAppear {
            if let group = editingGroup {
                label = group.label
                username = group.username ?? ""
                proxyJump = group.proxyJump ?? ""
                identityID = group.identityID
                setForwardings = group.forwardings != nil
                forwardings = group.forwardings ?? []
                if let port = group.port {
                    portText = "\(port)"
                }
            } else {
                labelFocused = true
            }
        }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let trimmedProxy = proxyJump.trimmingCharacters(in: .whitespaces)

        if var updated = editingGroup {
            updated.label = trimmedLabel
            updated.username = trimmedUser.isEmpty ? nil : trimmedUser
            updated.port = Int(portText)
            updated.proxyJump = trimmedProxy.isEmpty ? nil : trimmedProxy
            updated.identityID = identityID
            updated.forwardings = setForwardings ? forwardings : nil
            hostStore.updateGroup(updated)
        } else {
            var group = HostGroup(label: trimmedLabel)
            group.username = trimmedUser.isEmpty ? nil : trimmedUser
            group.port = Int(portText)
            group.proxyJump = trimmedProxy.isEmpty ? nil : trimmedProxy
            group.identityID = identityID
            group.forwardings = setForwardings ? forwardings : nil
            hostStore.addGroup(group)
        }
        onClose()
    }
}

/// WHICH ONE THING IS BEING DESTROYED, if any.
///
/// The workbench asks before it destroys a host, a group or an identity,
/// and it asks about ONE of them — held as three optionals, "two at once"
/// was representable and would have stacked two alerts, the second about
/// something the first had already removed.
enum HostsDeletion: Equatable {
    case host(HostEntry)
    case group(HostGroup)
    case identity(Identity)
}
