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
                if let gid = host.groupID,
                   let group = store.groups.first(where: { $0.id == gid }) {
                    Text(group.label)
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

// ===========================================================================
// Group BLOCK — the same card spec as host blocks (WI-2026-08-08-065):
// the Hosts page is two sections of equally sized blocks (GROUPS above,
// HOSTS below); group blocks are drop targets for host blocks.
// ===========================================================================

/// One block in the GROUPS section: All Hosts / Ungrouped pseudo-blocks,
/// real groups, or the New Group action block.
struct GroupBlockView: View {
    enum Kind: Hashable {
        case all
        case ungrouped
        case group(UUID)
        case new
    }

    let kind: Kind
    let label: String
    let icon: String
    /// Host count shown on the block (nil for the New Group block).
    var count: Int? = nil
    let isSelected: Bool
    var onSelect: () -> Void = {}
    /// Host-block drop target (group + Ungrouped blocks).
    var onDrop: (([HostDragPayload]) -> Bool)? = nil
    /// Context menu (real groups only).
    var onGroupSettings: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(kind == .new ? DS.textSecondary : (isSelected ? DS.accent : DS.textSecondary))
                Text(label)
                    .font(kind == .new ? DS.Typography.body : DS.Typography.bodyStrong)
                    .foregroundStyle(kind == .new ? DS.textSecondary : DS.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.xs)
            }
            if let count {
                Text("\(count) host\(count == 1 ? "" : "s")")
                    .font(DS.Typography.monoCaption)
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(DS.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .stroke(
                    kind == .new ? DS.border :
                        ((isSelected || isDropTargeted) ? DS.accent : (isHovered ? DS.border : DS.border.opacity(0.6))),
                    style: kind == .new
                        ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                        : StrokeStyle(lineWidth: (isSelected || isDropTargeted) ? 1.5 : 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in isHovered = hovering }
        .contextMenu {
            if onGroupSettings != nil {
                Button("Group Settings\u{2026}") { onGroupSettings?() }
            }
            if onDelete != nil {
                Divider()
                Button("Delete Group", role: .destructive) { onDelete?() }
            }
        }
        .dropDestination(for: HostDragPayload.self) { items, _ in
            onDrop?(items) ?? false
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }
}
