import Foundation
import AppKit

/// Wraps the single ghostty_app_t instance. One per application.
/// Ghostty internally manages PTYs, VT parsing, and Metal rendering.
@MainActor final class GhosttyApp {
    /// Singleton for clipboard callback access (C callbacks can't capture Swift context).
    static weak var shared: GhosttyApp?

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    /// The currently focused surface. Updated by GhosttyNSView when it
    /// becomes first responder (visible focused leaf only).
    var activeSurface: ghostty_surface_t?
    /// The GhosttyNSView currently holding keyboard focus — the redirect
    /// target when a hidden surface tries to steal focus (WI-2026-08-08-007).
    weak var activeView: GhosttyNSView?
    /// All live surfaces, registered by GhosttyNSView (main-thread only).
    /// Needed for per-surface color scheme updates (WI-2026-08-07-005).
    private(set) var liveSurfaces: [ghostty_surface_t] = []
    /// EVERYTHING KEYED BY LEAF, in one record.
    ///
    /// There were three maps — the surface, the search results and the
    /// last human keystroke — and `unregisterSurface` pruned one of them.
    /// The other two outlived every pane the human closed, for the life of
    /// the process; `clearSearchResults(forLeaf:)` existed to prune one
    /// and had no caller at all ([[WI-2026-08-28-018]]). One record cannot
    /// be half-forgotten, which is a stronger guarantee than three prunes
    /// that have to agree.
    ///
    /// THE RECORD BELONGS TO THE LEAF, NOT THE SURFACE. A surface can be
    /// destroyed and made again while the pane stays — a layout change
    /// does exactly that — so `unregisterSurface` clears only the surface,
    /// and `forgetLeaf` drops the record when the PANE is finished with.
    private struct LeafState {
        var surface: ghostty_surface_t?
        var search = SearchResults()
        var lastHumanInputAt: Date?
        /// The NSView holding the surface — the scrollbar overlay lives
        /// on it, and the action that feeds the overlay arrives with a
        /// SURFACE in hand. Weak via the box: this map must never keep a
        /// closed pane's view alive.
        var view: WeakViewBox?
    }

    final class WeakViewBox {
        weak var view: GhosttyNSView?
        init(_ view: GhosttyNSView) { self.view = view }
    }

    private var leaves: [UUID: LeafState] = [:]

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
    /// Set once app teardown begins (applicationWillTerminate): the app
    /// free destroys every surface, so late GhosttyNSView deinit must skip
    /// ghostty_surface_free on the freed pointers (WI-2026-08-08-015).
    private(set) var isShuttingDown = false

    /// Deduplicates wakeup → tick: multiple wakeups before the main queue drains
    /// result in a single tick() call, so all pending PTY output is processed at
    /// once and rendered in one frame.
    private var tickScheduled = false

    /// Load the Synapty-managed ghostty config fragment (scroll behavior,
    /// theme). The fragment is written by SynaptySettings; loaded after
    /// default files so it overrides them.
    private func loadSynaptyConfig(_ cfg: ghostty_config_t) {

        let path = ConfigPaths.ghosttyConfig.path
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
        // A hard reload re-resolves the config (theme conditionals etc.) —
        // the scheme guard is a cache with no other invalidation hook, so
        // it can go stale after a rebuild (WI-2026-08-08-027).
        appliedScheme = nil
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
        // The window content may render before applicationDidFinishLaunching
        // (window restoration, macOS 26); shared is a plain static var that
        // SwiftUI does not observe, so the "Initializing terminal…"
        // placeholder would stick until an unrelated body recompute
        // (WI-2026-08-08-079).
        NotificationCenter.default.post(name: .synaptyGhosttyReady, object: nil)
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
        // No app-level userdata: every callback below reaches this object
        // through `GhosttyApp.shared` or the per-surface leaf pointer, so a
        // pointer nobody read was one more thing to keep alive.
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

            // HOW MANY MATCHES, AND WHICH ONE — the two facts that make a
            // find bar a find bar rather than a text field. Ghostty counts
            // and selects; it reports both here, per surface, and the bar
            // reads them back ([[WI-2026-08-20-001]]).
            case GHOSTTY_ACTION_SEARCH_TOTAL:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else { return false }
                let total = Int(action.action.search_total.total)
                Task { @MainActor in
                    GhosttyApp.shared?.noteSearch(surface: surface, total: total)
                }
                return true

            // Where the viewport sits in the scrollback. Ghostty reports
            // this on every change; it was dropped on the floor, which is
            // why the terminal was the one scrolling surface in the app
            // with no scrollbar ([[WI-2026-09-02-001]]).
            case GHOSTTY_ACTION_SCROLLBAR:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else { return false }
                let bar = action.action.scrollbar
                let (total, offset, len) = (Int(bar.total), Int(bar.offset), Int(bar.len))
                Task { @MainActor in
                    GhosttyApp.shared?.noteScrollbar(
                        surface: surface, total: total, offset: offset, len: len)
                }
                return true

            // THE POINTER OVER A TERMINAL. Text wants an I-beam, a link
            // wants a hand, and until this case existed the pane showed
            // an arrow over everything ([[WI-2026-09-02-002]]).
            case GHOSTTY_ACTION_MOUSE_SHAPE:
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
                let shape = action.action.mouse_shape
                let shapeSurface = target.target.surface
                DispatchQueue.main.async {
                    GhosttyApp.shared?.view(forSurface: shapeSurface)?.setPointer(shape)
                }
                return true

            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
                let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
                DispatchQueue.main.async {
                    if hidden { NSCursor.setHiddenUntilMouseMoves(true) }
                }
                return true

            // A PASSWORD PROMPT turns on Secure Keyboard Entry, the way
            // Terminal.app and ghostty's own app do.
            case GHOSTTY_ACTION_SECURE_INPUT:
                // PER SURFACE ([[WI-2026-09-02-019]]): secure entry stays on
                // while any pane still asks for it.
                guard target.tag == GHOSTTY_TARGET_SURFACE, let asking = target.target.surface else { return false }
                let mode = action.action.secure_input
                let key = UnsafeRawPointer(asking)
                DispatchQueue.main.async { SecureInput.apply(mode, surface: key) }
                return true

            // SHELL INTEGRATION SAYS A COMMAND FINISHED, with its exit
            // code and how long it ran. A long build ending in a pane the
            // human is not looking at rings that pane's bell.
            case GHOSTTY_ACTION_COMMAND_FINISHED:
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
                let finished = action.action.command_finished
                let exit = Int(finished.exit_code)
                let seconds = TimeInterval(finished.duration) / 1_000_000_000
                let finishedSurface = target.target.surface
                DispatchQueue.main.async {
                    guard let app = GhosttyApp.shared,
                          let leaf = app.leafID(for: finishedSurface) else { return }
                    app.onCommandFinished?(leaf, exit, seconds)
                }
                return true

            case GHOSTTY_ACTION_PROGRESS_REPORT:
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
                let report = action.action.progress_report
                let progress: LeafProgress? = switch report.state {
                case GHOSTTY_PROGRESS_STATE_REMOVE: nil
                case GHOSTTY_PROGRESS_STATE_ERROR: LeafProgress(state: .error, percent: report.progress >= 0 ? Int(report.progress) : nil)
                case GHOSTTY_PROGRESS_STATE_INDETERMINATE: LeafProgress(state: .indeterminate, percent: nil)
                case GHOSTTY_PROGRESS_STATE_PAUSE: LeafProgress(state: .paused, percent: report.progress >= 0 ? Int(report.progress) : nil)
                default: LeafProgress(state: .set, percent: report.progress >= 0 ? Int(report.progress) : nil)
                }
                let progressSurface = target.target.surface
                DispatchQueue.main.async {
                    guard let app = GhosttyApp.shared,
                          let leaf = app.leafID(for: progressSurface) else { return }
                    app.onProgress?(leaf, progress)
                }
                return true

            // THE CHROME FOLLOWS THE FOCUSED PANE'S BACKGROUND, live. A
            // program that sets its own background (OSC 11) is changing
            // the largest surface in the window, and the chrome around it
            // borrows the theme's temperature for exactly this reason
            // ([[ChromeTint]]).
            case GHOSTTY_ACTION_COLOR_CHANGE:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND
                else { return false }
                let c = action.action.color_change
                let color = NSColor(calibratedRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                                    blue: CGFloat(c.b) / 255, alpha: 1)
                let colorSurface = target.target.surface
                DispatchQueue.main.async {
                    guard let app = GhosttyApp.shared,
                          app.activeView?.surface == colorSurface else { return }
                    ChromeTint.follow(background: color)
                    SynaptySettings.shared.applyChromeTint()
                }
                return true

            // CELL METRICS, so a split divider can snap to the grid.
            case GHOSTTY_ACTION_CELL_SIZE:
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
                let cell = action.action.cell_size
                let px = NSSize(width: CGFloat(cell.width), height: CGFloat(cell.height))
                let cellSurface = target.target.surface
                DispatchQueue.main.async {
                    guard let app = GhosttyApp.shared else { return }
                    let scale = app.view(forSurface: cellSurface)?.window?.backingScaleFactor ?? 2
                    app.cellSize = NSSize(width: px.width / scale, height: px.height / scale)
                }
                return true

            // A RENDERER THAT HAS FAILED LOOKS LIKE AN EMPTY PANE. Say so.
            case GHOSTTY_ACTION_RENDERER_HEALTH:
                let unhealthy = action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY
                DispatchQueue.main.async {
                    guard unhealthy else { return }
                    AppLog.search.error("terminal renderer reported unhealthy")
                    AppNotifications.shared?.post(
                        .failed, "A terminal pane stopped rendering",
                        detail: "The GPU renderer failed for one pane. Close and reopen it.")
                }
                return true

            case GHOSTTY_ACTION_SEARCH_SELECTED:
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface = target.target.surface else { return false }
                let selected = Int(action.action.search_selected.selected)
                Task { @MainActor in
                    GhosttyApp.shared?.noteSearch(surface: surface, selected: selected)
                }
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

            case GHOSTTY_ACTION_RING_BELL, GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                // Zero-config attention signals (WI-2026-08-09-021):
                // Claude Code rings the terminal bell / sends OSC 9 when it
                // needs input. Route surface -> leaf -> attention. OSC
                // notifications additionally carry title/body — forward
                // them to Notification Center when the human is in
                // another app (WI-2026-08-11-008); bell stays badge-only.
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
                let bellSurface = target.target.surface
                var noteTitle = ""
                var noteBody = ""
                if action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION {
                    let payload = action.action.desktop_notification
                    if let t = payload.title { noteTitle = String(cString: t) }
                    if let b = payload.body { noteBody = String(cString: b) }
                }
                DispatchQueue.main.async {
                    guard let leafID = GhosttyApp.shared?.leafID(for: bellSurface) else { return }
                    TerminalCoordinatorRef.instance?.leafNeedsAttention(leafID)
                    if NotificationForwarder.shouldForward(
                        appActive: NSApp.isActive,
                        hasPayload: !(noteTitle.isEmpty && noteBody.isEmpty))
                    {
                        NotificationForwarder.forward(title: noteTitle, body: noteBody)
                    }
                }
                return true

            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                // WHAT THE LINK UNDER THE POINTER GOES TO. The empty
                // string means the pointer left one. Held so that a click
                // can be compared against what the human was reading
                // ([[RFC-0015]] C-DERIVED rule two).
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
                let overSurface = target.target.surface
                let link = action.action.mouse_over_link
                let url = link.url.flatMap { link.len > 0 ? String(cString: $0) : nil } ?? ""
                DispatchQueue.main.async {
                    GhosttyApp.shared?.view(forSurface: overSurface)?.linkUnderPointer =
                        url.isEmpty ? nil : url
                }
                return true

            case GHOSTTY_ACTION_OPEN_URL:
                // `text`/`html` come from write_screen_file, which opens a
                // file the workbench itself wrote at the human's command.
                // Not this rule's business; left unhandled as it was.
                guard action.action.open_url.kind == GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
                      target.tag == GHOSTTY_TARGET_SURFACE,
                      let cURL = action.action.open_url.url
                else { return false }
                let opened = String(cString: cURL)
                let urlSurface = target.target.surface
                DispatchQueue.main.async {
                    GhosttyApp.shared?.view(forSurface: urlSurface)?.followLink(opened)
                }
                return true

            case GHOSTTY_ACTION_PWD:
                // OSC 7 cwd report → per-leaf pwd for session-restore
                // snapshots (RFC-0006: layout AND cwd come back).
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let cPwd = action.action.pwd.pwd else { return false }
                let pwd = String(cString: cPwd)
                let pwdSurface = target.target.surface
                DispatchQueue.main.async {
                    guard let leafID = GhosttyApp.shared?.leafID(for: pwdSurface) else { return }
                    TerminalCoordinatorRef.instance?.leafDidUpdatePwd(leafID, pwd: pwd)
                }
                return true

            case GHOSTTY_ACTION_SET_TITLE:
                // Shell-emitted OSC 0/2 title → tab label
                // (WI-2026-08-09-017). Resolve the surface to its leaf on
                // the main actor via the registry; C callback cannot
                // capture context (the START_SEARCH pattern).
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let cTitle = action.action.set_title.title else { return false }
                let title = String(cString: cTitle)
                let surface = target.target.surface
                DispatchQueue.main.async {
                    guard let leafID = GhosttyApp.shared?.leafID(for: surface) else { return }
                    TerminalCoordinatorRef.instance?.leafDidUpdateTitle(leafID, title: title)
                }
                return true

            default:
                return false
            }
        }
        runtime.close_surface_cb = { userdata, _ in
            // userdata is per-surface: a pointer to UUID (the leaf ID).
            guard let userdata else { return }
            let leafID = userdata.assumingMemoryBound(to: UUID.self).pointee
            Task { @MainActor in
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
        // The userdata argument is the PER-SURFACE leaf-UUID pointer — resolve
        // the requesting surface from it so the request completes on the
        // surface that asked, never on the global activeSurface (which a
        // hidden background surface may hold; WI-2026-08-08-008).
        runtime.read_clipboard_cb = { userdata, location, state in
            guard let surface = GhosttyApp.surface(for: userdata) else { return false }
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
        // Auto-confirm in V1 (no confirmation dialog). Same per-surface
        // userdata resolution as read_clipboard_cb (WI-2026-08-08-008).
        runtime.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content else { return }
            guard let surface = GhosttyApp.surface(for: userdata) else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }

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

        // Cold start (WI-2026-08-08-086): the appearance-changed notification
        // and the KVO may both have fired BEFORE this init (settings init
        // runs before GhosttyApp under window restoration), so the persisted
        // appearance would never reach ghostty — the terminal would stay
        // light while the UI chrome is dark. Push it once now.
        applyColorScheme()
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

    /// Reverse registry lookup: which leaf owns this surface
    /// (WI-2026-08-09-017 title routing). O(n) over a handful of surfaces.
    func leafID(for surface: ghostty_surface_t?) -> UUID? {
        guard let surface else { return nil }
        return leaves.first(where: { $0.value.surface == surface })?.key
    }

    /// Forward lookup for the passive detector (ADR-0005): the live
    /// surface hosting a leaf, if any.
    func surface(forLeaf leafID: UUID) -> ghostty_surface_t? {
        leaves[leafID]?.surface
    }

    // MARK: - Search results ([[WI-2026-08-20-001]])

    /// A COUNT THAT ARRIVES LATE MUST STILL REACH THE BAR.
    ///
    /// GhosttyApp is a plain class, not @Observable — the find bar read
    /// its results through an `@State` copy that SwiftUI never had reason
    /// to invalidate. So core's FIRST report (total 0, active area only)
    /// was the only one the bar ever drew; the real count, which the
    /// background HistorySearch delivers a few hundred milliseconds later
    /// as it climbs the scrollback, updated the dictionary and repainted
    /// nothing. To the human the bar said "none" for a match that was
    /// there — indistinguishable from search not covering the scrollback
    /// at all, which is exactly how this was reported
    /// ([[WI-2026-09-02-001]]).
    ///
    /// This tiny box IS observable. `noteSearch` bumps it, the bar
    /// watches it, and a late count repaints. It carries no data — the
    /// results still live per-leaf below — only the fact that they
    /// changed.
    @MainActor @Observable final class SearchTicker {
        var generation = 0
    }
    let searchTicker = SearchTicker()

    /// WHAT THE FIND BAR SHOWS BESIDE THE FIELD: how many matches there
    /// are, and which one is selected. Ghostty owns both — it does the
    /// searching — and reports them per surface as they change.
    ///
    /// KEYED BY LEAF, because the bar is a leaf's ([[RFC-0016]]
    /// C-DISPATCH row 2) and two panes searching at once have two counts.
    struct SearchResults: Equatable {
        var total: Int = 0
        /// Ghostty counts from zero and reports -1 for "none selected";
        /// the bar shows a human's ordinal, so the conversion lives here
        /// rather than in every surface that displays it.
        var selected: Int = -1

        var ordinal: Int? { selected >= 0 ? selected + 1 : nil }
        var isEmpty: Bool { total == 0 }
    }

    func searchResults(forLeaf leafID: UUID) -> SearchResults {
        leaves[leafID]?.search ?? SearchResults()
    }

    fileprivate func noteScrollbar(surface: ghostty_surface_t, total: Int, offset: Int, len: Int) {
        guard let state = leaves.first(where: { $0.value.surface == surface })?.value
        else { return }
        state.view?.view?.noteScrollbar(total: total, offset: offset, len: len)
    }

    fileprivate func noteSearch(surface: ghostty_surface_t, total: Int? = nil, selected: Int? = nil) {
        guard let leafID = leaves.first(where: { $0.value.surface == surface })?.key
        else {
            AppLog.search.error("search result for a surface no leaf claims")
            return
        }
        var results = leaves[leafID]?.search ?? SearchResults()
        if let total { results.total = total }
        if let selected { results.selected = selected }
        leaves[leafID]?.search = results
        // The write above is invisible to SwiftUI; this is what tells it.
        searchTicker.generation &+= 1
    }

    // MARK: - Human-typing recency (RFC-0005 C-STATE-GATE)

    /// First-human-input hook (RFC-0006: clears resume-attempted markers).
    var onHumanInput: ((UUID) -> Void)?

    /// Shell integration reported a command's end: leaf, exit code (-1 if
    /// not reported), duration in seconds ([[WI-2026-09-02-002]]).
    var onCommandFinished: ((UUID, Int, TimeInterval) -> Void)?
    /// OSC 9;4 progress for a leaf; nil clears it.
    var onProgress: ((UUID, LeafProgress?) -> Void)?
    /// BROADCAST ([[WI-2026-09-02-010]]): the other panes a keystroke in
    /// this leaf is copied to. Answered by the workspace model, which
    /// owns the armed set; this object only knows surfaces.
    var broadcastTargets: ((UUID) -> [UUID])?

    /// Copy a key event the focused surface just received to every armed
    /// sibling. Called inside the scope that owns `keyEvent.text`, so the
    /// pointer is still valid for every delivery.
    func forwardBroadcast(_ keyEvent: ghostty_input_key_s, from leafID: UUID) {
        guard let targets = broadcastTargets?(leafID), !targets.isEmpty else { return }
        for target in targets {
            guard let surface = surface(forLeaf: target) else { continue }
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    /// Cell metrics in POINTS, from the most recent CELL_SIZE report. One
    /// value for the app: every pane shares the font, so every pane shares
    /// the grid. Used to snap split dividers to cell boundaries.
    var cellSize: NSSize?

    /// The view registered for a surface — the route an action takes when
    /// it has to land on a specific pane's NSView.
    func view(forSurface surface: ghostty_surface_t?) -> GhosttyNSView? {
        guard let surface else { return nil }
        return leaves.first(where: { $0.value.surface == surface })?.value.view?.view
    }

    /// WHAT THE HUMAN HAS SELECTED in a leaf, or nil. Read through the
    /// core's own accessor and freed through its own release — the buffer
    /// is the core's.
    func selectedText(forLeaf leafID: UUID) -> String? {
        guard let surface = leaves[leafID]?.surface,
              ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text), let base = text.text else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                                        count: Int(text.text_len))
        let s = String(decoding: bytes, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    func noteHumanInput(leafID: UUID) {
        leaves[leafID, default: .init()].lastHumanInputAt = Date()
        onHumanInput?(leafID)
    }

    /// nil = the human never typed into this leaf.
    func secondsSinceHumanInput(forLeaf leafID: UUID) -> TimeInterval? {
        leaves[leafID]?.lastHumanInputAt.map { Date().timeIntervalSince($0) }
    }

    func registerSurface(_ surface: ghostty_surface_t, leafID: UUID?,
                         view: GhosttyNSView? = nil) {
        guard !liveSurfaces.contains(where: { $0 == surface }) else { return }
        liveSurfaces.append(surface)
        if let leafID {
            leaves[leafID, default: .init()].surface = surface
            if let view { leaves[leafID]?.view = WeakViewBox(view) }
        }
        // A surface created while paused/hidden must start paused — it
        // would otherwise keep rendering at 60fps (WI-2026-08-08-013).
        applyDisplayIds()
    }

    /// Resolve the surface a clipboard callback's userdata refers to.
    /// The userdata is the per-surface leaf-UUID pointer (allocated by
    /// GhosttyNSView and passed through the surface config); the callback
    /// must complete the request on THAT surface — never on the global
    /// activeSurface (completing on the wrong surface consumes the
    /// requester's clipboard state; WI-2026-08-08-008, WI-2026-08-08-032).
    /// An unregistered/unowned leaf resolves to nil and the callback
    /// refuses (ghostty then frees the request state).
    private static func surface(for userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        guard let userdata else { return nil }
        let leafID = userdata.assumingMemoryBound(to: UUID.self).pointee
        return GhosttyApp.shared?.leaves[leafID]?.surface
    }

    /// Page-level pause: the terminal page is not visible (WI-2026-08-07-006).
    private var surfacesPaused = false
    /// Pane-level visibility: leaves NOT in this set are hidden inside the
    /// terminal page (inactive workspaces/panes) and must not keep rendering.
    /// nil = no pane-level constraint (WI-2026-08-08-013).
    private var visibleLeaves: Set<UUID>?

    /// Pause vsync-driven rendering for all surfaces (WI-2026-08-07-006):
    /// hidden terminal surfaces must not keep rendering at 60fps — that
    /// saturates the GPU/window compositor and makes the whole UI feel
    /// sluggish. Display id 0 = render on wakeup only; surfaces stay alive.
    func setSurfacesPaused(_ paused: Bool) {
        surfacesPaused = paused
        applyDisplayIds()
    }

    /// Restrict vsync rendering to the visible leaves of the active pane
    /// (WI-2026-08-08-013): hidden workspaces/panes inside the terminal page
    /// stay paused. Pass the active pane's leaf set.
    func setVisibleLeaves(_ visible: Set<UUID>) {
        visibleLeaves = visible
        applyDisplayIds()
    }

    /// Re-apply display ids from the current page/pane visibility state.
    private func applyDisplayIds() {
        let hiddenLeaves = visibleLeaves.map { visible in
            leaves.keys.filter { !visible.contains($0) }
        } ?? []
        for (leafID, state) in leaves {
            guard let surface = state.surface else { continue }
            let paused = surfacesPaused || hiddenLeaves.contains(leafID)
            ghostty_surface_set_display_id(surface, paused ? 0 : displayIDForSurfaces)
            // AND TELL THE CORE ITSELF. Occlusion is the core's own word
            // for "nobody can see this"; with it set, ghostty stops its
            // own render work for the pane rather than relying on our
            // display-id trick alone (the bool is `visible`, as in
            // ghostty's macOS app).
            ghostty_surface_set_occlusion(surface, !paused)
        }
    }

    /// Current display id for vsync rendering: the ACTIVE window's screen
    /// when known — a blanket NSScreen.main would vsync-lock surfaces on
    /// secondary displays to the wrong screen (WI-2026-08-08-013). Without a
    /// key window NSScreen.main can be nil, so fall back to any attached
    /// screen — display_id 0 would leave surfaces paused and stall the
    /// cold-start shell spawn (WI-2026-08-08-078).
    private var displayIDForSurfaces: UInt32 {
        UInt32(activeView?.window?.screen?.displayID
            ?? NSScreen.main?.displayID
            ?? NSScreen.screens.first?.displayID
            ?? 0)
    }

    /// Re-apply display ids (public wrapper for the surface creation path,
    /// WI-2026-08-08-078): a surface created before the window/screen was
    /// fully ready must re-resolve its display id once the run loop settles.
    func refreshSurfaceDisplayIds() {
        applyDisplayIds()
    }

    /// Unregister a destroyed surface (called by GhosttyNSView on destroy).
    func unregisterSurface(_ surface: ghostty_surface_t) {
        liveSurfaces.removeAll { $0 == surface }
        // THE SURFACE ONLY. What is known about the LEAF outlives a view
        // that is rebuilt and is dropped by `forgetLeaf` when the pane is.
        for (leafID, state) in leaves where state.surface == surface {
            leaves[leafID]?.surface = nil
        }
    }

    /// The pane is gone, so everything known about it goes. Called from
    /// [[WorkspaceManager]]`.forget`, which is the one place a pane is
    /// destroyed.
    func forgetLeaf(_ leafID: UUID) {
        leaves.removeValue(forKey: leafID)
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
        isShuttingDown = true
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

        // THE LIBGHOSTTY OBJECTS ARE DELIBERATELY NOT FREED
        // ([[WI-2026-08-14-013]]).
        //
        // The only caller is applicationWillTerminate, and
        // `ghostty_app_free` tears down every surface while the NSViews
        // that own them are still alive — it segfaulted on every normal
        // quit, which macOS then reported to the human as an abnormal
        // exit. There is nothing to gain: the process is about to end and
        // the kernel reclaims this memory either way, so the free is pure
        // risk. Nothing is flushed here — the session snapshot and the
        // settings write happen elsewhere and are unaffected.
        //
        // If a caller ever needs to tear ghostty down while the app KEEPS
        // RUNNING, that caller has to close the surfaces first, and this
        // is not that function.
        liveSurfaces.removeAll()
        leaves.removeAll()
        activeSurface = nil
        activeView = nil
    }
}
