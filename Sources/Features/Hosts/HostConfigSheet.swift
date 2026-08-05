import SwiftUI

/// Host management page — Termius-style host management:
/// nested groups in a sidebar, searchable host list with tags, and full
/// CRUD for hosts, groups and reusable identities.
struct HostConfigSheet: View {
    @ObservedObject var hostStore: HostStore
    @ObservedObject var tunnelManager: TunnelManager

    /// Currently selected group (nil = All).
    @State private var selectedGroupID: UUID?
    /// Host search text.
    @State private var searchText = ""
    @State private var showAddHost = false
    @State private var showNewGroup = false
    @State private var subgroupRequest: GroupSubgroupRequest?
    @State private var hostToEdit: HostEntry?
    @State private var hostToDelete: HostEntry?
    @State private var groupToDelete: HostGroup?
    @State private var editingGroupID: UUID?

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

            HStack(spacing: 0) {
                // Left: group tree
                groupSidebar
                    .frame(width: 200)

                Divider()

                // Right: host list
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
                Spacer()
                if let group = selectedGroup {
                    Button(role: .destructive) {
                        groupToDelete = group
                    } label: {
                        Label("Delete Group", systemImage: "trash")
                    }
                    .disabled(hostStore.childGroups(of: group.id).isEmpty && hostStore.hosts(inGroup: group.id).isEmpty)
                    .help("Only empty groups can be deleted")
                }
            }
            .padding(DS.Space.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        .sheet(isPresented: $showAddHost) {
            AddHostSheet(
                hostStore: hostStore,
                tunnelManager: tunnelManager,
                isPresented: $showAddHost,
                presetGroupID: selectedGroupID
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
            NewGroupSheet(hostStore: hostStore, parentID: selectedGroupID, isPresented: $showNewGroup)
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
        .alert("Delete Group", isPresented: Binding(
            get: { groupToDelete != nil },
            set: { if !$0 { groupToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { groupToDelete = nil }
            Button("Delete", role: .destructive) {
                if let group = groupToDelete {
                    hostStore.removeGroup(group)
                    if selectedGroupID == group.id { selectedGroupID = nil }
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
                Text("Are you sure you want to delete \"\(host.label)\"?")
            }
        }
    }

    // MARK: - Group sidebar

    private var selectedGroup: HostGroup? {
        guard let selectedGroupID else { return nil }
        return hostStore.groups.first(where: { $0.id == selectedGroupID })
    }

    private var groupSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                DSSectionLabel(text: "Groups")
                Spacer()
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)

            List(selection: $selectedGroupID) {
                // "All hosts" pseudo-group
                Label("All Hosts", systemImage: "square.grid.2x2")
                    .font(DS.Typography.detailStrong)
                    .tag(Optional<UUID>.none)

                // Ungrouped pseudo-group
                if !hostStore.hosts(inGroup: nil).isEmpty {
                    Label("Ungrouped", systemImage: "tray")
                        .font(DS.Typography.detail)
                        .foregroundStyle(DS.textSecondary)
                        .tag(UUID()) // placeholder tag — handled via selectedGroupID == nil check below
                }

                // Group tree
                ForEach(hostStore.groups.filter { $0.parentID == nil }.sorted { $0.label < $1.label }) { group in
                    GroupRow(
                        group: group,
                        hostStore: hostStore,
                        indent: 0,
                        editingGroupID: $editingGroupID,
                        onNewSubgroup: { parentID in subgroupRequest = GroupSubgroupRequest(parentID: parentID) }
                    )
                    .tag(Optional(group.id))
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(DS.sidebar)
    }

    // MARK: - Host list

    private var visibleHosts: [HostEntry] {
        hostStore.searchHosts(searchText, in: selectedGroupID)
    }

    private var hostListPane: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.textTertiary)
                TextField("Search hosts, addresses, tags", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.detail)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)

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
                List {
                    ForEach(visibleHosts) { host in
                        HostConfigRow(
                            host: host,
                            store: hostStore,
                            tunnelStatus: tunnelManager.status(for: host),
                            onEdit: { hostToEdit = host },
                            onDelete: { hostToDelete = host },
                            onReconnect: { tunnelManager.reconnectTunnel(for: host) },
                            onDisconnect: { tunnelManager.disconnectTunnel(for: host) }
                        )
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
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
    @ObservedObject var hostStore: HostStore
    let indent: Int
    @Binding var editingGroupID: UUID?
    /// Request a new subgroup under this group.
    let onNewSubgroup: (UUID) -> Void

    @State private var isExpanded = true
    @State private var editText = ""

    private var children: [HostGroup] {
        hostStore.childGroups(of: group.id)
    }

    private var isEditing: Bool { editingGroupID == group.id }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if !children.isEmpty {
                ForEach(children) { child in
                    GroupRow(
                        group: child,
                        hostStore: hostStore,
                        indent: indent + 1,
                        editingGroupID: $editingGroupID,
                        onNewSubgroup: onNewSubgroup
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
        }
        .contextMenu {
            Button("Rename") { editingGroupID = group.id }
            Button("New Subgroup") { onNewSubgroup(group.id) }
        }
    }
}

// MARK: - New group sheet

struct NewGroupSheet: View {
    @ObservedObject var hostStore: HostStore
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
                if let parentID, let parent = hostStore.groups.first(where: { $0.id == parentID }) {
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

// MARK: - Host row

struct HostConfigRow: View {
    let host: HostEntry
    @ObservedObject var store: HostStore
    let tunnelStatus: TunnelManager.TunnelStatus
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReconnect: () -> Void
    let onDisconnect: () -> Void

    private var effectiveUsername: String { store.effectiveUsername(for: host) }
    private var effectivePort: Int { store.effectivePort(for: host) }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            // Status dot
            DSStatusDot(
                color: Color(tunnelStatus.color),
                size: 8,
                pulsing: tunnelStatus == .connecting || tunnelStatus == .reconnecting
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.sm) {
                    Text(host.label)
                        .font(DS.Typography.bodyStrong)
                        .lineLimit(1)
                    // Tags
                    ForEach(host.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(DS.Typography.captionStrong)
                            .foregroundStyle(DS.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(DS.accentSoft, in: Capsule())
                    }
                }
                HStack(spacing: DS.Space.xs) {
                    Text("\(effectiveUsername)@\(host.address):\(effectivePort)")
                        .font(DS.Typography.monoCaption)
                        .foregroundStyle(DS.textSecondary)
                    // Group path (if grouped)
                    if let gid = host.groupID, !store.groupPath(for: gid).isEmpty {
                        Text(store.groupPath(for: gid).joined(separator: " / "))
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                    Text("· \(tunnelStatus.label)")
                        .font(DS.Typography.caption)
                        .foregroundStyle(Color(tunnelStatus.color))
                }
            }

            Spacer()

            // Tunnel actions
            if tunnelStatus == .connected {
                Button {
                    onDisconnect()
                } label: {
                    Image(systemName: "bolt.slash")
                        .foregroundStyle(DS.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Disconnect tunnel")
            } else if tunnelStatus == .disconnected || tunnelStatus != .connecting {
                Button {
                    onReconnect()
                } label: {
                    Image(systemName: "bolt")
                        .foregroundStyle(DS.accent)
                }
                .buttonStyle(.borderless)
                .help("Reconnect tunnel")
            }

            Button { onEdit() } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(DS.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button { onDelete() } label: {
                Image(systemName: "trash")
                    .foregroundStyle(DS.danger)
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, DS.Space.xs)
    }
}
