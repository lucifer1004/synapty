import AppKit
import SwiftUI

/// The sidebar toggle, in the TITLE BAR, on the same row as the window
/// buttons ([[WI-2026-08-14-008]]).
///
/// `NSTitlebarAccessoryViewController` with a leading layout attribute is
/// the system mechanism for this: AppKit places it in the titlebar after
/// the traffic lights and keeps it there. That is where Finder, Mail,
/// Notes and Xcode put their sidebar toggles, and it is a row no app
/// content can occupy — so the control cannot land on anything, and it
/// does not move when it is pressed.
///
/// EVERY EARLIER PLACEMENT PUT IT BELOW THAT ROW. The window is
/// `.hiddenTitleBar` with `fullSizeContentView`, so its safe area starts
/// content underneath the titlebar band; anything positioned from SwiftUI
/// begins there, one row too low. Reaching the band means leaving SwiftUI's
/// coordinate space, not nudging within it.
enum SidebarToggleAccessory {

    /// Install once per window. Idempotent: re-running on a window that
    /// already has one does nothing, so it is safe from the same
    /// `applicationDidFinishLaunching` sweep that sets the other window
    /// properties.
    @MainActor
    static func install(in window: NSWindow) {
        let marker = "dev.synapty.sidebar-toggle"
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier?.rawValue == marker })
        else { return }

        let controller = NSTitlebarAccessoryViewController()
        controller.identifier = NSUserInterfaceItemIdentifier(marker)
        controller.layoutAttribute = .leading
        let host = NSHostingView(rootView: SidebarToggleButton())
        // Sized here rather than by the hosting view's intrinsic content:
        // the titlebar lays accessories out against a fixed-height row,
        // and a view that reports a taller ideal size gets clipped.
        host.frame = NSRect(x: 0, y: 0, width: 30, height: 28)
        controller.view = host
        window.addTitlebarAccessoryViewController(controller)
    }
}

/// The control itself. Reads the persisted state directly so the icon and
/// the help text follow the sidebar without anything having to push them.
private struct SidebarToggleButton: View {

    @AppStorage("synapty.sidebarHidden") private var sidebarHidden = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .synaptyToggleSidebar, object: nil)
        } label: {
            Image(systemName: "sidebar.leading")
                .font(DS.Icon.control)
                .foregroundStyle(Color.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(CommandHint.help(sidebarHidden ? "Show Sidebar" : "Hide Sidebar",
                               for: "sidebar.toggle"))
        .accessibilityLabel(sidebarHidden ? "Show sidebar" : "Hide sidebar")
    }
}

/// Hands back the window this view lands in, once it lands in one.
///
/// NEITHER `applicationDidFinishLaunching` NOR `NSApp.keyWindow` is a
/// reliable moment: at launch the SwiftUI window often does not exist yet,
/// and in an `onAppear` it frequently is not key yet — the toggle went
/// missing each way. A view knows its own window as soon as it has one,
/// which is the only timing that does not depend on luck.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Accessor(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Accessor: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onWindow(window)
        }
    }
}
