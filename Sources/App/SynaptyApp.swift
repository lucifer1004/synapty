import SwiftUI

@main
struct SynaptyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        ghosttyApp?.shutdown()
        ghosttyApp = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
