import SwiftUI
import AppKit

/// A click that knows which modifiers were held, and tells a double from a
/// single, while leaving the row draggable.
///
/// SwiftUI's `onTapGesture` reports neither fact. An overlaid NSView reports
/// both — and was tried — but a row that is ALSO a drag source cannot have
/// its mouse-down swallowed, and a view transparent enough not to swallow
/// it (`hitTest` returning nil) never receives the event either. There is no
/// setting of that dial that gives both.
///
/// So the gestures stay SwiftUI's, which coexist with `onDrag`, and the
/// modifiers are read from the event AppKit is currently dispatching — the
/// same event the gesture recogniser is acting on.
///
/// [[WI-2026-08-15-009]]
struct RowClick: ViewModifier {
    let onClick: (EventModifiers) -> Void
    let onDoubleClick: () -> Void

    func body(content: Content) -> some View {
        content
            // Double FIRST: attached in this order, SwiftUI waits for the
            // double before delivering the single, so opening a folder does
            // not also select it and leave the two fighting.
            .onTapGesture(count: 2) { onDoubleClick() }
            .onTapGesture { onClick(Self.currentModifiers()) }
            // A GESTURE HAS NO KEYBOARD PATH AT ALL — not a weak one, none.
            // A row reachable only by pointer is a row that does not exist
            // for anyone driving this from a keyboard or a screen reader,
            // and every file in the panel was such a row.
            //
            // The actions are named for what they DO rather than for the
            // gesture that used to be the only way to ask: "open" is what a
            // double click meant, and nobody navigating by keyboard should
            // have to know that.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onClick([]) }
            .accessibilityAction(named: "Open") { onDoubleClick() }
            .accessibilityAction(named: "Add to selection") { onClick([.command]) }
    }

    /// What is held right now, which during a tap's dispatch is what was
    /// held for the tap.
    static func currentModifiers() -> EventModifiers {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        var out: EventModifiers = []
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.option) { out.insert(.option) }
        return out
    }
}
