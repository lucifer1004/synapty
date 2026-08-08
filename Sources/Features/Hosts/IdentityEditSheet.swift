import SwiftUI

/// Sheet for adding or editing a reusable Identity (credentials).
struct IdentityEditSheet: View {
    var hostStore: HostStore
    @Binding var isPresented: Bool
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
            DSSheetHeader(
                title: isEditing ? "Edit Identity" : "New Identity",
                icon: "key",
                isPresented: $isPresented
            )

            Divider()

            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    DSSectionLabel(text: "Identity")
                    TextField("Label", text: $label)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.Typography.body)
                        .focused($focused)
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.Typography.body)
                }

                VStack(alignment: .leading, spacing: DS.Space.md) {
                    DSSectionLabel(text: "SSH Key")
                    HStack {
                        TextField("SSH Key Path (optional)", text: $sshKeyPath)
                            .textFieldStyle(.roundedBorder)
                            .font(DS.Typography.detail)
                        Button("Browse\u{2026}") {
                            showFilePicker = true
                        }
                    }
                    Text("Leave empty to use the default SSH agent / password auth.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .padding(DS.Space.xl)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Create") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .buttonStyle(.borderedProminent)
                .tint(DS.accent)
            }
            .padding(DS.Space.lg)
        }
        .frame(width: 400)
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
        isPresented = false
    }
}
