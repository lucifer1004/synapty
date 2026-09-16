import SwiftUI

@main
struct SynaptyApp: App {

    init() {
        // Classify-by-lifetime migration (WI-2026-08-13-003). Runs before
        // anything can read a config path, so a first launch after the
        // upgrade finds its files where the new layout expects them.
        ConfigPaths.migrate()
    }
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty window title: the app name is already in the macOS menu bar.
        WindowGroup("") {
            ContentView()
                .tint(DS.selectionAccent)
        }
        // Hidden title bar + full-size content (WI-2026-08-08-090): the
        // sidebar's vibrancy runs to the window top and the traffic lights
        // float over it — the Finder/Notes/Ghostty window idiom. The
        // transparent titlebar strip still handles window dragging.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        .commands {
            SynaptyCommands()
        }
    }
}

/// Manages the single ghostty_app_t instance and its lifecycle.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var ghosttyApp: GhosttyApp?
    /// Cmd+K local monitor token (WI-2026-08-09-003).
    /// ⌘⌥N / ⌘⌃N tier-switch monitor token (WI-2026-08-09-015).

    func applicationDidFinishLaunching(_ notification: Notification) {
        ghosttyApp = GhosttyApp()

        // WITHOUT THIS THE PROCESS HAS NO PUSH TOKEN, so CloudKit's silent
        // pushes cannot be delivered and CKSyncEngine only learns of a
        // remote change when it next fetches on its own schedule — a
        // change on one Mac takes minutes to appear on another
        // ([[WI-2026-08-14-011]]). The CloudKit header states the engine
        // "requires the CloudKit and Remote notifications entitlements"
        // and populates its unfetched-zone list itself "when receiving a
        // push notification", so nothing needs forwarding to it; the app
        // only has to be registered. The entitlement was already declared.
        NSApplication.shared.registerForRemoteNotifications()

        // WARM THE BUILD IDENTITY OFF THE MAIN THREAD. Resolving it spawns
        // `synapty version` and waits — 15ms here, and a synchronous
        // process spawn is exactly the kind of cost that becomes 300ms on
        // a loaded machine. It is a lazy `static let`, so whichever side
        // gets there first computes it and the other finds it done; the
        // main thread never pays more than it does today, and usually
        // pays nothing.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = HubManager.expectedBuild
        }

        // EVERY CHORD THIS WORKBENCH ANSWERS TO, IN ONE PLACE
        // ([[RFC-0016]] C-TABLE). Two monitors stood here — one for the
        // palette, one for the ⌘⌥N / ⌘⌃N jumps — and a switch in the
        // terminal view held fourteen more, with ten chords written in
        // both. Which one ran depended on whether a terminal held first
        // responder, a fact with no pixel on screen.
        //
        // A MONITOR STILL, and for the reason those two were: it runs
        // before the window dispatches, and `performKeyEquivalent` on the
        // terminal view answers YES to every command-modified equivalent
        // it is offered, so nothing downstream of it can be the authority.
        // What changed is that there is now exactly one, and it decides
        // nothing itself — it asks the table.
        KeyDispatcher.shared.install()

        // Font enumeration happens once, off the main thread, so the first
        // Settings/panel open never hitches (WI-2026-08-08-026).
        FontCatalog.warmUp()

        // ONE OWNER for what a workbench window looks like
        // ([[WindowChrome]]): this ran at launch and a near-copy ran from
        // ContentView's onAppear, and the two had drifted.
        for window in NSApplication.shared.windows {
            WindowChrome.apply(to: window)
        }
    }

    /// Logged, not ignored: a registration that failed is invisible
    /// otherwise, and its only symptom is sync being slow — which reads as
    /// a sync problem rather than a missing token.
    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        AppLog.sync.info("registered for remote notifications — CloudKit pushes can reach this app")
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLog.sync.error(
            "not registered for remote notifications: \(error.localizedDescription, privacy: .public) — sync still converges, but only when the engine next fetches on its own schedule")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // BEFORE the terminal teardown, and deliberately: these are ssh
        // control commands on masters that outlive this process, so they
        // must go out while there is still a runloop to send them.
        PortForwardService.shared?.withdrawEverything()
        // AND THEN THE CONNECTIONS THEMSELVES — in that order, because the
        // withdrawals above ride these masters and a closed one cannot
        // carry them.
        //
        // ControlPersist=yes means nothing reaps a master for us, so every
        // one this application opened outlived it: an authenticated
        // connection to each of the human's machines, held open with
        // nothing watching, until the Mac rebooted.
        //
        // The cost is a re-authentication on the next launch, which is
        // real now that restored workspaces dial on their own. It is the
        // right side of the trade: a capability that outlives the process
        // that made it is the thing this codebase refuses everywhere else.
        if let tunnels = TunnelManager.shared, let hosts = tunnels.hostStore?.hosts {
            tunnels.closeAllMasters(hosts: hosts)
        }
        ghosttyApp?.shutdown()
        ghosttyApp = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
