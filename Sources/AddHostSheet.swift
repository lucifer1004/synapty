import SwiftUI

struct AddHostSheet: View {
    @ObservedObject var hostStore: HostStore
    @Binding var isPresented: Bool

    @State private var label = ""
    @State private var address = ""
    @State private var portText = "22"
    @State private var username = ""
    @State private var sshKeyPath = ""
    @State private var showFilePicker = false

    private var port: Int { Int(portText) ?? 22 }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !address.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Label", text: $label)
                TextField("Address", text: $address)
                TextField("Port", text: $portText)
                TextField("Username", text: $username)
                HStack {
                    TextField("SSH Key Path (optional)", text: $sshKeyPath)
                    Button("Browse…") {
                        showFilePicker = true
                    }
                }
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    let entry = HostEntry(
                        label: label.trimmingCharacters(in: .whitespaces),
                        address: address.trimmingCharacters(in: .whitespaces),
                        port: port,
                        username: username.trimmingCharacters(in: .whitespaces),
                        sshKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath
                    )
                    hostStore.addHost(entry)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 400)
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
