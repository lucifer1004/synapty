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

// MARK: - Host avatar (shared by card and list row)

/// Identity avatar (WI-2026-08-08-090, WI-2026-08-09-006): tint by OS
/// FAMILY when known (scannable classes — warm orange for the Linux
/// family, blue for Windows, graphite for macOS — without trademark art),
/// deterministic per-host hash hue otherwise. Known OS shows its glyph;
/// unknown keeps the label initials. Tunnel-status dot pinned to the
/// corner.
struct HostAvatar: View {
    let host: HostEntry
    let tunnelStatus: TunnelManager.TunnelStatus
    var size: CGFloat = 32

    /// Family tints deepened for white-glyph contrast (WI-2026-08-09-019):
    /// the earlier 0.68–0.76 brightness left white text borderline in
    /// light mode — same class as the dark-mode segmented fix (WI-…-016).
    /// THE HOST'S OWN COLOUR, not its OS family's ([[HostTint]]): the OS
    /// is the glyph's to say, and a fleet of Linux boxes in one orange
    /// told the eye nothing about which was which.
    private var color: Color { HostTint.color(for: host.label) }

    private var initials: String {
        String(host.label.trimmingCharacters(in: .whitespaces).prefix(2)).uppercased()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.75)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            if let glyph = OSProbe.glyph(for: host.osHint) {
                Image(systemName: glyph)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
            }
            DSStatusDot(
                color: Color(tunnelStatus.color),
                size: size * 0.28,
                pulsing: tunnelStatus == .connecting || tunnelStatus == .reconnecting
            )
            .overlay(Circle().stroke(DS.surface, lineWidth: 2))
            .offset(x: 3, y: 3)
        }
    }
}

/// Card block for one host. Self-contained hover/selection visuals; the
/// grid and drag wiring live in the host list pane.
/// The failure marks a host can carry, defined ONCE for both
/// presentations (WI-2026-08-13-011).
///
/// The card and the list row are two views of the same host, and a human
/// switches between them with a toggle. A mark implemented twice drifts,
/// and the drift shows up as "the failure disappears when I switch to
/// list view" — which reads as the failure resolving itself.
///
/// WHAT, not why, in all of these: the reason lives in Console (see
/// AppLog's two-channel rule), and these strings say what it means for the
/// human and what will not happen on its own.
enum HostFailureMarks {
    /// Icon, tint and hover text for the machine's HUB state, or nil when
    /// there is nothing to act on. Silent while it works: a capability
    /// that works is invisible by working ([[RFC-0010]]
    /// C-DIAGNOSABILITY).
    static func peer(_ state: TunnelManager.PeerState) -> (String, Color, String)? {
        switch state {
        case .none, .linked:
            return nil
        case .notReached:
            return ("bolt.horizontal.circle", DS.textTertiary,
                    "Tunnel is up but this machine's hub has not answered — agents here cannot exchange messages with it yet.")
        case .gaveUp:
            return ("bolt.horizontal.circle.fill", DS.danger,
                    "Lost contact with this machine's hub and stopped retrying — reconnect the host to try again.")
        }
    }

    /// The machine's hub is not the build that was deployed to it.
    ///
    /// A WARNING, NOT A FAILURE. The hub answers, agents route, and
    /// everything the old build knows about still works — what changed is
    /// what the human can expect, because tools added since are refused.
    /// Rendering it in red would teach them to ignore red.
    ///
    /// WHY THIS NEEDS SAYING AT ALL: the only symptom otherwise is a tool
    /// coming back "unknown tool", which names neither the host nor the
    /// cause. Measured on a real host — a hub three days behind rejected
    /// every primitive added since, and finding out why took half an hour
    /// of reading source.
    static func hubBuild(_ builds: TunnelManager.HubBuilds?) -> (String, Color, String)? {
        guard let builds, builds.isSkewed else { return nil }
        return ("exclamationmark.arrow.triangle.2.circlepath", DS.warning,
                "This machine is running an older hub than the one deployed to it — "
                + "anything added since will be refused. Reconnect the host to replace it.")
    }

    static let unsavedHelp =
        "Not saved to disk — this host will be gone after a relaunch. Check Console for the reason."

    /// Icon, tint and hover text for a credential this Mac does not have
    /// ([[ADR-0009]]). Two tints on purpose: a host the human can still
    /// open is a WARNING, and one they cannot is a failure. Rendering both
    /// in red would teach them to ignore the red.
    /// Two machines edited this host and both edits are real. NOT an
    /// error — the merge did its job — but the human has to choose, and
    /// nothing else can choose for them.
    static func conflict(_ fields: [String]?) -> (String, Color, String)? {
        guard let fields, !fields.isEmpty else { return nil }
        let list = fields.joined(separator: ", ")
        return ("arrow.triangle.branch", DS.warning,
                "Edited on another Mac too — \(list) differ. Your version is shown; open the host to choose.")
    }

    /// ONLY WHAT BLOCKS THE HUMAN'S OWN USE ([[WI-2026-08-15-003]]).
    ///
    /// A host with no key path configured is the ORDINARY setup for
    /// anyone using ssh-agent or ~/.ssh/config, and it opens a terminal
    /// perfectly well — so marking it put a warning glyph on every card
    /// in the grid, permanently, beside the name. A mark that is on for
    /// the normal case carries no information and costs the marks that do.
    ///
    /// The deploy gap is real but CONDITIONAL and FUTURE: it matters when
    /// someone deploys an agent to that host, and that is where it should
    /// be said. `HostReadiness` still computes it and `describe` still
    /// speaks it, so nothing is lost — it just stops decorating a grid.
    static func readiness(_ r: HostReadiness) -> (String, Color, String)? {
        guard r.terminalGap != nil, let summary = r.summary else { return nil }
        return ("key.slash.fill", DS.danger, summary)
    }

    /// Spoken form. A red glyph is not a fact for everyone, and the
    /// session rows in HostSidebar have carried their failure in the
    /// label since they were written.
    static func describe(
        host: HostEntry, connected: Bool, unsaved: Bool,
        peerState: TunnelManager.PeerState, readiness: HostReadiness? = nil,
        conflictFields: [String]? = nil
    ) -> String {
        var parts = [host.label, host.address, connected ? "connected" : "not connected"]
        if unsaved { parts.append("not saved to disk") }
        if let phrase = readiness?.accessibilityPhrase { parts.append(phrase) }
        if let c = conflictFields, !c.isEmpty {
            parts.append("also edited on another Mac, \(c.joined(separator: ", ")) differ")
        }
        switch peerState {
        case .notReached: parts.append("hub has not answered")
        case .gaveUp: parts.append("lost contact with the hub, reconnect to retry")
        case .none, .linked: break
        }
        return parts.joined(separator: ", ")
    }
}

struct HostBlockView: View {
    let host: HostEntry
    /// ADR-0009 enrolment sheet.
    @State private var showEnrolSheet = false
    /// Which card claimed `--enrol-sheet`. NOT a consumed one-shot: grid
    /// cards are created and discarded during layout, so a flag spent on
    /// a transient instance leaves the sheet unopened and the trigger
    /// gone. Claiming by host id lets the same card re-arm and keeps
    /// every other card out.
    nonisolated(unsafe) private static var devEnrolSheetHost: UUID?
    var store: HostStore
    let tunnelStatus: TunnelManager.TunnelStatus
    /// The machine's HUB, which is a different question from its tunnel:
    /// the forward can be up with nothing listening behind it.
    let peerState: TunnelManager.PeerState
    /// THE ARGUMENTS A ONE-OFF ssh TO THIS HOST NEEDS, from the resolver
    /// the REAL connection uses ([[TunnelManager]]`.oneOffArgs`). Passed
    /// as a value for the same reason `peerState` is — and because
    /// building them here is what let Test Connection drift: it went
    /// straight at a bastion-only host and presented a different key
    /// than Connect, then reported a failure Connect does not have.
    let sshArgs: (_ connectTimeout: Int, _ remote: String) -> [String]

    /// What build this machine's hub IS versus what was deployed to it.
    /// Passed as a value like `peerState`, so the card stays a function of
    /// what it is given rather than reaching for a service.
    let hubBuilds: TunnelManager.HubBuilds?
    let isSelected: Bool
    /// Terminal open on double-click (WI-2026-08-08-075); also exposed as an
    /// accessibility action.
    let onOpenTerminal: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReconnect: () -> Void
    let onDisconnect: () -> Void
    /// PUT THE CURRENT BINARY ON THIS HOST ([[HostBinary]]).
    var onUpdateBinary: () -> Void = {}
    /// Whether the host answered with a different build. Only ever true
    /// for a connected host, because only those are asked.
    var binaryStale = false
    var updatingBinary = false

    // Test-connection state (WI-2026-08-08-045): nil = idle, true = ok,
    // false = failed.
    @State private var testResult: Bool?
    @State private var isTesting = false
    @State private var isHovered = false

    private var accessibilityDescription: String {
        HostFailureMarks.describe(
            host: host, connected: tunnelStatus.isActive,
            unsaved: isUnsaved, peerState: peerState, readiness: readiness,
            conflictFields: store.conflict(for: host))
    }

    private var peerMark: (String, Color, String)? { HostFailureMarks.peer(peerState) }
    private var hubBuildMark: (String, Color, String)? {
        HostFailureMarks.hubBuild(hubBuilds)
    }

    /// This host did not reach disk on the last save.
    private var isUnsaved: Bool {
        store.unpersistedRecordIDs.contains(host.id.uuidString)
    }

    private var readiness: HostReadiness { HostReadiness.evaluate(host: host, store: store) }
    private var readinessMark: (String, Color, String)? { HostFailureMarks.readiness(readiness) }
    private var conflictMark: (String, Color, String)? { HostFailureMarks.conflict(store.conflict(for: host)) }

    private var effectiveUsername: String { store.effectiveUsername(for: host) }
    private var effectivePort: Int { store.effectivePort(for: host) }

    /// BUILT AS A STRING, and passed to Text as one. `Text("…:\(anInt)")`
    /// resolves to the LocalizedStringKey initialiser, which formats the
    /// number for the locale — so a host on 2222 read `host:2,222`, an
    /// address that connects to nothing. A port is an identifier.
    private var endpoint: String { "\(effectiveUsername)@\(host.address):\(effectivePort)" }

    /// What the card shows under the name — the address, and the port only
    /// where it is not the one everybody assumes. The full `user@host:port`
    /// is still one hover away.
    private var subtitle: String {
        effectivePort == 22 ? host.address : "\(host.address):\(effectivePort)"
    }

    /// ssh -o BatchMode=yes -o ConnectTimeout=5 ... — no password prompts,
    /// bounded time, key used when configured. The test command doubles as
    /// the OS probe (WI-2026-08-09-002): success parses the output and
    /// fills osHint when it is still unset.
    private func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil
        let args = sshArgs(5, OSProbe.command)
        let hostID = host.id
        DispatchQueue.global(qos: .userInitiated).async {
            let output = SubprocessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: args,
                timeout: 8
            )
            let ok = output.error == nil && !output.timedOut
            let hint = ok ? OSProbe.parse(output.stdout) : nil
            DispatchQueue.main.async {
                isTesting = false
                testResult = ok
                if let hint {
                    store.setDetectedOS(hint, for: hostID)
                }
            }
        }
    }

    private var avatar: some View {
        HostAvatar(host: host, tunnelStatus: tunnelStatus, size: DS.scaled(32))
    }

    /// Shared action list — the hover ellipsis menu AND the right-click
    /// context menu offer the same commands (WI-2026-08-08-090).
    @ViewBuilder
    private var cardActions: some View {
        Button {
            onOpenTerminal()
        } label: {
            Label("Connect", systemImage: "terminal")
        }
        Button {
            testConnection()
        } label: {
            Label("Test Connection", systemImage: "waveform")
        }
        if tunnelStatus == .connected {
            // PUTTING THE CURRENT BINARY THERE, EXPLICITLY.
            //
            // `setup-host.sh` compares and uploads, but the fast path does
            // not run it for a host that is already connected, and
            // ControlPersist keeps that master alive as long as the host
            // is peered — so a host dialled before a rebuild stays on the
            // old binary until it is disconnected, which is a thing a
            // human has no reason to do and, until this, no sign to do it
            // for.
            //
            // ONLY WHILE CONNECTED, because the act rides the master
            // already open; offered on a host that is not, it would dial
            // one to do it.
            Button {
                onUpdateBinary()
            } label: {
                Label(binaryStale ? "Update Synapty on This Host (out of date)"
                                  : "Update Synapty on This Host",
                      systemImage: "arrow.down.circle")
            }
            .disabled(updatingBinary)
            Button {
                onDisconnect()
            } label: {
                Label("Disconnect Tunnel", systemImage: "bolt.slash")
            }
        } else if tunnelStatus.canReconnect {
            Button {
                onReconnect()
            } label: {
                Label("Reconnect Tunnel", systemImage: "bolt")
            }
        }
        DSHairline()
        // A GRANT OF STANDING ACCESS, so it is a deliberate menu item
        // behind a sheet and never a side effect of anything else
        // ([[ADR-0009]], [[WI-2026-08-14-001]]).
        Button {
            showEnrolSheet = true
        } label: {
            Label("Authorize a Mac\u{2026}", systemImage: "key.horizontal")
        }
        DSHairline()
        Button {
            onEdit()
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            // Identity row: avatar + label/address. Double-click IS the
            // connect action (WI-2026-08-08-075) — no redundant Connect
            // button (user feedback); quiet actions appear on hover.
            HStack(spacing: DS.Space.md) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.xs) {
                        Text(host.label)
                            .font(DS.Typography.bodyStrong)
                            .lineLimit(1)
                        // NOT SAVED. The one failure a human cannot detect
                        // by looking, because the list on screen still
                        // shows exactly what they typed and the disk does
                        // not (WI-2026-08-13-008 made this observable;
                        // nothing observed it). Inside the label row on
                        // purpose: this card has ONE constant anatomy so
                        // every card is the same height, and a mark that
                        // reflowed the grid would trade one problem for a
                        // worse one.
                        if isUnsaved {
                            Image(systemName: "exclamationmark.icloud.fill")
                                .font(DS.Icon.control)
                                .foregroundStyle(DS.danger)
                                .help(HostFailureMarks.unsavedHelp)
                        }
                        // The machine's hub. Silent when it is working,
                        // because a capability that works is invisible by
                        // working ([[RFC-0010]] C-DIAGNOSABILITY) and this
                        // card has one constant anatomy to protect.
                        if let (icon, tint, hint) = peerMark {
                            Image(systemName: icon)
                                .font(DS.Icon.control)
                                .foregroundStyle(tint)
                                .help(hint)
                        }
                        // Beside the other hub mark, because they answer
                        // the same question: what can this machine's hub
                        // actually do for me.
                        if let (icon, tint, hint) = hubBuildMark {
                            Image(systemName: icon)
                                .font(DS.Icon.control)
                                .foregroundStyle(tint)
                                .help(hint)
                        }
                        // The credential this Mac does not have. Shown
                        // BEFORE anything is attempted — the point of
                        // [[ADR-0009]]'s obligation is that a synced host
                        // says what it cannot do here rather than failing
                        // at connect time.
                        if let (icon, tint, hint) = readinessMark {
                            Image(systemName: icon)
                                .font(DS.Icon.control)
                                .foregroundStyle(tint)
                                .help(hint)
                        }
                        if let (icon, tint, hint) = conflictMark {
                            Image(systemName: icon)
                                .font(DS.Typography.monoCaption)
                                .foregroundStyle(tint)
                                .help(hint)
                        }
                    }
                    // THE SAME SENTENCE THE LIST ROW SAYS. It used to
                    // read `user@host:port` here and `host` there, which
                    // the list's own comment already says it must not:
                    // "a subtitle that differs by view reads as the data
                    // differing". The card had the worse end of it — a
                    // 260pt column with `operator@` and `:22` in front of
                    // the name left the middle of the HOSTNAME to be
                    // truncated, so the one word that identifies the
                    // machine was the word that went.
                    Text(subtitle)
                        .font(DS.Typography.monoCaption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(endpoint)
                        // Narrow cards middle-truncate — full address on
                        // hover (WI-2026-08-08-090).
                        .help(endpoint)
                }
                Spacer(minLength: DS.Space.xs)

                // Test feedback stays visible while relevant, independent
                // of hover.
                if isTesting {
                    ProgressView()
                        .controlSize(.mini)
                } else if let result = testResult {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(DS.Icon.control)
                        .foregroundStyle(result ? DS.success : DS.danger)
                        .help(result ? "Connection OK" : "Connection failed")
                }

                // Hover-revealed quick actions.
                HStack(spacing: DS.Space.xs) {
                    DSIconButton(icon: "pencil", help: "Edit", size: 22) { onEdit() }
                    DSOverflowMenu {
                        cardActions
                    }
                }
                .opacity(isHovered ? 1 : 0)
                // Invisible controls must not swallow mouse-downs — they
                // ate drags that started in the card's trailing area
                // (user report, WI-2026-08-08-090).
                .allowsHitTesting(isHovered)
            }

            // NO meta row — Termius parity (user feedback,
            // WI-2026-08-08-090): host cards keep ONE constant anatomy
            // (avatar + label + address) so every card is the same height.
            // Tags stay searchable and filterable; group membership reads
            // from the grouping context.
        }
        .padding(DS.Space.lg)
        .dsCardChrome(isHovered: isHovered, isSelected: isSelected)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        // NO .contextMenu here: on macOS a context menu attached to the
        // same view as an (outer) .draggable eats the drag's mouse-down,
        // so host blocks could no longer be dragged onto groups (user
        // report, WI-2026-08-08-090). The hover ellipsis menu carries the
        // exact same cardActions.
        // Double-click affordance (WI-2026-08-08-075).
        .help("Double-click to open terminal")
        // One spoken element per card — fragments (initials, mono address)
        // read as noise (WI-2026-08-09-020).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .onAppear {
            // ONE card only: the flag is consumed, so the first host to
            // appear opens it and the rest do not stack sheets.
            if DevLaunchArgs.enrolSheet,
               Self.devEnrolSheetHost == nil || Self.devEnrolSheetHost == host.id {
                Self.devEnrolSheetHost = host.id
                // Next runloop: a sheet flag set during onAppear, before
                // the card is fully in the hierarchy, is dropped.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    showEnrolSheet = true
                }
            }
        }
        .sheet(isPresented: $showEnrolSheet) {
            EnrolMachineSheet(
                host: host,
                tunnelManager: TunnelManager.shared,
                onClose: { showEnrolSheet = false })
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(named: "Open Terminal") {
            onOpenTerminal()
        }
    }
}

// MARK: - Host list row (WI-2026-08-09-006)

/// Compact list-view row — same semantics as the card block (single tap
/// selects, double-click connects, draggable at the call site, hover
/// reveals actions); tags fit here where the grid card dropped them.
struct HostListRow: View {
    let host: HostEntry
    var store: HostStore
    let tunnelStatus: TunnelManager.TunnelStatus
    /// Same two marks the card carries. A human can switch between list
    /// and grid at will, and a failure that is visible in one
    /// presentation and not the other is a failure they will miss by
    /// changing a view preference.
    let peerState: TunnelManager.PeerState
    /// As on the card: a value, so the row stays a function of its inputs.
    let hubBuilds: TunnelManager.HubBuilds?
    let isSelected: Bool
    let onOpenTerminal: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReconnect: () -> Void
    let onDisconnect: () -> Void
    var onUpdateBinary: () -> Void = {}
    /// Whether the host answered with a different build. Only ever true
    /// for a connected host, because only those are asked.
    var binaryStale = false
    var updatingBinary = false

    @State private var isHovered = false

    private var isUnsaved: Bool { store.unpersistedRecordIDs.contains(host.id.uuidString) }

    private var readiness: HostReadiness { HostReadiness.evaluate(host: host, store: store) }
    private var readinessMark: (String, Color, String)? { HostFailureMarks.readiness(readiness) }
    private var conflictMark: (String, Color, String)? { HostFailureMarks.conflict(store.conflict(for: host)) }
    private var peerMark: (String, Color, String)? { HostFailureMarks.peer(peerState) }
    private var hubBuildMark: (String, Color, String)? {
        HostFailureMarks.hubBuild(hubBuilds)
    }
    private var accessibilityDescription: String {
        HostFailureMarks.describe(
            host: host, connected: tunnelStatus.isActive,
            unsaved: isUnsaved, peerState: peerState, readiness: readiness,
            conflictFields: store.conflict(for: host))
    }

    @ViewBuilder
    private var rowActions: some View {
        Button {
            onOpenTerminal()
        } label: {
            Label("Connect", systemImage: "terminal")
        }
        if tunnelStatus == .connected {
            // The same act as the card's, for the same reasons (see
            // HostBlockView).
            Button {
                onUpdateBinary()
            } label: {
                Label(binaryStale ? "Update Synapty on This Host (out of date)"
                                  : "Update Synapty on This Host",
                      systemImage: "arrow.down.circle")
            }
            .disabled(updatingBinary)
            Button {
                onDisconnect()
            } label: {
                Label("Disconnect Tunnel", systemImage: "bolt.slash")
            }
        } else if tunnelStatus.canReconnect {
            Button {
                onReconnect()
            } label: {
                Label("Reconnect Tunnel", systemImage: "bolt")
            }
        }
        DSHairline()
        Button {
            onEdit()
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            HostAvatar(host: host, tunnelStatus: tunnelStatus, size: DS.scaled(24))
            Text(host.label)
                .font(DS.Typography.bodyStrong)
                .lineLimit(1)
            if isUnsaved {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(DS.Icon.control)
                    .foregroundStyle(DS.danger)
                    .help(HostFailureMarks.unsavedHelp)
            }
            if let (icon, tint, hint) = peerMark {
                Image(systemName: icon)
                    .font(DS.Icon.control)
                    .foregroundStyle(tint)
                    .help(hint)
            }
            if let (icon, tint, hint) = hubBuildMark {
                Image(systemName: icon)
                    .font(DS.Icon.control)
                    .foregroundStyle(tint)
                    .help(hint)
            }
            if let (icon, tint, hint) = readinessMark {
                Image(systemName: icon)
                    .font(DS.Icon.control)
                    .foregroundStyle(tint)
                    .help(hint)
            }
            if let (icon, tint, hint) = conflictMark {
                Image(systemName: icon)
                    .font(DS.Icon.control)
                    .foregroundStyle(tint)
                    .help(hint)
            }
            // The list row is the same host in another presentation, so
            // it says the same thing — a subtitle that differs by view
            // reads as the data differing.
            Text(store.effectivePort(for: host) == 22
                 ? host.address
                 : "\(host.address):\(store.effectivePort(for: host))")
                .font(DS.Typography.detail)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Space.md)
            ForEach(host.tags.prefix(2), id: \.self) { tag in
                DSTag(text: tag)
            }
            HStack(spacing: DS.Space.xs) {
                DSIconButton(icon: "pencil", help: "Edit", size: 22) { onEdit() }
                DSOverflowMenu {
                    rowActions
                }
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .background(isSelected ? DS.selection : (isHovered ? DS.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .help("Double-click to open terminal")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(named: "Open Terminal") {
            onOpenTerminal()
        }
    }
}

// ===========================================================================
// Group BLOCK — the same card spec as host blocks (WI-2026-08-08-065):
// the Hosts page is two sections of equally sized blocks (GROUPS above,
// HOSTS below); group blocks are drop targets for host blocks.
// ===========================================================================

/// One block in the GROUPS section. Creation lives in the section header
/// "+" — no dashed action card (WI-2026-08-08-090, redundancy feedback).
/// All Hosts is the DEFAULT view (breadcrumb navigation), not a block
/// (WI-2026-08-08-066).
struct GroupBlockView: View {
    let label: String
    let icon: String
    /// Host count shown on the block.
    var count: Int? = nil
    let isSelected: Bool
    var onSelect: () -> Void = {}
    /// Host-block drop target.
    var onDrop: (([HostDragPayload]) -> Bool)? = nil
    var onGroupSettings: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    /// One connected pane per member, in a grid ([[WI-2026-09-02-009]]).
    var onOpenAsGrid: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared action list for the hover pencil + ellipsis menu
    /// (host-card parity).
    @ViewBuilder
    private var cardActions: some View {
        Button("Open Group") { onSelect() }
        if let onOpenAsGrid {
            Button("Open as Grid") { onOpenAsGrid() }
        }
        if let onGroupSettings {
            Button("Group Settings\u{2026}") { onGroupSettings() }
        }
        if let onDelete {
            DSHairline()
            Button("Delete Group\u{2026}", role: .destructive) { onDelete() }
        }
    }

    var body: some View {
        // Folder tile + label/count — the macOS folder-card idiom
        // (WI-2026-08-08-090).
        HStack(spacing: DS.Space.md) {
            // Same tile geometry as HostAvatar (scaled size, size/4 corner)
            // so sibling cards share one leading-visual language; the soft
            // tint stays — groups are containers, not machines
            // (WI-2026-08-09-010).
            RoundedRectangle(cornerRadius: DS.scaled(8), style: .continuous)
                .fill(DS.accentSoft)
                .frame(width: DS.scaled(32), height: DS.scaled(32))
                .overlay(
                    Image(systemName: icon)
                        .font(DS.Icon.avatar)
                        .foregroundStyle(DS.accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(DS.Typography.bodyStrong)
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                if let count {
                    Text("\(count) host\(count == 1 ? "" : "s")")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
            Spacer(minLength: 0)
            // Hover-revealed actions — pencil + overflow, the same pair as
            // host/identity cards (WI-2026-08-08-090).
            HStack(spacing: DS.Space.xs) {
                if let onGroupSettings {
                    DSIconButton(icon: "pencil", help: "Group Settings", size: 22) {
                        onGroupSettings()
                    }
                }
                DSOverflowMenu {
                    cardActions
                }
            }
            .opacity(isHovered ? 1 : 0)
            // Invisible controls must not swallow clicks (WI-2026-08-08-090).
            .allowsHitTesting(isHovered)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .dsCardChrome(isHovered: isHovered, isSelected: isSelected || isDropTargeted)
        // Unmistakable drop feedback (user request, WI-2026-08-08-090):
        // accent wash + slight lift while a dragged host floats over the
        // group. The wash must not intercept the drop's hit testing.
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .fill(isDropTargeted ? DS.selectionAccentSoft : Color.clear)
                .allowsHitTesting(false)
        )
        .scaleEffect(isDropTargeted && !reduceMotion ? 1.03 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in isHovered = hovering }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(
            reduceMotion ? nil : .spring(duration: 0.25),
            value: isDropTargeted
        )
        // NO .contextMenu: it interferes with drag/drop routing on macOS
        // (same reason it was dropped from host blocks); the hover
        // ellipsis menu carries the same cardActions (WI-2026-08-08-090).
        .dropDestination(for: HostDragPayload.self) { items, _ in
            onDrop?(items) ?? false
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }
}
