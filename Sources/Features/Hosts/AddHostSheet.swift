import SwiftUI

/// Sheet for adding or editing a host entry.
struct AddHostSheet: View {
    @ObservedObject var hostStore: HostStore
    @Binding var isPresented: Bool

    /// If set, we're editing an existing host; otherwise adding a new one.
    var editingHost: HostEntry?

    @State private var label = ""
    @State private var address = ""
    @State private var portText = "22"
    @State private var username = ""
    @State private var sshKeyPath = ""
    @State private var showFilePicker = false

    private var isEditing: Bool { editingHost != nil }
    private var port: Int { Int(portText) ?? 22 }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !address.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            DSSheetHeader(
                title: isEditing ? "Edit Host" : "Add Host",
                icon: isEditing ? "pencil.circle" : "plus.circle",
                isPresented: $isPresented
            )

            Divider()

            Form {
                TextField("Label", text: $label)
                TextField("Address", text: $address)
                TextField("Port", text: $portText)
                TextField("Username", text: $username)
                HStack {
                    TextField("SSH Key Path (optional)", text: $sshKeyPath)
                    Button("Browse\u{2026}") {
                        showFilePicker = true
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.vertical, DS.Space.sm)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Add") {
                    if var existing = editingHost {
                        existing.label = label.trimmingCharacters(in: .whitespaces)
                        existing.address = address.trimmingCharacters(in: .whitespaces)
                        existing.port = port
                        existing.username = username.trimmingCharacters(in: .whitespaces)
                        existing.sshKeyPath = sshKeyPath.isEmpty ? nil : sshKeyPath
                        hostStore.updateHost(existing)
                    } else {
                        let entry = HostEntry(
                            label: label.trimmingCharacters(in: .whitespaces),
                            address: address.trimmingCharacters(in: .whitespaces),
                            port: port,
                            username: username.trimmingCharacters(in: .whitespaces),
                            sshKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath
                        )
                        hostStore.addHost(entry)
                    }
                    isPresented = false
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
            if let host = editingHost {
                label = host.label
                address = host.address
                portText = "\(host.port)"
                username = host.username
                sshKeyPath = host.sshKeyPath ?? ""
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
}
