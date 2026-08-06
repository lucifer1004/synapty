import Foundation
import AppKit

// ===========================================================================
// SynaptySettings — persisted app settings (~/.config/synapty/settings.json).
//
// Also owns the ghostty config fragment (~/.config/synapty/ghostty.conf):
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

@MainActor final class SynaptySettings: ObservableObject {

    // MARK: - Appearance (app-level)

    /// Light / Dark / System for the whole app UI. Not a ghostty fragment
    /// key — applied to NSApp and forwarded to ghostty's color scheme.
    @Published var appearanceMode: AppearanceMode = .system {
        didSet {
            applyAppearance()
            persistOnly()
        }
    }

    /// Apply the appearance to the app and notify ghostty (colors, theme
    /// conditionals). Safe to call during init/load (no observers yet).
    func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
        NotificationCenter.default.post(name: .synaptyAppearanceChanged, object: nil)
    }

    // MARK: - Terminal (appearance)

    /// Ghostty theme for light appearance; nil = ghostty default.
    @Published var lightThemeName: String? {
        didSet { persistAndWriteFragment() }
    }

    /// Ghostty theme for dark appearance; nil = ghostty default.
    @Published var darkThemeName: String? {
        didSet { persistAndWriteFragment() }
    }

    /// Terminal font family (e.g. "JetBrains Mono"). nil = ghostty default.
    @Published var fontFamily: String? {
        didSet { persistAndWriteFragment() }
    }

    /// Extra fallback font families appended after the primary — ghostty
    /// walks them for codepoints missing from the primary font (unicode
    /// symbols, Nerd Font icons, etc.).
    @Published var fontFallbackFamilies: [String] {
        didSet { persistAndWriteFragment() }
    }

    /// Terminal font size in points. nil = ghostty default.
    @Published var fontSize: Double? {
        didSet { persistAndWriteFragment() }
    }

    /// Background opacity 0…1. nil = ghostty default.
    @Published var backgroundOpacity: Double? {
        didSet { persistAndWriteFragment() }
    }

    /// Cursor style: block | bar | underline. nil = ghostty default.
    @Published var cursorStyle: String? {
        didSet { persistAndWriteFragment() }
    }

    // MARK: - Scrolling

    /// Scrollback line limit. nil = ghostty default (10000).
    @Published var scrollbackLimit: Int? {
        didSet { persistAndWriteFragment() }
    }

    // MARK: - Clipboard

    /// Copy on mouse selection.
    @Published var copyOnSelect: Bool? {
        didSet { persistAndWriteFragment() }
    }

    /// Allow applications to read the clipboard (OSC 52).
    @Published var clipboardRead: Bool? {
        didSet { persistAndWriteFragment() }
    }

    /// Allow applications to write the clipboard (OSC 52).
    @Published var clipboardWrite: Bool? {
        didSet { persistAndWriteFragment() }
    }

    // MARK: - Network (Synapty)

    /// Hub TCP port. Applied on next hub start.
    @Published var hubPort: Int {
        didSet { persistOnly() }
    }

    /// Reverse-tunnel port. Applied on next tunnel establishment.
    @Published var tunnelPort: Int {
        didSet { persistOnly() }
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
        var hubPort: Int?
        var tunnelPort: Int?
        var appearanceMode: AppearanceMode?
    }

    private static var settingsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/synapty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var settingsURL: URL { settingsDir.appendingPathComponent("settings.json") }
    private static var ghosttyConfURL: URL { settingsDir.appendingPathComponent("ghostty.conf") }

    init() {
        // Defaults before load (ports are Synapty's hardcoded defaults).
        hubPort = 9000
        tunnelPort = 9000
        fontFallbackFamilies = []
        load()
        // Ensure the fragment exists (first run or after changes).
        writeGhosttyFragment()
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
        if let hubPort = payload.hubPort { self.hubPort = hubPort }
        if let tunnelPort = payload.tunnelPort { self.tunnelPort = tunnelPort }
        if let appearanceMode = payload.appearanceMode { self.appearanceMode = appearanceMode }
    }

    private func persistOnly() {
        save()
    }

    private func persistAndWriteFragment() {
        save()
        writeGhosttyFragment()
        // Live apply: GhosttyApp rebuilds the config and propagates it to
        // all surfaces (WI-2026-08-06-001).
        NotificationCenter.default.post(name: .synaptySettingsChanged, object: nil)
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
            hubPort: hubPort,
            tunnelPort: tunnelPort,
            appearanceMode: appearanceMode
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.settingsURL, options: .atomic)
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
    func writeGhosttyFragment() {
        var lines: [String] = []
        // Scroll behavior (WI-2026-03-31-005): never force scroll to bottom.
        lines.append(Self.scrollToBottomLine)
        // Bound the scrollback: ghostty's default line limit is unbounded
        // (only byte-capped), which lets the grid grow huge and drags
        // memory/layout cost. 10k lines is plenty for agent work.
        lines.append("scrollback-limit-lines = 10000")

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

        let fragment = lines.joined(separator: "\n") + "\n"
        try? fragment.write(to: Self.ghosttyConfURL, atomically: true, encoding: .utf8)
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
