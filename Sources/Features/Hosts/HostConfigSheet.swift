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
            DSSheetHeader(title: "Host Configuration", icon: "server.rack", isPresented: $isPresented)

            Divider()

            // Host list
            if hostStore.hosts.isEmpty {
                VStack(spacing: DS.Space.lg) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 36))
                        .foregroundStyle(DS.textTertiary)
                    Text("No hosts configured")
                        .font(DS.Typography.titleLarge)
                        .foregroundStyle(DS.textSecondary)
                    Text("Add a remote host to get started.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.background)
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
                .scrollContentBackground(.hidden)
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
            .padding(DS.Space.lg)
        }
        .frame(width: 560, height: 420)
        .background(DS.background)
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
        HStack(spacing: DS.Space.md) {
            // Status dot
            DSStatusDot(
                color: Color(tunnelStatus.color),
                size: 8,
                pulsing: tunnelStatus == .connecting || tunnelStatus == .reconnecting
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                    .font(DS.Typography.bodyStrong)
                HStack(spacing: DS.Space.xs) {
                    Text("\(host.username)@\(host.address):\(host.port)")
                        .font(DS.Typography.monoCaption)
                        .foregroundStyle(DS.textSecondary)
                    Text("· \(tunnelStatus.label)")
                        .font(DS.Typography.caption)
                        .foregroundStyle(Color(tunnelStatus.color))
                }
            }

            Spacer()

            // Tunnel actions
            if tunnelStatus == .connected {
                Button {
                    onDisconnect()
                } label: {
                    Image(systemName: "bolt.slash")
                        .foregroundStyle(DS.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Disconnect tunnel")
            } else if tunnelStatus == .disconnected || tunnelStatus != .connecting {
                Button {
                    onReconnect()
                } label: {
                    Image(systemName: "bolt")
                        .foregroundStyle(DS.accent)
                }
                .buttonStyle(.borderless)
                .help("Reconnect tunnel")
            }

            Button { onEdit() } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(DS.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button { onDelete() } label: {
                Image(systemName: "trash")
                    .foregroundStyle(DS.danger)
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, DS.Space.xs)
    }
}
