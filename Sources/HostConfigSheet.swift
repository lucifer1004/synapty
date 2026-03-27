import SwiftUI

/// Dedicated host configuration sheet — full CRUD for host entries.
struct HostConfigSheet: View {
    @ObservedObject var hostStore: HostStore
    @Binding var isPresented: Bool

    @State private var showAddHost = false
    @State private var hostToEdit: HostEntry?
    @State private var hostToDelete: HostEntry?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Host Configuration")
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Host list
            if hostStore.hosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No hosts configured")
                        .foregroundColor(.secondary)
                    Text("Add a remote host to get started.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(hostStore.hosts) { host in
                        HostConfigRow(
                            host: host,
                            onEdit: { hostToEdit = host },
                            onDelete: { hostToDelete = host }
                        )
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer
            HStack {
                Button {
                    showAddHost = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
                Spacer()
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .sheet(isPresented: $showAddHost) {
            AddHostSheet(hostStore: hostStore, isPresented: $showAddHost)
        }
        .sheet(item: $hostToEdit) { host in
            AddHostSheet(
                hostStore: hostStore,
                isPresented: Binding(
                    get: { hostToEdit != nil },
                    set: { if !$0 { hostToEdit = nil } }
                ),
                editingHost: host
            )
        }
        .alert("Delete Host", isPresented: Binding(
            get: { hostToDelete != nil },
            set: { if !$0 { hostToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { hostToDelete = nil }
            Button("Delete", role: .destructive) {
                if let host = hostToDelete {
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
}

struct HostConfigRow: View {
    let host: HostEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                    .font(.body)
                Text("\(host.username)@\(host.address):\(host.port)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, 2)
    }
}
