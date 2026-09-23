import SwiftUI

// ===========================================================================
// Quick Connect (WI-2026-08-09-003) — Cmd+K command palette: fuzzy host
// search + ssh-target parse + Enter to connect, available on every page.
// Termius's "Find a host or ssh user@hostname…" in the stronger,
// Spotlight-style form.
// ===========================================================================

// MARK: - SSH target parsing

/// Parsed ad-hoc ssh target.
struct SSHTarget: Equatable {
    var username: String?
    var host: String
    var port: Int = 22

    /// "user@host:port" with default parts elided.
    var display: String {
        let user = username.map { "\($0)@" } ?? ""
        return port == 22 ? "\(user)\(host)" : "\(user)\(host):\(port)"
    }
}

enum QuickConnectParser {
    /// Parse `user@host[:port]` / `host[:port]`.
    ///
    /// A bare word stays a SEARCH query — input only counts as a target
    /// when it contains '@', '.' or ':' (so "otherhost" filters hosts while
    /// "root@otherhost" or "10.0.0.5" offers a connect row). IPv6 literals are
    /// out of scope for V1 (happy path).
    static func parse(_ input: String) -> SSHTarget? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        guard trimmed.contains("@") || trimmed.contains(".") || trimmed.contains(":") else {
            return nil
        }

        var rest = Substring(trimmed)
        var username: String?
        if let at = rest.firstIndex(of: "@") {
            let user = rest[..<at]
            guard !user.isEmpty else { return nil }
            username = String(user)
            rest = rest[rest.index(after: at)...]
            // A second '@' is ambiguous — not a target.
            guard !rest.contains("@") else { return nil }
        }

        var port = 22
        if let colon = rest.lastIndex(of: ":") {
            let portPart = rest[rest.index(after: colon)...]
            guard let parsed = Int(portPart), (1...65535).contains(parsed) else { return nil }
            port = parsed
            rest = rest[..<colon]
        }

        guard !rest.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard rest.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        return SSHTarget(username: username, host: String(rest), port: port)
    }
}

// MARK: - Palette

/// Spotlight-style overlay: DS field on ultraThinMaterial, keyboard-driven
/// row list. The caller owns presentation and the connect actions.
struct QuickConnectPalette: View {
    var hostStore: HostStore
    var tunnelManager: TunnelManager
    var onClose: () -> Void
    var onConnectHost: (HostEntry) -> Void
    var onConnectTarget: (SSHTarget) -> Void
    var onSaveTarget: (SSHTarget) -> Void
    var onLocalTerminal: () -> Void
    /// GO TO PANE ([[WI-2026-09-02-007]]): the open panes a query is held
    /// against, and what choosing one does. Optional, because the palette
    /// is also shown where no workbench is open behind it.
    var paneManager: WorkspaceManager? = nil
    var onGoToPane: (UUID) -> Void = { _ in }
    /// Dev/test only: what the field holds when the palette appears.
    var initialQuery: String = ""

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private enum Row: Identifiable {
        case target(SSHTarget)
        case local
        case pane(PaneSearch.Candidate)
        case host(HostEntry)

        var id: String {
            switch self {
            case .target: return "target"
            case .local: return "local"
            case .pane(let pane): return "pane-\(pane.id.uuidString)"
            case .host(let host): return host.id.uuidString
            }
        }
    }

    private var rows: [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // Local terminal stays one Enter away (WI-2026-08-09-003);
            // hosts in MRU order (WI-2026-08-09-006).
            return [.local] + hostStore.hosts.sorted(by: HostStore.byRecency).map(Row.host)
        }
        var out: [Row] = []
        if let target = QuickConnectParser.parse(trimmed) {
            out.append(.target(target))
        }
        // OPEN PANES BEFORE HOSTS. Going to a pane that exists costs
        // nothing; a host row opens a new connection. When both match the
        // same word — the host's label, typically — the pane already on
        // that host is the likelier destination.
        out += PaneSearch.rank(trimmed, in: paneManager?.paneSearchCandidates ?? [])
            .map(Row.pane)
        out += hostStore.searchHosts(trimmed, in: .all)
            .sorted(by: HostStore.byRecency)
            .map(Row.host)
        return out
    }

    private var clampedSelection: Int {
        min(max(selection, 0), max(rows.count - 1, 0))
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            // Input row
            HStack(spacing: DS.Space.md) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Typography.bodyStrong)
                    .foregroundStyle(DS.textTertiary)
                // NOT "TO CONNECT". The first row of this list is Local
                // Terminal, which connects nothing, and the placeholder
                // named only hosts while offering something that is not
                // one.
                TextField("Search hosts, or type user@host:port", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.bodyStrong)
                    .focused($focused)
                    .onSubmit { execute(rows[safe: clampedSelection]) }
                DSKeycap("esc")
            }
            .padding(DS.Space.xl)

            DSHairline()

            // Result rows
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: DS.Space.xxs) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, isSelected: index == clampedSelection)
                                .id(row.id)
                                .onTapGesture { execute(row) }
                                .onHover { hovering in
                                    if hovering { selection = index }
                                }
                        }
                        if rows.isEmpty {
                            Text("No matches")
                                .font(DS.Typography.detail)
                                .foregroundStyle(DS.textTertiary)
                                .padding(DS.Space.xl)
                        }
                    }
                    .padding(DS.Space.sm)
                }
                .frame(maxHeight: DS.scaled(340))
                .onChange(of: clampedSelection) { _, newValue in
                    if let row = rows[safe: newValue] {
                        proxy.scrollTo(row.id)
                    }
                }
            }
        }
        .frame(width: DS.scaled(560))
        .dsFloatingPanel()
        .dsListKeyNavigation(selection: $selection, count: { self.rows.count })
        .onExitCommand { onClose() }
        .onChange(of: query) { _, _ in selection = 0 }
        .onAppear {
            focused = true
            if query.isEmpty { query = initialQuery }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: Row, isSelected: Bool) -> some View {
        HStack(spacing: DS.Space.md) {
            switch row {
            case .target(let target):
                Image(systemName: "arrow.right.circle.fill")
                    .font(DS.Typography.bodyStrong)
                    .foregroundStyle(DS.accent)
                    .frame(width: 20)
                Text("Connect to \(target.display)")
                    .font(DS.Typography.bodyStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.md)
                Button("Save as Host\u{2026}") {
                    onClose()
                    onSaveTarget(target)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // NEVER SQUEEZED. A long target shares the row with this
                // button, and the layout compressed the button's label to
                // an unreadable sliver before it truncated the target
                // (measured at uiFontScale 1.3, [[WI-2026-09-02-011]]).
                // The target is the thing that can be shortened without
                // loss — its middle is elided — so the button keeps its
                // size and the text gives way.
                .fixedSize()
            case .local:
                Image(systemName: "terminal")
                    .font(DS.Typography.bodyStrong)
                    .foregroundStyle(DS.accent)
                    .frame(width: 20)
                Text("Local Terminal")
                    .font(DS.Typography.bodyStrong)
                Spacer(minLength: DS.Space.md)
            case .pane(let pane):
                // ENOUGH TO TELL PANES APART: label, then where it is
                // (workspace · host), then whether it is busy or asking.
                let busy = paneManager?.isBusy(pane.id) == true
                let asking = paneManager?.isAwaitingAttention(pane.id) == true
                Image(systemName: "rectangle.split.2x1")
                    .font(DS.Typography.bodyStrong)
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 20)
                Text(pane.label)
                    .font(DS.Typography.bodyStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text([pane.workspace, pane.host].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(DS.Typography.monoCaption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.md)
                if asking {
                    DSStatusDot(color: DS.warning, size: 6, pulsing: true)
                } else if busy {
                    DSStatusDot(color: DS.textTertiary, size: 6)
                }
            case .host(let host):
                DSStatusDot(color: Color(tunnelManager.status(for: host).color), size: 8)
                    .frame(width: 20)
                Text(host.label)
                    .font(DS.Typography.bodyStrong)
                    .lineLimit(1)
                Text("\(tunnelManager.effectiveUsername(for: host))@\(host.address)")
                    .font(DS.Typography.monoCaption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.md)
            }
            if isSelected {
                Text("↩")
                    .font(DS.Typography.monoCaption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(isSelected ? DS.selection : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func execute(_ row: Row?) {
        guard let row else { return }
        onClose()
        switch row {
        case .local:
            onLocalTerminal()
        case .pane(let pane):
            onGoToPane(pane.id)
        case .host(let host):
            onConnectHost(host)
        case .target(let target):
            onConnectTarget(target)
        }
    }
}

// MARK: - Safe indexing

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
