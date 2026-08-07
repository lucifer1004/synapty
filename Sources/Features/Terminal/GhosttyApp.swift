import Foundation
import AppKit

/// Wraps the single ghostty_app_t instance. One per application.
/// Ghostty internally manages PTYs, VT parsing, and Metal rendering.
@MainActor final class GhosttyApp {
    /// Singleton for clipboard callback access (C callbacks can't capture Swift context).
    static weak var shared: GhosttyApp?

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    /// The currently focused surface. Updated by GhosttyNSView when it becomes first responder.
    var activeSurface: ghostty_surface_t?
    /// All live surfaces, registered by GhosttyNSView (main-thread only).
    /// Needed for per-surface color scheme updates (WI-2026-08-07-005).
    private(set) var liveSurfaces: [ghostty_surface_t] = []

    /// Settings-change observer (live config apply).
    private var settingsObserver: NSObjectProtocol?
    /// Appearance-change observer (ghostty color scheme).
    private var appearanceObserver: NSObjectProtocol?
    /// Ghostty-initiated reload request observer.
    private var reloadObserver: NSObjectProtocol?
    /// KVO on effectiveAppearance (System mode / OS appearance changes).
    private var systemAppearanceKVO: NSKeyValueObservation?
    /// Last scheme pushed to ghostty (avoid redundant updates).
    private var appliedScheme: ghostty_color_scheme_e?

    /// Deduplicates wakeup → tick: multiple wakeups before the main queue drains
    /// result in a single tick() call, so all pending PTY output is processed at
    /// once and rendered in one frame.
    private var tickScheduled = false

    /// Load the Synapty-managed ghostty config fragment (scroll behavior,
    /// theme). The fragment is written by SynaptySettings; loaded after
    /// default files so it overrides them.
    private func loadSynaptyConfig(_ cfg: ghostty_config_t) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.config/synapty/ghostty.conf"
        path.withCString { cStr in
            ghostty_config_load_file(cfg, cStr)
        }
    }

    /// Rebuild the app config from the current fragment and propagate it to
    /// all surfaces (WI-2026-08-06-001): settings changes apply live instead
    /// of requiring an app restart.
    private func reloadConfig() {
        guard let app else { return }
        guard let newCfg = ghostty_config_new() else {
            print("Failed to create ghostty config for reload")
            return
        }
        ghostty_config_load_default_files(newCfg)
        loadSynaptyConfig(newCfg)
        ghostty_config_finalize(newCfg)
        ghostty_app_update_config(app, newCfg)
        if let config { ghostty_config_free(config) }
        config = newCfg
    }

    /// Coalesced reload scheduling (WI-2026-08-07-005): a single user
    /// action (e.g. appearance switch) cascades several reload requests
    /// (app + per-surface) within one run-loop turn. Collapse same-turn
    /// requests into ONE update with ~zero added latency; hard requests
    /// win over soft.
    private var reloadQueued = false
    private var pendingReloadIsSoft = true

    private func scheduleReload(soft: Bool) {
        pendingReloadIsSoft = pendingReloadIsSoft && soft
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadQueued = false
            let soft = self.pendingReloadIsSoft
            self.pendingReloadIsSoft = true
            guard let app = self.app else { return }
            if soft {
                if let config = self.config {
                    ghostty_app_update_config(app, config)
                }
            } else {
                self.reloadConfig()
            }
        }
    }

    init() {
        GhosttyApp.shared = self
        // macOS crashes inside ghostty_init's setlocale when LANG is a
        // locale with missing data (observed: en_CN.UTF-8 → loadlocale
        // NULL-deref in open()). Pin a safe locale for the process before
        // initializing; children (synapty run) inherit it too.
        if let lang = getenv("LANG"), String(cString: lang).contains("en_CN") {
            setenv("LANG", "en_US.UTF-8", 1)
        }

        // Initialize the Ghostty library — must be called before any other ghostty_ function
        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            print("Failed to initialize Ghostty: \(initResult)")
            return
        }

        // Create and finalize config
        guard let cfg = ghostty_config_new() else {
            print("Failed to create Ghostty config")
            return
        }
        config = cfg
        // First-launch ordering (WI-2026-08-06-001): this init can run before
        // SynaptySettings is initialized, so make sure the fragment exists.
        SynaptySettings.ensureGhosttyFragmentExists()
        ghostty_config_load_default_files(cfg)
        // Synapty-managed overrides (WI-2026-03-31-005): never force the
        // scroll position back to the bottom on keystroke/output — agents
        // produce output while the user is reading history, and snapping
        // back to bottom reads as "scroll reset".
        loadSynaptyConfig(cfg)
        ghostty_config_finalize(cfg)

        // Build runtime config with callbacks
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.wakeup_cb = { userdata in
            DispatchQueue.main.async {
                GhosttyApp.shared?.requestTick()
            }
        }
        runtime.action_cb = { app, target, action in
            // Forward search actions to the UI layer. Ghostty's core performs
            // the actual search; the embedder is responsible for the find bar
            // UI (start_search → show bar, search:<needle> drives results).
            // WI-2026-03-31-006 (Cmd+F find-in-scrollback).
            switch action.tag {
            case GHOSTTY_ACTION_START_SEARCH:
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
                NotificationCenter.default.post(name: .synaptyFind, object: nil)
                return true

            case GHOSTTY_ACTION_RELOAD_CONFIG:
                // Ghostty requests a config reload (e.g. after a color
                // scheme change — the light/dark theme pair re-resolves
                // through the conditional state). The embedded apprt
                // delegates the reload to the embedder: soft → re-apply
                // the current config so surfaces re-derive it; hard →
                // rebuild from the fragment. WI-2026-08-07-001.
                // Notification pattern: C function pointers cannot capture
                // context, so hop via NotificationCenter (like START_SEARCH).
                let isSoft = action.action.reload_config.soft
                NotificationCenter.default.post(
                    name: .synaptyReloadRequested,
                    object: nil,
                    userInfo: ["soft": isSoft]
                )
                return true

            default:
                return false
            }
        }
        runtime.close_surface_cb = { userdata, _ in
            // userdata is per-surface: a pointer to UUID (the leaf ID).
            guard let userdata else { return }
            let leafID = userdata.assumingMemoryBound(to: UUID.self).pointee
            DispatchQueue.main.async {
                TerminalCoordinatorRef.instance?.leafDidClose(leafID)
            }
        }

        // Clipboard callbacks — required for mouse selection and paste to work.
        // Without write_clipboard_cb, ghostty dereferences a null function pointer
        // when a mouse selection completes.

        runtime.write_clipboard_cb = { _, location, content, len, _ in
            guard let content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))
            var text: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)
                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        text = value
                        break
                    }
                }
                if text == nil { text = value }
            }
            guard let text else { return }
            let pb: NSPasteboard
            if location == GHOSTTY_CLIPBOARD_SELECTION {
                pb = NSPasteboard(name: .find)
            } else {
                pb = NSPasteboard.general
            }
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        // read_clipboard_cb: ghostty requests clipboard content for paste/OSC 52.
        // Uses GhosttyApp.shared.activeSurface (avoids userdata which may be per-surface).
        runtime.read_clipboard_cb = { _, location, state in
            guard let surface = GhosttyApp.shared?.activeSurface else { return false }
            let pb: NSPasteboard
            if location == GHOSTTY_CLIPBOARD_SELECTION {
                pb = NSPasteboard(name: .find)
            } else {
                pb = NSPasteboard.general
            }
            guard let str = pb.string(forType: .string) else { return false }
            str.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
        }

        // confirm_read_clipboard_cb: ghostty has content and wants user confirmation.
        // Auto-confirm in V1 (no confirmation dialog).
        runtime.confirm_read_clipboard_cb = { _, content, state, _ in
            guard let content else { return }
            guard let surface = GhosttyApp.shared?.activeSurface else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }

        // Create the Ghostty app
        app = ghostty_app_new(&runtime, config)
        if app == nil {
            print("Failed to create Ghostty app")
        }

        // Live-apply settings changes: rebuild the config from the fragment
        // and propagate to all surfaces (WI-2026-08-06-001).
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .synaptySettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleReload(soft: false)
            }
        }

        // Appearance mode (WI-2026-08-06-004): forward the resolved color
        // scheme to ghostty so terminal colors and light/dark theme
        // conditionals follow the app appearance.
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .synaptyAppearanceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyColorScheme()
            }
        }

        // Ghostty-initiated reload requests (WI-2026-08-07-001): soft →
        // re-apply current config (color scheme → light/dark theme);
        // hard → rebuild from fragment. Coalesced (WI-2026-08-07-005).
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .synaptyReloadRequested,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let soft = (note.userInfo?["soft"] as? NSNumber)?.boolValue ?? false
            Task { @MainActor in
                self?.scheduleReload(soft: soft)
            }
        }

        // System mode: keep ghostty in sync when macOS switches appearance
        // (KVO on effectiveAppearance — AppKit has no appearance notification).
        systemAppearanceKVO = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyColorScheme()
            }
        }
    }

    /// Push the resolved color scheme (settings override, else OS) to ghostty.
    private func applyColorScheme() {
        guard let app else { return }
        let scheme: ghostty_color_scheme_e
        switch NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua?: scheme = GHOSTTY_COLOR_SCHEME_DARK
        default: scheme = GHOSTTY_COLOR_SCHEME_LIGHT
        }
        // Skip if unchanged (KVO can fire redundantly on appearance sets).
        if appliedScheme == scheme { return }
        appliedScheme = scheme
        ghostty_app_set_color_scheme(app, scheme)
        // Per-surface: surfaces keep their own conditional state; without
        // this the light/dark theme pair always resolves with the initial
        // scheme (WI-2026-08-07-005).
        for surface in liveSurfaces {
            ghostty_surface_set_color_scheme(surface, scheme)
        }
    }

    /// Register a live surface (called by GhosttyNSView on creation).
    func registerSurface(_ surface: ghostty_surface_t) {
        guard !liveSurfaces.contains(where: { $0 == surface }) else { return }
        liveSurfaces.append(surface)
    }

    /// Pause vsync-driven rendering for all surfaces (WI-2026-08-07-006):
    /// hidden terminal surfaces must not keep rendering at 60fps — that
    /// saturates the GPU/window compositor and makes the whole UI feel
    /// sluggish. Display id 0 = render on wakeup only; surfaces stay alive.
    func setSurfacesPaused(_ paused: Bool) {
        for surface in liveSurfaces {
            ghostty_surface_set_display_id(surface, paused ? 0 : displayIDForSurfaces)
        }
    }

    /// Current display id for vsync rendering (re-queried per resume).
    private var displayIDForSurfaces: UInt32 {
        UInt32(NSScreen.main?.displayID ?? 0)
    }

    /// Unregister a destroyed surface (called by GhosttyNSView on destroy).
    func unregisterSurface(_ surface: ghostty_surface_t) {
        liveSurfaces.removeAll { $0 == surface }
    }

    /// Schedule a tick if one isn't already pending. Multiple wakeups between
    /// main queue drains collapse into a single tick, so all PTY output is
    /// processed at once and rendered in one display link frame.
    func requestTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickScheduled = false
            self.tick()
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func shutdown() {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
        if let reloadObserver {
            NotificationCenter.default.removeObserver(reloadObserver)
            self.reloadObserver = nil
        }
        systemAppearanceKVO?.invalidate()
        systemAppearanceKVO = nil
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
        if let config {
            ghostty_config_free(config)
            self.config = nil
        }
    }
}
