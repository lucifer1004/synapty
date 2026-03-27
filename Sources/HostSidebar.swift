import SwiftUI

struct HostSidebar: View {
    @ObservedObject var hostStore: HostStore
    @State private var showAddHost = false
    @State private var hostToDelete: HostEntry?
    /// Called when the user taps a remote host row to initiate a connection.
    var onHostConnect: ((HostEntry) -> Void)?
    /// Called when the user taps "New Terminal" to open a local shell pane.
    var onNewLocalPane: (() -> Void)?

    var body: some View {
        List {
            Section("Local") {
                Label("New Terminal", systemImage: "terminal")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onNewLocalPane?()
                    }
            }

            Section("Remote Hosts") {
                ForEach(hostStore.hosts) { host in
                    HostRow(host: host)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onHostConnect?(host)
                        }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        hostStore.removeHost(hostStore.hosts[index])
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    showAddHost = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Remote Host")
            }
        }
        .sheet(isPresented: $showAddHost) {
            AddHostSheet(hostStore: hostStore, isPresented: $showAddHost)
        }
    }
}

struct HostRow: View {
    let host: HostEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.label)
                .font(.body)
            Text("\(host.username)@\(host.address):\(host.port)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
