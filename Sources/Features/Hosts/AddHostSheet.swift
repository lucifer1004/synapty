import SwiftUI

/// Sheet for adding or editing a host entry — Termius-style: group
/// membership, tags, and reusable credentials (Identity) or inline fields.
struct AddHostSheet: View {
    var hostStore: HostStore
    var tunnelManager: TunnelManager
    @Binding var isPresented: Bool

    /// If set, we're editing an existing host; otherwise adding a new one.
    var editingHost: HostEntry?
    /// Preselected group when creating from within a group.
    var presetGroupID: UUID?

    @State private var label = ""
    @State private var address = ""
    @State private var portText = "22"
    @State private var username = ""
    @State private var sshKeyPath = ""
    @State private var groupID: UUID?
    @State private var identityID: UUID?
    @State private var tagsText = ""
    @State private var proxyJump = ""
    @State private var forwardings: [PortForward] = []
    @State private var showFilePicker = false

    private var isEditing: Bool { editingHost != nil }
    private var port: Int { Int(portText) ?? 22 }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !address.trimmingCharacters(in: .whitespaces).isEmpty &&
        (!username.trimmingCharacters(in: .whitespaces).isEmpty || identityID != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            DSSheetHeader(
                title: isEditing ? "Edit Host" : "Add Host",
                icon: isEditing ? "pencil.circle" : "plus.circle",
                isPresented: $isPresented
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    // Connection
                    formSection("Connection") {
                        TextField("Label", text: $label)
                        TextField("Address", text: $address)
                        TextField("Port", text: $portText)
                        TextField("Username (optional)", text: $username)
                        // Jump host (ProxyJump): e.g. "user@bastion:22"
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.textTertiary)
                            TextField("Jump host (optional, user@host:port)", text: $proxyJump)
                        }
                    }

                    // Port forwardings
                    formSection("Port Forwarding") {
                        if forwardings.isEmpty {
                            Text("No forwarding rules. Add local (-L) or remote (-R) forwards, applied when the tunnel is established.")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.textTertiary)
                        }
                        ForEach(forwardings.indices, id: \.self) { idx in
                            HStack(spacing: DS.Space.sm) {
                                Picker("", selection: $forwardings[idx].kind) {
                                    Text("Local (-L)").tag(PortForward.Kind.local)
                                    Text("Remote (-R)").tag(PortForward.Kind.remote)
                                }
                                .labelsHidden()
                                .frame(width: 110)
                                TextField("Listen", text: Binding(
                                    get: { "\(forwardings[idx].listenPort)" },
                                    set: { forwardings[idx].listenPort = Int($0) ?? 0 }
                                ))
                                .frame(width: 55)
                                Text(":")
                                TextField("Target", text: $forwardings[idx].targetHost)
                                Text(":")
                                TextField("Port", text: Binding(
                                    get: { "\(forwardings[idx].targetPort)" },
                                    set: { forwardings[idx].targetPort = Int($0) ?? 0 }
                                ))
                                .frame(width: 55)
                                Button {
                                    forwardings.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(DS.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(DS.Typography.monoCaption)
                        }
                        Button {
                            forwardings.append(PortForward())
                        } label: {
                            Label("Add Forward", systemImage: "plus")
                                .font(DS.Typography.detailStrong)
                        }
                    }

                    // Group
                    formSection("Group") {
                        Picker("Group", selection: $groupID) {
                            Text("Ungrouped").tag(Optional<UUID>.none)
                            ForEach(hostStore.groups) { group in
                                Text(hostStore.groupPath(for: group.id).joined(separator: " / "))
                                    .tag(Optional(group.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Credentials
                    formSection("Credentials") {
                        Picker("Identity", selection: $identityID) {
                            Text("Inline (below)").tag(Optional<UUID>.none)
                            ForEach(hostStore.identities) { identity in
                                Text(identity.label).tag(Optional(identity.id))
                            }
                        }
                        .pickerStyle(.menu)

                        if identityID == nil {
                            HStack {
                                TextField("SSH Key Path (optional)", text: $sshKeyPath)
                                Button("Browse\u{2026}") {
                                    showFilePicker = true
                                }
                            }
                        } else {
                            // Show the identity's resolved key for reference.
                            if let id = identityID,
                               let identity = hostStore.identities.first(where: { $0.id == id }),
                               let key = identity.sshKeyPath {
                                Text("Key: \(key)")
                                    .font(DS.Typography.monoCaption)
                                    .foregroundStyle(DS.textSecondary)
                            }
                        }
                    }

                    // Tags
                    formSection("Tags") {
                        TextField("prod, gpu, ubuntu…", text: $tagsText)
                            .font(DS.Typography.detail)
                        if !hostStore.allTags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: DS.Space.xs) {
                                    ForEach(hostStore.allTags, id: \.self) { tag in
                                        let selectedTags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                        let isSelected = selectedTags.contains(tag)
                                        Button {
                                            if isSelected {
                                                tagsText = selectedTags.filter { $0 != tag }.joined(separator: ", ")
                                            } else {
                                                tagsText = tagsText.isEmpty ? tag : "\(tagsText), \(tag)"
                                            }
                                        } label: {
                                            Text(tag)
                                                .font(DS.Typography.captionStrong)
                                                .foregroundStyle(isSelected ? DS.accent : DS.textSecondary)
                                                .padding(.horizontal, DS.Space.sm)
                                                .padding(.vertical, 2)
                                                .background(isSelected ? DS.accentSoft : DS.hover, in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(DS.Space.xl)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Add") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .buttonStyle(.borderedProminent)
                .tint(DS.accent)
            }
            .padding(DS.Space.lg)
        }
        .frame(width: 440, height: 560)
        .background(DS.background)
        .onAppear {
            if let host = editingHost {
                label = host.label
                address = host.address
                portText = "\(host.port)"
                username = host.username
                sshKeyPath = host.sshKeyPath ?? ""
                groupID = host.groupID
                identityID = host.identityID
                tagsText = host.tags.joined(separator: ", ")
                proxyJump = host.proxyJump ?? ""
                forwardings = host.forwardings
            } else if let presetGroupID {
                groupID = presetGroupID
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                sshKeyPath = url.path
            }
        }
    }

    // MARK: - Helpers

    private func formSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionLabel(text: title)
            content()
                .font(DS.Typography.body)
        }
    }

    private var parsedTags: [String] {
        tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        let trimmedProxy = proxyJump.trimmingCharacters(in: .whitespaces)
        let validForwardings = forwardings.filter { $0.listenPort > 0 && $0.targetPort > 0 }

        if var existing = editingHost {
            existing.label = trimmedLabel
            existing.address = trimmedAddress
            existing.port = port
            existing.username = trimmedUsername
            existing.sshKeyPath = sshKeyPath.isEmpty ? nil : sshKeyPath
            existing.groupID = groupID
            existing.identityID = identityID
            existing.tags = parsedTags
            existing.proxyJump = trimmedProxy.isEmpty ? nil : trimmedProxy
            existing.forwardings = validForwardings
            hostStore.updateHost(existing)
        } else {
            let entry = HostEntry(
                label: trimmedLabel,
                address: trimmedAddress,
                port: port,
                username: trimmedUsername,
                sshKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath,
                groupID: groupID,
                tags: parsedTags,
                identityID: identityID,
                proxyJump: trimmedProxy.isEmpty ? nil : trimmedProxy,
                forwardings: validForwardings
            )
            hostStore.addHost(entry)
        }
        isPresented = false
    }
}
