import Foundation

// ===========================================================================
// SynaptySettings — small persisted app settings (~/.config/synapty).
//
// Also owns the ghostty config fragment (~/.config/synapty/ghostty.conf):
// Synapty-managed overrides (scroll behavior, theme) are written as a
// complete fragment on every change so the file always reflects the
// current settings.
// ===========================================================================

@MainActor final class SynaptySettings: ObservableObject {
    /// Ghostty theme name; nil = ghostty default. Picked from the 590+
    /// built-in themes (ghostty +list-themes).
    @Published var themeName: String? {
        didSet {
            save()
            writeGhosttyFragment()
        }
    }

    private struct Payload: Codable {
        var themeName: String?
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
        load()
        // Ensure the fragment exists (first run or after changes).
        writeGhosttyFragment()
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: Self.settingsURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        themeName = payload.themeName
    }

    func save() {
        let payload = Payload(themeName: themeName)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.settingsURL, options: .atomic)
    }

    // MARK: - Ghostty fragment

    /// Writes the full Synapty-managed ghostty config fragment.
    /// Kept separate from the user's own ghostty config; loaded after
    /// default files so it overrides them.
    func writeGhosttyFragment() {
        var lines: [String] = []
        lines.append("scroll-to-bottom = no-keystroke,no-output")
        if let themeName, !themeName.isEmpty {
            lines.append("theme = \(themeName)")
        }
        let fragment = lines.joined(separator: "\n") + "\n"
        try? fragment.write(to: Self.ghosttyConfURL, atomically: true, encoding: .utf8)
    }

    /// Built-in theme names shipped with the bundled ghostty, for the picker.
    static func builtinThemeNames() -> [String] {
        // GhosttyKit bundles themes under Contents/Resources/ghostty/themes.
        if let resPath = Bundle.main.resourcePath {
            let themesDir = "\(resPath)/ghostty/themes"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: themesDir))
                .map { $0.sorted() } ?? []
            if !names.isEmpty { return names }
        }
        // Dev fallback: the ghostty submodule's built themes.
        let devPath = "ghostty/zig-out/share/ghostty/themes"
        return (try? FileManager.default.contentsOfDirectory(atPath: devPath))
            .map { $0.sorted() } ?? []
    }
}
