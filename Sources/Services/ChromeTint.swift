import AppKit

/// The terminal theme's temperature, borrowed by the app's chrome.
///
/// THE TERMINAL IS THE LARGEST SURFACE IN THE APP AND THE ONLY ONE THE
/// CHROME NEVER CONSULTED. The chrome was a fixed warm paper; the theme is
/// the human's own choice — measured with GitHub Dark Dimmed, warm gray
/// chrome (54,53,52) butted against a blue terminal (35,39,45), two color
/// temperatures meeting at every seam. Light mode had the same collision
/// in miniature: warm paper against GitHub's neutral gray.
///
/// So the chrome keeps its own LIGHTNESS ladder — that hierarchy is this
/// app's, not the theme's — and takes its HUE from the theme's background,
/// with the saturation capped hard. Chrome must stay nearly neutral to
/// stay chrome; it borrows a cast, never a color.
///
/// A NEUTRAL THEME YIELDS NEUTRAL CHROME. GitHub light's background is
/// pure gray, so the paper loses its warm cast entirely — that is the
/// correct answer, not a degenerate case: the collision this exists to
/// remove was precisely warm paper around a neutral terminal.
enum ChromeTint {

    struct Tint: Equatable {
        var hue: Double
        /// The theme's saturation after the cap — the budget every chrome
        /// token draws a fraction of.
        var chroma: Double
    }

    /// CHROME IS NEVER MORE THAN A CAST. An aggressively saturated theme
    /// (Dracula's purple, Solarized's teal) must not turn the toolbar its
    /// color; past this cap the chrome would read as themed rather than
    /// as neutral furniture around a themed terminal.
    static let chromaCap = 0.35

    /// How much of the budget an appearance spends. Dark chrome carries
    /// visibly more saturation than light at the same perceptual distance
    /// — these reproduce the warm paper this replaces (light sat ≈0.037,
    /// dark sat ≈0.084) when fed the warm defaults below.
    static let lightSpend = 0.15
    static let darkSpend = 0.30

    /// The warm paper the chrome had before it learned to follow — kept
    /// as the answer for a missing theme, an unreadable file, or ghostty's
    /// built-in default (no theme name to look up).
    static let warmLight = Tint(hue: 0.115, chroma: 0.25)
    static let warmDark = Tint(hue: 0.105, chroma: 0.28)

    /// Read by the DS surface colors' dynamic providers AT RESOLVE TIME,
    /// which is what lets a theme change repaint chrome without every
    /// view being rebuilt: the closures re-run on redraw, not on init.
    private(set) static var light = warmLight
    private(set) static var dark = warmDark

    // MARK: - Loading

    static func reload(lightTheme: String?, darkTheme: String?) {
        lightBackground = lightTheme.flatMap(background(forTheme:))
        darkBackground = darkTheme.flatMap(background(forTheme:))
        light = lightBackground.map(tint(fromBackground:)) ?? warmLight
        dark = darkBackground.map(tint(fromBackground:)) ?? warmDark
        followed = nil
    }

    /// THE THEME'S BACKGROUND ITSELF, not just its temperature — for the
    /// wash laid over panes not in focus ([[PaneFocusPresentation]]). A
    /// wash is made of the color it sits on, or it is a second color:
    /// black over a light theme is a gray smear, chrome-gray over a dark
    /// one a haze. Nil when no theme could be read, and the wash falls
    /// back rather than borrowing the previous theme's color.
    private(set) static var lightBackground: NSColor?
    private(set) static var darkBackground: NSColor?

    /// WHAT THE TERMINAL SHOWS WHEN NO THEME IS NAMED: ghostty's own
    /// built-in background (Config.zig, `background = #282c34`). It is
    /// dark in either appearance — a fallback keyed on appearance measured
    /// wrong: a light-chrome window over an unthemed dark terminal washed
    /// the neighbours WHITE.
    static let ghosttyDefaultBackground = NSColor(
        calibratedRed: 0x28 / 255, green: 0x2c / 255, blue: 0x34 / 255, alpha: 1)

    static func terminalBackground(for appearance: NSAppearance) -> NSColor? {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let followed, followed.appearance == (isDark ? .darkAqua : .aqua) {
            return followed.background
        }
        return isDark ? darkBackground : lightBackground
    }

    /// THE FOCUSED PANE'S LIVE BACKGROUND, when a program set one (OSC
    /// 11). Overrides the theme's tint for the CURRENT appearance until
    /// the next theme reload; the theme is what the human chose, the
    /// program's color is what is actually on screen, and the seam this
    /// exists to remove is against what is on screen.
    private(set) static var followed: (appearance: NSAppearance.Name, tint: Tint, background: NSColor)?

    static func follow(background: NSColor) {
        let name: NSAppearance.Name =
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .darkAqua : .aqua
        followed = (name, tint(fromBackground: background), background)
    }

    /// What the ladder should draw with, for an appearance.
    static func current(for appearance: NSAppearance) -> Tint {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let followed, followed.appearance == (isDark ? .darkAqua : .aqua) { return followed.tint }
        return isDark ? dark : light
    }

    private static func background(forTheme name: String) -> NSColor? {
        guard let directory = themesDirectory else { return nil }
        guard let contents = try? String(contentsOfFile: "\(directory)/\(name)",
                                         encoding: .utf8) else { return nil }
        return parseBackground(contents)
    }

    /// Same two roots as `SynaptySettings.builtinThemeNames`: the bundle,
    /// then the dev checkout.
    private static var themesDirectory: String? {
        if let resPath = Bundle.main.resourcePath {
            let bundled = "\(resPath)/ghostty/themes"
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        let dev = "ghostty/zig-out/share/ghostty/themes"
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    // MARK: - The measurable parts

    /// `background = #rrggbb` out of a ghostty theme file. First match
    /// wins; palette lines also contain hex colors and must not.
    static func parseBackground(_ contents: String) -> NSColor? {
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "background"
            else { continue }
            return color(fromHex: parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func color(fromHex raw: String) -> NSColor? {
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func tint(fromBackground color: NSColor) -> Tint {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return Tint(hue: rgb.hueComponent,
                    chroma: min(rgb.saturationComponent, chromaCap))
    }
}
