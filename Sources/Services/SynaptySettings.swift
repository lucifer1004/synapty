import Foundation

// ===========================================================================
// SynaptySettings — persisted app settings (~/.config/synapty/settings.json).
//
// Also owns the ghostty config fragment (~/.config/synapty/ghostty.conf):
// Synapty-managed overrides are written as a complete fragment on every
// change so the file always reflects the current settings. The fragment is
// loaded by GhosttyApp after the default files, so it overrides them.
// ===========================================================================

@MainActor final class SynaptySettings: ObservableObject {

    // MARK: - Terminal (appearance)

    /// Ghostty theme name; nil = ghostty default.
    @Published var themeName: String? {
        didSet { persistAndWriteFragment() }
    }

    /// Terminal font family (e.g. "JetBrains Mono"). nil = ghostty default.
    @Published var fontFamily: String? {
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
        var fontFamily: String?
        var fontSize: Double?
        var backgroundOpacity: Double?
        var cursorStyle: String?
        var scrollbackLimit: Int?
        var copyOnSelect: Bool?
        var clipboardRead: Bool?
        var clipboardWrite: Bool?
        var hubPort: Int?
        var tunnelPort: Int?
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
        load()
        // Ensure the fragment exists (first run or after changes).
        writeGhosttyFragment()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.settingsURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        themeName = payload.themeName
        fontFamily = payload.fontFamily
        fontSize = payload.fontSize
        backgroundOpacity = payload.backgroundOpacity
        cursorStyle = payload.cursorStyle
        scrollbackLimit = payload.scrollbackLimit
        copyOnSelect = payload.copyOnSelect
        clipboardRead = payload.clipboardRead
        clipboardWrite = payload.clipboardWrite
        if let hubPort = payload.hubPort { self.hubPort = hubPort }
        if let tunnelPort = payload.tunnelPort { self.tunnelPort = tunnelPort }
    }

    private func persistOnly() {
        save()
    }

    private func persistAndWriteFragment() {
        save()
        writeGhosttyFragment()
    }

    private func save() {
        let payload = Payload(
            themeName: themeName,
            fontFamily: fontFamily,
            fontSize: fontSize,
            backgroundOpacity: backgroundOpacity,
            cursorStyle: cursorStyle,
            scrollbackLimit: scrollbackLimit,
            copyOnSelect: copyOnSelect,
            clipboardRead: clipboardRead,
            clipboardWrite: clipboardWrite,
            hubPort: hubPort,
            tunnelPort: tunnelPort
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.settingsURL, options: .atomic)
    }

    // MARK: - Ghostty fragment

    /// Writes the full Synapty-managed ghostty config fragment.
    func writeGhosttyFragment() {
        var lines: [String] = []
        // Scroll behavior (WI-2026-03-31-005): never force scroll to bottom.
        lines.append("scroll-to-bottom = no-keystroke,no-output")

        if let themeName, !themeName.isEmpty {
            lines.append("theme = \(themeName)")
        }
        if let fontFamily, !fontFamily.isEmpty {
            lines.append("font-family = \(fontFamily)")
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
    static func builtinThemeNames() -> [String] {
        if let resPath = Bundle.main.resourcePath {
            let themesDir = "\(resPath)/ghostty/themes"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: themesDir))
                .map { $0.sorted() } ?? []
            if !names.isEmpty { return names }
        }
        let devPath = "ghostty/zig-out/share/ghostty/themes"
        return (try? FileManager.default.contentsOfDirectory(atPath: devPath))
            .map { $0.sorted() } ?? []
    }

    /// Common monospace font families for the picker.
    static let fontFamilySuggestions = [
        "SF Mono", "Menlo", "Monaco", "JetBrains Mono",
        "Fira Code", "Maple Mono NF", "Cascadia Code", "IBM Plex Mono",
    ]

    /// Cursor style options (ghostty cursor-style values).
    static let cursorStyleOptions = [
        ("block", "Block"),
        ("bar", "Bar"),
        ("underline", "Underline"),
    ]
}
