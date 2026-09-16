import SwiftUI
import UniformTypeIdentifiers

/// Tab drag payload ([[WI-2026-08-09-018]]). The UTType MUST stay
/// declared in project.yml UTExportedTypeDeclarations: an undeclared
/// custom type refuses every drop, and does so silently.
///
/// IT CARRIES A PANE, which is now the only thing there is to carry. It
/// used to carry a tab id, and a tab was a container a level above the
/// split leaves — so a drag could reorder tabs and nothing else.
struct TabDragPayload: Codable, Transferable {
    let paneID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tabDragPayload)
    }
}

extension UTType {
    static let tabDragPayload = UTType(exportedAs: "dev.synapty.tab-drag")
}

/// Width preference for overflow detection (WI-2026-08-09-019).
private struct TabsContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// THE TABS OF ONE POSITION ([[RFC-0015]] C-LAYOUT).
///
/// This was one strip across the top of the workspace, because a tab was a
/// container holding a split tree. It is the other way round: the tree
/// holds positions, a position holds a stack of panes, and this is what
/// that stack looks like. A position showing one pane never draws it —
/// there is nothing to choose between.
struct SlotTabBar: View {
    var paneManager: WorkspaceManager
    let slot: SplitNode.Slot
    /// Registered agents — tool badge per tab (WI-2026-08-09-022).
    var agentMonitor: AgentMonitor? = nil
    /// RFC-0006: resume markers (WI-2026-08-11-014).
    var resumeCoordinator: ResumeCoordinator? = nil
    /// ⌘⌥-hold tab hints (WI-2026-08-09-015) — only the focused position
    /// answers them, so only it wears the numbers.
    var hintState: ModifierHintState? = nil
    @Binding var editingPaneID: UUID?

    /// THE TAB A DRAG IS CURRENTLY OVER, and the trailing gap past the
    /// last one ([[WI-2026-08-17-028]]). One of each, because a pointer
    /// is in one place: a dictionary here would be state that can hold
    /// something the world cannot.
    @State private var targetedTabID: UUID?
    @State private var trailingTargeted = false

    /// Overflow fade (WI-2026-08-09-019): content vs container width.
    @State private var tabsContentWidth: CGFloat = 0
    @State private var tabsContainerWidth: CGFloat = 0

    private func agent(in pane: SplitNode.Pane) -> AgentInfo? {
        guard let agentMonitor, let agentID = paneManager.agentID(forLeaf: pane.id) else { return nil }
        return agentMonitor.agents.first {
            AgentMonitor.namesSameAgent($0.id, agentID) && $0.isAgent
        }
    }


    private var isFocusedSlot: Bool {
        paneManager.activeWorkspace?.focusedSlot?.id == slot.id
    }

    /// Which tab the pointer is over, lifted here because a separator
    /// between two tabs has to know about both of them.
    @State private var hoveredTabID: UUID?

    /// A HAIRLINE BETWEEN TWO INACTIVE TABS, and nowhere else. Equal
    /// widths turned a row of labels into a row of boxes with no edges —
    /// a short title in a 200pt box left "whose close button is this"
    /// open. The active tab already has a pill and a hovered one a wash;
    /// a line beside either would double its edge, so those are skipped,
    /// as is a gap the drop caret is about to occupy (Chrome and Safari
    /// draw theirs by the same rule) ([[WI-2026-09-02-002]]).
    private func separatorFollows(_ index: Int) -> Bool {
        let panes = slot.panes
        guard index + 1 < panes.count else { return false }
        let here = panes[index].id, next = panes[index + 1].id
        for id in [here, next] {
            if id == slot.activePaneID || id == hoveredTabID { return false }
        }
        return targetedTabID != next
    }

    var body: some View {
        HStack(spacing: 0) {
            tabs
            // THE MARK THAT SAYS THE OTHERS ARE HIDDEN, NOT GONE
            // ([[WI-2026-09-02-006]]). A zoomed position looks exactly
            // like a workspace with one position, which is the one thing
            // it must not be mistaken for; this is the difference, on the
            // strip the eye already reads, and clicking it is the way back.
            if paneManager.activeWorkspace?.zoomedSlot?.id == slot.id {
                let hidden = (paneManager.activeWorkspace?.slots.count ?? 1) - 1
                DSIconButton(icon: "arrow.down.right.and.arrow.up.left",
                             help: CommandHint.help(
                                "Zoomed — \(hidden) other \(hidden == 1 ? "position" : "positions") hidden. Restore layout",
                                for: "layout.zoom"),
                             size: 18) {
                    paneManager.toggleZoom()
                }
                .foregroundStyle(DS.accent)
                .padding(.trailing, DS.Space.sm)
            }
        }
        .background(DSChromeBackground())
        .overlay(alignment: .bottom) { DSHairline() }
    }

    private var tabs: some View {
        // EQUAL WIDTHS, DECIDED BY COUNT AND NOTHING ELSE. Tabs hugged their
        // labels, and the label is the shell's live title — so a `cd` or a
        // command starting resized a tab and shifted every neighbour, with
        // the close button sliding out from under the pointer. The width
        // now comes from the slot's width and the tab count; the title
        // still changes, inside a box that does not ([[WI-2026-09-02-002]]).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xs) {
                let tabWidth = TabLayout.width(available: tabsContainerWidth,
                                               count: slot.panes.count,
                                               spacing: DS.Space.xs)
                ForEach(Array(slot.panes.enumerated()), id: \.element.id) { index, pane in
                    PaneTab(
                        pane: pane,
                        width: tabWidth,
                        tooltip: paneManager.tabTooltip(for: pane),
                        isBusy: { paneManager.isBusy(pane.id) },
                        displayLabel: paneManager.displayLabel(for: pane),
                        isActive: slot.activePaneID == pane.id,
                        inFocusedSlot: isFocusedSlot,
                        needsAttention: paneManager.isAwaitingAttention(pane.id),
                        hostLabel: paneManager.host(ofLeaf: pane.id)?.label,
                        agent: agent(in: pane),
                        wakeArmed: paneManager.isWakeArmed(pane.id),
                        broadcastArmed: paneManager.isBroadcastArmed(pane.id),
                        execOwner: paneManager.execOwner(pane.id),
                        reconnecting: paneManager.connectProgress.progress(for: pane.id)?
                            .lostSince != nil,
                        progress: paneManager.progress(ofLeaf: pane.id),
                        hintIndex: (hintState?.level == .tab && isFocusedSlot && index < 9) ? index + 1 : nil,
                        editingPaneID: $editingPaneID,
                        onSelect: { paneManager.activatePane(pane.id) },
                        // ✕ CLOSES, ⌥✕ ARCHIVES ([[ADR-0019]]); the tooltip
                        // names both before either happens.
                        onClose: {
                            if NSEvent.modifierFlags.contains(.option) { paneManager.archivePane(pane.id) }
                            else { paneManager.closePaneAsking(pane.id) }
                        },
                        onRename: { newName in paneManager.renamePane(pane.id, to: newName) },
                        onHoverChange: { over in
                            hoveredTabID = over ? pane.id : (hoveredTabID == pane.id ? nil : hoveredTabID)
                        }
                    )
                    // The separator sits in the gap after this tab, drawn
                    // as an overlay so it costs the layout nothing.
                    .overlay(alignment: .trailing) {
                        if separatorFollows(index) {
                            Rectangle()
                                .fill(DS.border)
                                .frame(width: 1, height: DS.scaled(12))
                                .offset(x: DS.Space.xs / 2 + 0.5)
                                .allowsHitTesting(false)
                        }
                    }
                    // Drag (WI-2026-08-09-018). NOTE: tabs keep their
                    // contextMenu because they are NOT the drag-blocked
                    // host-card case — there the contextMenu ate
                    // .draggable's mouse-down on CARDS; verify
                    // interactively and drop the menu if the same class
                    // appears here.
                    .draggable(TabDragPayload(paneID: pane.id))
                    .contextMenu {
                        Button("Rename") {
                            editingPaneID = pane.id
                        }
                        // The same verb the menu and ⌘⇧↩ carry, on the tab
                        // ([[WI-2026-09-02-006]]). On another position's
                        // tab it zooms THAT position: the human pointed at
                        // it, and pointing is focusing.
                        if (paneManager.activeWorkspace?.slots.count ?? 0) > 1 {
                            let armed = paneManager.isBroadcastArmed(pane.id)
                            Button(armed ? "Stop Broadcasting to This Pane" : "Broadcast to This Pane") {
                                paneManager.setBroadcastArmed(pane.id, !armed)
                            }
                            Button(isFocusedSlot && paneManager.isZoomed ? "Restore Layout" : "Zoom") {
                                if !isFocusedSlot {
                                    paneManager.activatePane(pane.id)
                                    if paneManager.isZoomed { return }
                                }
                                paneManager.toggleZoom()
                            }
                        }
                        // RFC-0005 C-AUTHORITY: arming is the human's act,
                        // per pane, default off — shown only when a
                        // registered agent lives here (nothing to wake
                        // otherwise).
                        if agent(in: pane) != nil {
                            DSHairline()
                            let armed = paneManager.isWakeArmed(pane.id)
                            Button {
                                paneManager.setWakeArmed(pane.id, !armed)
                            } label: {
                                if armed {
                                    Label("Peer Wake Armed", systemImage: "checkmark")
                                } else {
                                    Text("Arm Peer Wake")
                                }
                            }
                        }
                        DSHairline()
                        Button("Archive Pane") {
                            paneManager.archivePane(pane.id)
                        }
                        Button("Close Pane") {
                            paneManager.closePaneAsking(pane.id)
                        }
                    }
                    .dropDestination(for: TabDragPayload.self) { payloads, _ in
                        guard let payload = payloads.first else { return false }
                        // A DROP FROM ANOTHER POSITION IS THE SAME MOVE.
                        // One type, one operation — the whole point of
                        // C-LAYOUT: this used to be a reorder within one
                        // tab strip because there was nowhere else a tab
                        // could come from.
                        paneManager.movePane(payload.paneID, before: pane.id)
                        return true
                    } isTargeted: { over in
                        targetedTabID = over ? pane.id : (targetedTabID == pane.id ? nil : targetedTabID)
                    }
                    // THE DROP LANDS BEFORE THIS TAB, so the caret goes
                    // in the gap before it and not on the tab — the tab
                    // is what is being aimed PAST. Inset from both ends
                    // for the same reason a text cursor is shorter than
                    // its line: a rule the full height of what it sits
                    // between is a divider.
                    .dropCaret(targetedTabID == pane.id, on: .leading,
                               gap: DS.Space.xs, inset: DS.Space.xxs)
                }
                // Trailing drop zone: drop past the last tab appends to
                // THIS position's stack.
                Color.clear
                    .frame(width: DS.scaled(40), height: DS.scaled(20))
                    .dropDestination(for: TabDragPayload.self) { payloads, _ in
                        guard let payload = payloads.first else { return false }
                        paneManager.movePane(payload.paneID, toEndOfSlot: slot.id)
                        return true
                    } isTargeted: { trailingTargeted = $0 }
                    .dropCaret(trailingTargeted, on: .leading,
                               gap: DS.Space.xs, inset: DS.Space.xxs)
            }
            .padding(.horizontal, DS.Space.xs)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: TabsContentWidthKey.self, value: g.size.width)
                }
            )
        }
        .onPreferenceChange(TabsContentWidthKey.self) { tabsContentWidth = $0 }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { tabsContainerWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in tabsContainerWidth = w }
            }
        )
        // Overflow fade (WI-2026-08-09-019): a silent horizontal scroller
        // reads as "that's all the tabs" — the trailing fade says more are
        // clipped.
        .overlay(alignment: .trailing) {
            if tabsContentWidth > tabsContainerWidth + 1 {
                LinearGradient(
                    colors: [DS.surface.opacity(0), DS.surface],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: DS.scaled(28))
                .allowsHitTesting(false)
            }
        }
    }
}

struct PaneTab: View {
    let pane: SplitNode.Pane
    /// Resolved label (WI-2026-08-09-017): manual rename > shell title >
    /// stored default.
    /// Shared by every tab in the slot — see the bar's `TabLayout`.
    let width: CGFloat
    /// The half the tab is not showing ([[WorkspaceManager.tabTooltip]]).
    let tooltip: String
    /// Asked once a second while the tab is renamed: a named pane shows
    /// a dot while a command runs, since its label no longer can.
    let isBusy: () -> Bool
    let displayLabel: String
    let isActive: Bool
    /// The slot this tab sits in holds the keyboard. With `isActive` this
    /// is THE tab with the keyboard, and the one that wears the accent
    /// ([[PaneFocusPresentation]]).
    var inFocusedSlot: Bool = false
    /// This pane wants human input (WI-2026-08-09-021).
    var needsAttention: Bool = false
    /// The machine this pane is on, for its colour ([[HostTint]]); nil for
    /// a local pane, which wears none.
    var hostLabel: String? = nil
    /// Registered agent in this pane (WI-2026-08-09-022) — tool badge.
    var agent: AgentInfo? = nil
    /// This pane is armed for peer wake (RFC-0005 C-AUTHORITY: an armed
    /// pane MUST be visibly marked for as long as it is armed).
    var wakeArmed: Bool = false
    /// Keystrokes typed in any armed pane land here too
    /// ([[WI-2026-09-02-010]]). Louder than any other mark this strip
    /// has, because it is the one that makes a key irreversible.
    var broadcastArmed: Bool = false
    /// RFC-0006: a resume incantation was typed here — marked until the
    /// human's first input.
    /// RFC-0007 C-EXEC-SCOPE: machine-operated exec pane, owned by this
    /// agent id. MUST be visibly marked as long as it lives.
    var execOwner: String? = nil
    /// THE LINK BEHIND THIS PANE IS DOWN and its client is dialling
    /// again. The screen stays exactly as it was — it is the last true
    /// thing the session said — and this is what says it is no longer
    /// live ([[WI-2026-08-29-004]]).
    var reconnecting: Bool = false
    /// A program's own OSC 9;4 progress, drawn under the label
    /// ([[WI-2026-09-02-002]]).
    var progress: LeafProgress? = nil
    /// ⌘⌥-hold hint number (WI-2026-08-09-015); nil = no badge.
    var hintIndex: Int? = nil
    @Binding var editingPaneID: UUID?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    var onHoverChange: (Bool) -> Void = { _ in }

    @State private var editText = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var isHovered = false
    /// Manual double-click detection (WI-2026-08-08-076 pattern):
    /// double-click renames inline — the Terminal.app tab behavior.
    @State private var lastTapTime = Date.distantPast

    private var isEditing: Bool { editingPaneID == pane.id }

    private var wearsAccent: Bool {
        PaneFocusPresentation.tabWearsAccent(isActive: isActive, inFocusedSlot: inFocusedSlot)
    }

    @ViewBuilder
    private var progressHairline: some View {
        if let progress { ProgressHairline(progress: progress) }
    }

    private func commitRename() {
        if !editText.isEmpty { onRename(editText) }
        editingPaneID = nil
    }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            // CENTRED AS A GROUP. Leading alignment was the content-width
            // habit: box and text were the same size, so it made no
            // difference. In a fixed box a short title sat at the left
            // with the close slot at the right and nothing between — the
            // glyphs, label and busy dot now centre together, as every
            // equal-width tab bar on this platform does, and the close
            // slot stays where the hand expects it.
            Spacer(minLength: 0)
            // THE KIND, WHERE IT IS NOT A TERMINAL ([[RFC-0015]]
            // C-CONTENT). WI-2026-08-09-013 removed per-tab glyphs when
            // every leaf was a terminal and every tab therefore wore the
            // same one; a leaf is no longer necessarily a terminal, so
            // this marks the exceptions and leaves the default bare —
            // which is what keeps it from becoming the noise that finding
            // was about.
            if let icon = pane.content.tabIcon {
                Image(systemName: icon)
                    .font(DS.Icon.mark)
                    .foregroundStyle(isActive ? DS.textSecondary : DS.textTertiary)
                    .help(pane.content.kindName)
                    .accessibilityLabel(pane.content.kindName)
            }
            // ⌘⌥-hold hint (WI-2026-08-09-015): this tab answers ⌘⌥N.
            if let hintIndex {
                DSKeycap("\(hintIndex)")
            }
            // WHICH MACHINE, at a glance ([[HostTint]]): the same colour
            // the host's avatar and workspace row wear. Equal-width tabs
            // show a title, and titles look alike across machines.
            if let hostLabel {
                DSStatusDot(color: HostTint.color(for: hostLabel), size: 6)
                    .help(hostLabel)
                    .accessibilityLabel("On \(hostLabel)")
            }
            // Attention pulse (WI-2026-08-09-021).
            if needsAttention {
                DSStatusDot(color: DS.warning, size: 6, pulsing: true)
            }
            // Registered-agent tool badge (WI-2026-08-09-022). An agent
            // whose merged status is `unknown` reads as NOT visibly
            // present — ghosted, never the last tool color pretending
            // liveness (WI-2026-08-11-016: the harness may have exited;
            // the registration and resume plan survive, the badge must
            // not lie).
            if let agent {
                let ghosted = agent.status == "unknown"
                Image(systemName: agent.tool.sfSymbol)
                    .font(DS.Icon.mark)
                    .foregroundStyle(
                        needsAttention ? DS.warning
                            : ghosted ? DS.textTertiary : agent.tool.accentColor)
                    .opacity(ghosted ? 0.55 : 1.0)
                    .help("\(agent.tool.displayName) · \(agent.statusPhrase)")
                    .accessibilityHidden(true)
            }
            // Armed-for-wake mark (RFC-0005 C-AUTHORITY): the human must
            // see at a glance which panes peers can start.
            if reconnecting {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(DS.Icon.mark)
                    .foregroundStyle(DS.warning)
                    .help("The link to this session dropped. What you see is the last "
                          + "screen it sent; the client is dialling again.")
                    .accessibilityLabel("Reconnecting")
            }
            if broadcastArmed {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(DS.Icon.mark)
                    .foregroundStyle(DS.danger)
                    .help("Broadcast armed — keys typed in any armed pane are sent here")
                    .accessibilityLabel("Broadcast armed")
            }
            if wakeArmed {
                Image(systemName: "bolt.fill")
                    .font(DS.Icon.mark)
                    .foregroundStyle(DS.warning)
                    .help("Peer wake armed — messages can start this agent")
                    .accessibilityLabel("Peer wake armed")
            }
            // Exec-pane marker (RFC-0007 C-EXEC-SCOPE): a machine-operated
            // pane an agent runs commands in — must be visible as long as
            // it lives, with the owner.
            if let execOwner {
                Image(systemName: "terminal.fill")
                    .font(DS.Icon.mark)
                    .foregroundStyle(DS.warning)
                    .help("Exec pane — \(execOwner) runs commands here")
                    .accessibilityLabel("Machine-operated exec pane owned by \(execOwner)")
            }
            if isEditing {
                TextField("Name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.body)
                    .frame(minWidth: 50)
                    .focused($isTextFieldFocused)
                    .onAppear {
                        editText = displayLabel
                        DispatchQueue.main.async {
                            isTextFieldFocused = true
                        }
                    }
                    .onSubmit { commitRename() }
                    .onExitCommand { editingPaneID = nil }
                    .onChange(of: isTextFieldFocused) { _, focused in
                        if !focused {
                            Task { @MainActor in commitRename() }
                        }
                    }
            } else {
                Text(displayLabel)
                    .font(isActive ? DS.Typography.bodyStrong : DS.Typography.body)
                    .foregroundStyle(wearsAccent ? DS.accent
                                     : isActive ? DS.textPrimary : DS.textSecondary)
                    .lineLimit(1)
                    // MIDDLE, because a path's two ends are the informative
                    // ones and its middle is not.
                    .truncationMode(.middle)
                    // A PROGRAM'S OWN PROGRESS, as a hairline under its
                    // name ([[WI-2026-09-02-002]]): a pane that is not on
                    // screen still says how far along its build is.
                    .overlay(alignment: .bottomLeading) { progressHairline }
                // A NAMED PANE HAS GIVEN UP ITS LIVE TITLE, so this is what
                // says "something is running here". Two points, the accent,
                // re-asked once a second — only for renamed tabs.
                if pane.userRenamed {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if isBusy() {
                            Circle()
                                .fill(DS.accent)
                                .frame(width: 5, height: 5)
                                .accessibilityLabel("Running")
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Close slot ALWAYS reserved (WI-2026-08-09-013): a hover-only
            // member shifted every tab's width on mouse-over (tab dance).
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(DS.Icon.mark)
                    .frame(width: DS.scaled(12), height: DS.scaled(12))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.textTertiary)
            .accessibilityLabel("Close pane; with Option, archive it")
            .opacity(isHovered || isActive ? 1 : 0)
            .allowsHitTesting(isHovered || isActive)
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(width: width, height: DS.scaled(20))
        .help(tooltip)
        // ONE selection grammar (WI-2026-08-09-013): the active tab wears
        // the same DS.selection pill as sidebar nav and session rows — the
        // old raised white chip vanished on the WI-010 white surface band.
        // THE TAB WITH THE KEYBOARD wears the soft accent on that same
        // pill: focus speaks the selection language the sidebar taught,
        // instead of the ring that used to be drawn around its pane
        // ([[WI-2026-09-02-003]]). Solid accent fill stays with
        // DSSegmented — it would fight the agent badge, busy dot and
        // progress hairline that share this strip.
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(wearsAccent ? DS.accentSoft
                      : isActive ? DS.selection
                      : isHovered ? DS.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(lastTapTime) < NSEvent.doubleClickInterval {
                lastTapTime = .distantPast
                editingPaneID = pane.id
            } else {
                lastTapTime = now
                onSelect()
            }
        }
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering)
        }
        // One spoken element per tab; close is an action, not a stray
        // unlabeled x (WI-2026-08-09-020).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pane: \(displayLabel)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(named: "Close Tab") { onClose() }
        .accessibilityAction(named: "Rename") { editingPaneID = pane.id }
    }
}

/// OSC 9;4 progress under a tab label. Two points tall, the label's width;
/// a figure fills proportionally, no figure pulses the whole width, and an
/// error wears the danger colour.
private struct ProgressHairline: View {
    let progress: LeafProgress

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(progress.percent ?? 100) / 100
            Capsule()
                .fill(color)
                .frame(width: max(2, geo.size.width * fraction), height: 2)
                .opacity(progress.state == .indeterminate ? 0.5 : 0.9)
        }
        .frame(height: 2)
        .offset(y: 3)
        .accessibilityLabel(label)
    }

    private var color: Color {
        switch progress.state {
        case .error: return DS.danger
        case .paused: return DS.warning
        case .set, .indeterminate: return DS.accent
        }
    }

    private var label: String {
        if let percent = progress.percent { return "\(percent) percent" }
        return progress.state == .indeterminate ? "In progress" : "Progress"
    }
}

/// How wide every tab in a slot is: the slot's width shared equally,
/// clamped so a lone tab does not sprawl and a crowd does not vanish.
enum TabLayout {
    static var minWidth: CGFloat { DS.scaled(90) }
    static var maxWidth: CGFloat { DS.scaled(220) }

    static func width(available: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0 else { return minWidth }
        let gaps = CGFloat(max(0, count - 1)) * spacing
        let share = (available - gaps) / CGFloat(count)
        return min(maxWidth, max(minWidth, share))
    }
}

