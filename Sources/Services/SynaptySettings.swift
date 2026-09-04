import Foundation
import Observation
import AppKit


// ===========================================================================
// SynaptySettings — persisted app settings (~/.config/synapty/shared/settings.json).
//
// Also owns the ghostty config fragment (~/.config/synapty/shared/ghostty.conf):
// Synapty-managed overrides are written as a complete fragment on every
// change so the file always reflects the current settings. The fragment is
// loaded by GhosttyApp after the default files, so it overrides them.
// ===========================================================================

/// App-level appearance mode (WI-2026-08-06-004).
enum AppearanceMode: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The NSAppearance to force, or nil to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor @Observable final class SynaptySettings {
    /// Shared instance — SwiftUI can re-create the ContentView (window
    /// restoration rebuilds the WindowGroup content, WI-2026-08-08-085);
    /// @State would then construct a fresh settings object that reloads the
    /// disk and can override live state. A shared instance survives
    /// view re-creation.
    static let shared = SynaptySettings()

    // MARK: - Appearance (app-level)

    /// Light / Dark / System for the whole app UI. Not a ghostty fragment
    /// key — applied to NSApp and forwarded to ghostty's color scheme.
    var appearanceMode: AppearanceMode = .system {
        didSet {
            guard !isLoading else { return }
            applyAppearance()
            // IMMEDIATE write (WI-2026-08-08-085): a re-created settings
            // instance (window restoration) loads the disk value in its
            // init and re-applies it — if the mode were still debounced,
            // the stale value would override this switch.
            persistNow()
        }
    }

    /// Apply the appearance to the app and notify ghostty (colors, theme
    /// conditionals). Safe to call during init/load (no observers yet).
    /// The visible windows' appearance animates as a ~0.25s crossfade
    /// (WI-2026-08-08-002) so dark→light does not snap.
    func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
        for window in NSApp.windows where window.isVisible {
            let target = appearanceMode.nsAppearance
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.appearance = target
            }
        }
        // The terminal reloads its theme through .synaptyAppearanceChanged,
        // in the same turn as the window crossfade starts — the terminal
        // snaps to the new colors at t=0 while the UI chrome crossfades
        // (native-terminal behavior, cf. Ghostty/iTerm2; WI-2026-08-08-002).
        NotificationCenter.default.post(name: .synaptyAppearanceChanged, object: nil)
    }

    /// Hand the theme pair to [[ChromeTint]] and make every window
    /// re-resolve its dynamic colors.
    ///
    /// THE FLIP IS THE INVALIDATION. Dynamic NSColors re-run their
    /// providers when a view draws under a CHANGED appearance; setting
    /// the same appearance again is a no-op, and nothing else reaches
    /// every AppKit- and SwiftUI-drawn surface at once. Flipping to the
    /// opposite and back inside one runloop turn never reaches the
    /// screen — CATransaction commits only the final state — but marks
    /// everything dirty on the way through.
    func applyChromeTint() {
        ChromeTint.reload(lightTheme: lightThemeName, darkTheme: darkThemeName)
        guard !isLoading, NSApp != nil else { return }
        for window in NSApp.windows where window.isVisible {
            let current = window.effectiveAppearance
            let opposite: NSAppearance.Name =
                current.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .aqua : .darkAqua
            let restore = window.appearance
            window.appearance = NSAppearance(named: opposite)
            window.appearance = restore
        }
    }

    // MARK: - UI chrome (app-level)

    /// App UI font scale (0.85–1.3) — drives DS.Typography globally; the
    /// terminal font size is separate (WI-2026-08-08-070).
    var uiFontScale: Double = 1.0 {
        didSet {
            guard !isLoading else { return }
            applyUIFontScale()
            persistOnly()
        }
    }

    // MARK: - Terminal (appearance)

    /// Ghostty theme for light appearance; nil = ghostty default.
    var lightThemeName: String? {
        didSet { guard !isLoading else { return }; applyChromeTint(); persistAndWriteFragment() }
    }

    /// Ghostty theme for dark appearance; nil = ghostty default.
    var darkThemeName: String? {
        didSet { guard !isLoading else { return }; applyChromeTint(); persistAndWriteFragment() }
    }

    /// Terminal font family (e.g. "JetBrains Mono"). nil = ghostty default.
    var fontFamily: String? {
        didSet { guard !isLoading else { return }; persistAndWriteFragment() }
    }

    /// Extra fallback font families appended after the primary — ghostty
    /// walks them for codepoints missing from the primary font (unicode
    /// symbols, Nerd Font icons, etc.).
    var fontFallbackFamilies: [String] {
        didSet { guard !isLoading else { return }; persistAndWriteFragment() }
    }

    /// Terminal font size in points. nil = ghostty default.
    var fontSize: Double? {
        didSet { guard !isLoading else { return }; persistAndWriteFragment() }
    }

    /// Background opacity 0…1. nil = ghostty default.
    var backgroundOpacity: Double? {
        didSet { guard !isLoading else { return }; persistAndWriteFragment() }
    }

    /// Cursor style: block | bar | underline. nil = ghostty default.
    var cursorStyle: String? {
        didSet { guard !isLoading else { return }; persistAndWriteFragment() }
    }

    // MARK: - Scrolling

    /// Scrollback line limit. nil = ghostty default (10000).
    var scrollbackLimit: Int? {
        didSet { guard !isLoading else { return }; persistAndWriteFragment() }
    }

    // MARK: - Clipboard

    /// Copy on mouse selection.
    var copyOnSelect: Bool? {
        didSet { guard !isLoading else { return }; persistAndWriteFragment() }
    }

    /// Allow applications to read the clipboard (OSC 52).
    var clipboardRead: Bool? {
        didSet { guard !isLoading else { return }; persistAndWriteFragment() }
    }

    /// Allow applications to write the clipboard (OSC 52).
    var clipboardWrite: Bool? {
        didSet { guard !isLoading else { return }; persistAndWriteFragment() }
    }

    // MARK: - Network (Synapty)

    // hubPort setting RETIRED (WI-2026-08-11-017): the embedded hub owns
    // its port (default 9000 + backoff; SYNAPTY_HUB_PORT env var is the
    // only override). The legacy payload key is ignored on load.

    /// WHETHER THIS MAC'S OWN PANES SURVIVE THE WINDOW CLOSING
    /// ([[RFC-0014]] C-SCOPE, C-OPT-OUT).
    ///
    /// REFUSABLE, AND ON THE SAME TERMS AS ANY HOST. Durability on the
    /// machine a human is sitting at means work continues after they
    /// close the window — which is a promise and a cost at once: it is
    /// the difference between an agent that survives a laptop sleeping
    /// and one that goes on spending after its human has finished for
    /// the day. A workbench that made that choice for them would be
    /// making it silently, every evening.
    ///
    /// MACHINE-SCOPED like the pane layout it governs: whether THIS Mac's
    /// panes outlive their window is not a preference to replicate onto
    /// another one.
    var localDurableSessions: Bool = true {
        didSet { guard !isLoading else { return }; persistOnly() }
    }

    /// Reverse-tunnel port. Applied on next tunnel establishment.
    var tunnelPort: Int {
        didSet { guard !isLoading else { return }; persistOnly() }
    }

    /// How much every hub this workbench operates should say
    /// ([[RFC-0012]] C-LEVEL-CONTROL).
    ///
    /// SHARED configuration, not machine state: "how verbose do I want
    /// this to be" is the human's intent, the same class as appearance,
    /// so one Mac's choice reaches the fleet. And pushed to RUNNING hubs
    /// rather than applied at their next start — restarting a hub severs
    /// A2A for every agent working on that machine.
    var logLevel: String = "info" {
        didSet {
            guard !isLoading else { return }
            persistOnly()
            HubLogLevel.applyEverywhere(logLevel)
        }
    }

    /// How much an AGENT may move in one transfer, in megabytes.
    ///
    /// A HUMAN'S OWN DRAG IS NOT LIMITED. This bounds what an agent can ask
    /// for unattended, because every relayed byte crosses this Mac twice
    /// and shares the connection carrying the human's keystrokes
    /// ([[RFC-0013]] C-CONTROL-PLANE). The clause requires a limit that is
    /// stated rather than discovered; it does not require a fixed one, and
    /// the right number depends on a link and a fleet only the operator
    /// knows.
    ///
    /// IT SYNCS, deliberately. It is a preference, not a credential — the
    /// same judgement made on one Mac is the judgement on the others, and
    /// re-making it per machine is how two machines come to disagree about
    /// what an agent may do.
    var agentTransferLimitMB: Int = 256 {
        didSet { guard !isLoading else { return }; persistOnly() }
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var themeName: String?
        var lightThemeName: String?
        var darkThemeName: String?
        var fontFamily: String?
        var fontFallbackFamilies: [String]?
        var fontSize: Double?
        var backgroundOpacity: Double?
        var cursorStyle: String?
        var scrollbackLimit: Int?
        var copyOnSelect: Bool?
        var clipboardRead: Bool?
        var clipboardWrite: Bool?
        var localDurableSessions: Bool?
        var tunnelPort: Int?
        var logLevel: String?
        var agentTransferLimitMB: Int?
        var appearanceMode: AppearanceMode?
        var uiFontScale: Double?
    }

    /// Test seam: redirect storage to a temp directory so tests never
    /// touch the real ~/.config/synapty (WI-2026-08-08-020).
    static var storageOverride: URL?

    private static var settingsDir: URL {
        if let storageOverride {
            return storageOverride
        }
        // SHARED by classification (ConfigPaths): appearance and terminal
        // preferences are the human's intent, not this machine's state.
        let dir = ConfigPaths.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // THE NAMES COME FROM THE CLASSIFICATION ([[ConfigPaths.Entry]]), not
    // from here. The directory is this type's own, because tests redirect
    // it; the file names are one fact and were written out in three
    // places, this being one of them ([[WI-2026-08-30-003]]).
    private static var settingsURL: URL {
        settingsDir.appendingPathComponent(ConfigPaths.Entry.settings.name)
    }
    /// MACHINE-SCOPED, unlike settings.json beside it in tests: the
    /// fragment is derived from the settings and this machine's shell
    /// ([[ConfigPaths.Entry]]), so it lives with the machine's state and
    /// is never offered to sync. Tests still redirect it with the same
    /// override, so a test's fragment lands beside its settings.
    private static var ghosttyConfURL: URL {
        if let storageOverride {
            return storageOverride.appendingPathComponent(ConfigPaths.Entry.ghosttyConfig.name)
        }
        let dir = ConfigPaths.machine
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(ConfigPaths.Entry.ghosttyConfig.name)
    }

    /// True while init/load() assigns stored properties. Every didSet
    /// side effect (persist, fragment write, notification, appearance
    /// apply) is suppressed during load — otherwise a single launch fires
    /// ~14 saves and ~11 fragment rewrites plus an NSApp appearance
    /// mutation mid-init (WI-2026-08-08-011).
    private var isLoading = false

    init() {
        // Defaults before load (ports are Synapty's hardcoded defaults).
        isLoading = true
        tunnelPort = 9000
        fontFallbackFamilies = []
        load()
        isLoading = false
        // The chrome borrows the theme's temperature ([[ChromeTint]]),
        // and must know it BEFORE the first view resolves a surface color
        // — applyAppearance below is what triggers that first resolve.
        applyChromeTint()
        // Apply the persisted appearance exactly once — the didSet was
        // suppressed during load (WI-2026-08-08-011).
        applyAppearance()
        // Push the persisted UI scale into the global DS (didSet was
        // suppressed during load; WI-2026-08-08-070).
        applyUIFontScale()
        // Ensure the fragment exists (first run or after changes).
        writeGhosttyFragment()
    }

    /// Re-read after something OUTSIDE this object changed the file —
    /// which sync does, on a machine that is already running.
    ///
    /// Hosts already refresh live because the engine calls load() on the
    /// store after writing. Settings did not, so a preference changed on
    /// one Mac appeared on the other only after a relaunch — the same
    /// class of half-working the startup-only sync had, one layer up, and
    /// just as invisible.
    func reloadFromDisk() {
        // A record handed over by sync is NOT this machine's edit, and
        // loading it must not re-enter persistence: every assignment
        // below fires its didSet, which would write the file back and
        // offer it to the engine as a local change.
        isLoading = true
        load()
        isLoading = false
        // The side effects the suppressed didSets would have had, applied
        // once, exactly as `init` does after its own load.
        applyChromeTint()
        applyAppearance()
        applyUIFontScale()
        // THE FRAGMENT FOLLOWS, BEFORE GHOSTTY IS TOLD TO RELOAD. It is
        // derived from what was just loaded and is not a sync record of
        // its own any more ([[ConfigPaths.Entry]]); the old rule of not
        // touching it here — to protect a merged copy — protected a copy
        // that never arrived, and a fresh machine kept ghostty's default
        // theme while its settings said otherwise ([[WI-2026-09-02-005]]).
        // Synchronous, so the reload the notification below triggers reads
        // the new file and not the old one.
        writeGhosttyFragment()
        NotificationCenter.default.post(name: .synaptyAppearanceChanged, object: nil)
        NotificationCenter.default.post(name: .synaptySettingsChanged, object: nil)
    }

    /// `DS.uiFontScale` IS OBSERVABLE, so assigning it IS the whole act:
    /// a body that read it during its last evaluation is re-evaluated.
    /// This used to post a notification as well, and a writer that forgot
    /// to changed every view drawn afterwards and none already on screen
    /// ([[WI-2026-08-28-010]], [[WI-2026-08-28-021]]).
    private func applyUIFontScale() {
        DS.uiFontScale = CGFloat(uiFontScale)
        // AND THE WINDOW'S FLOOR, which is computed from the scale and is
        // not a view body — so observation cannot re-run it and the one
        // writer has to ([[WI-2026-08-28-022]]).
        WindowChrome.applyMinimumSizeToAll()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.settingsURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        lightThemeName = payload.lightThemeName
        darkThemeName = payload.darkThemeName
        // Migration (WI-2026-08-06-005): legacy single theme → both slots.
        if lightThemeName == nil, darkThemeName == nil, let legacy = payload.themeName {
            lightThemeName = legacy
            darkThemeName = legacy
        }
        fontFamily = payload.fontFamily
        fontFallbackFamilies = payload.fontFallbackFamilies ?? []
        fontSize = payload.fontSize
        backgroundOpacity = payload.backgroundOpacity
        cursorStyle = payload.cursorStyle
        scrollbackLimit = payload.scrollbackLimit
        copyOnSelect = payload.copyOnSelect
        clipboardRead = payload.clipboardRead
        clipboardWrite = payload.clipboardWrite
        if let durable = payload.localDurableSessions { self.localDurableSessions = durable }
        if let tunnelPort = payload.tunnelPort { self.tunnelPort = tunnelPort }
        if let logLevel = payload.logLevel { self.logLevel = logLevel }
        // A stored zero or a negative would mean "an agent may move
        // nothing", which is a state no control offers and no human chose;
        // it can only be a corrupt or hand-edited file, so the default
        // stands rather than silently disabling every agent transfer.
        if let limit = payload.agentTransferLimitMB, limit > 0 {
            self.agentTransferLimitMB = limit
        }
        if let appearanceMode = payload.appearanceMode { self.appearanceMode = appearanceMode }
        if let uiFontScale = payload.uiFontScale { self.uiFontScale = uiFontScale }
    }

    /// Debounced settings.json write (WI-2026-08-08-049): slider drags and
    /// rapid tweaks coalesce into one disk write instead of one per tick on
    /// the main thread.
    private var persistenceDebounceTask: Task<Void, Never>?

    /// Has a human actually set something on this machine?
    ///
    /// THE APP'S OWN DEFAULTS ARE NOT AN EDIT ([[WI-2026-08-14-003]]). A
    /// settings.json written from untouched defaults is indistinguishable
    /// from a deliberate one once it reaches sync, and the receiving
    /// machine's three-way merge reads every field the defaults omit as a
    /// field the human deleted.
    private var hasLocalEdit = false

    /// Write without waiting for the debounce. For settings whose value is
    /// re-read during window restoration, where a pending write would be
    /// overtaken by the stale disk value (WI-2026-08-08-085).
    private func persistNow() {
        guard !isLoading else { return }
        hasLocalEdit = true
        persistenceDebounceTask?.cancel()
        persistenceDebounceTask = nil
        save()
    }

    private func persistOnly() {
        guard !isLoading else { return }
        hasLocalEdit = true
        persistenceDebounceTask?.cancel()
        persistenceDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    /// Serial writer for ghostty.conf: rapid tweaks queue in order, so the
    /// file always ends with the newest fragment and a flush can drain the
    /// queue deterministically (WI-2026-08-08-049).
    private let fragmentQueue = DispatchQueue(label: "dev.synapty.settings-fragment")

    private func persistAndWriteFragment() {
        guard !isLoading else { return }
        persistOnly()
        // ghostty.conf is written OFF the main thread; the live-apply
        // notification is posted after the write completes so the reload
        // always reads the fresh fragment (WI-2026-08-08-049).
        let fragment = buildFragment()
        fragmentQueue.async {
            Self.writeFragment(fragment)
            DispatchQueue.main.async {
                // Live apply: GhosttyApp rebuilds the config and propagates
                // it to all surfaces (WI-2026-08-06-001).
                NotificationCenter.default.post(name: .synaptySettingsChanged, object: nil)
            }
        }
    }

    /// Flush all pending persistence: the debounced settings.json save plus
    /// any in-flight ghostty.conf writes (called on teardown; also makes
    /// persistence deterministic under test) (WI-2026-08-08-049).
    func flushPersistence() {
        persistenceDebounceTask?.cancel()
        persistenceDebounceTask = nil
        // Only if a human set something — see `hasLocalEdit`.
        if hasLocalEdit { save() }
        // Drain the fragment queue: after this returns, every queued write
        // has landed and the file holds the newest fragment (serial FIFO).
        fragmentQueue.sync {}
    }

    private func save() {
        let payload = Payload(
            themeName: nil,
            lightThemeName: lightThemeName,
            darkThemeName: darkThemeName,
            fontFamily: fontFamily,
            fontFallbackFamilies: fontFallbackFamilies,
            fontSize: fontSize,
            backgroundOpacity: backgroundOpacity,
            cursorStyle: cursorStyle,
            scrollbackLimit: scrollbackLimit,
            copyOnSelect: copyOnSelect,
            clipboardRead: clipboardRead,
            clipboardWrite: clipboardWrite,
            localDurableSessions: localDurableSessions,
            tunnelPort: tunnelPort,
            logLevel: logLevel,
            agentTransferLimitMB: agentTransferLimitMB,
            appearanceMode: appearanceMode,
            uiFontScale: uiFontScale
        )
        do {
            let encoder = JSONEncoder()
            // Stable key order, so "did this change?" below is a byte
            // comparison rather than a re-parse.
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            // A write that changes nothing is not a change and must not
            // be offered to sync.
            guard data != (try? Data(contentsOf: Self.settingsURL)) else { return }
            try data.write(to: Self.settingsURL, options: .atomic)
            // Writing to disk is not sending. Without this the engine
            // only ever sees settings.json as it was at launch, so a
            // preference changed now would not reach the other Mac until
            // the next relaunch.
            SyncEngine.shared.noteLocalChange(path: ConfigPaths.Entry.settings.name)
        } catch {
            // `error`, not `warning`: nothing retries and the caller is not
            // told, so the human changes a setting, sees it take effect,
            // and finds it reverted after a relaunch with nothing anywhere
            // explaining why. See AppLog's severity policy.
            AppLog.settings.error(
                "settings not saved: \(error.localizedDescription, privacy: .public) — changes will be lost on relaunch")
        }
    }

    // MARK: - Ghostty fragment

    /// Base fragment line: never force the scroll position back to the
    /// bottom (WI-2026-03-31-005).
    static let scrollToBottomLine = "scroll-to-bottom = no-keystroke,no-output"

    /// Build the `theme` line for the fragment (WI-2026-08-06-005).
    /// Both themes set → ghostty light/dark pair (comma syntax, both
    /// required); exactly one set → plain single theme (applies to both
    /// appearances); neither → nil.
    nonisolated static func themeLine(light: String?, dark: String?) -> String? {
        let light = light?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dark = dark?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let light, !light.isEmpty, let dark, !dark.isEmpty {
            return "theme = light:\(light),dark:\(dark)"
        }
        if let single = (light?.isEmpty == false ? light : (dark?.isEmpty == false ? dark : nil)) {
            return "theme = \(single)"
        }
        return nil
    }

    /// Ensure the fragment file exists before the initial ghostty config
    /// load. GhosttyApp builds its config at launch, which can run before
    /// this settings object is initialized (first launch); the file must
    /// exist so the config load picks up the Synapty defaults.
    static func ensureGhosttyFragmentExists() {
        let url = ghosttyConfURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? "\(scrollToBottomLine)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes the full Synapty-managed ghostty config fragment.
    /// Build the ghostty fragment text from the current settings — pure,
    /// used both by the synchronous init write and the async live-apply
    /// write (WI-2026-08-08-049).
    private func buildFragment() -> String {
        var lines: [String] = []
        // THE ENGINE HOLDS NO BINDINGS OF ITS OWN ([[RFC-0016]]
        // C-TERMINAL). Stated as a set relationship and not as a
        // precedence, because precedence is evaluated over the chords the
        // table names AT THE TIME — and a chord the human rebinds away or
        // clears stops being named, which would hand it straight back to
        // ghostty and undo their act. With the engine bound to nothing
        // there is no second authority for a keystroke to fall back to.
        //
        // FIRST LINE, and this fragment is loaded AFTER ghostty's own
        // default files, so it clears both what ghostty ships and what the
        // human wrote in ~/.config/ghostty/config. That displacement is
        // real and invisible from inside that file, which is why
        // C-TERMINAL obliges our documentation to say so.
        //
        // Only BINDINGS. Ghostty's input handling, its escape sequences
        // and whatever a program inside the pane does with a keystroke are
        // untouched.
        lines.append("keybind = clear")
        // Scroll behavior (WI-2026-03-31-005): never force scroll to bottom.
        lines.append(Self.scrollToBottomLine)
        // Bound the scrollback: ghostty's default line limit is unbounded
        // (only byte-capped), which lets the grid grow huge and drags
        // memory/layout cost. 10k lines is plenty for agent work.
        lines.append("scrollback-limit-lines = 10000")
        // NAMED, BECAUSE DETECTION SEES OUR WRAPPER, NOT THE SHELL — see
        // [[TerminalSignals.shellIntegrationValue]] for what was lost
        // while this line was missing.
        if let shell = TerminalSignals.shellIntegrationValue(
            forShellPath: ProcessInfo.processInfo.environment["SHELL"]) {
            lines.append("shell-integration = \(shell)")
            // THE HUMAN'S CURSOR STYLE IS THE HUMAN'S. Integration's
            // `cursor` feature forces a bar at every prompt, over the
            // Cursor Style setting in this app — measured as "the cursor
            // is always an I now". The other features (title, sudo,
            // ssh-env) stay.
            lines.append("shell-integration-features = no-cursor")
        }

        // GHOSTTY MATCHES ADDRESSES; THIS APPLICATION MATCHES PATHS.
        //
        // Its matcher is written for the job and handles a url wrapped
        // across lines, which a single-row reader cannot. What it hands
        // back on a click is compared against the characters under the
        // pointer before anything opens ([[RFC-0015]] C-DERIVED rule
        // two), so a hyperlink escape cannot make one address read as
        // another. Left at ghostty's own default rather than written
        // out, so this fragment says only what it changes.

        if let themeLine = Self.themeLine(light: lightThemeName, dark: darkThemeName) {
            lines.append(themeLine)
        }
        if let fontFamily, !fontFamily.isEmpty {
            // Clear any font-family set by the user's own ghostty config
            // (~/.config/ghostty/config etc.): font-family is a repeatable
            // key — later lines APPEND as a fallback chain instead of
            // overriding, so without the clear the primary font would always
            // come from the user's config (WI-2026-08-06-003).
            lines.append("font-family = \"\"")
            lines.append("font-family = \(fontFamily)")
            // Fallback fonts: repeated font-family lines append (ghostty
            // walks them for codepoints missing from the primary).
            for fallback in fontFallbackFamilies where !fallback.isEmpty {
                lines.append("font-family = \(fallback)")
            }
        }
        if let fontSize {
            lines.append("font-size = \(fontSize)")
        }
        if let backgroundOpacity {
            lines.append("background-opacity = \(backgroundOpacity)")
        }
        if let cursorStyle, !cursorStyle.isEmpty {
            lines.append("cursor-style = \(cursorStyle)")
        }
        if let scrollbackLimit {
            lines.append("scrollback-limit-lines = \(scrollbackLimit)")
        }
        if let copyOnSelect {
            lines.append("copy-on-select = \(copyOnSelect ? "true" : "false")")
        }
        if let clipboardRead {
            lines.append("clipboard-read = \(clipboardRead ? "allow" : "deny")")
        }
        if let clipboardWrite {
            lines.append("clipboard-write = \(clipboardWrite ? "allow" : "deny")")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Synchronous fragment write — used once at init to guarantee the file
    /// exists before ghostty starts; live updates go through the async
    /// persistAndWriteFragment path (WI-2026-08-08-049). The fragment is
    /// built on the main actor; only the disk write runs on the serial
    /// fragment queue so it cannot interleave with a pending async write.
    func writeGhosttyFragment() {
        let fragment = buildFragment()
        fragmentQueue.sync { Self.writeFragment(fragment) }
    }

    /// Write the fragment ONLY if the bytes changed — `init` rewrites it
    /// on every launch to guarantee the file exists. Nothing is offered to
    /// sync: the fragment is this machine's derived file, and settings.json
    /// is the record that carries the intent ([[WI-2026-09-02-005]]).
    private static func writeFragment(_ fragment: String) {
        let previous = try? String(contentsOf: ghosttyConfURL, encoding: .utf8)
        guard fragment != previous else { return }
        do {
            try fragment.write(to: ghosttyConfURL, atomically: true, encoding: .utf8)
        } catch {
            AppLog.settings.error(
                "theme fragment not written: \(error.localizedDescription, privacy: .public) — terminal appearance will not follow the setting")
        }
    }

    // MARK: - Helpers

    /// Built-in theme names shipped with the bundled ghostty, for the picker.
    /// Built-in theme names — computed ONCE (592 entries) and cached:
    /// the picker renders a lazy list from this, so it must not re-read
    /// the directory on every body evaluation (WI-2026-08-07-006).
    static let builtinThemeNames: [String] = {
        if let resPath = Bundle.main.resourcePath {
            let themesDir = "\(resPath)/ghostty/themes"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: themesDir))
                .map { $0.sorted() } ?? []
            if !names.isEmpty { return names }
        }
        let devPath = "ghostty/zig-out/share/ghostty/themes"
        return (try? FileManager.default.contentsOfDirectory(atPath: devPath))
            .map { $0.sorted() } ?? []
    }()

    /// Cursor style options (ghostty cursor-style values).
    static let cursorStyleOptions = [
        ("block", "Block"),
        ("bar", "Bar"),
        ("underline", "Underline"),
    ]
}
