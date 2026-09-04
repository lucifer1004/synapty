import Foundation

/// Typed coordinator protocol for terminal surface events.
/// Replaces stringly-typed NotificationCenter plumbing between
/// GhosttyNSView (AppKit) and WorkspaceManager (SwiftUI state).
/// All methods run on the main actor (the coordinator mutates SwiftUI
/// state); callers from AppKit/C callbacks hop via Task { @MainActor }.
@MainActor
protocol TerminalCoordinator: AnyObject {
    func requestSplit(direction: SplitNode.SplitDirection)
    /// One-click layout preset for the active tab (WI-2026-08-09-012).
    func applyLayout(_ preset: SplitNode.LayoutPreset)
    func requestCloseSplit()
    /// Archive the focused pane ([[RFC-0015]] C-PANE-ARCHIVE).
    func requestArchivePane()
    func requestFocusNextSlot()
    func requestFocusPreviousSlot()
    func requestNewPane()
    func requestNextPane()
    func requestPreviousPane()
    func requestSwitchWorkspace(index: Int)
    /// Three-tier direct jumps (WI-2026-08-09-015): ⌘⌥N tab, ⌘⌃N pane.
    func requestSelectPane(index: Int)
    func requestFocusSlot(index: Int)
    /// Zoom the focused position or restore the layout
    /// ([[WI-2026-09-02-006]]).
    func requestToggleZoom()
    /// Push one edge of the focused position out by a step, or give every
    /// position an even share ([[WI-2026-09-02-008]]).
    func requestResizeFocused(_ edge: SplitNode.Edge)
    func requestEqualizePositions()
    /// Arm every visible pane for broadcast, or disarm them all
    /// ([[WI-2026-09-02-010]]).
    func requestToggleBroadcast()
    func leafDidFocus(_ leafID: UUID)
    func leafDidClose(_ leafID: UUID)
    /// Shell emitted an OSC title for this leaf (WI-2026-08-09-017).
    func leafDidUpdateTitle(_ leafID: UUID, title: String)
    /// Shell reported its cwd via OSC 7 (RFC-0006 session snapshots).
    func leafDidUpdatePwd(_ leafID: UUID, pwd: String)
    /// Bell / OSC notification / agent status asked for human attention
    /// (WI-2026-08-09-021).
    func leafNeedsAttention(_ leafID: UUID)

    /// WHERE A RELATIVE NAME IN THIS PANE'S OUTPUT RESOLVES FROM — the
    /// holder's answer or the kernel's, never the one the child announced
    /// ([[RFC-0015]] C-DERIVED).
    func resolutionBase(ofLeaf leafID: UUID) -> String?

    /// ASK THE FAR SIDE WHERE IT IS STANDING, if it has not been asked.
    ///
    /// A round trip, so it cannot answer the caller: it fills in what the
    /// next question will find. `resolutionBase` stays a plain query — a
    /// getter that dials a host is a side effect nobody reading it would
    /// expect.
    func refreshRemotePwd(ofLeaf leafID: UUID)

    /// The human took an offer drawn on a recognised path: show the
    /// directory that holds it, on this pane's machine.
    @discardableResult
    func showWhereItLives(_ path: String, from leafID: UUID) -> UUID?

    /// WHAT A COMMAND WOULD ACT ON, asked so a command with no object can
    /// be shown UNAVAILABLE rather than doing nothing when its chord is
    /// pressed ([[RFC-0016]] C-DISPATCH). Two facts cover every command in
    /// the table: whether there is a pane at all, and how many positions
    /// there are to arrange.
    var hasFocusedPane: Bool { get }
    var slotCount: Int { get }
}

/// Global holder for the coordinator reference.
/// Set by ContentView, accessed by GhosttyNSView and GhosttyApp callbacks.
/// `nonisolated(unsafe)`: set once before any surface exists and never
/// mutated afterwards; all readers hop to the main actor before use.
enum TerminalCoordinatorRef {
    nonisolated(unsafe) static weak var instance: TerminalCoordinator?
}
