import Foundation

/// Typed coordinator protocol for terminal surface events.
/// Replaces stringly-typed NotificationCenter plumbing between
/// GhosttyNSView (AppKit) and TerminalPaneManager (SwiftUI state).
/// All methods run on the main actor (the coordinator mutates SwiftUI
/// state); callers from AppKit/C callbacks hop via Task { @MainActor }.
@MainActor
protocol TerminalCoordinator: AnyObject {
    func requestSplit(direction: SplitNode.SplitDirection)
    func requestCloseSplit()
    func requestFocusNextSplit()
    func requestFocusPreviousSplit()
    func requestNewTab()
    func requestNextTab()
    func requestPreviousTab()
    func requestSwitchSession(index: Int)
    func leafDidFocus(_ leafID: UUID)
    func leafDidClose(_ leafID: UUID)
}

/// Global holder for the coordinator reference.
/// Set by ContentView, accessed by GhosttyNSView and GhosttyApp callbacks.
/// `nonisolated(unsafe)`: set once before any surface exists and never
/// mutated afterwards; all readers hop to the main actor before use.
enum TerminalCoordinatorRef {
    nonisolated(unsafe) static weak var instance: TerminalCoordinator?
}
