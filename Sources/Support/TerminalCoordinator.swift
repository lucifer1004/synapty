import Foundation

/// Typed coordinator protocol for terminal surface events.
/// Replaces stringly-typed NotificationCenter plumbing between
/// GhosttyNSView (AppKit) and TerminalPaneManager (SwiftUI state).
/// Typed coordinator protocol for terminal surface events.
/// All methods are called on the main thread via DispatchQueue.main.async.
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
enum TerminalCoordinatorRef {
    static weak var instance: TerminalCoordinator?
}
