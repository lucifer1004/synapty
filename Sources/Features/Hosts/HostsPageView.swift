import SwiftUI

/// Sub-panes of the Hosts page.
enum HostsPane: Hashable {
    case hosts
    case identities
}

/// Host management page — Termius-style host management:
/// nested groups in a sidebar, searchable host list with tags, and full
/// CRUD for hosts, groups and reusable identities.
struct HostsPageView: View {
    var hostStore: HostStore
    var tunnelManager: TunnelManager
    /// One-click terminal open from the host list (WI-2026-08-08-064).
    var onOpenTerminal: ((HostEntry) -> Void)? = nil

    /// Currently selected host-list filter.
    @State private var selectedFilter: HostFilter = .all
    /// Host search text.
    @State private var searchText = ""
    /// Multi-selection for drag-and-drop (WI-2026-08-08-057): Cmd-click
    /// toggles; dragging a selected block drags the whole selection.
    @State private var selectedHostIDs: Set<UUID> = []
    /// Hover highlight for the Ungrouped drop target.
    @State private var ungroupedDropTargeted = false
    /// Hover highlight for the All Hosts root drop target (group reparent
    /// to top level, WI-2026-08-08-062).
    @State private var allHostsDropTargeted = false
    /// Tag filter (WI-2026-08-08-059): hosts must have ALL selected tags.
    @State private var selectedTags: Set<String> = []
    /// Which sub-pane of the Hosts page is shown.
    @State private var pane: HostsPane = .hosts
    @State private var showAddHost = false
    @State private var showNewGroup = false
    @State private var subgroupRequest: GroupSubgroupRequest?
    @State private var groupToEdit: HostGroup?
    @State private var hostToEdit: HostEntry?
    @State private var hostToDelete: HostEntry?
    @State private var groupToDelete: HostGroup?
    @State private var editingGroupID: UUID?
    @State private var identityToEdit: Identity?
    @State private var identityToDelete: Identity?
    @State private var showNewIdentity = false

    var body: some View {
        VStack(spacing: 0) {
            // Page header
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .frame(width: 18)
                Text("Hosts")
                    .font(DS.Typography.titleLarge)
                Spacer()
                if !hostStore.hosts.isEmpty {
                    Text("\(hostStore.hosts.count) hosts")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)
            Divider()

            // Sub-navigation: Hosts | Identities
            HStack(spacing: DS.Space.sm) {
                paneChip(.hosts, title: "Hosts", icon: "server.rack")
                paneChip(.identities, title: "Identities", icon: "key")
                Spacer()
                if pane == .hosts {
                    Text("\(hostStore.hosts.count) hosts · \(hostStore.groups.count) groups")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                } else if pane == .identities {
                    Text("\(hostStore.identities.count) identities")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.md)

            switch pane {
            case .hosts: hostsPane
            case .identities: identitiesPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        .sheet(isPresented: $showAddHost) {
            AddHostSheet(
                hostStore: hostStore,
                tunnelManager: tunnelManager,
                isPresented: $showAddHost,
                presetGroupID: selectedGroup?.id
            )
        }
        .sheet(item: $hostToEdit) { host in
            AddHostSheet(
                hostStore: hostStore,
                tunnelManager: tunnelManager,
                isPresented: Binding(
                    get: { hostToEdit != nil },
                    set: { if !$0 { hostToEdit = nil } }
                ),
                editingHost: host
            )
        }
        .sheet(isPresented: $showNewGroup) {
            NewGroupSheet(hostStore: hostStore, parentID: selectedGroup?.id, isPresented: $showNewGroup)
        }
        .sheet(item: $subgroupRequest) { request in
            NewGroupSheet(
                hostStore: hostStore,
                parentID: request.parentID,
                isPresented: Binding(
                    get: { subgroupRequest != nil },
                    set: { if !$0 { subgroupRequest = nil } }
                )
            )
        }
        .sheet(item: $groupToEdit) { group in
            GroupEditSheet(
                hostStore: hostStore,
                isPresented: Binding(
                    get: { groupToEdit != nil },
                    set: { if !$0 { groupToEdit = nil } }
                ),
                editingGroup: group
            )
        }
        .sheet(isPresented: $showNewIdentity) {
            IdentityEditSheet(hostStore: hostStore, isPresented: $showNewIdentity)
        }
        .sheet(item: $identityToEdit) { identity in
            IdentityEditSheet(
                hostStore: hostStore,
                isPresented: Binding(
                    get: { identityToEdit != nil },
                    set: { if !$0 { identityToEdit = nil } }
                ),
                editingIdentity: identity
            )
        }
        .alert("Delete Group", isPresented: Binding(
            get: { groupToDelete != nil },
            set: { if !$0 { groupToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { groupToDelete = nil }
            Button("Delete", role: .destructive) {
                if let group = groupToDelete {
                    hostStore.removeGroup(group)
                    if case .group(let id) = selectedFilter, id == group.id {
                        selectedFilter = .all
                    }
                    groupToDelete = nil
                }
            }
        } message: {
            Text("Delete \"\(groupToDelete?.label ?? "")\"? Hosts become ungrouped; subgroups move to its parent.")
        }
        .alert("Delete Host", isPresented: Binding(
            get: { hostToDelete != nil },
            set: { if !$0 { hostToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { hostToDelete = nil }
            Button("Delete", role: .destructive) {
                if let host = hostToDelete {
                    tunnelManager.disconnectTunnel(for: host)
                    hostStore.removeHost(host)
                    hostToDelete = nil
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
            set: { if !$0 { identityToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { identityToDelete = nil }
            Button("Delete", role: .destructive) {
                if let identity = identityToDelete {
                    hostStore.removeIdentity(identity)
                    identityToDelete = nil
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
    }

    // MARK: - Group sidebar

    private var selectedGroup: HostGroup? {
        guard case .group(let id) = selectedFilter else { return nil }
        return hostStore.groups.first(where: { $0.id == id })
    }

    private var groupSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                DSSectionLabel(text: "Groups")
                Spacer()
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)

            List(selection: $selectedFilter) {
                // "All hosts" pseudo-group — also the root drop target:
                // dropping a group here moves it to the top level
                // (WI-2026-08-08-062).
                Label("All Hosts", systemImage: "square.grid.2x2")
                    .font(DS.Typography.detailStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md)
                            .fill(allHostsDropTargeted ? DS.accent.opacity(0.18) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .dropDestination(for: GroupDragPayload.self) { items, _ in
                        let ids = items.flatMap(\.groupIDs)
                        guard let first = ids.first, ids.count == 1 else { return false }
                        return hostStore.moveGroup(first, toParent: nil)
                    } isTargeted: { targeted in
                        allHostsDropTargeted = targeted
                    }
                    .tag(HostFilter.all)

                // Ungrouped pseudo-group — also a drop target: dropping
                // here clears group membership (WI-2026-08-08-057).
                if !hostStore.hosts(inGroup: nil).isEmpty {
                    Label("Ungrouped", systemImage: "tray")
                        .font(DS.Typography.detail)
                        .foregroundStyle(DS.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.md)
                                .fill(ungroupedDropTargeted ? DS.accentSoft : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .dropDestination(for: HostDragPayload.self) { items, _ in
                            let ids = items.flatMap(\.hostIDs)
                            guard !ids.isEmpty else { return false }
                            hostStore.moveHosts(ids, toGroup: nil)
                            return true
                        } isTargeted: { targeted in
                            ungroupedDropTargeted = targeted
                        }
                        .tag(HostFilter.ungrouped)
                }

                // Group tree
                ForEach(hostStore.groups.filter { $0.parentID == nil }.sorted { $0.label < $1.label }) { group in
                    GroupRow(
                        group: group,
                        hostStore: hostStore,
                        indent: 0,
                        editingGroupID: $editingGroupID,
                        onNewSubgroup: { parentID in subgroupRequest = GroupSubgroupRequest(parentID: parentID) },
                        onEdit: { group in groupToEdit = group }
                    )
                    .tag(HostFilter.group(group.id))
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(DS.sidebar)
    }

    // MARK: - Host list

    /// Hosts matching the group filter + search text + tag filter (AND).
    private var visibleHosts: [HostEntry] {
        let base = hostStore.searchHosts(searchText, in: selectedFilter)
        guard !selectedTags.isEmpty else { return base }
        return base.filter { host in
            selectedTags.allSatisfy { host.tags.contains($0) }
        }
    }

    private var hostListPane: some View {
        VStack(spacing: 0) {
            // Search bar + tag filter (WI-2026-08-08-059)
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.textTertiary)
                TextField("Search hosts, addresses, tags", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.detail)

                // Tags menu — multi-select AND filter (Termius parity).
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
                        Divider()
                        Button("Clear") { selectedTags = [] }
                    }
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "tag")
                            .font(.system(size: 11))
                        if !selectedTags.isEmpty {
                            Text("\(selectedTags.count)")
                                .font(DS.Typography.monoCaption)
                        }
                    }
                    .foregroundStyle(selectedTags.isEmpty ? DS.textSecondary : DS.accent)
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.pill)
                            .fill(selectedTags.isEmpty ? DS.hover : DS.accentSoft)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter by tags")
                .accessibilityLabel("Filter by tags")
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.md)

            // Active tag chips (removable)
            if !selectedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs) {
                        ForEach(selectedTags.sorted(), id: \.self) { tag in
                            HStack(spacing: DS.Space.xs) {
                                Text(tag)
                                    .font(DS.Typography.captionStrong)
                                Button {
                                    selectedTags.remove(tag)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove tag \(tag)")
                            }
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.vertical, 2)
                            .background(DS.accentSoft, in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.sm)
                .padding(.top, DS.Space.xs)
            } else {
                // Keep the search row's bottom padding stable.
                Color.clear
                    .frame(height: DS.Space.md)
                    .padding(.bottom, DS.Space.sm)
            }

            Divider()

            if visibleHosts.isEmpty {
                VStack(spacing: DS.Space.lg) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 32))
                        .foregroundStyle(DS.textTertiary)
                    Text(hostStore.hosts.isEmpty ? "No hosts configured" : "No hosts match")
                        .font(DS.Typography.titleLarge)
                        .foregroundStyle(DS.textSecondary)
                    Text("Add a host with the button below.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // Host BLOCKS in a responsive grid (WI-2026-08-08-057):
                    // cards are the drag source; the group tree is the
                    // drop target.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: DS.Space.md)],
                        alignment: .leading,
                        spacing: DS.Space.md
                    ) {
                        ForEach(visibleHosts) { host in
                            HostBlockView(
                                host: host,
                                store: hostStore,
                                tunnelStatus: tunnelManager.status(for: host),
                                isSelected: selectedHostIDs.contains(host.id),
                                onOpenTerminal: { onOpenTerminal?(host) },
                                onEdit: { hostToEdit = host },
                                onDelete: { hostToDelete = host },
                                onReconnect: { tunnelManager.reconnectTunnel(for: host) },
                                onDisconnect: { tunnelManager.disconnectTunnel(for: host) }
                            )
                            .onTapGesture { selectHost(host.id) }
                            .draggable(HostDragPayload(hostIDs: dragIDs(for: host)))
                        }
                    }
                    .padding(DS.Space.lg)
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedHostIDs = [] }
            }
        }
    }

    // MARK: - Block selection (drag-and-drop support)

    /// Cmd-click toggles membership; plain click selects just this host.
    private func selectHost(_ id: UUID) {
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

    // MARK: - Hosts pane (group tree + list + footer)

    private var hostsPane: some View {
        VStack(spacing: 0) {
            if hostStore.hosts.isEmpty {
                // First-run empty state (WI-2026-08-07-004).
                VStack(spacing: DS.Space.lg) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 36))
                        .foregroundStyle(DS.textTertiary)
                    Text("No hosts yet")
                        .font(DS.Typography.titleLarge)
                        .foregroundStyle(DS.textSecondary)
                    Text("Add hosts manually, or import them from your ~/.ssh/config.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: DS.Space.md) {
                        Button {
                            showAddHost = true
                        } label: {
                            Label("New Host", systemImage: "plus")
                        }
                        Button {
                            importFromSSHConfig()
                        } label: {
                            Label("Import from ~/.ssh/config", systemImage: "square.and.arrow.down")
                        }
                        .help("Import hosts from ~/.ssh/config")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    groupSidebar
                        .frame(width: 200)

                    Divider()

                    hostListPane
                }

                Divider()

                // Footer
                HStack(spacing: DS.Space.md) {
                    Button {
                        showAddHost = true
                    } label: {
                        Label("New Host", systemImage: "plus")
                    }
                    Button {
                        showNewGroup = true
                    } label: {
                        Label("New Group", systemImage: "folder.badge.plus")
                    }
                    Button {
                        importFromSSHConfig()
                    } label: {
                        Label("Import from SSH Config", systemImage: "square.and.arrow.down")
                    }
                    .help("Import hosts from ~/.ssh/config")
                    Spacer()
                    if let group = selectedGroup {
                        Button(role: .destructive) {
                            groupToDelete = group
                        } label: {
                            Label("Delete Group", systemImage: "trash")
                        }
                        // The model's removeGroup reparents subgroups and
                        // ungroups hosts — the confirmation alert documents
                        // exactly that, so non-empty groups are deletable
                        // (WI-2026-08-08-025).
                        .help("Hosts become ungrouped; subgroups move to the parent")
                    }
                }
                .padding(DS.Space.lg)
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

    // MARK: - Identities pane

    private var identitiesPane: some View {
        VStack(spacing: 0) {
            if hostStore.identities.isEmpty {
                VStack(spacing: DS.Space.lg) {
                    Image(systemName: "key")
                        .font(.system(size: 32))
                        .foregroundStyle(DS.textTertiary)
                    Text("No identities")
                        .font(DS.Typography.titleLarge)
                        .foregroundStyle(DS.textSecondary)
                    Text("Identities are reusable credentials (username + SSH key)\nshared across hosts and groups.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(hostStore.identities) { identity in
                        IdentityRow(
                            identity: identity,
                            store: hostStore,
                            onEdit: { identityToEdit = identity },
                            onDelete: { identityToDelete = identity }
                        )
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()

            // Footer
            HStack {
                Button {
                    showNewIdentity = true
                } label: {
                    Label("New Identity", systemImage: "plus")
                }
                Spacer()
            }
            .padding(DS.Space.lg)
        }
    }

    // MARK: - Pane chips

    private func paneChip(_ target: HostsPane, title: String, icon: String) -> some View {
        let isActive = pane == target
        return Button {
            pane = target
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(DS.Typography.detailStrong)
            }
            .foregroundStyle(isActive ? DS.accent : DS.textSecondary)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.pill)
                    .fill(isActive ? DS.accentSoft : DS.hover)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Identity row

struct IdentityRow: View {
    let identity: Identity
    var store: HostStore
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var usedByCount: Int {
        store.hosts.filter { $0.identityID == identity.id }.count +
        store.groups.filter { $0.identityID == identity.id }.count
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "key.fill")
                .font(.system(size: 12))
                .foregroundStyle(DS.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(identity.label)
                    .font(DS.Typography.bodyStrong)
                HStack(spacing: DS.Space.xs) {
                    Text(identity.username)
                        .font(DS.Typography.monoCaption)
                        .foregroundStyle(DS.textSecondary)
                    if let key = identity.sshKeyPath {
                        Text(key)
                            .font(DS.Typography.monoCaption)
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if usedByCount > 0 {
                Text("\(usedByCount) reference\(usedByCount == 1 ? "" : "s")")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundStyle(DS.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Edit")
            .accessibilityLabel("Edit")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(DS.danger)
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .accessibilityLabel("Delete")
        }
        .padding(.vertical, DS.Space.xs)
    }
}

// MARK: - Group tree row (recursive)

/// Identifiable request for creating a subgroup via context menu.
struct GroupSubgroupRequest: Identifiable {
    let id = UUID()
    let parentID: UUID
}

struct GroupRow: View {
    let group: HostGroup
    var hostStore: HostStore
    let indent: Int
    @Binding var editingGroupID: UUID?
    /// Request a new subgroup under this group.
    let onNewSubgroup: (UUID) -> Void
    /// Open the group settings sheet.
    let onEdit: (HostGroup) -> Void

    /// Persisted collapsed groups (WI-2026-08-08-061): JSON-encoded set of
    /// group IDs in UserDefaults; expansion defaults to open. Each row owns
    /// its own entry — recursive rows must not share a binding.
    @AppStorage("synapty.collapsedGroupIDs") private var collapsedData = Data()

    @State private var editText = ""
    /// Drop-target highlight while host blocks are dragged over this row
    /// (WI-2026-08-08-057).
    @State private var isDropTargeted = false
    /// Drop-target highlight while a GROUP is dragged over this row
    /// (reparenting, WI-2026-08-08-062) — distinct from host drops.
    @State private var isGroupDropTargeted = false

    private var collapsedGroupIDs: Set<UUID> {
        (try? JSONDecoder().decode(Set<UUID>.self, from: collapsedData)) ?? []
    }

    /// Expansion binding — persisted, defaults open (WI-2026-08-08-061).
    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: { !collapsedGroupIDs.contains(group.id) },
            set: { expanded in
                var set = collapsedGroupIDs
                if expanded {
                    set.remove(group.id)
                } else {
                    set.insert(group.id)
                }
                collapsedData = (try? JSONEncoder().encode(set)) ?? Data()
            }
        )
    }

    private var children: [HostGroup] {
        hostStore.childGroups(of: group.id)
    }

    private var isEditing: Bool { editingGroupID == group.id }

    var body: some View {
        DisclosureGroup(isExpanded: isExpandedBinding) {
            if !children.isEmpty {
                ForEach(children) { child in
                    GroupRow(
                        group: child,
                        hostStore: hostStore,
                        indent: indent + 1,
                        editingGroupID: $editingGroupID,
                        onNewSubgroup: onNewSubgroup,
                        onEdit: onEdit
                    )
                }
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.accent)
                if isEditing {
                    TextField("Group name", text: $editText)
                        .textFieldStyle(.plain)
                        .font(DS.Typography.detailStrong)
                        .onSubmit {
                            hostStore.renameGroup(group, to: editText)
                            editingGroupID = nil
                        }
                        .onExitCommand { editingGroupID = nil }
                } else {
                    Text(group.label)
                        .font(DS.Typography.detailStrong)
                        .lineLimit(1)
                    if !hostStore.hosts(inGroup: group.id).isEmpty {
                        Text("\(hostStore.hosts(inGroup: group.id).count)")
                            .font(DS.Typography.monoCaption)
                            .foregroundStyle(DS.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(isDropTargeted ? DS.accentSoft : (isGroupDropTargeted ? DS.accent.opacity(0.18) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .stroke(isGroupDropTargeted ? DS.accent : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            // Drop target for host blocks (move hosts into this group).
            .dropDestination(for: HostDragPayload.self) { items, _ in
                let ids = items.flatMap(\.hostIDs)
                guard !ids.isEmpty else { return false }
                hostStore.moveHosts(ids, toGroup: group.id)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            // Drop target for group rows (reparent under this group,
            // cycle-safe; WI-2026-08-08-062).
            .dropDestination(for: GroupDragPayload.self) { items, _ in
                let ids = items.flatMap(\.groupIDs)
                guard let first = ids.first, ids.count == 1 else { return false }
                return hostStore.moveGroup(first, toParent: group.id)
            } isTargeted: { targeted in
                isGroupDropTargeted = targeted
            }
            // Group rows are draggable themselves (WI-2026-08-08-062).
            .draggable(GroupDragPayload(groupIDs: [group.id]))
        }
        .contextMenu {
            Button("Rename") {
                editText = group.label
                editingGroupID = group.id
            }
            Button("New Subgroup") { onNewSubgroup(group.id) }
            Divider()
            Button("Group Settings\u{2026}") { onEdit(group) }
        }
        // Also seed when the edit target changes (menu path vs keyboard).
        .onChange(of: editingGroupID) { _, newID in
            if newID == group.id && editText.isEmpty {
                editText = group.label
            }
        }
    }
}

// MARK: - New group sheet

struct NewGroupSheet: View {
    var hostStore: HostStore
    var parentID: UUID?
    @Binding var isPresented: Bool

    @State private var label = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            DSSheetHeader(title: "New Group", icon: "folder.badge.plus", isPresented: $isPresented)
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                TextField("Group name", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typography.body)
                    .focused($focused)
                if let parentID, hostStore.groups.contains(where: { $0.id == parentID }) {
                    Text("Inside: \(hostStore.groupPath(for: parentID).joined(separator: " / "))")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") {
                        let group = HostGroup(
                            label: label.trimmingCharacters(in: .whitespaces),
                            parentID: parentID
                        )
                        hostStore.addGroup(group)
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accent)
                }
            }
            .padding(DS.Space.xl)
        }
        .frame(width: 340)
        .background(DS.background)
        .onAppear { focused = true }
    }
}

// MARK: - Group edit sheet (inherited settings)

/// Edit a group's inherited defaults (Termius-style): hosts and subgroups
/// inherit these unless they override them explicitly.
struct GroupEditSheet: View {
    var hostStore: HostStore
    @Binding var isPresented: Bool
    var editingGroup: HostGroup

    @State private var label = ""
    @State private var identityID: UUID?
    @State private var portText = ""
    @State private var username = ""
    @State private var proxyJump = ""
    /// Parent group picker (WI-2026-08-08-060): nil = top level.
    @State private var parentID: UUID?
    /// Inherited forwardings (WI-2026-08-08-060): nil = inherit from parent;
    /// when override is on, `forwardings` replaces the chain.
    @State private var inheritForwardings = true
    @State private var forwardings: [PortForward] = []

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Reparent candidates: every group except this one and its descendants
    /// (cycle-safe, WI-2026-08-08-060).
    private var parentCandidates: [HostGroup] {
        hostStore.groups.filter { hostStore.canReparent(editingGroup, to: $0.id) }
            .sorted { $0.label < $1.label }
    }

    var body: some View {
        VStack(spacing: 0) {
            DSSheetHeader(title: "Group Settings", icon: "folder", isPresented: $isPresented)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        DSSectionLabel(text: "Group")
                        TextField("Label", text: $label)
                            .textFieldStyle(.roundedBorder)
                            .font(DS.Typography.body)

                        // Parent group (WI-2026-08-08-060)
                        Picker("Parent Group", selection: $parentID) {
                            Text("Top level").tag(Optional<UUID>.none)
                            ForEach(parentCandidates) { group in
                                Text(hostStore.groupPath(for: group.id).joined(separator: " / "))
                                    .tag(Optional(group.id))
                            }
                        }
                        .pickerStyle(.menu)
                        Text("Hosts and subgroups inherit defaults from the parent chain.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                    }

                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        DSSectionLabel(text: "Inherited Defaults")
                        Text("Hosts and subgroups inherit these unless they set their own values.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)

                        Picker("Identity", selection: $identityID) {
                            Text("Inherit from parent").tag(Optional<UUID>.none)
                            ForEach(hostStore.identities) { identity in
                                Text(identity.label).tag(Optional(identity.id))
                            }
                        }
                        .pickerStyle(.menu)

                        TextField("Username (inherited)", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .font(DS.Typography.body)

                        TextField("Port (inherited)", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .font(DS.Typography.body)

                        TextField("Jump host (inherited, user@host:port)", text: $proxyJump)
                            .textFieldStyle(.roundedBorder)
                            .font(DS.Typography.body)
                    }

                    // Inherited port forwardings (WI-2026-08-08-060)
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        DSSectionLabel(text: "Port Forwarding")
                        Toggle("Inherit rules from parent group", isOn: $inheritForwardings)
                            .toggleStyle(.switch)
                            .font(DS.Typography.detail)
                        if !inheritForwardings {
                            ForwardingsEditor(forwardings: $forwardings)
                        }
                    }
                }
                .padding(DS.Space.xl)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .buttonStyle(.borderedProminent)
                .tint(DS.accent)
            }
            .padding(DS.Space.lg)
        }
        .frame(width: 420)
        .background(DS.background)
        .onAppear {
            label = editingGroup.label
            identityID = editingGroup.identityID
            username = editingGroup.username ?? ""
            proxyJump = editingGroup.proxyJump ?? ""
            parentID = editingGroup.parentID
            inheritForwardings = editingGroup.forwardings == nil
            forwardings = editingGroup.forwardings ?? []
            if let port = editingGroup.port {
                portText = "\(port)"
            }
        }
    }

    private func save() {
        var updated = editingGroup
        updated.label = label.trimmingCharacters(in: .whitespaces)
        updated.identityID = identityID
        updated.username = username.trimmingCharacters(in: .whitespaces).isEmpty ? nil : username.trimmingCharacters(in: .whitespaces)
        updated.port = Int(portText)
        updated.proxyJump = proxyJump.trimmingCharacters(in: .whitespaces).isEmpty ? nil : proxyJump.trimmingCharacters(in: .whitespaces)
        updated.forwardings = inheritForwardings ? nil : forwardings
        updated.parentID = parentID
        hostStore.updateGroup(updated)
        isPresented = false
    }
}
