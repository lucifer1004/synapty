import SwiftUI

/// WHERE THE FOCUSED PANE IS, published from the split view so surfaces
/// drawn ABOVE the terminals can sit over it ([[WI-2026-08-20-001]]).
///
/// It has to travel: a ghostty pane is a Metal-backed NSView, so anything
/// SwiftUI draws beside it inside the split view is composited behind it
/// and cannot be seen. The find bar therefore lives at the window level —
/// and needs the frame the split view alone computes.
struct FocusedPaneFramePreference: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
