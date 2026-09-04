import Foundation
import CoreGraphics

/// The layout of one workspace ([[RFC-0015]] C-LAYOUT).
///
/// ONE TYPE, AND A TAB IS NOT ONE OF THEM. This was a tab bar of split
/// trees: a workspace held tabs, and every tab held a tree of its own. So
/// "these two panes share a position" — the arrangement docking exists for
/// — meant converting a split leaf into a tab that lives a level up, an
/// operation with no type to write it against.
///
/// It is a split tree of stacks instead. A slot is a POSITION; the panes
/// in it are what that position is showing, and a tab bar is what a slot
/// with more than one draws. Two panes in one slot is an arrangement.
indirect enum SplitNode: Identifiable, Equatable {
    case slot(Slot)
    case split(SplitData)

    /// WHAT A PANE IS SHOWING ([[RFC-0015]] C-CONTENT).
    ///
    /// A leaf was a terminal and nothing else, and the workbench put a
    /// host's files and its exposed web services in a fixed panel beside
    /// the layout instead — where they could not be split, moved, or set
    /// beside the terminal writing those files.
    ///
    /// All three are host-bound, so the connection binding is unchanged
    /// and answers for every one of them. Only a terminal has a command.
    enum PaneContent: Equatable {
        /// nil = ghostty's default shell.
        case terminal(command: String?)
        /// The files of this leaf's machine, and WHICH DIRECTORY it is
        /// showing.
        ///
        /// THE DIRECTORY IS THE LEAF'S, not the view's ([[RFC-0015]]
        /// C-PERSIST: a file leaf's durable state is "the directory it is
        /// showing"). It lived in the file view's own `@State`, so every
        /// time the human switched tabs the view was destroyed and the
        /// pane came back at `~` — five clicks deep on a remote machine
        /// undone by looking at something else.
        ///
        /// nil means "wherever this machine starts a human", which is the
        /// only sensible answer before the pane has been anywhere.
        case files(directory: String?)
        /// The web services exposed on this leaf's machine.
        case services
        /// A PAGE THE HUMAN ADDRESSED, on the local connection always
        /// ([[RFC-0015]] C-CONTENT).
        ///
        /// NOT A MODE OF THE SERVICES LEAF, and the reason is not
        /// stylistic: every row of that pane is bound to a named machine
        /// and a typed address is not, so one pane would have to answer
        /// "over whose network?" and could not.
        ///
        /// nil is a leaf with nothing addressed yet — it has been opened
        /// and not pointed anywhere, which is a state the human creates
        /// deliberately and the pane must have something to say about.
        case browser(address: String?)

        var terminalCommand: String? {
            guard case .terminal(let command) = self else { return nil }
            return command
        }

        /// Where a file leaf is looking, if it is one.
        var fileDirectory: String? {
            guard case .files(let directory) = self else { return nil }
            return directory
        }

        /// What a browser leaf is showing, if it is one.
        var browserAddress: String? {
            guard case .browser(let address) = self else { return nil }
            return address
        }

        /// A BROWSER LEAF IS ALWAYS ON THIS MAC ([[RFC-0015]] C-CONTENT),
        /// and the clause says in its own text that this is a STIPULATION
        /// rather than a derivation — the reasoning that suggests it does
        /// not survive its own edge case, since a human may address a
        /// forwarded port on loopback and that fetch is served over the
        /// far machine's network. Implemented as stated, not as reasoned.
        var demandsLocalConnection: Bool {
            if case .browser = self { return true }
            return false
        }

        var isTerminal: Bool {
            if case .terminal = self { return true }
            return false
        }

        /// KEPT ALIVE WHILE HIDDEN, like a terminal and for a kindred
        /// reason. A terminal holds a pty whose child must not die. A web
        /// pane holds a LOADED PAGE — scroll position, a form half filled,
        /// a session — and so does a SERVICES pane while it is viewing an
        /// exposed service, which is its own WKWebView by another name.
        /// None of that lives in the pane manager, so a rebuild is a
        /// reload and the human's work goes with it.
        ///
        /// A FILE PANE IS THE ONE THAT DOES NOT, and the difference is
        /// where the state is rather than what the pane looks like: its
        /// navigation, filter and listing are all in the manager, so
        /// rebuilding one costs nothing worth keeping. Asking what the
        /// MANAGER holds is what first put `services` on the wrong side of
        /// this line — the question is what the VIEW holds.
        var survivesHiding: Bool {
            switch self {
            case .terminal, .browser, .services: return true
            case .files: return false
            }
        }

        /// WHAT MARKS THIS KIND ON A TAB — and nil for a terminal, which
        /// is deliberate.
        ///
        /// [[WI-2026-08-09-013]] took per-tab glyphs OUT: every tab
        /// repeated the same one and it was pure noise in a multi-tab row.
        /// That finding still holds; what changed is that a leaf is no
        /// longer necessarily a terminal ([[RFC-0015]] C-CONTENT), so a
        /// glyph now DISTINGUISHES rather than repeats.
        ///
        /// The terminal stays unmarked because it is the default: marking
        /// every kind would restore the noise, and a mark that appears on
        /// three tabs in twenty is one the eye can actually use.
        var tabIcon: String? {
            switch self {
            case .terminal: return nil
            case .files: return "folder"
            // THE GLOBE MOVED. It marked the services leaf while that was
            // the only kind showing a page; a browser leaf is the one a
            // human reads as "the web", so the services leaf takes the
            // mark of what it actually is — what a machine is offering.
            case .services: return "antenna.radiowaves.left.and.right"
            case .browser: return "globe"
            }
        }

        /// What this kind is called, for the places a name is better than
        /// a glyph — a tooltip, an accessibility label, a menu.
        var kindName: String {
            switch self {
            case .terminal: return "Terminal"
            case .files: return "Files"
            case .services: return "Services"
            case .browser: return "Browser"
            }
        }

        /// The kind without its runtime detail. A stored command names a
        /// wrapper invocation from a previous launch and is minted fresh
        /// on restore, so persisting one would record something that is
        /// already false — only the KIND is durable.
        var kindOnly: PaneContent {
            isTerminal ? .terminal(command: nil) : self
        }
    }

    /// The atom of the layout: one surface, what it shows, and the
    /// machine it is on. Every layout operation moves one of these.
    struct Pane: Identifiable, Equatable {
        private(set) var id: UUID
        var label: String
        /// The user renamed this pane — their name wins over shell titles
        /// permanently (WI-2026-08-09-017).
        var userRenamed = false
        /// WHAT THIS PANE SHOWS. The KIND is fixed at creation
        /// ([[RFC-0015]] C-CONTENT) and nothing here can change it; only
        /// a terminal's command may arrive later, because a pane bound to
        /// a host exists before its dial finishes and has nothing to run
        /// until it does ([[RFC-0015]] C-DIAL).
        private(set) var content: PaneContent
        /// Where the surface starts (RFC-0006 — layout AND cwd come
        /// back). nil = ghostty default.
        ///
        /// FIXED WHILE THE PANE IS IN THE TREE, where the leaf's facts
        /// carry the current directory instead and this is only what it
        /// was opened in. It moves once, on the way out — see
        /// `willReopen(in:)`.
        private(set) var workingDirectory: String?
        /// WHICH MACHINE THIS PANE IS ON, asked of the pane and never of
        /// the tree it is sitting in ([[RFC-0015]] C-LEAF-BINDING).
        ///
        /// Required rather than defaulted: a pane that forgot to say
        /// would be one whose host is decided by wherever it landed.
        let connectionID: UUID

        /// THE COMMAND ARRIVES AFTER THE PANE DOES. A leaf bound to a
        /// host is created and shown while its connection is still being
        /// dialled, so it is created with nothing to run and is given the
        /// wrapper invocation when the dial returns.
        ///
        /// ONLY THE COMMAND. This cannot change a pane's kind, which
        /// [[RFC-0015]] C-CONTENT fixes at creation — a conversion is a
        /// close and an open, not a mutation.
        /// A file leaf moved. Like `start(command:)` this changes the
        /// leaf's STATE and never its KIND — [[RFC-0015]] C-CONTENT fixes
        /// the kind at creation, and a pane that became something else
        /// would be a new pane wearing an old identity.
        mutating func navigateFiles(to directory: String) {
            guard case .files = content else { return }
            content = .files(directory: directory)
        }

        /// A browser leaf went somewhere. Its ADDRESS is state and its
        /// KIND is not — the same split the file leaf's directory makes.
        mutating func navigateBrowser(to address: String) {
            guard case .browser = content else { return }
            content = .browser(address: address)
        }

        mutating func start(command: String) {
            guard case .terminal = content else { return }
            content = .terminal(command: command)
        }

        /// WHERE IT WILL OPEN NEXT TIME, set as it leaves the tree.
        ///
        /// A pane IN the tree has a leaf, and where its shell actually is
        /// is read off that leaf's facts. A pane that leaves — archived
        /// ([[RFC-0015]] C-PANE-ARCHIVE) — has no leaf to read, and every
        /// branch of the workbench's `pwd(ofLeaf:)` asks about one. So
        /// the last known directory is written onto the value at the
        /// moment it goes, which is the only thing that still knows it:
        /// it is what the row shows, what the snapshot records, and where
        /// the pane reopens when it is returned.
        mutating func willReopen(in directory: String?) {
            workingDirectory = directory
        }

        init(label: String = "Shell", content: PaneContent,
             workingDirectory: String? = nil, connectionID: UUID) {
            self.id = UUID()
            self.label = label
            self.content = content
            self.workingDirectory = workingDirectory
            self.connectionID = connectionID
        }

        /// A terminal, which is what most panes are.
        init(label: String = "Shell", command: String? = nil,
             workingDirectory: String? = nil, connectionID: UUID) {
            self.init(label: label, content: .terminal(command: command),
                      workingDirectory: workingDirectory, connectionID: connectionID)
        }

        /// THE SAME PANE ON A DIFFERENT CONNECTION. Its identity, name and
        /// content are kept — an archived pane that comes back is the pane
        /// that left, pointed at the connection acquired for its return
        /// ([[RFC-0015]] C-PANE-ARCHIVE).
        func rebound(to connectionID: UUID) -> Pane {
            var copy = Pane(label: label, content: content,
                            workingDirectory: workingDirectory, connectionID: connectionID)
            copy.id = id
            copy.userRenamed = userRenamed
            return copy
        }
    }

    /// A POSITION IN THE LAYOUT, and the stack of panes occupying it.
    /// Never empty: a slot that loses its last pane collapses into its
    /// sibling rather than lingering as a hole.
    struct Slot: Identifiable, Equatable {
        let id: UUID
        private(set) var panes: [Pane]
        var activePaneID: UUID

        /// More than one pane occupies this position, so its tab bar has
        /// something to choose between.
        ///
        /// NOT WHETHER THE BAR IS DRAWN. Every position draws one, because
        /// the tab is what the human GRABS: a position that hid its bar
        /// when it held a single pane left that pane with nothing to take
        /// hold of, and the drag this whole model exists to permit could
        /// not be started on the commonest arrangement there is
        /// ([[RFC-0015]] C-LAYOUT).
        var isStacked: Bool { panes.count > 1 }

        var activePane: Pane? { panes.first { $0.id == activePaneID } }

        init(pane: Pane) {
            self.id = UUID()
            self.panes = [pane]
            self.activePaneID = pane.id
        }

        init(panes: [Pane], activePaneID: UUID? = nil) {
            precondition(!panes.isEmpty, "a slot is never empty")
            self.id = UUID()
            self.panes = panes
            self.activePaneID = activePaneID ?? panes[0].id
        }

        /// Put a pane in this position. What was just placed comes to the
        /// front, because the human asked for it.
        mutating func stack(_ pane: Pane, at index: Int? = nil) {
            let i = index.map { min(max(0, $0), panes.count) } ?? panes.count
            panes.insert(pane, at: i)
            activePaneID = pane.id
        }

        /// Take a pane out. The slot may be left EMPTY, which is a state
        /// it may not stay in — whoever holds it collapses it, because
        /// only they have a sibling to collapse into.
        mutating func remove(_ paneID: UUID) {
            guard let i = panes.firstIndex(where: { $0.id == paneID }) else { return }
            panes.remove(at: i)
            guard !panes.isEmpty else { return }
            if activePaneID == paneID {
                activePaneID = panes[min(i, panes.count - 1)].id
            }
        }

        mutating func update(_ paneID: UUID, _ change: (inout Pane) -> Void) {
            guard let i = panes.firstIndex(where: { $0.id == paneID }) else { return }
            change(&panes[i])
        }
    }

    struct SplitData: Identifiable, Equatable {
        let id: UUID
        let direction: SplitDirection
        /// Split ratio (0.0–1.0). First child gets `ratio` of the space.
        var ratio: CGFloat
        var first: SplitNode
        var second: SplitNode

        init(direction: SplitDirection, first: SplitNode, second: SplitNode, ratio: CGFloat = 0.5) {
            self.id = UUID()
            self.direction = direction
            self.ratio = ratio
            self.first = first
            self.second = second
        }
    }

    enum SplitDirection {
        case horizontal // side by side (split right/left)
        case vertical   // stacked (split down/up)
    }

    var id: UUID {
        switch self {
        case .slot(let s): return s.id
        case .split(let d): return d.id
        }
    }

    /// Every position in this subtree, in order.
    var slots: [Slot] {
        switch self {
        case .slot(let s): return [s]
        case .split(let d): return d.first.slots + d.second.slots
        }
    }

    /// Every pane in this subtree, in order — across all positions and all
    /// their stacks.
    var panes: [Pane] { slots.flatMap(\.panes) }

    var paneIDs: [UUID] { panes.map(\.id) }

    /// The pane the human is looking at in each position.
    var activePanes: [Pane] { slots.compactMap(\.activePane) }

    func findPane(_ id: UUID) -> Pane? {
        panes.first { $0.id == id }
    }

    func slot(containing paneID: UUID) -> Slot? {
        slots.first { $0.panes.contains { $0.id == paneID } }
    }

    func slot(_ id: UUID) -> Slot? { slots.first { $0.id == id } }

    // MARK: - The four operations

    /// Put a pane into an existing position. THIS IS THE DROP-ON-CENTRE:
    /// one operation on one type, which is what the old shape could not
    /// express.
    func stack(_ pane: Pane, intoSlot slotID: UUID, at index: Int? = nil) -> SplitNode {
        switch self {
        case .slot(var s):
            guard s.id == slotID else { return self }
            s.stack(pane, at: index)
            return .slot(s)
        case .split(var d):
            d.first = d.first.stack(pane, intoSlot: slotID, at: index)
            d.second = d.second.stack(pane, intoSlot: slotID, at: index)
            return .split(d)
        }
    }

    /// Make a new position beside this one, holding `newPane`. Returns the
    /// tree and the new slot's id.
    ///
    /// `before` puts the new position on the NEAR side — left of a
    /// horizontal split, above a vertical one. The children of a split are
    /// ordered, so without it the left edge of a pane and its right edge
    /// produce the same arrangement, and half the docking gesture is
    /// silently the other half ([[WI-2026-08-17-028]]).
    func splitSlot(_ slotID: UUID, direction: SplitDirection,
                   newPane: Pane, before: Bool = false) -> (SplitNode, UUID?) {
        switch self {
        case .slot(let s):
            guard s.id == slotID else { return (self, nil) }
            let created = Slot(pane: newPane)
            let data = before
                ? SplitData(direction: direction, first: .slot(created), second: self)
                : SplitData(direction: direction, first: self, second: .slot(created))
            return (.split(data), created.id)
        case .split(var d):
            let (first, a) = d.first.splitSlot(slotID, direction: direction,
                                               newPane: newPane, before: before)
            d.first = first
            if let a { return (.split(d), a) }
            let (second, b) = d.second.splitSlot(slotID, direction: direction,
                                                 newPane: newPane, before: before)
            d.second = second
            return (.split(d), b)
        }
    }

    /// Result of removing a pane: the tree it leaves behind, or the pane
    /// was NOT there. Callers must not treat "not found" as a successful
    /// removal — the old API returned a structurally identical copy for
    /// that case and callers moved focus anyway (WI-2026-08-08-033).
    enum RemoveResult: Equatable {
        case removed(SplitNode)
        case notFound
    }

    /// Take a pane out. A slot emptied by it collapses into its sibling.
    func removePane(_ paneID: UUID) -> RemoveResult {
        switch self {
        case .slot(var s):
            guard s.panes.contains(where: { $0.id == paneID }) else { return .notFound }
            // An emptied slot comes back EMPTY and is collapsed by the
            // split holding it — or, at the root, by the workspace, which
            // is the only level with anywhere else to put the answer.
            s.remove(paneID)
            return .removed(.slot(s))
        case .split(var d):
            switch d.first.removePane(paneID) {
            case .removed(let first):
                d.first = first
                return .removed(collapsed(d) ?? .split(d))
            case .notFound: break
            }
            switch d.second.removePane(paneID) {
            case .removed(let second):
                d.second = second
                return .removed(collapsed(d) ?? .split(d))
            case .notFound: return .notFound
            }
        }
    }

    /// A child that lost its last pane is gone; the split becomes its
    /// sibling.
    private func collapsed(_ d: SplitData) -> SplitNode? {
        if d.first.panes.isEmpty { return d.second }
        if d.second.panes.isEmpty { return d.first }
        return nil
    }

    /// Change a pane in place, wherever it is.
    func updating(_ paneID: UUID, _ change: (inout Pane) -> Void) -> SplitNode {
        switch self {
        case .slot(var s):
            s.update(paneID, change)
            return .slot(s)
        case .split(var d):
            d.first = d.first.updating(paneID, change)
            d.second = d.second.updating(paneID, change)
            return .split(d)
        }
    }

    /// Bring a pane to the front of its own position.
    func focusing(_ paneID: UUID) -> SplitNode {
        switch self {
        case .slot(var s):
            if s.panes.contains(where: { $0.id == paneID }) { s.activePaneID = paneID }
            return .slot(s)
        case .split(var d):
            d.first = d.first.focusing(paneID)
            d.second = d.second.focusing(paneID)
            return .split(d)
        }
    }

    /// What a split may be dragged to. Named once because the preview line
    /// a drag draws has to stop where the commit would stop — a ghost that
    /// slides past the limit promises an edge that jumps back on release
    /// ([[WI-2026-08-17-002]]).
    static let ratioRange: ClosedRange<CGFloat> = 0.1...0.9

    static func clampRatio(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    // MARK: - Resizing from the keyboard ([[WI-2026-09-02-008]])

    /// One of a position's four edges, named the way the arrow keys do.
    enum Edge { case left, right, up, down }

    /// PUSH THIS EDGE OUT. The split that owns a position's edge is the
    /// nearest ancestor on that axis in which the position sits on the
    /// near side — for the right edge, the nearest horizontal split with
    /// the position in its FIRST child, whose divider is that edge; for
    /// the left edge, the nearest with it in the SECOND. Pushing the edge
    /// moves that divider by `step` of the split's extent, clamped as a
    /// drag is. A position whose edge is the window's has no such split
    /// and the tree is returned unchanged: there is nothing to push.
    /// tmux's resize-pane -R, ghostty's resize_split:right.
    func pushingEdge(_ edge: Edge, ofSlot slotID: UUID, by step: CGFloat) -> SplitNode {
        let axis: SplitDirection = (edge == .left || edge == .right) ? .horizontal : .vertical
        let nearSideIsFirst = (edge == .right || edge == .down)
        guard let owner = owningSplit(ofEdge: axis, nearSideIsFirst: nearSideIsFirst, slotID: slotID)
        else { return self }
        var out = self
        out.setRatio(splitID: owner.id, ratio: owner.ratio + (nearSideIsFirst ? step : -step))
        return out
    }

    /// The innermost split on `axis` whose `first` (or `second`) child
    /// contains the position — innermost, because the divider nearest the
    /// pane is the one the human means by "its edge".
    private func owningSplit(ofEdge axis: SplitDirection, nearSideIsFirst: Bool,
                             slotID: UUID) -> SplitData? {
        guard case .split(let data) = self else { return nil }
        let inFirst = data.first.slot(slotID) != nil
        let inSecond = data.second.slot(slotID) != nil
        guard inFirst || inSecond else { return nil }
        let child = inFirst ? data.first : data.second
        if let deeper = child.owningSplit(ofEdge: axis, nearSideIsFirst: nearSideIsFirst, slotID: slotID) {
            return deeper
        }
        if data.direction == axis, inFirst == nearSideIsFirst { return data }
        return nil
    }

    /// EVERY POSITION ITS FAIR SHARE: each split's ratio becomes the
    /// share of positions under its first child, so a chain of three
    /// columns comes out in thirds rather than a half and two quarters.
    /// Ratios only — positions, panes and order are untouched.
    func equalised() -> SplitNode {
        guard case .split(var data) = self else { return self }
        data.first = data.first.equalised()
        data.second = data.second.equalised()
        let first = CGFloat(data.first.slots.count), total = first + CGFloat(data.second.slots.count)
        data.ratio = SplitNode.clampRatio(first / total)
        return .split(data)
    }

    /// Update the split ratio for a split node by ID. Clamps to `ratioRange`.
    mutating func setRatio(splitID: UUID, ratio: CGFloat) {
        switch self {
        case .slot:
            break
        case .split(var data):
            if data.id == splitID {
                data.ratio = SplitNode.clampRatio(ratio)
                self = .split(data)
            } else {
                data.first.setRatio(splitID: splitID, ratio: ratio)
                data.second.setRatio(splitID: splitID, ratio: ratio)
                self = .split(data)
            }
        }
    }

    // MARK: - Layout presets (WI-2026-08-09-012)

    /// One-click arrangements for the panes of a tab. Rearrange-only:
    /// presets fold the EXISTING leaves into a new tree shape.
    enum LayoutPreset: String, CaseIterable {
        case columns
        case rows
        case grid
        case mainStack

        var label: String {
            switch self {
            case .columns: return "Columns"
            case .rows: return "Rows"
            case .grid: return "Grid"
            case .mainStack: return "Main + Stack"
            }
        }

        var sfSymbol: String {
            switch self {
            case .columns: return "rectangle.split.3x1"
            case .rows: return "rectangle.split.1x2"
            case .grid: return "rectangle.split.2x2"
            case .mainStack: return "rectangle.leadinghalf.inset.filled"
            }
        }
    }

    /// Fold the existing POSITIONS into the preset's shape. Slots are
    /// reused verbatim, so every pane keeps its id — and with it its
    /// ghostty surface and pty — and any stack rides along with the slot
    /// holding it. Split nodes are new (new divider ids), which is inert.
    static func arranged(slots: [SplitNode.Slot], preset: LayoutPreset) -> SplitNode {
        precondition(!slots.isEmpty, "arranged() needs at least one position")
        switch preset {
        case .columns:
            return stacked(slots, direction: .horizontal)
        case .rows:
            return stacked(slots, direction: .vertical)
        case .grid:
            // Rows of two; an odd trailing position becomes a full-width row.
            let pairs = stride(from: 0, to: slots.count, by: 2).map {
                Array(slots[$0..<min($0 + 2, slots.count)])
            }
            let rows = pairs.map { stacked($0, direction: .horizontal) }
            return stackedNodes(rows, direction: .vertical)
        case .mainStack:
            guard slots.count > 1 else { return .slot(slots[0]) }
            return .split(SplitData(
                direction: .horizontal,
                first: .slot(slots[0]),
                second: stacked(Array(slots.dropFirst()), direction: .vertical),
                ratio: 0.65
            ))
        }
    }

    /// Equal-share nested splits: the first position takes 1/n, the
    /// remainder recurse over the rest.
    private static func stacked(_ slots: [SplitNode.Slot], direction: SplitDirection) -> SplitNode {
        stackedNodes(slots.map { .slot($0) }, direction: direction)
    }

    private static func stackedNodes(_ nodes: [SplitNode], direction: SplitDirection) -> SplitNode {
        precondition(!nodes.isEmpty)
        if nodes.count == 1 { return nodes[0] }
        return .split(SplitData(
            direction: direction,
            first: nodes[0],
            second: stackedNodes(Array(nodes.dropFirst()), direction: direction),
            ratio: 1.0 / CGFloat(nodes.count)
        ))
    }

    /// Focus navigation walks POSITIONS, taking whichever pane each one
    /// is showing. Cycling through every pane in every stack would make
    /// the shortcut visit panes the human cannot see.
    func nextPane(after paneID: UUID) -> UUID? {
        step(from: paneID, by: 1)
    }

    func previousPane(before paneID: UUID) -> UUID? {
        step(from: paneID, by: -1)
    }

    private func step(from paneID: UUID, by delta: Int) -> UUID? {
        let positions = slots
        guard positions.count > 1,
              let here = positions.firstIndex(where: { $0.panes.contains { $0.id == paneID } })
        else { return nil }
        let next = (here + delta + positions.count) % positions.count
        return positions[next].activePaneID
    }
}
