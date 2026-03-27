import SwiftUI

/// Dedicated host configuration sheet — full CRUD for host entries with tunnel status.
struct HostConfigSheet: View {
    @ObservedObject var hostStore: HostStore
    @ObservedObject var tunnelManager: TunnelManager
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
                            tunnelStatus: tunnelManager.status(for: host),
                            onEdit: { hostToEdit = host },
                            onDelete: { hostToDelete = host },
                            onReconnect: { tunnelManager.reconnectTunnel(for: host) },
                            onDisconnect: { tunnelManager.disconnectTunnel(for: host) }
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
        .frame(width: 550, height: 400)
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
}

struct HostConfigRow: View {
    let host: HostEntry
    let tunnelStatus: TunnelManager.TunnelStatus
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReconnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack {
            // Status dot
            Circle()
                .fill(Color(tunnelStatus.color))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                    .font(.body)
                HStack(spacing: 4) {
                    Text("\(host.username)@\(host.address):\(host.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("- \(tunnelStatus.label)")
                        .font(.caption)
                        .foregroundColor(Color(tunnelStatus.color))
                }
            }

            Spacer()

            // Tunnel actions
            if tunnelStatus == .connected {
                Button {
                    onDisconnect()
                } label: {
                    Image(systemName: "bolt.slash")
                }
                .buttonStyle(.borderless)
                .help("Disconnect tunnel")
            } else if tunnelStatus == .disconnected || tunnelStatus != .connecting {
                Button {
                    onReconnect()
                } label: {
                    Image(systemName: "bolt")
                }
                .buttonStyle(.borderless)
                .help("Reconnect tunnel")
            }

            Button { onEdit() } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button { onDelete() } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, 2)
    }
}
