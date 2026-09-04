import AppKit
import SwiftUI

/// Double-clicking the title bar area does what the human told macOS it
/// should do.
///
/// The window is `.hiddenTitleBar` with `fullSizeContentView`, so the
/// system's own double-click handling never sees the click — the app's
/// content occupies that strip. Every other Mac app does this, so its
/// absence reads as the window being broken rather than as a feature
/// nobody wrote.
///
/// THE ACTION IS THE USER'S CHOICE, NOT OURS. System Settings offers
/// zoom, minimise, or nothing, and an app that hardcodes zoom overrides an
/// explicit preference — which is worse than not implementing this at all,
/// because it fails for exactly the people who went and changed it.
enum TitlebarAction {

    enum Kind: Equatable {
        case zoom
        case minimise
        case none
    }

    /// macOS writes this to NSGlobalDomain. An ABSENT key means the
    /// default, which is zoom — so a missing value must not read as
    /// "do nothing".
    static func kind(from preference: String?) -> Kind {
        switch preference {
        case "Minimize": return .minimise
        case "None": return .none
        // "Maximize" is the value macOS writes for the Zoom option; the
        // name is historical.
        case "Maximize": return .zoom
        case nil: return .zoom
        default: return .zoom
        }
    }

    static func current() -> Kind {
        kind(from: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"))
    }

    static func perform(on window: NSWindow?) {
        guard let window else { return }
        switch current() {
        case .zoom: window.performZoom(nil)
        case .minimise: window.performMiniaturize(nil)
        case .none: break
        }
    }
}

/// WATCHES THE WINDOW, RATHER THAN SITTING IN IT.
///
/// The catcher used to be a background behind the app's own chrome, so it
/// received only the clicks nothing in front wanted. That shape cannot
/// work here and the reason is structural rather than a layering mistake
/// anyone made: a `NavigationSplitView` builds its own `NSHostingView`
/// inside an `NSSplitView`, a subtree the window's root knows nothing
/// about, and a click there never reaches anything behind it. Measured —
/// the far side of the Hosts page hit
/// `NSHostingView<…NavigationPaneModifier…> < _NSSplitViewItemViewWrapper
/// < NSSplitView` and stopped. Every `.allowsHitTesting(false)` in the
/// world does not help, because the layer taking the click is not in the
/// same tree ([[WI-2026-09-03-015]]).
///
/// So the event is taken before the view hierarchy sees it. A local
/// monitor is what the app has that the strip does not: it is asked about
/// every mouse-down in this process, whichever subtree the point lands
/// in.
///
/// THE TRAFFIC LIGHTS ARE NOT OURS. They live in the theme frame, outside
/// the content view, and a monitor that swallowed a double click on one
/// would break closing a window by mistake — so the standard buttons'
/// frames are checked and left alone.
struct TitlebarDoubleClickCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.installMonitor()
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CatcherView: NSView {
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                guard event.clickCount == 2 else {
                    // Single clicks and drags are not ours. Passing them
                    // on is what keeps the strip draggable — swallowing
                    // them would trade one missing behaviour for another.
                    return event
                }
                let p = event.locationInWindow
                guard p.y >= window.frame.height - Self.stripHeight else { return event }
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    if let b = window.standardWindowButton(kind),
                       b.superview?.convert(b.frame, to: nil).contains(p) == true {
                        return event
                    }
                }
                TitlebarAction.perform(on: window)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// The strip a double click acts from, which is the title bar's
        /// own height and never a caller's business.
        static let stripHeight: CGFloat = 28
    }
}

extension View {
    /// Apply once to a view that lives for the window's lifetime.
    func titlebarDoubleClickToZoom() -> some View {
        background(alignment: .top) {
            TitlebarDoubleClickCatcher().frame(width: 0, height: 0)
        }
    }
}
