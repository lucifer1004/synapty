import SwiftUI

struct HostSidebar: View {
    @ObservedObject var hostStore: HostStore
    @State private var showAddHost = false
    @State private var hostToDelete: HostEntry?

    var body: some View {
        List {
            Section("Local") {
                Label("New Terminal", systemImage: "terminal")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // V1: opening a new local terminal pane is a future action
                    }
            }

            Section("Remote Hosts") {
                ForEach(hostStore.hosts) { host in
                    HostRow(host: host)
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
