import SwiftUI

/// Corner number badge shown over a split pane while ⌘⌃ is held
/// (WI-2026-08-09-015). High-contrast against arbitrary terminal
/// content: dark capsule + light text, both appearance modes.
struct PaneHintBadge: View {
    let number: Int

    var body: some View {
        Text(String(number))
            .font(.system(size: DS.scaled(12), weight: .bold, design: .monospaced))
            .accessibilityHidden(true)
            .foregroundStyle(.white)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
            )
    }
}

/// Renders ALL panes of ALL workspaces in a single flat ZStack.
/// Only the panes in front of the active workspace's positions are
/// visible; the rest are hidden but alive (preserving ghostty surface
/// state across every switch).
///
/// A PANE IS NOT NECESSARILY A TERMINAL ([[RFC-0015]] C-CONTENT). A pane
/// may show a machine's files or its exposed web services, and every
/// layout operation treats all three alike — only what is drawn differs.
///
/// THE TAB BAR BELONGS TO A POSITION, NOT TO THE WORKSPACE ([[RFC-0015]]
/// C-LAYOUT). Every position draws one across its own top edge, showing
/// what THAT position is holding — and a position holding a single pane
/// draws it too, because the tab is the handle the pane is dragged by.
///
/// WHICH PANES ARE KEPT ALIVE WHILE HIDDEN, and why the answer changed.
/// A terminal holds a pty whose child must not die when the human
/// switches tabs, which is what the whole hidden-but-present arrangement
/// is for. A file or services pane keeps its navigation, filter and
/// listing in the pane manager, so rebuilding one costs nothing.
///
/// A WEB PANE NOW STAYS BUILT TOO. Its page — the scroll position, a form
/// half filled, a session — lives in the WKWebView and nowhere else, so
/// being rebuilt is being RELOADED, and the human's work goes with it.
/// That cost used to be accepted here on the ground that a resident
/// WKWebView would add another view to the overlapping AppKit stack that
/// once sent two file transfers to the wrong machine. The ground no
/// longer holds: `isHidden` is what takes a view out of hit-testing AND
/// out of its drag-destination registration, TerminalSurface has used
/// exactly that one line since, and BrowserSurface uses it now.
struct AllPanesSplitView: View {
    var paneManager: WorkspaceManager
    let ghosttyApp: GhosttyApp
    /// Services a non-terminal pane needs. Absent in previews and in the
    /// tests that render this view without a workbench.
    var hostStore: HostStore? = nil
    var tunnelManager: TunnelManager? = nil
    var transfers: TransferService? = nil
    var forwards: PortForwardService? = nil
    var artifacts: ArtifactService? = nil
    /// Whether the Terminal page is the shown page (focus gating,
    /// WI-2026-08-08-032).
    var isTerminalPageVisible: Bool = true
    /// Modifier-hold hints (WI-2026-08-09-015): ⌘⌃ held → number badges
    /// on the active workspace's position corners.
    var hintState: ModifierHintState? = nil
    /// Files dropped onto a terminal ([[WI-2026-08-15-009]]). Absent in the
    /// previews and tests that render this view without a workbench.
    var dropCoordinator: TerminalDropCoordinator? = nil
    /// Chrome the per-position tab bars need. Absent in previews.
    var agentMonitor: AgentMonitor? = nil
    var resumeCoordinator: ResumeCoordinator? = nil
    /// Re-dial the connection one leaf names ([[RFC-0015]] C-DIAL).
    var onRetryLeaf: ((UUID) -> Void)? = nil

    /// Last visible frame per pane: hidden panes keep their last size
    /// instead of being re-framed to the full container on every switch,
    /// which forced real PTY resizes (SIGWINCH) of invisible surfaces
    /// (WI-2026-08-08-027).
    @State private var lastFrames: [UUID: CGRect] = [:]

    /// The divider being dragged right now, if any — a line, not a resize
    /// (WI-2026-08-17-002).
    @State private var dividerDrag = DividerDrag()

    /// Which position's tab is being renamed inline. One at a time across
    /// the whole layout: the human is editing one name.
    @State private var editingPaneID: UUID?

    /// Which non-terminal pane a pane drag is over, and where in it
    /// ([[WI-2026-08-17-028]]). A terminal answers this in AppKit, on its
    /// own surface; these draw in SwiftUI and answer here.
    @State private var bodyDropTarget: PaneBodyDropTarget?

    /// Frame/divider computation cache (WI-2026-08-08-051): recomputed only
    /// when the container size OR the workspace's split tree changes —
    /// unrelated body evaluations (focus moves, session publishes) reuse it.
    ///
    /// A REFERENCE, NOT A VALUE: the cache is filled from inside `body`,
    /// and storing into a class held by @State is a plain store, where
    /// assigning a @State value from body is "modifying state during view
    /// update" — a second render pass that ended only because it hit the
    /// cache ([[WI-2026-09-02-026]]).
    @State private var layoutCache = LayoutCache()

    private final class LayoutCache {
        var entry: (size: CGSize, tree: SplitNode?, zoomed: UUID?,
                    frames: [UUID: CGRect], dividers: [SplitLayout.DividerInfo])?
    }

    var body: some View {
        GeometryReader { geo in
            let layoutTree = paneManager.activeWorkspace?.layout
            // THE POSITIONS ON SCREEN, which under a zoom is one
            // ([[WI-2026-09-02-006]]). Everything below — tab strips,
            // frames, the wash — is drawn over this list, so a hidden
            // position has no frame, no strip and no wash, and the
            // one-position rules apply to a zoomed workspace as written.
            let slots = paneManager.activeWorkspace?.visibleSlots ?? []
            let zoomed = paneManager.activeWorkspace?.zoomedSlot
            // ONE PANE PER POSITION IS ON SCREEN — whatever each position
            // is showing. The rest of a stack is alive and behind it.
            let visibleIDs = Set(paneManager.visibleLeafIDs)
            let focusedPaneID = paneManager.activeWorkspace?.focusedPaneID
            // Cached layout: identical (size, tree) pairs skip recomputation
            // (WI-2026-08-08-051).
            let layout = cachedLayout(for: geo.size, tree: layoutTree, zoomed: zoomed)
            let slotFrames = layout.frames
            let dividers = layout.dividers
            /// Where a pane's own content goes — its position's rect, less
            /// the strip its tab bar occupies when it draws one.
            let paneFrame: (UUID) -> CGRect? = { paneID in
                guard let slot = layoutTree?.slot(containing: paneID),
                      let rect = slotFrames[slot.id] else { return nil }
                return SplitLayout.contentRect(of: rect)
            }

            ZStack(alignment: .topLeading) {
                // All panes from all workspaces — flat ForEach for stable
                // identity. A pane that is not a terminal is drawn only
                // while it is in front; see the note on this type.
                ForEach(paneManager.allLeaves.filter { !$0.content.isTerminal }, id: \.id) { leaf in
                    // A WEB PANE IS BUILT WHETHER OR NOT IT IS IN FRONT.
                    // Drawn only while visible, it was destroyed on the way
                    // out and rebuilt on the way back — and a rebuilt
                    // WKWebView is a RELOAD: the page, the scroll position
                    // and a half-filled form are all gone. None of that
                    // lives in the pane manager, unlike a file pane's
                    // navigation or a services pane's selection.
                    if visibleIDs.contains(leaf.id) || leaf.content.survivesHiding {
                        let isActive = visibleIDs.contains(leaf.id)
                        let frame = paneFrame(leaf.id) ?? CGRect(origin: .zero, size: geo.size)
                        PaneContentView(
                            isVisible: isActive,
                            content: leaf.content,
                            host: paneManager.host(ofLeaf: leaf.id),
                            hostStore: hostStore,
                            tunnelManager: tunnelManager,
                            transfers: transfers,
                            forwards: forwards,
                            artifacts: artifacts,
                            onDirectoryChange: { paneManager.fileLeafDidNavigate(leaf.id, to: $0) },
                            navigation: paneManager.navigation(ofFileLeaf: leaf.id),
                            openedFrom: paneManager.openedFromDescription(leaf: leaf.id),
                            onFilter: { paneManager.setFilter($0, ofFileLeaf: leaf.id) },
                            onListing: { paneManager.cacheListing($0, for: $1, ofFileLeaf: leaf.id) },
                            onInvalidate: { paneManager.invalidateCache(path: $0, ofFileLeaf: leaf.id) },
                            onSort: { paneManager.sortFileLeaf(leaf.id, by: $0) },
                            onBack: { paneManager.fileLeafGoBack(leaf.id) },
                            onForward: { paneManager.fileLeafGoForward(leaf.id) },
                            viewing: paneManager.viewing(ofServicesLeaf: leaf.id),
                            onViewing: { paneManager.servicesLeaf(leaf.id, isShowing: $0) },
                            onAddress: { paneManager.browserLeafDidNavigate(leaf.id, to: $0) })
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: isActive ? frame.minX : 0, y: isActive ? frame.minY : 0)
                            .opacity(isActive ? 1 : 0)
                            // AND IT TAKES NOTHING WHILE IT IS BEHIND. The
                            // hidden-but-present arrangement earns its
                            // keep only if the hidden view is inert: an
                            // overlapping stack that still answers drags
                            // is what sent two file transfers to the wrong
                            // machine.
                            .allowsHitTesting(isActive)
                            .onTapGesture { paneManager.focusLeaf(leaf.id) }
                            // NOT AN NSVIEW, so the SwiftUI destination
                            // is asked here and the AppKit one is not.
                            // The region, what it means, and the mark
                            // drawn for it are shared; only the API
                            // differs ([[WI-2026-08-17-028]]).
                            .onDrop(of: [.tabDragPayload], delegate: PaneBodyDrop(
                                size: frame.size,
                                onRegion: { region in
                                    bodyDropTarget = region.map {
                                        PaneBodyDropTarget(paneID: leaf.id, region: $0)
                                    }
                                },
                                onDrop: { paneID, region in
                                    paneManager.dockPane(paneID, onto: leaf.id, region: region)
                                }))
                            // The shape the arriving pane will TAKE, the
                            // same block the terminal surface paints —
                            // half the position for an edge, all of it
                            // for the centre.
                            // The shape the arriving pane will TAKE — the
                            // same mark the terminal surface paints, and
                            // it MOVES between regions rather than being
                            // rebuilt in place: the rectangle grows from
                            // half the pane to all of it as the pointer
                            // leaves the band.
                            .overlay(alignment: .topLeading) {
                                let over = bodyDropTarget?.paneID == leaf.id
                                let mark = PaneDragBoard.highlight(
                                    bodyDropTarget?.region ?? .stack,
                                    in: CGRect(origin: .zero, size: frame.size))
                                RoundedRectangle(cornerRadius: DropMark.cornerRadius,
                                                 style: .continuous)
                                    .fill(DS.selectionAccentSoft)
                                    .frame(width: mark.width, height: mark.height)
                                    .offset(x: mark.minX, y: mark.minY)
                                    .opacity(over ? 1 : 0)
                                    .allowsHitTesting(false)
                                    .animation(DropMark.motion, value: bodyDropTarget)
                            }
                    }
                }

                // A LEAF WHOSE CONNECTION IS NOT UP SHOWS THE DIAL, IN ITS
                // OWN PLACE ([[RFC-0015]] C-DIAL, C-FAILURE). It is drawn
                // before the terminals so a surface never appears over it,
                // and the terminal for that leaf is not created at all —
                // which is what keeps a pane with no command from spawning
                // ghostty's default LOCAL shell on a remote pane
                // (WI-2026-03-31-003).
                ForEach(paneManager.allLeaves.filter(\.content.isTerminal), id: \.id) { leaf in
                    let surface = paneManager.surface(of: leaf.id)
                    if surface != .terminal, visibleIDs.contains(leaf.id),
                       let frame = paneFrame(leaf.id) {
                        LeafConnectionView(
                            host: paneManager.host(ofLeaf: leaf.id),
                            progress: paneManager.connectProgress.progress(for: leaf.id),
                            failure: { if case .failed(let r) = surface { return r }; return nil }(),
                            taken: surface == .taken,
                            onRetry: { onRetryLeaf?(leaf.id) })
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }

                ForEach(paneManager.allLeaves.filter(\.content.isTerminal), id: \.id) { leaf in
                    // NOT CONSTRUCTED UNTIL THE CONNECTION IS UP, and this
                    // is the gate rather than `isActive` below. Gating only
                    // visibility still built the NSView, whose
                    // viewDidMoveToWindow creates the ghostty surface at
                    // once — with no command, which is the spurious LOCAL
                    // shell WI-2026-03-31-003 is about. A command that
                    // arrives afterwards cannot be applied: the surface is
                    // already made.
                    if paneManager.surface(of: leaf.id) == .terminal {
                    let isActive = visibleIDs.contains(leaf.id)
                    // LESS THE STRIP, WHILE THERE IS ONE. A notice drawn
                    // over the grid sits on the shell's first row and
                    // hides the very output it is reporting on.
                    let frame = RejoinNoticeView.paneRect(
                        paneFrame(leaf.id) ?? lastFrames[leaf.id]
                            ?? CGRect(origin: .zero, size: geo.size),
                        showing: paneManager.rejoinNotice(leaf.id) != nil)
                    let command = leaf.content.terminalCommand

                    TerminalView(
                        ghosttyApp: ghosttyApp,
                        command: command,
                        workingDirectory: leaf.workingDirectory,
                        leafID: leaf.id,
                        // Hidden panes must never steal keyboard focus
                        // (WI-2026-08-08-007); among the visible ones only
                        // the focused pane may; and only when the Terminal
                        // page is actually shown (WI-2026-08-08-032).
                        isVisiblePane: isActive,
                        // NOT WHILE ITS OWN FIND BAR IS UP. A SwiftUI
                        // `@FocusState` does not outrank AppKit's first
                        // responder, and this view takes the responder
                        // whenever it believes it is the focused leaf — so
                        // the bar opened, took SwiftUI focus, and the
                        // terminal took the keyboard straight back. Every
                        // letter of the search went to the shell.
                        isFocusedLeaf: isActive && leaf.id == focusedPaneID
                            && !paneManager.isFinding(leaf.id),
                        isTerminalPageVisible: isTerminalPageVisible,
                        dropPreview: { sources in
                            guard let first = sources.first else { return nil }
                            return dropCoordinator?.preview(dragging: first, ontoLeaf: leaf.id,
                                                            count: sources.count)
                        },
                        dropHandler: { sources in
                            dropCoordinator?.perform(dragging: sources, ontoLeaf: leaf.id) != nil
                        },
                        // DOCKING IS APPKIT'S, and this is why: a SwiftUI
                        // drop modifier on this pane is never asked,
                        // because the terminal in front of it is an
                        // NSView and AppKit finds its destination by
                        // walking the view tree ([[WI-2026-08-17-028]]).
                        paneDropHandler: { paneID, region in
                            paneManager.dockPane(paneID, onto: leaf.id, region: region)
                        }
                    )
                    // SIZED BY THE LAYOUT EVEN WHILE HIDDEN, and this is
                    // what the far side feels. A pty's size is what the
                    // attach client polls and forwards to the holder, so a
                    // pane kept at its LAST size while stacked behind
                    // another tab tells the remote nothing until the human
                    // switches to it — and then the remote reflows, which
                    // is the extra layout adjustment on every pane switch
                    // after a resize. `paneFrame` answers for a stacked
                    // pane too (it asks which SLOT holds it, not which tab
                    // is in front), so the size is available all along;
                    // only a pane in another workspace has no rect in this
                    // layout, and that is what the fallback is for.
                    //
                    // POSITION still follows visibility: an offscreen pane
                    // is parked at the origin rather than drawn where it
                    // would go.
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: isActive ? frame.minX : 0,
                            y: isActive ? frame.minY : 0)
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .onAppear { lastFrames[leaf.id] = frame }
                    .onChange(of: frame) { _, newFrame in
                        lastFrames[leaf.id] = newFrame
                    }
                    }
                }

                // A SCREEN NOTHING IS UPDATING, said by dimming it rather
                // than by writing on it.
                //
                // The content is the last true thing the session sent and
                // stays exactly as it was. This is a SCRIM over the grid,
                // not opacity ON it: the terminal is a Metal surface in an
                // NSView, and asking SwiftUI to fade that is asking the
                // compositor for something it need not honour. It takes no
                // clicks — the pane is still the human's to scroll and
                // select in ([[WI-2026-08-29-004]]).
                ForEach(paneManager.allLeaves.filter(\.content.isTerminal), id: \.id) { leaf in
                    if visibleIDs.contains(leaf.id),
                       paneManager.connectProgress.progress(for: leaf.id)?.lostSince != nil,
                       let frame = paneFrame(leaf.id) {
                        Rectangle()
                            .fill(DS.background.opacity(0.45))
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                }

                // WHETHER EACH PANE CAME BACK TO ITS WORK ([[RFC-0015]]
                // C-HONESTY). Drawn after the terminals so it sits over
                // the grid, and only where there is something to say: a
                // pane that rejoined got what it was promised.
                ForEach(paneManager.allLeaves.filter(\.content.isTerminal), id: \.id) { leaf in
                    if visibleIDs.contains(leaf.id),
                       let told = paneManager.rejoinNotice(leaf.id),
                       let frame = paneFrame(leaf.id) {
                        RejoinNoticeView(
                            told: told,
                            plan: paneManager.rejoinOffer(leaf.id),
                            // ONE ATTEMPT PER ACT OF THE HUMAN'S
                            // ([[RFC-0006]] C-RESUME-RESTORE): taking the
                            // offer dismisses the notice, so the button
                            // that typed cannot be pressed again without
                            // a fresh restart to report.
                            onResume: {
                                resumeCoordinator?.resumeNow(leafID: leaf.id)
                                paneManager.dismissRejoinNotice(leaf.id)
                            }
                        ) {
                            paneManager.dismissRejoinNotice(leaf.id)
                        }
                        .frame(width: frame.width, height: RejoinNoticeView.height)
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }

                // EVERY POSITION DRAWS ITS OWN TAB BAR, across its own top
                // edge ([[RFC-0015]] C-LAYOUT) — including one holding a
                // single pane.
                //
                // THE TAB IS WHAT THE HUMAN GRABS. Hiding the bar for a
                // lone pane saves 26pt and takes the handle with it: the
                // commonest arrangement there is becomes the one
                // arrangement that cannot be dragged anywhere, which is
                // the whole capability this model was rebuilt for. Every
                // workbench with docking draws it always, for this reason
                // and not for symmetry.
                ForEach(slots, id: \.id) { slot in
                    if let rect = slotFrames[slot.id] {
                        SlotTabBar(
                            paneManager: paneManager,
                            slot: slot,
                            agentMonitor: agentMonitor,
                            resumeCoordinator: resumeCoordinator,
                            hintState: hintState,
                            editingPaneID: $editingPaneID)
                            .frame(width: rect.width, height: SplitLayout.tabStripHeight)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }

                if layoutTree != nil {
                    ForEach(dividers) { info in
                        DraggableDivider(
                            info: info,
                            onPreview: { dividerDrag.update(info, ratio: $0) },
                            onCommit: {
                                guard let done = dividerDrag.commit() else { return }
                                paneManager.resizeSplit(splitID: done.id, ratio: done.ratio)
                            })
                    }

                    // The ghost. Drawn from the divider's own parent rect,
                    // so it starts on top of the real line and leaves it
                    // where it is until the drag ends.
                    if let inFlight = dividerDrag.active, let info = dividerDrag.info {
                        let rect = SplitLayout.previewRect(for: info, ratio: inFlight.ratio)
                        Rectangle()
                            .fill(DS.selectionAccent)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }

                    // THE PANES NOT IN FOCUS STEP BACK. A wash of the
                    // terminal theme's own background over every visible
                    // pane except the focused one; the focused pane wears
                    // nothing. This replaced a 2pt accent ring around the
                    // focused pane, which decorated the surface being read,
                    // lost its right and bottom edges to the window's, and
                    // shared its shape with the attention ring. Same scrim
                    // route as the lost-link wash above: OVER the Metal
                    // surface, never opacity on it. A pane awaiting
                    // attention is exempt — the tab already carries its
                    // mark, and receding is the one thing it must not do
                    // ([[PaneFocusPresentation]], [[WI-2026-09-02-003]]).
                    ForEach(slots.compactMap(\.activePane), id: \.id) { pane in
                        if PaneFocusPresentation.dims(
                            paneID: pane.id, focusedPaneID: focusedPaneID,
                            slotCount: slots.count,
                            awaitingAttention: paneManager.isAwaitingAttention(pane.id)),
                           let frame = paneFrame(pane.id) {
                            Rectangle()
                                .fill(DS.terminalWash.opacity(PaneFocusPresentation.dimOpacity))
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }

                    // ⌘⌃-hold position badges (WI-2026-08-09-015): the Nth
                    // POSITION answers ⌘⌃N.
                    if hintState?.level == .pane {
                        ForEach(Array(slots.prefix(9).enumerated()), id: \.element.id) { idx, slot in
                            if let frame = slotFrames[slot.id] {
                                PaneHintBadge(number: idx + 1)
                                    .offset(x: frame.minX + DS.Space.md, y: frame.minY + DS.Space.md)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
            .coordinateSpace(name: "splitArea")
            // PUBLISHED IN THE WINDOW'S OWN COORDINATE SPACE, which
            // [[ContentView]] names — so the reader can offset a view by
            // it directly, without a geometry reader of its own wrapped
            // around the bar. That wrapper cost an evening: a text field
            // inside it never took keyboard focus, and every letter of the
            // search went to the sidebar.
            .preference(
                key: FocusedPaneFramePreference.self,
                value: paneManager.activeWorkspace?.focusedPaneID
                    .flatMap { paneFrame($0) }
                    .map { rect in
                        let origin = geo.frame(in: .named("synaptyWindow"))
                        return CGRect(x: origin.minX + rect.minX,
                                      y: origin.minY + rect.minY,
                                      width: rect.width, height: rect.height)
                    })
        }
        // Pause vsync rendering for hidden workspaces/panes inside the
        // terminal page (WI-2026-08-08-013): only the visible pane set
        // keeps rendering. Runs on appear and whenever that set changes.
        .onAppear { syncSurfaceVisibility() }
        .onChange(of: paneManager.visibleLeafIDs) { _, _ in
            syncSurfaceVisibility()
        }
        // Prune lastFrames when panes close — otherwise the dictionary
        // grows for every split ever created (WI-2026-08-08-033).
        .onChange(of: paneManager.allLeaves.map(\.id)) { _, newIDs in
            let live = Set(newIDs)
            lastFrames = lastFrames.filter { live.contains($0.key) }
            // The split the human was dragging may have just closed.
            dividerDrag.dropIfGone(
                dividerIDs: paneManager.activeWorkspace?.layout.map {
                    SplitLayout.computeDividers(node: $0, in: .zero).map(\.id)
                } ?? [])
        }
    }

    /// Frame/divider computation with a (size, tree) cache — unrelated
    /// body evaluations reuse the last result (WI-2026-08-08-051).
    private func cachedLayout(
        for size: CGSize,
        tree: SplitNode?,
        zoomed: SplitNode.Slot?
    ) -> (frames: [UUID: CGRect], dividers: [SplitLayout.DividerInfo]) {
        if let cache = layoutCache.entry, cache.size == size, cache.tree == tree,
           cache.zoomed == zoomed?.id {
            return (cache.frames, cache.dividers)
        }
        let full = CGRect(origin: .zero, size: size)
        // A ZOOMED POSITION IS THE WHOLE AREA, and there is no divider to
        // drag — the tree's ratios are kept, not shown.
        let frames: [UUID: CGRect]
        let divs: [SplitLayout.DividerInfo]
        if let zoomed {
            frames = [zoomed.id: full]
            divs = []
        } else {
            frames = tree.map { SplitLayout.computeFrames(node: $0, in: full) } ?? [:]
            divs = tree.map { SplitLayout.computeDividers(node: $0, in: full) } ?? []
        }
        layoutCache.entry = (size, tree, zoomed?.id, frames, divs)
        return (frames, divs)
    }

    private func syncSurfaceVisibility() {
        ghosttyApp.setVisibleLeaves(Set(paneManager.visibleLeafIDs))
    }
}

// MARK: - Layout computation (pure functions)

enum SplitLayout {
    /// Divider info for rendering and interaction.
    struct DividerInfo: Identifiable {
        let id: UUID // matches SplitData.id
        let rect: CGRect
        let direction: SplitNode.SplitDirection
        /// The full extent of the parent split (for ratio calculation during drag).
        let parentRect: CGRect
    }

    /// The strip every position's tab bar occupies along its top edge
    /// ([[RFC-0015]] C-LAYOUT). Every position spends it, because the tab
    /// is the handle its pane is dragged by.
    static var tabStripHeight: CGFloat { DS.scaled(26) }

    /// A position's rect, less its tab strip. The pane occupying it is
    /// drawn here — never under its own tabs.
    static func contentRect(of rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY + tabStripHeight,
               width: rect.width, height: max(0, rect.height - tabStripHeight))
    }

    /// Frames keyed by SLOT id — a position is what the tree lays out, and
    /// every pane stacked in one shares its rectangle.
    static func computeFrames(node: SplitNode, in rect: CGRect) -> [UUID: CGRect] {
        // Round to integral points so fractional sizes never ping-pong
        // the layout (each pass would otherwise recompute a slightly
        // different frame → perpetual re-layout → UI jank).
        let rounded = rect.integral
        switch node {
        case .slot(let slot):
            return [slot.id: rounded]

        case .split(let data):
            let dividerSize: CGFloat = 4 // slightly wider for easier grab
            let (firstRect, secondRect) = splitRects(rounded, direction: data.direction, ratio: data.ratio, dividerSize: dividerSize)
            let first = computeFrames(node: data.first, in: firstRect)
            let second = computeFrames(node: data.second, in: secondRect)
            return first.merging(second) { _, b in b }
        }
    }

    static func computeDividers(node: SplitNode, in rect: CGRect) -> [DividerInfo] {
        // Same integral rounding as computeFrames — divider geometry must
        // sit exactly on the rendered position edges (WI-2026-08-08-027).
        let rounded = rect.integral
        switch node {
        case .slot:
            return []
        case .split(let data):
            let dividerSize: CGFloat = 4
            var dividers: [DividerInfo] = []

            let (firstRect, secondRect) = splitRects(rounded, direction: data.direction, ratio: data.ratio, dividerSize: dividerSize)

            let dividerRect: CGRect
            switch data.direction {
            case .horizontal:
                dividerRect = CGRect(x: firstRect.maxX, y: rounded.minY, width: dividerSize, height: rounded.height)
            case .vertical:
                dividerRect = CGRect(x: rounded.minX, y: firstRect.maxY, width: rounded.width, height: dividerSize)
            }
            dividers.append(DividerInfo(id: data.id, rect: dividerRect, direction: data.direction, parentRect: rounded))

            dividers += computeDividers(node: data.first, in: firstRect)
            dividers += computeDividers(node: data.second, in: secondRect)
            return dividers
        }
    }

    /// Where a divider WOULD sit at a given ratio, without moving it there.
    ///
    /// The same arithmetic `computeDividers` uses, applied to one divider's
    /// own parent rect — so the ghost a drag draws starts exactly on top of
    /// the real one instead of jumping the moment the gesture begins
    /// ([[WI-2026-08-17-002]]).
    static func previewRect(for info: DividerInfo, ratio: CGFloat) -> CGRect {
        let rect = info.parentRect.integral
        let dividerSize: CGFloat = 4
        let (first, _) = splitRects(rect, direction: info.direction,
                                    ratio: SplitNode.clampRatio(ratio),
                                    dividerSize: dividerSize)
        switch info.direction {
        case .horizontal:
            return CGRect(x: first.maxX, y: rect.minY, width: dividerSize, height: rect.height)
        case .vertical:
            return CGRect(x: rect.minX, y: first.maxY, width: rect.width, height: dividerSize)
        }
    }

    private static func splitRects(_ rect: CGRect, direction: SplitNode.SplitDirection, ratio: CGFloat, dividerSize: CGFloat) -> (CGRect, CGRect) {
        switch direction {
        case .horizontal:
            let firstWidth = (rect.width - dividerSize) * ratio
            let secondWidth = rect.width - dividerSize - firstWidth
            return (
                CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                CGRect(x: rect.minX + firstWidth + dividerSize, y: rect.minY, width: secondWidth, height: rect.height)
            )
        case .vertical:
            let firstHeight = (rect.height - dividerSize) * ratio
            let secondHeight = rect.height - dividerSize - firstHeight
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                CGRect(x: rect.minX, y: rect.minY + firstHeight + dividerSize, width: rect.width, height: secondHeight)
            )
        }
    }
}

// MARK: - Divider drag

/// A DRAG IS A LINE THE HUMAN MOVES; the split tree hears about it once.
///
/// Writing the ratio on every frame made each cell boundary the divider
/// crossed a real PTY resize of the pane beside it — and a resize rewraps
/// scrollback and repaints whatever TUI is drawing there, which in this
/// application is usually an agent mid-render. Forty columns of travel
/// cost forty reflows to arrive at one answer ([[WI-2026-08-17-002]]).
///
/// Deferred rather than live, deliberately: an editor reflows for free and
/// can afford a live sash, a terminal cannot. The preview line is what
/// keeps the deferral legible.
@MainActor @Observable final class DividerDrag {

    struct InFlight: Equatable {
        let id: UUID
        var ratio: CGFloat
    }

    private(set) var active: InFlight?
    /// Kept so the ghost can be drawn from the divider's own geometry
    /// after the committed one has been recomputed underneath it.
    private(set) var info: SplitLayout.DividerInfo?

    func update(_ info: SplitLayout.DividerInfo, ratio: CGFloat) {
        self.info = info
        active = InFlight(id: info.id, ratio: SplitNode.clampRatio(ratio))
    }

    /// The ratio to write, once. Nil when nothing is in flight — SwiftUI
    /// delivers a gesture's end more than once, and a second write would
    /// be a second resize.
    func commit() -> InFlight? {
        defer { active = nil; info = nil }
        return active
    }

    func ratio(for dividerID: UUID) -> CGFloat? {
        guard let active, active.id == dividerID else { return nil }
        return active.ratio
    }

    /// A DIVIDER THAT NO LONGER EXISTS CANNOT STILL BE BEING DRAGGED.
    ///
    /// SwiftUI delivers `onEnded` for a mouse-up, not for a gesture whose
    /// view went away — and a split can be closed from a keystroke or a
    /// process exit while the human is mid-drag. Without this the ghost
    /// line outlives the divider it belonged to and sits on the terminal
    /// until the next drag.
    func dropIfGone(dividerIDs: [UUID]) {
        guard let active, !dividerIDs.contains(active.id) else { return }
        self.active = nil
        info = nil
    }
}

struct DraggableDivider: View {
    let info: SplitLayout.DividerInfo
    /// Called while dragging: moves the ghost, touches nothing else.
    let onPreview: (CGFloat) -> Void
    /// Called on release: the one write.
    let onCommit: () -> Void
    @State private var isHovered = false

    private let grabSize: CGFloat = 12 // invisible hit area

    var body: some View {
        let isHorizontal = info.direction == .horizontal
        let centerX = info.rect.midX
        let centerY = info.rect.midY

        ZStack {
            Rectangle()
                .fill(isHovered ? DS.selectionAccent : DS.border)
                .frame(
                    width: isHorizontal ? 4 : info.rect.width,
                    height: isHorizontal ? info.rect.height : 4
                )

            // Invisible wide grab area with cursor + drag
            Rectangle()
                .fill(isHovered ? DS.selectionAccentSoft : Color.clear)
                .frame(
                    width: isHorizontal ? grabSize : info.rect.width,
                    height: isHorizontal ? info.rect.height : grabSize
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        if isHorizontal {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.resizeUpDown.push()
                        }
                    } else {
                        NSCursor.pop()
                    }
                }
        }
        .position(x: centerX, y: centerY)
        .gesture(
            DragGesture(coordinateSpace: .named("splitArea"))
                .onChanged { value in
                    // SNAPPED TO THE CELL GRID ([[WI-2026-09-02-002]]): a
                    // divider between two terminals lands on a column or
                    // row boundary, so neither pane carries a sliver of
                    // dead space along the seam. The core reports the
                    // cell size; without one, the drag is free.
                    let cell = GhosttyApp.shared?.cellSize
                    let newRatio: CGFloat
                    if isHorizontal {
                        let offset = TerminalSignals.snap(
                            value.location.x - info.parentRect.minX, toCell: cell?.width ?? 0)
                        newRatio = offset / info.parentRect.width
                    } else {
                        let offset = TerminalSignals.snap(
                            value.location.y - info.parentRect.minY, toCell: cell?.height ?? 0)
                        newRatio = offset / info.parentRect.height
                    }
                    onPreview(newRatio)
                }
                .onEnded { _ in onCommit() }
        )
    }
}
