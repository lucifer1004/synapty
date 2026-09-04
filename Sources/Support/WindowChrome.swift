import AppKit

/// THE CHROME A WORKBENCH WINDOW WEARS, in one place.
///
/// It was set twice: once at launch over whatever windows existed, and
/// once from a view's `onAppear`, because the `WindowGroup`'s window often
/// does not exist yet at `applicationDidFinishLaunching`
/// ([[WI-2026-08-08-033]]). The second copy had already drifted — it left
/// the title, subtitle and title visibility alone — which is what two
/// copies of a settings block do ([[WI-2026-08-28-022]]).
enum WindowChrome {

    /// WHICH WINDOWS ARE OURS. `NSApp.windows` also holds sheets, panels
    /// and whatever AppKit made for a popover, and a 760-point floor on
    /// one of those is a floor on the wrong thing. Applying the chrome is
    /// what marks a window as a workbench window.
    static let identifier = NSUserInterfaceItemIdentifier("synapty.workbench")

    static func apply(to window: NSWindow) {
        window.identifier = identifier
        applyMinimumSize(to: window)
        // The app name lives in the menu bar; no in-window branding.
        window.title = ""
        window.subtitle = ""
        window.titleVisibility = .hidden
        // Belt-and-braces for .hiddenTitleBar ([[WI-2026-08-08-090]]):
        // content extends under the transparent titlebar strip.
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // The app has its own tab bar — native window tabbing would stack
        // a second, conflicting tab strip.
        window.tabbingMode = .disallowed
    }

    /// THE FLOOR, WHICH FOLLOWS THE UI SCALE.
    ///
    /// At Extra Large the sidebar and inspector floors alone take 572 of a
    /// fixed 760, which is why the multiplication is here at all
    /// ([[WI-2026-08-15-007]]). It used to be computed once, at launch and
    /// in an `onAppear`, so a human who changed the scale afterwards could
    /// drag the window smaller than its own content needs until the next
    /// launch.
    static func applyMinimumSize(to window: NSWindow) {
        window.minSize = NSSize(width: DS.scaled(760), height: DS.scaled(480))
    }

    /// Re-floor every workbench window. Called by the one writer of the UI
    /// scale, so the floor cannot be left behind by a change to it.
    static func applyMinimumSizeToAll() {
        for window in NSApp.windows where window.identifier == identifier {
            applyMinimumSize(to: window)
        }
    }
}
