import Foundation

/// Centralized notification names for cross-component communication.
/// Used by GhosttyNSView (sender) and ContentView (receiver) for
/// split/focus/close events that bridge AppKit → SwiftUI.
extension Notification.Name {
    static let synaptyRequestSplit = Notification.Name("synaptyRequestSplit")
    static let synaptyRequestCloseSplit = Notification.Name("synaptyRequestCloseSplit")
    static let synaptyRequestFocusNextSplit = Notification.Name("synaptyRequestFocusNextSplit")
    static let synaptyRequestFocusPreviousSplit = Notification.Name("synaptyRequestFocusPreviousSplit")
    static let synaptyLeafFocused = Notification.Name("synaptyLeafFocused")
    static let synaptyLeafClosed = Notification.Name("synaptyLeafClosed")
}
