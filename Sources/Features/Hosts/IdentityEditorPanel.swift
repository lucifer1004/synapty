import SwiftUI

/// Right-side inspector panel for adding or editing a reusable Identity
/// (credentials). Same surface as the host/group editors — every entity
/// on the Hosts page creates and edits in the inspector
/// (WI-2026-08-08-090; this was previously a sheet, the odd one out).
struct IdentityEditorPanel: View {
    var hostStore: HostStore
    var onClose: () -> Void = {}
    /// If set, we're editing an existing identity; otherwise creating one.
    var editingIdentity: Identity?

    @State private var label = ""
    @State private var username = ""
    @State private var sshKeyPath = ""
    @State private var showFilePicker = false
    @FocusState private var focused: Bool

    private var isEditing: Bool { editingIdentity != nil }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Panel header (inspector form, WI-2026-08-08-069).
            HStack(spacing: DS.Space.sm) {
                Image(systemName: isEditing ? "key" : "key.fill")
                    .font(DS.Typography.titleLarge)
                    .foregroundStyle(DS.accent)
                    .frame(width: 18)
                Text(isEditing ? "Edit Identity" : "New Identity")
                    .font(DS.Typography.titleLarge)
                Spacer()
                DSIconButton(icon: "xmark", help: "Close", size: 22) { onClose() }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)

            DSHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    DSSectionBlock(title: "Identity") {
                        DSFormField("Label") {
                            TextField("e.g. Work key", text: $label)
                                .dsField()
                                .font(DS.Typography.body)
                                .focused($focused)
                        }
                        DSFormField("Username") {
                            TextField("e.g. ubuntu", text: $username)
                                .dsField()
                                .font(DS.Typography.body)
                        }
                    }

                    DSSectionBlock(
                        title: "SSH Key",
                        help: "Leave empty to use the default SSH agent / password auth."
                    ) {
                        DSFormField("Key path") {
                            HStack {
                                TextField("Optional", text: $sshKeyPath)
                                    .dsField()
                                    .font(DS.Typography.detail)
                                Button("Browse\u{2026}") {
                                    showFilePicker = true
                                }
                            }
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
        // (WI-2026-08-08-090; fixed widths clip at large UI scales).
        .frame(minWidth: 320, maxWidth: .infinity)
        .background(DS.background)
        .onAppear {
            if let identity = editingIdentity {
                label = identity.label
                username = identity.username
                sshKeyPath = identity.sshKeyPath ?? ""
            }
            focused = true
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

    private func save() {
        if var existing = editingIdentity {
            existing.label = label.trimmingCharacters(in: .whitespaces)
            existing.username = username.trimmingCharacters(in: .whitespaces)
            existing.sshKeyPath = sshKeyPath.isEmpty ? nil : sshKeyPath
            hostStore.updateIdentity(existing)
        } else {
            let identity = Identity(
                label: label.trimmingCharacters(in: .whitespaces),
                username: username.trimmingCharacters(in: .whitespaces),
                sshKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath
            )
            hostStore.addIdentity(identity)
        }
        onClose()
    }
}
