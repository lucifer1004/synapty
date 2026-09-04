import SwiftUI

/// Right-side inspector panel for adding or editing a host entry —
/// Termius-style: group membership, tags, and reusable credentials
/// (Identity) or inline fields (WI-2026-08-08-069).
struct HostEditorPanel: View {
    var hostStore: HostStore
    var tunnelManager: TunnelManager
    /// Called after Save (and by the close button) to dismiss the panel.
    var onClose: () -> Void = {}

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

    /// THE CHOICE IS THE HUMAN'S ON EVERY HOST. Durability rides the
    /// binary this project deploys ([[ADR-0012]]), so there is no
    /// capability to report and nothing for a machine to lack.
    private var durabilityNote: String {
        durableSessions
            ? "Sessions keep running on the host after a disconnect, and reopening returns "
                + "to the one you left — where it was, and what was on the screen. "
                + "Closing a session still ends it."
            : "Sessions run directly, exactly as an ordinary SSH client would. Nothing "
                + "survives a disconnect, and the working directory a dropped file lands "
                + "in cannot be read back."
    }

    /// OS identity ("" = auto-detect on connect, WI-2026-08-09-002).
    @State private var osHint = ""
    @State private var durableSessions = true

    private var isEditing: Bool { editingHost != nil }
    private var port: Int { Int(portText) ?? 22 }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !address.trimmingCharacters(in: .whitespaces).isEmpty &&
        (!username.trimmingCharacters(in: .whitespaces).isEmpty || identityID != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Panel header (inspector form, WI-2026-08-08-069).
            DSPanelHeader(
                title: isEditing ? "Edit Host" : "Add Host",
                icon: isEditing ? "pencil.circle" : "plus.circle"
            ) { onClose() }

            DSHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    // Connection — labeled fields (WI-2026-08-08-090):
                    // placeholder-only fields lose their meaning once
                    // filled.
                    DSSectionBlock(title: "Connection") {
                        DSFormField("Label") {
                            TextField("e.g. prod-gpu-1", text: $label)
                                .dsField()
                        }
                        HStack(alignment: .top, spacing: DS.Space.md) {
                            DSFormField("Address") {
                                TextField("host or IP", text: $address)
                                    .dsField()
                            }
                            DSFormField("Port") {
                                TextField("22", text: $portText)
                                    .dsField()
                                    .frame(width: DS.scaled(70))
                            }
                        }
                        DSFormField("Username") {
                            TextField("Optional when an Identity is set", text: $username)
                                .dsField()
                        }
                        // Jump host (ProxyJump): e.g. "user@bastion:22"
                        DSFormField("Jump host") {
                            TextField("user@host:port (optional)", text: $proxyJump)
                                .dsField()
                        }
                        // OS identity (WI-2026-08-09-002): Auto lets a
                        // successful connect fill it; a manual pick is
                        // never overwritten by detection.
                        DSFormField("Operating system") {
                            DSDropdown(selection: $osHint, options: osOptions)
                        }
                    }

                    // TMUX IS A DEPENDENCY WITH A KNOWN FAILURE MODE, so
                    // there is a way out of it — it sits between the human
                    // and their shell, and the only remedy used to be
                    // uninstalling it on the host.
                    DSSectionBlock(title: "Sessions") {
                        Toggle("Keep workspaces alive after a disconnect",
                               isOn: $durableSessions)
                            .toggleStyle(.switch)
                            .font(DS.Typography.detail)

                        Text(durabilityNote)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Port forwardings (shared editor, WI-2026-08-08-060)
                    DSSectionBlock(title: "Port Forwarding") {
                        ForwardingsEditor(forwardings: $forwardings)
                    }

                    DSSectionBlock(title: "Group") {
                        DSDropdown(
                            selection: $groupID,
                            options: [(Optional<UUID>.none, "Ungrouped")]
                                + hostStore.groups
                                    .sorted { $0.label < $1.label }
                                    .map { (Optional($0.id), $0.label) }
                        )
                    }

                    DSSectionBlock(title: "Credentials") {
                        DSFormField("Identity") {
                            // "None" wording matches the group editor
                            // (WI-2026-08-08-090 consistency pass).
                            DSDropdown(
                                selection: $identityID,
                                options: [(Optional<UUID>.none, "None (use fields below)")]
                                    + hostStore.identities.map { (Optional($0.id), $0.label) }
                            )
                        }

                        if identityID == nil {
                            DSFormField("SSH key path") {
                                HStack {
                                    TextField("Optional", text: $sshKeyPath)
                                        .dsField()
                                    Button("Browse\u{2026}") {
                                        showFilePicker = true
                                    }
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

                    DSSectionBlock(title: "Tags") {
                        TextField("prod, gpu, ubuntu…", text: $tagsText)
                            .dsField()
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
                                            DSTag(text: tag, style: isSelected ? .accent : .neutral)
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

            DSSheetFooter(confirm: isEditing ? "Save" : "Add Host",
                          canConfirm: canSave,
                          onCancel: onClose,
                          onConfirm: save)
        }
        // Flexible — the inspector column decides the width
        // (WI-2026-08-08-090; fixed 400 clipped at large UI scales).
        .frame(minWidth: 320, maxWidth: .infinity)
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
                osHint = host.osHint ?? ""
                durableSessions = host.durableSessions
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

    /// OS dropdown options — a detected distro id (e.g. "ubuntu") that is
    /// not in the fixed list appears as its own entry so it never renders
    /// as a placeholder (WI-2026-08-09-002).
    private var osOptions: [(String, String)] {
        var options: [(String, String)] = [
            ("", "Auto (detect on connect)"),
            ("macos", "macOS"),
            ("linux", "Linux"),
            ("windows", "Windows"),
        ]
        if !osHint.isEmpty && !options.contains(where: { $0.0 == osHint }) {
            options.insert((osHint, "Detected: \(osHint.capitalized)"), at: 1)
        }
        return options
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
            existing.osHint = osHint.isEmpty ? nil : osHint
            existing.durableSessions = durableSessions
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
                forwardings: validForwardings,
                osHint: osHint.isEmpty ? nil : osHint,
                durableSessions: durableSessions
            )
            hostStore.addHost(entry)
        }
        onClose()
    }
}
