import SwiftUI

/// One line of the stream, from either source.
///
/// TWO SOURCES, ONE READER. The hub records what agents asked it for; the
/// transfer service records what this workbench moved. A human's drag never
/// reaches the hub — nothing about it is a hub event — so it has nowhere
/// else it could appear, and a record that omits half the transfers is one
/// nobody can use to answer "where did this file come from"
/// ([[RFC-0013]] C-AUTHORIZATION, [[WI-2026-08-15-009]]).
///
/// Its own identity rather than the hub row's `ts`: two entries from
/// different sources can land on the same millisecond, and a duplicate id
/// makes a list misrender rather than merely look wrong.
struct ActivityLine: Identifiable {
    let id: String
    let ts: Int64
    let agent: String
    let tool: String
    let detail: String
}

/// Activity stream — the hub's tool-request feed (RFC-0003 C-UI) merged
/// with this workbench's own transfers. Rendered by [[ActivityPage]].
struct ActivityStreamView: View {
    var taskMonitor: TaskMonitor
    /// Absent in previews and in tests that render this without a workbench.
    var transfers: TransferService? = nil

    /// Merged newest-last, the order the timeline scrolls in.
    private var lines: [ActivityLine] {
        let fromHub = taskMonitor.activities.map {
            ActivityLine(id: "hub-\($0.ts)-\($0.agent)", ts: $0.ts,
                         agent: $0.agent, tool: $0.tool, detail: $0.detail)
        }
        let fromTransfers = (transfers?.transfers ?? []).map { line($0) }
        // A THIRD SOURCE, for the same reason there were two: a file
        // pane's create, rename and delete reach no hub and move no bytes,
        // so this is the only place they could be found again
        // ([[RFC-0015]] C-PANE-WRITES).
        let fromWrites = (transfers?.paneWrites ?? []).map { write in
            ActivityLine(
                id: "write-\(write.id.uuidString)",
                ts: Int64(write.at.timeIntervalSince1970 * 1000),
                agent: "you",
                tool: "files",
                detail: write.summary)
        }
        return (fromHub + fromTransfers + fromWrites).sorted { $0.ts < $1.ts }
    }

    /// A transfer, as the stream reads it. The initiator is the agent
    /// column, because a plane serving both a human's gesture and an
    /// agent's call must say which it was serving; the two machines are in
    /// the detail, because "where did this file come from" is the question
    /// the record exists to answer.
    private func line(_ t: TransferService.Transfer) -> ActivityLine {
        let size = t.totalBytes.map {
            " (" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + ")"
        } ?? ""
        let verb: String
        switch t.state {
        case .done: verb = "delivered"
        case .failed(let why): verb = "failed: \(why) —"
        case .cancelled: verb = "cancelled"
        case .running: verb = "sending"
        case .queued: verb = "queued"
        case .awaitingChoice: verb = "waiting on you"
        }
        let route = transfers.map { "\($0.machineName(of: t.source)) → \($0.machineName(of: t.destination))" }
            ?? ""
        return ActivityLine(
            id: "transfer-\(t.id.uuidString)",
            ts: Int64(t.startedAt.timeIntervalSince1970 * 1000),
            agent: t.initiator.label,
            tool: "file.transfer",
            detail: "\(verb) \(t.fileName): \(route)\(size)")
    }

    var body: some View {
        Group {
            if lines.isEmpty {
                emptyState
            } else {
                activityTimeline
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        DSEmptyState(
            icon: "tray",
            title: "No activity yet",
            message: "Agents' requests, file transfers, and what you change in a file pane all appear here as they happen — including what you deleted, and on which machine."
        )
    }

    // MARK: - Activity timeline

    private var activityTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Inset-grouped card timeline (WI-2026-08-09-005) —
                // the Tasks-page block idiom, width-constrained like
                // Settings for a readable column.
                DSCard(padding: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, item in
                            ActivityRow(item: item)
                                .id(item.id)
                            if index < lines.count - 1 {
                                DSHairline().padding(.leading, DS.Space.xl)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.lg)
                .frame(maxWidth: DS.scaled(760), alignment: .leading)
                // Bounded from the page's own left edge rather than centred in
                // what is left over — the same page-title-and-content-disagree
                // defect the Settings column had.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Key on the LAST ITEM's identity, not the array count: once
            // the stream is at its 100-item cap the count never changes
            // and count-based auto-scroll silently dies (WI-2026-08-08-023).
            .onChange(of: lines.last?.id) { _, _ in
                if let last = lines.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Row

struct ActivityRow: View {
    let item: ActivityLine

    /// Hoisted: DateFormatter allocation is notoriously expensive, and
    /// this row re-renders on every 5s activity poll (WI-2026-08-08-023).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var timeText: String {
        // Hub timestamps are milliseconds since epoch (WI-2026-08-08-032).
        let seconds = TimeInterval(item.ts) / 1000
        return Self.timeFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private var icon: String {
        switch item.tool {
        case "task.create": return "plus.circle"
        case "task.claim": return "hand.raised"
        case "task.update": return "arrow.triangle.2.circlepath"
        case "task.comment": return "bubble.left"
        case "file.transfer": return "arrow.left.arrow.right"
        default: return "list.bullet"
        }
    }

    private var iconColor: Color {
        switch item.tool {
        case "task.create": return DS.success
        case "task.claim": return DS.info
        case "task.update": return DS.warning
        case "task.comment": return DS.accent
        case "file.transfer": return DS.info
        default: return DS.textSecondary
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            Image(systemName: icon)
                .font(DS.Typography.monoCaption)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            Text(timeText)
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.textTertiary)
            Text(item.detail)
                .font(DS.Typography.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Space.md)
            Text(item.agent)
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 1)
                .background(DS.hover, in: Capsule())
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
    }
}
