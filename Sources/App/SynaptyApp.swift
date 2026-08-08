import SwiftUI

@main
struct SynaptyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty window title: the app name is already in the macOS menu bar,
        // and in-app branding was removed from the sidebar. No duplicate
        // "Synapty" text anywhere in the window.
        WindowGroup("") {
            ContentView()
                .environmentObject(appDelegate)
                .tint(DS.accent)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 720)
        .commands {
            SynaptyCommands()
        }
    }
}

/// Manages the single ghostty_app_t instance and its lifecycle.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var ghosttyApp: GhosttyApp?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ghosttyApp = GhosttyApp()

        // Font enumeration happens once, off the main thread, so the first
        // Settings/panel open never hitches (WI-2026-08-08-026).
        FontCatalog.warmUp()

        // Enforce a sensible minimum window size and clear any window title
        // (the app name lives in the menu bar; no in-window branding).
        for window in NSApplication.shared.windows {
            window.minSize = NSSize(width: 760, height: 480)
            window.title = ""
            window.subtitle = ""
            window.titleVisibility = .hidden
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ghosttyApp?.shutdown()
        ghosttyApp = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
