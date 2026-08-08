import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// ===========================================================================
// Host BLOCKS (WI-2026-08-08-057) — Termius-style card blocks instead of
// dense rows: each host is a draggable card in a responsive grid, so
// organizing hosts by drag-and-drop onto the group tree is natural.
// ===========================================================================

/// Drag payload: the host IDs being dragged. Dragging an already-selected
/// block carries the whole selection (multi-select drag).
struct HostDragPayload: Codable, Transferable {
    let hostIDs: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .hostDragPayload)
    }
}

extension UTType {
    static let hostDragPayload = UTType(exportedAs: "dev.synapty.host-drag")
    /// Group-tree drags (reparenting, WI-2026-08-08-062) use a distinct
    /// type so group rows can be both sources and targets.
    static let groupDragPayload = UTType(exportedAs: "dev.synapty.group-drag")
}

/// Drag payload for group rows (WI-2026-08-08-062): reparenting a group.
struct GroupDragPayload: Codable, Transferable {
    let groupIDs: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .groupDragPayload)
    }
}

/// Card block for one host. Self-contained hover/selection visuals; the
/// grid and drag wiring live in the host list pane.
struct HostBlockView: View {
    let host: HostEntry
    var store: HostStore
    let tunnelStatus: TunnelManager.TunnelStatus
    let isSelected: Bool
    /// One-click session start from the Hosts list (WI-2026-08-08-064).
    let onOpenTerminal: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReconnect: () -> Void
    let onDisconnect: () -> Void

    // Test-connection state (WI-2026-08-08-045): nil = idle, true = ok,
    // false = failed.
    @State private var testResult: Bool?
    @State private var isTesting = false
    @State private var isHovered = false

    private var effectiveUsername: String { store.effectiveUsername(for: host) }
    private var effectivePort: Int { store.effectivePort(for: host) }

    /// ssh -o BatchMode=yes -o ConnectTimeout=5 ... true — no password
    /// prompts, bounded time, key used when configured.
    private func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-p", "\(effectivePort)"]
        if let key = store.effectiveKeyPath(for: host), !key.isEmpty {
            args += ["-i", key]
        }
        args += ["\(effectiveUsername)@\(host.address)", "true"]
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = SubprocessRunner.runQuiet(
                executable: "/usr/bin/ssh",
                arguments: args,
                timeout: 8
            )
            DispatchQueue.main.async {
                isTesting = false
                testResult = ok
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            // Header: status + label + tags
            HStack(spacing: DS.Space.sm) {
                DSStatusDot(
                    color: Color(tunnelStatus.color),
                    size: 8,
                    pulsing: tunnelStatus == .connecting || tunnelStatus == .reconnecting
                )
                Text(host.label)
                    .font(DS.Typography.bodyStrong)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.xs)
                ForEach(host.tags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(DS.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(DS.accentSoft, in: Capsule())
                }
            }

            // Effective credentials
            HStack(spacing: DS.Space.xs) {
                Text("\(effectiveUsername)@\(host.address):\(effectivePort)")
                    .font(DS.Typography.monoCaption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let gid = host.groupID, !store.groupPath(for: gid).isEmpty {
                    Text(store.groupPath(for: gid).joined(separator: " / "))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                }
            }

            // Tunnel state
            Text(tunnelStatus.label)
                .font(DS.Typography.caption)
                .foregroundStyle(Color(tunnelStatus.color))

            Divider()

            // Actions
            HStack(spacing: DS.Space.sm) {
                // One-click terminal open (WI-2026-08-08-064) — the primary
                // action of a host block.
                Button(action: onOpenTerminal) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DS.accent)
                .help("Open terminal")
                .accessibilityLabel("Open terminal for \(host.label)")

                if tunnelStatus == .connected {
                    Button(action: onDisconnect) {
                        Image(systemName: "bolt.slash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DS.textSecondary)
                    .help("Disconnect tunnel")
                } else if tunnelStatus.canReconnect {
                    Button(action: onReconnect) {
                        Image(systemName: "bolt")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DS.accent)
                    .help("Reconnect tunnel")
                    .accessibilityLabel("Reconnect tunnel")
                }

                Button(action: testConnection) {
                    if isTesting {
                        ProgressView()
                            .controlSize(.mini)
                    } else if testResult == true {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.success)
                    } else if testResult == false {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.danger)
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.textSecondary)
                    }
                }
                .buttonStyle(.borderless)
                .help(testResult == true ? "Connection OK" : (testResult == false ? "Connection failed" : "Test connection"))
                .accessibilityLabel("Test connection")

                Spacer()

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DS.textSecondary)
                .help("Edit")
                .accessibilityLabel("Edit")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DS.danger)
                .help("Delete")
                .accessibilityLabel("Delete")
            }
        }
        .padding(DS.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(DS.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .stroke(
                    isSelected ? DS.accent : (isHovered ? DS.border : DS.border.opacity(0.6)),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
    }
}
