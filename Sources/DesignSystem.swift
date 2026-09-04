import SwiftUI


import AppKit

// ===========================================================================
// Synapty Design System — the single source of truth for the UI language.
// Design-code driven: every color, font, spacing, radius and shared component
// lives here so views stay consistent and the look can evolve in one place.
//
// Palette rationale: Synapty is a terminal-native orchestration workbench
// ("Synapse + PTY"). The brand accent is a deep teal — a terminal-adjacent
// hue that reads as technical without being a generic blue. Semantic state
// colors (success/warning/danger/info) are desaturated variants that sit
// comfortably on both light and dark backgrounds.
// ===========================================================================

enum DS {

    // MARK: - Dynamic color helper

    /// Build a color that adapts to the current system appearance.
    private static func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    // MARK: - Brand

    /// Brand accent — teal. Used for focus indicators, active tabs, links.
    ///
    /// THE APPKIT TWIN IS THE SAME COLOUR, not a second pair of literals.
    /// The terminal surface draws through Core Animation, where a SwiftUI
    /// `Color` cannot go, and it was reaching for `controlAccentColor`
    /// instead — the SYSTEM accent, which [[ADR-0011]] decided against for
    /// exactly this: one surface answering a drag in the user's system
    /// blue while every other receiver answered in ours.
    static let accentNSColor = dynamicNSColor(
        light: NSColor(red: 0.02, green: 0.45, blue: 0.48, alpha: 1),
        dark: NSColor(red: 0.25, green: 0.68, blue: 0.72, alpha: 1)
    )
    static let accent = Color(nsColor: accentNSColor)

    // MARK: - Selection (ours, not the system's)

    /// SELECTION IS THE APPLICATION'S COLOUR, NOT THE SYSTEM'S
    /// ([[ADR-0011]], reversing the accent half of an earlier decision).
    ///
    /// This followed `controlAccentColor` for a while, on the argument that
    /// an app highlighting teal on a Mac set to blue reads as ported rather
    /// than written here. That argument turned out to be weak — what makes
    /// an app read as ported is foreign controls, typography, spacing and
    /// window chrome, all of which are native here — and it cost two things
    /// that are not weak.
    ///
    /// THE SYSTEM ACCENT IS AN UNCONTROLLABLE SIDE OF THE RELATIONSHIP. The
    /// default macOS blue measured too loud against this warm low-chroma
    /// paper, and it could not be tuned: any adjustment has to hold for
    /// every accent a human might set, and reducing chroma by lightening
    /// dropped white-on-accent text to 2.34:1 — measured, below the 3:1
    /// floor for large text. With our own colour both sides are ours, and
    /// the numbers are ours to keep: 5.53:1 in light, 6.06:1 in dark.
    ///
    /// AND THE BRAND COLOUR WAS NOT DOING THE JOB IT WAS SAID TO. The note
    /// this replaces claimed the teal was reserved for identity and
    /// meaning — status dots and badges. It was not: status is carried by
    /// the semantic colours in dozens of places, and the teal was tinting
    /// eleven decorative glyphs. It was free.
    ///
    /// What is given up, plainly: a human who set a non-default accent does
    /// not see it here. Most independent Mac applications behave this way.
    static var selectionAccent: Color { accent }

    /// Tinted fill for a selected or targeted region.
    static var selectionAccentSoft: Color { accentSoft }

    /// Foreground ON an accent fill. AppKit's `alternateSelectedControlTextColor`
    /// used to carry this, and it was doing real work: it guaranteed legible
    /// text on an accent we did not choose, including the yellow and orange
    /// ones where white fails. That guarantee is ours now, and it is met by
    /// a pair chosen for this exact teal rather than by a system promise.
    static var textOnSelection: Color { textOnAccent }

    /// Softer accent for fills (badges, hovers).
    /// The AppKit twin, for the terminal surface's Core Animation marks —
    /// same reason and same single source as `accentNSColor`.
    static let accentSoftNSColor = dynamicNSColor(
        light: NSColor(red: 0.02, green: 0.45, blue: 0.48, alpha: 0.12),
        dark: NSColor(red: 0.25, green: 0.68, blue: 0.72, alpha: 0.18)
    )
    static let accentSoft = Color(nsColor: accentSoftNSColor)

    /// Text/glyphs sitting ON an accent fill (DSSegmented selected
    /// segment): white over the dark light-mode teal, near-black over the
    /// LIGHT dark-mode cyan — plain white there washed out at ~1.6:1
    /// contrast (WI-2026-08-09-016 dark audit).
    static let textOnAccent = dynamicColor(
        light: .white,
        dark: NSColor(red: 0.10, green: 0.14, blue: 0.15, alpha: 1)
    )

    // MARK: - Surfaces

    /// EVERY SURFACE BELOW IS A LIGHTNESS RUNG WEARING THE THEME'S CAST
    /// ([[ChromeTint]]). The hierarchy — which rung sits above which — is
    /// this app's own and never moves; the hue comes from the terminal
    /// theme's background, because the terminal is the largest surface in
    /// the window and chrome that ignores its temperature collides with
    /// it at every seam (measured: warm 54,53,52 against GitHub Dark
    /// Dimmed's blue 35,39,45).
    ///
    /// RESOLVED AT DRAW TIME. The provider closure reads [[ChromeTint]]
    /// when the color is rendered, not when this token is built — so a
    /// theme change repaints chrome on redraw without a single view being
    /// reconstructed.
    private static func chromeLadder(
        lightBrightness: Double, dark darkBrightness: Double,
        lightTinted: Bool = true
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let tint = ChromeTint.current(for: appearance)
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(hue: tint.hue,
                               saturation: tint.chroma * ChromeTint.darkSpend,
                               brightness: darkBrightness, alpha: 1)
            }
            return NSColor(hue: tint.hue,
                           saturation: lightTinted ? tint.chroma * ChromeTint.lightSpend : 0,
                           brightness: lightBrightness, alpha: 1)
        })
    }

    /// Main window background — paper, not clinical gray.
    /// DEEPER IN LIGHT MODE, so a white card is a card
    /// ([[WI-2026-08-15-006]], deepened again in the 2026-09-01 review).
    ///
    /// Measured across the gap between two host cards, the light palette
    /// sat inside nine levels: page 246, card 255 — with the shadow
    /// contributing ONE, the whole structure of the page hung on a
    /// single-pixel hairline, and every page read as white rectangles on
    /// white. The standard is this app's own dark mode, which separates
    /// card from page by 13 levels and looks layered; 0.945 puts light
    /// mode at 14.
    static let background = chromeLadder(lightBrightness: 0.945, dark: 0.153)

    /// THE TERMINAL'S OWN BACKGROUND, for a wash laid OVER a terminal
    /// ([[PaneFocusPresentation]]). The chrome ladder above is the wrong
    /// color for that: a chrome-tinted wash over a themed grid is a second
    /// color on top of the theme's, where the theme's own only deepens it.
    /// Resolved at draw time like the ladder, so a theme change repaints
    /// the wash without a rebuild. With no theme named the terminal shows
    /// ghostty's built-in background, so that is the fallback — NOT a
    /// color picked by appearance, which is the chrome's business and not
    /// the grid's.
    static let terminalWash = Color(nsColor: NSColor(name: nil) { appearance in
        ChromeTint.terminalBackground(for: appearance) ?? ChromeTint.ghosttyDefaultBackground
    })

    /// Elevated surface (sheets, cards, find bar) — pure white in light
    /// mode (untinted: cards are content, not chrome); lifted gray in
    /// dark.
    static let surface = chromeLadder(lightBrightness: 1.0, dark: 0.200,
                                      lightTinted: false)

    /// The one chrome tone: the app's paper, a shade off the content
    /// so a flanking panel is distinguishable from what it flanks without
    /// being a different KIND of surface ([[WI-2026-08-15-005]]).
    static let chrome = chromeLadder(lightBrightness: 0.925, dark: 0.129)

    /// Sidebar background (slightly distinct from the terminal area).
    /// NOTE: the main sidebar now renders on DSVisualEffect vibrancy
    /// (WI-2026-08-08-090); this token remains for opaque fallbacks.
    static let sidebar = chromeLadder(lightBrightness: 0.97, dark: 0.11)

    /// Raised surface sitting ON background chrome (active tab, segmented
    /// thumb). Light: pure white with a whisper of shadow; dark: lifted
    /// gray — the Safari/Terminal active-tab treatment
    /// (WI-2026-08-08-090).
    static let surfaceRaised = chromeLadder(lightBrightness: 1.0, dark: 0.278,
                                            lightTinted: false)

    /// Hover highlight for rows/cells.
    static let hover = dynamicColor(
        light: NSColor(calibratedWhite: 0, alpha: 0.05),
        dark: NSColor(calibratedWhite: 1, alpha: 0.07)
    )

    /// Selected row highlight — the system's unemphasized selection color,
    /// exactly what native list rows use when not key (WI-2026-08-08-090).
    static let selection = dynamicColor(
        light: NSColor.unemphasizedSelectedContentBackgroundColor,
        dark: NSColor.unemphasizedSelectedContentBackgroundColor
    )



    // MARK: - Borders & separators

    /// Quiet hairline. THE SYSTEM SEPARATOR, not a hand-picked grey
    /// ([[WI-2026-08-15-006]]): `separatorColor` strengthens by itself
    /// when a human turns on Increase Contrast, and a colour we chose
    /// cannot — which would leave the one setting whose entire purpose is
    /// making edges visible with no effect on ours.
    ///
    /// `separator` was already this and `border` was a second, hand-picked
    /// token for the same job. One of them followed the system and the
    /// other did not, and callers had no way to know which they wanted.
    static let border = Color(nsColor: .separatorColor)

    static let separator = Color(nsColor: .separatorColor)

    // MARK: - Text

    static let textPrimary = dynamicColor(
        light: NSColor.labelColor,
        dark: NSColor.labelColor
    )

    static let textSecondary = dynamicColor(
        light: NSColor.secondaryLabelColor,
        dark: NSColor.secondaryLabelColor
    )

    static let textTertiary = dynamicColor(
        // Both modes hand-tuned for >= 4.5:1 contrast (WI-2026-08-07-004,
        // WI-2026-08-08-024): light ~4.6:1 on white, dark ~4.8:1 on the
        // darkest DS surface (0.11 gray). NSColor.tertiaryLabelColor only
        // reaches ~3.2:1 on dark surfaces.
        light: NSColor(red: 0.40, green: 0.40, blue: 0.42, alpha: 1),
        dark: NSColor(red: 0.62, green: 0.62, blue: 0.64, alpha: 1)
    )

    // MARK: - Semantic states
    // Desaturated, appearance-adaptive versions of the classic status hues.

    static let success = dynamicColor(
        light: NSColor(red: 0.12, green: 0.55, blue: 0.30, alpha: 1),
        dark: NSColor(red: 0.35, green: 0.78, blue: 0.50, alpha: 1)
    )

    static let warning = dynamicColor(
        light: NSColor(red: 0.80, green: 0.55, blue: 0.10, alpha: 1),
        dark: NSColor(red: 0.95, green: 0.72, blue: 0.30, alpha: 1)
    )

    static let danger = dynamicColor(
        light: NSColor(red: 0.78, green: 0.24, blue: 0.24, alpha: 1),
        dark: NSColor(red: 0.92, green: 0.42, blue: 0.40, alpha: 1)
    )

    static let info = dynamicColor(
        light: NSColor(red: 0.15, green: 0.42, blue: 0.72, alpha: 1),
        dark: NSColor(red: 0.40, green: 0.62, blue: 0.90, alpha: 1)
    )

    // MARK: - Typography

    /// WHAT EVERY SIZE BELOW IS MULTIPLIED BY, and the reason a change to
    /// it redraws what is already on screen.
    ///
    /// OBSERVABLE, NOT ANNOUNCED. It was a plain static, which SwiftUI
    /// cannot see, so making a change visible took two more things: a
    /// notification, and a tick counter in ContentView threaded as a
    /// binding into the notification handlers and read as `let _ = tick`
    /// purely to force a re-evaluation. A writer could then set the value
    /// and forget to announce it, which is exactly what `reloadFromDisk`
    /// did ([[WI-2026-08-28-010]]). Reading an observable during a body is
    /// tracked by SwiftUI itself, so the mistake is no longer available
    /// ([[WI-2026-08-28-021]]).
    ///
    /// NOT `SynaptySettings.shared` DIRECTLY: that singleton's init writes
    /// the ghostty fragment, and the design system must not be the thing
    /// that decides when a file is created.
    @Observable final class Scale {
        static let shared = Scale()
        var value: CGFloat = 1.0
    }

    static var uiFontScale: CGFloat {
        get { Scale.shared.value }
        set { Scale.shared.value = newValue }
    }

    /// Scale a layout dimension with the global UI font scale — for
    /// containers and columns whose content is text (popovers, sheets,
    /// panels, labeled columns). Fixed sizes clip or truncate once the
    /// text grows (WI-2026-08-08-090, large-scale inspector clipping).
    static func scaled(_ value: CGFloat) -> CGFloat {
        value * uiFontScale
    }

    /// How big a symbol is.
    ///
    /// A SYMBOL BESIDE TEXT TAKES THAT TEXT'S FONT, and there is no token
    /// here for it because none is needed — `.font(DS.Typography.body)` on
    /// the Image is the whole rule. It is the rule Apple's own applications
    /// follow, and the reason is that a symbol is punctuation for the
    /// sentence it sits in: sized on its own it drifts, and drift is what
    /// this project had. Measured before this: `body` text appeared beside
    /// symbols at 8, 10, 11, 12 and 13pt, and `caption` beside 6, 9, 10 and
    /// 11 — one text size, five icon sizes, chosen per call site.
    ///
    /// The tokens below are for symbols with NO text to follow — four
    /// roles, because a symbol does four genuinely different jobs and
    /// collapsing them would just move the arbitrariness somewhere else.
    enum Icon {
        /// A subordinate glyph in dense chrome: a tab badge, a status dot's
        /// symbol, a menu chevron. DELIBERATELY SMALLER than the text it
        /// modifies — it is a diacritic, not a word, and at the text's own
        /// size it competes with what it is marking.
        static var mark: Font { .system(size: 9 * DS.uiFontScale, weight: .semibold) }

        /// A symbol that is the whole control — a toolbar button, a close
        /// box. One size, because they are one thing.
        static var control: Font { .system(size: 11 * DS.uiFontScale, weight: .medium) }

        /// A glyph filling a container: the symbol inside a host card's
        /// 32pt tile. Its size follows the TILE, not any text, which is why
        /// it cannot take a Typography token.
        static var avatar: Font { .system(size: 14 * DS.uiFontScale, weight: .medium) }

        /// The large figure in an empty state, which is illustration rather
        /// than punctuation and is the one place a symbol leads.
        static var feature: Font { .system(size: 24 * DS.uiFontScale, weight: .regular) }
    }

    enum Typography {
        /// 11pt — metadata, timestamps, counts.
        static var caption: Font { .system(size: 11 * DS.uiFontScale) }
        /// 11pt semibold — section headers, badges.
        static var captionStrong: Font { .system(size: 11 * DS.uiFontScale, weight: .semibold) }
        /// 12pt — secondary rows, addresses.
        static var detail: Font { .system(size: 12 * DS.uiFontScale) }
        /// 12pt medium — labels in bars.
        static var detailStrong: Font { .system(size: 12 * DS.uiFontScale, weight: .medium) }
        /// 13pt — body rows.
        static var body: Font { .system(size: 13 * DS.uiFontScale) }
        /// 13pt medium — pane tabs.
        static var bodyStrong: Font { .system(size: 13 * DS.uiFontScale, weight: .medium) }
        // 14pt WAS HERE AND IS GONE. Between 13 and 16 it was not a step
        // anyone could see: Apple's own ladder jumps 13 → 15 → 17 → 22
        // precisely so each rung reads as a different rank, and a 1pt
        // difference from body reads as an accident rather than a level.
        // Its five callers took `bodyStrong`, which is what they were
        // reaching for — emphasis, not size.
        /// 16pt semibold — sheet titles.
        static var titleLarge: Font { .system(size: 16 * DS.uiFontScale, weight: .semibold) }
        /// 20pt semibold — THE PAGE TITLE, and only that ([[DSPageHeader]],
        /// [[WI-2026-09-02-011]]). At 16pt the page's name sat on the same
        /// rung as a sheet's, and the review read the four pages as having
        /// no top. One rung above, used once per page, is a top.
        static var pageTitle: Font { .system(size: 20 * DS.uiFontScale, weight: .semibold) }
        /// Monospaced — IDs, addresses, logs, key caps.
        static var mono: Font { .system(size: 12 * DS.uiFontScale, design: .monospaced) }
        /// Monospaced caption — tiny IDs/timestamps.
        static var monoCaption: Font { .system(size: 11 * DS.uiFontScale, design: .monospaced) }
    }

    // MARK: - Spacing

    /// SPACING SCALES WITH THE TYPE ([[WI-2026-08-15-002]]).
    ///
    /// Every step in `Typography` is multiplied by `uiFontScale` and these
    /// were constants, so at Extra Large the glyphs grew by a third and
    /// the boxes holding them did not. The visible result was truncation —
    /// a host address reading `operator@…loud:22` at 1.3 and
    /// `operator@remotehost:22` at 1.0 — and a general crowding that reads
    /// as a design failure rather than as a missing multiplication.
    ///
    /// A UI-size setting means "make this interface bigger", not "make the
    /// letters bigger in the same room".
    enum Space {
        static var xxs: CGFloat { DS.scaled(2) }
        static var xs: CGFloat { DS.scaled(4) }
        static var sm: CGFloat { DS.scaled(6) }
        static var md: CGFloat { DS.scaled(8) }
        static var lg: CGFloat { DS.scaled(12) }
        static var xl: CGFloat { DS.scaled(16) }
        static var xxl: CGFloat { DS.scaled(24) }
    }

    // MARK: - Radii

    /// Radii do NOT scale, deliberately: a corner is a property of the
    /// shape, not of the text inside it, and Apple's own controls keep
    /// their curvature across Dynamic Type sizes. Scaling them would make
    /// large-type cards read as rounder rather than as larger.
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let pill: CGFloat = 999
    }

    // MARK: - Layout metrics

    enum Layout {
        /// Bottom context bar height. Tracks the UI scale — a fixed bar
        /// under scaled content was one of the two-proportion-systems
        /// tells (WI-2026-08-09-009).
        static var statusBarHeight: CGFloat { DS.scaled(30) }
        /// Height of the hidden-titlebar strip (traffic lights live here).
        /// Standard macOS titlebar metric for .fullSizeContentView windows
        /// (WI-2026-08-08-090).
        static let titlebarInset: CGFloat = 28
    }
}

// MARK: - Vibrancy surface

/// NSVisualEffectView wrapper — behind-window vibrancy for chrome surfaces
/// (sidebar, overlay panels). This is what gives Finder/Notes sidebars the
/// frosted, desktop-tinted look (WI-2026-08-08-090).
/// THE ONE CHROME SURFACE ([[WI-2026-08-15-005]]).
///
/// Everything that FLANKS the content — the navigation sidebar, the
/// settings inspector, the status bar — is chrome and shares this
/// material; the content itself stays opaque. They were three surfaces in
/// two treatments, so the sidebar read as chrome and the inspector read
/// as more content, which is the inconsistency a human sees before they
/// can name it.
///
/// Two things can flatten it, and they answer different questions.
/// `accessibilityDisplayShouldReduceTransparency` is the SYSTEM's answer
/// and always wins — an accessibility setting must not need turning off
/// twice. The app's own switch covers what the system one cannot: a
/// human running a translucent TERMINAL may want opaque chrome, which is
/// a combination only this app has.
struct DSChromeBackground: View {
    @AppStorage("synapty.translucentChrome") private var translucent = true
    /// Re-read on the system's change notification rather than cached:
    /// the setting can be toggled while the app is running.
    @State private var systemReducesTransparency =
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    @State private var systemIncreasesContrast =
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

    var body: some View {
        Group {
            // Increase Contrast turns materials off too: it asks for
            // edges and tone the eye can separate, and a translucent
            // surface blending the desktop is the opposite of that. Same
            // class of setting as Reduce Transparency, so it is honoured
            // the same way rather than left to the app's own switch.
            if translucent && !systemReducesTransparency && !systemIncreasesContrast {
                // Vibrancy UNDER a wash of the app's own paper. The
                // material alone is neutral grey and blends the desktop,
                // which would make chrome the one part of this window that
                // is not warm — unifying the surfaces must not mean
                // unifying them onto the palette nobody chose.
                DSVisualEffect(material: .sidebar)
                    .overlay(DS.chrome.opacity(Self.wash))
            } else {
                DS.chrome
            }
        }
        .ignoresSafeArea()
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        ) { _ in
            systemReducesTransparency =
                NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            systemIncreasesContrast =
                NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
    }
}

extension DSChromeBackground {
    /// How much of the app's paper goes over the material.
    ///
    /// Enough to keep the window WARM — the material alone is neutral and
    /// blends the desktop, which would leave chrome the one part of this
    /// window not in the app's palette. Not so much that the vibrancy it
    /// is washing has nothing left to show.
    ///
    /// The frosted state reads LIGHTER than the content in dark mode and
    /// darker in light. That is what the material does — Finder and Music
    /// look the same way — and it was a mistake to spend a round trying
    /// to force one depth relationship on both states: reaching it in
    /// dark took a 0.95 wash, at which point nothing was being made
    /// translucent. What has to hold is that all chrome matches, and that
    /// chrome is distinguishable from content; both do, in all four
    /// combinations.
    static let wash: Double = 0.55
}

struct DSVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // .active, not .followsWindowActiveState: with follows-active the
        // material collapses to flat gray whenever the window is not key —
        // which is exactly when the user is inspecting the UI from another
        // app. Always-on vibrancy (WI-2026-08-08-090).
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// ===========================================================================
// Shared components
// ===========================================================================

// MARK: - Sheet header (title + close)

/// Uniform panel/inspector header: optional leading icon + title +
/// optional help popover, trailing close button (WI-2026-08-08-090
/// pass 2 — one header for sheets, inspectors and docked panels).
struct DSPanelHeader: View {
    let title: String
    var icon: String? = nil
    var help: String? = nil
    var closeHelp: String = "Close"
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .frame(width: 18)
            }
            Text(title)
                .font(DS.Typography.titleLarge)
            if let help {
                DSHelpButton(text: help)
            }
            Spacer()
            DSIconButton(icon: "xmark", help: closeHelp, size: 22) {
                onClose()
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.lg)
    }
}

/// Sheet variant of DSPanelHeader — closes via the presentation Binding
/// (WI-2026-08-08-072).
struct DSSheetHeader: View {
    let title: String
    var icon: String? = nil
    var help: String? = nil
    @Binding var isPresented: Bool

    var body: some View {
        DSPanelHeader(title: title, icon: icon, help: help) {
            isPresented = false
        }
    }
}

// MARK: - Section label

/// Uppercase section heading used in sidebars and sheets.
struct DSSectionLabel: View {
    let text: String
    var count: Int? = nil
    /// Data-derived labels (hostnames, project names) keep their case —
    /// uppercasing is chrome grammar, not data grammar (WI-2026-08-09-010).
    var preserveCase: Bool = false

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Text(preserveCase ? text : text.uppercased())
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.textSecondary)
                .kerning(preserveCase ? 0 : 0.6)
            if let count {
                // Separated capsule badge — a bare number glued to the
                // label read as part of the name ("HOSTS 11", "TEST 1";
                // WI-2026-08-09-010).
                Text("\(count)")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.textTertiary)
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, 1)
                    .background(DS.hover, in: Capsule())
            }
        }
    }
}

/// A SECTION HEADING THAT FOLDS ITS ROWS AWAY.
///
/// THE COUNT STAYS WHEN THE ROWS GO, and that is what makes this a fold
/// rather than a hiding. [[RFC-0015]] C-PANE-ARCHIVE requires its list to be
/// "reachable without knowing a session exists — a human tidying their
/// window does not remember what they closed"; a heading that showed only
/// SESSIONS while collapsed would give that human no reason to open it.
/// The number is what carries the obligation across the fold, so it is
/// drawn from the same call in both states rather than from a branch that
/// could lose one of them.
struct DSSectionDisclosure: View {

    let text: String
    var count: Int? = nil
    @Binding var collapsed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                collapsed.toggle()
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                // ONE GLYPH, TURNED. A pair of them (right/down) is two
                // images that can disagree about weight and baseline, and
                // it cannot animate between the states it describes.
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.textTertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: DS.scaled(10))
                DSSectionLabel(text: text, count: count)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(text)" : "Hide \(text)")
        .accessibilityLabel(text)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }
}

// MARK: - Segmented control (scaled)

/// Scalable segmented control (WI-2026-08-09-009) — replaces the native
/// segmented Picker in app chrome. System controls do not track
/// DS.uiFontScale, so at Large/XL every mixed row carried TWO proportion
/// systems: scaled text next to fixed-size segments. Accent-fill selected
/// segment matches the app's control accent language.
struct DSSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Option]

    struct Option {
        let value: Value
        var label: String?
        var icon: String?
        var help: String?
        /// Set for size segments: draw the sample letter at this point
        /// size instead of the label text.
        var sampleSize: CGFloat? = nil
    }

    /// Text segments.
    init(selection: Binding<Value>, options: [(Value, String)]) {
        self._selection = selection
        self.options = options.map { Option(value: $0.0, label: $0.1, icon: nil, help: nil) }
    }

    /// Icon segments (value, sfSymbol, help).
    init(selection: Binding<Value>, iconOptions: [(Value, String, String)]) {
        self._selection = selection
        self.options = iconOptions.map { Option(value: $0.0, label: nil, icon: $0.1, help: $0.2) }
    }

    /// SIZE segments: the control demonstrates what it sets, by drawing
    /// one letter at each size it offers.
    ///
    /// Four spelled-out sizes cannot fit a side panel — "Standard" broke
    /// across two lines and "Extra Large" wrapped — and no width setting
    /// fixes that for every language. A letter at four sizes needs no
    /// translation, never wraps, and answers "what does this do" without
    /// being read ([[WI-2026-08-15-004]]); it is what macOS itself uses
    /// for text size. The names stay as the tooltip and the spoken label,
    /// so nothing is lost for anyone who needs the word.
    init(selection: Binding<Value>, sizeOptions: [(Value, String, CGFloat)]) {
        self._selection = selection
        self.options = sizeOptions.map {
            Option(value: $0.0, label: $0.1, icon: nil, help: $0.1, sampleSize: $0.2)
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                segment(option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(DS.hover)
        )
    }


    /// Extracted so the type-checker sees three small expressions rather
    /// than one large one — inlined, this stopped compiling in reasonable
    /// time.
    @ViewBuilder
    private func segmentContent(_ option: Option) -> some View {
        Group {

                if let sample = option.sampleSize {
                    // One glyph, at the size this segment selects, sitting
                    // on a SHARED BASELINE. Centred, four sizes read as
                    // four separate objects that happen to differ;
                    // bottom-aligned they read as one letter at several
                    // sizes, which is the thing being chosen. Type sits on
                    // a baseline, and "A" has no descender, so a common
                    // bottom edge IS a common baseline.
                    // FIXED width, not a minimum: an "A" at 16pt is wider
                    // than one at 10pt, so a minimum lets each segment size
                    // to its own glyph and the four boxes come out
                    // different. Invisible until one is filled, and then
                    // the selected pill is visibly a different size from
                    // its neighbours and changes width as the selection
                    // moves. Wide enough for the largest sample.
                    Text("A")
                        .font(.system(size: DS.scaled(sample), weight: .medium))
                        .frame(height: DS.scaled(17), alignment: .bottom)
                        .frame(width: DS.scaled(20))
                } else if let icon = option.icon {
                    // Same reason: SF Symbols do not share an advance
                    // width, so `folder` and `paintbrush` produced two
                    // differently-sized segments in one control.
                    Image(systemName: icon)
                        .font(.system(size: DS.scaled(11), weight: .medium))
                        .frame(width: DS.scaled(18))
                } else {
                    // EVERY SEGMENT AS WIDE AS THE WIDEST LABEL.
                    //
                    // Sized to its own text, "Terminal" and "GitHub" become
                    // two different buttons in one control, and the pill
                    // changes width as the selection moves. Measured against
                    // this application's own native picker, whose labels run
                    // from three characters to five and whose segments come
                    // out within a few pixels of each other — content sizing
                    // cannot produce that, so equal width is the platform's
                    // behaviour and this was the deviation.
                    //
                    // The widest label is established by laying them all out
                    // hidden and showing only this one, which needs no
                    // measurement pass and no guess at a character width.
                    ZStack {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, other in
                            Text(other.label ?? "")
                                .font(DS.Typography.detailStrong)
                                .lineLimit(1)
                                .hidden()
                        }
                        Text(option.label ?? "")
                            .font(DS.Typography.detailStrong)
                            // A label that does not fit must compress, never
                            // break mid-word: "Standar/d" reads as a bug.
                            .lineLimit(1)
                    }
                }
        }
    }

    @ViewBuilder
    private func segment(_ option: Option) -> some View {
        let isSelected = option.value == selection
        Button {
            selection = option.value
        } label: {
            segmentContent(option)
            .foregroundStyle(isSelected ? DS.textOnSelection : DS.textSecondary)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.scaled(3))
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(isSelected ? DS.selectionAccent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(option.help ?? option.label ?? "")
        // Icon segments have no text child — the help string is the
        // VoiceOver label (WI-2026-08-09-020).
        .accessibilityLabel(option.label ?? option.help ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Help button (on-demand explanation)

/// "?" button + popover carrying a section's explanation — keeps forms
/// clean; the text appears only when asked (WI-2026-08-08-071).
struct DSHelpButton: View {
    let text: String
    @State private var showHelp = false

    var body: some View {
        Button {
            showHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(DS.textTertiary)
        }
        .buttonStyle(.plain)
        .help("Help")
        .accessibilityLabel("Help")
        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
            Text(text)
                .font(DS.Typography.detail)
                .foregroundStyle(DS.textPrimary)
                // Fixed width + vertical fixedSize: with only a maxWidth
                // the popover measures the single-line ideal height and
                // CLIPS the wrapped text (user report).
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: DS.scaled(280), alignment: .leading)
                .padding(DS.Space.md)
        }
    }
}

// MARK: - Section block (title row + content)

/// Section with a title row (title + optional help) and content — the one
/// shared section construct (WI-2026-08-08-073), replacing the private
/// groupBlock / formSection / section copies. Content sits in an
/// inset-grouped card with the label outside — the System Settings /
/// grouped-Form idiom (WI-2026-08-08-090).
struct DSSectionBlock<Content: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                DSSectionLabel(text: title)
                if let help {
                    DSHelpButton(text: help)
                }
            }
            .padding(.leading, DS.Space.xs)
            DSCard {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    content
                }
            }
        }
    }
}

// MARK: - Drag divider (resize handle)

/// Resize handle between two panes (WI-2026-08-08-080): a wide invisible
/// hit target with a resize cursor; the caller clamps the dragged width.
/// A separator ONE PHYSICAL PIXEL wide ([[WI-2026-08-15-007]]).
///
/// SwiftUI's `Divider` draws one POINT, which is two pixels on Retina —
/// twice every separator AppKit puts beside it. Measured on the window's
/// own boundaries: 2px where the system draws 1. The colour is already
/// `separatorColor`, which is tuned for a single-pixel line and reads
/// heavy at double the width.
///
/// The thickness comes from the environment so a window moved to a
/// non-Retina display redraws at that display's hairline.
struct DSHairline: View {
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(DS.border)
            .frame(
                width: axis == .vertical ? 1 / displayScale : nil,
                height: axis == .horizontal ? 1 / displayScale : nil)
    }
}

struct DSDragDivider: View {
    let onDrag: (CGFloat) -> Void
    var onEnded: () -> Void = {}

    var body: some View {
        Rectangle()
            // NOT `Color.clear` ([[WI-2026-08-15-007]]): this strip is 6pt
            // wide and runs the full height of the window, so a clear fill
            // showed the raw window background as a bright white seam
            // between the sidebar and the content — a line the width of a
            // scrollbar that nobody designed and every screenshot had.
            //
            // It belongs to the chrome it is attached to, so it wears the
            // chrome's tone and the boundary is the Divider beside it.
            .fill(DS.chrome)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                // GLOBAL, not the default local space ([[WI-2026-08-15-004]]).
                // This divider MOVES as the pane it sizes grows, so a
                // translation measured against its own origin is measured
                // against a moving ruler — the drag lags the pointer and
                // jumps when it catches up.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in onDrag(value.translation.width) }
                    .onEnded { _ in onEnded() }
            )
    }
}

// MARK: - Status dot

/// Semantic status dot with optional pulse.
struct DSStatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var pulsing: Bool = false

    @ViewBuilder
    var body: some View {
        // Color-only signal — parent rows carry the state in their
        // accessibility labels (WI-2026-08-09-020).
        Group {
            if pulsing {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .modifier(PulseAnimation())
            } else {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Divider style


// MARK: - Page header

/// Uniform management-page header (WI-2026-08-08-090): text-only title
/// (no accent icon — native macOS pane headers are plain), optional
/// trailing metadata caption, then trailing actions. Doubles as the page's
/// "toolbar row" under the hidden titlebar.
struct DSPageHeader<Trailing: View>: View {
    let title: String
    var meta: String? = nil
    @ViewBuilder var trailing: Trailing

    init(_ title: String, meta: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.meta = meta
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Text(title)
                .font(DS.Typography.pageTitle)
            Spacer()
            if let meta {
                Text(meta)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            trailing
        }
        .padding(.horizontal, DS.Space.xl)
        // Tighter header band (WI-2026-08-09-006) — content earns the room.
        .padding(.vertical, DS.Space.md)
        // CHROME, and for the same reason the pane tab bar is: this is the
        // top row of the content column, so its background is what fills
        // the title-bar strip above it ([[WI-2026-08-15-007]]). Left on
        // the page colour, that strip changed tone when the human switched
        // from the terminal — where the tab bar reaches it — to a
        // management page, where nothing did.
        .background(DSChromeBackground())
    }
}

// MARK: - Empty state

/// Native empty state — thin wrapper over ContentUnavailableView (macOS 14)
/// so every page's "nothing here" moment looks like Mail/Photos
/// (WI-2026-08-08-090).
struct DSEmptyState<Actions: View>: View {
    let icon: String
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: Actions

    init(icon: String, title: String, message: String? = nil,
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card (grouped content block)

/// Inset-grouped card — the System Settings content-block idiom: elevated
/// surface, continuous corners, hairline border (WI-2026-08-08-090).
struct DSCard<Content: View>: View {
    var padding: CGFloat = DS.Space.xl
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(DS.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(DS.border, lineWidth: 1)
            )
    }
}

// MARK: - Keycap hint

/// Keyboard-hint chip ("esc", "↩", "⌘K") — the quick-connect palette's
/// hint language, shared by every transient surface (WI-2026-08-09-004).
struct DSKeycap: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Typography.monoCaption)
            .foregroundStyle(DS.textTertiary)
            // Decorative shortcut hint — VoiceOver users get shortcuts
            // from the menus/labels, not floating keycaps
            // (WI-2026-08-09-020).
            .accessibilityHidden(true)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, 2)
            .background(
                DS.hover,
                in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
            )
    }
}

// MARK: - Floating panel chrome

extension View {
    /// Floating transient-surface chrome (palette, find bar): ultra-thin
    /// material, continuous corners, hairline border, deep soft shadow
    /// (WI-2026-08-09-004).
    func dsFloatingPanel() -> some View {
        self
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(DS.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    }
}

// MARK: - Keyboard list navigation

/// Arrow-key navigation for keyboard-first lists, via a scoped local
/// event monitor — the ONLY reliable layer while a TextField is focused:
/// the field editor consumes arrow keyDowns before onKeyPress fires AND
/// swallows moveUp:/moveDown: before onMoveCommand fires (hard-won in
/// WI-2026-08-09-003; generalized in WI-2026-08-09-004). `count` is a
/// closure so filtering stays live without reinstalling the monitor.
///
/// A LOCAL MONITOR SEES EVERY KEY IN THE APPLICATION, so it answers only
/// for a key headed to its own window while that window's field editor
/// is typing — anything else is somebody else's arrow, and a terminal's
/// shell history was one keypress from being stolen the day this was
/// reused outside a popover ([[WI-2026-09-02-026]]).
struct DSListKeyNavigation: ViewModifier {
    @Binding var selection: Int
    let count: () -> Int
    @State private var monitor: Any?
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window = $0 })
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard let window, event.window === window,
                          (window.firstResponder as? NSTextView)?.isFieldEditor == true
                    else { return event }
                    let n = count()
                    guard n > 0 else { return event }
                    let current = min(max(selection, 0), n - 1)
                    switch event.keyCode {
                    case 125: // down arrow
                        selection = min(current + 1, n - 1)
                        return nil
                    case 126: // up arrow
                        selection = max(current - 1, 0)
                        return nil
                    default:
                        return event
                    }
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// A SEARCH PALETTE IS NOT A GRID, and its keys cannot be focus-driven.
/// The field editor of a focused TextField consumes arrow keyDowns before
/// `onKeyPress` fires and swallows moveUp:/moveDown: before
/// `onMoveCommand` fires — learned the hard way in WI-2026-08-09-003. So
/// a palette, where the human types to filter and arrows to choose, keeps
/// its scoped monitor. The grid, which has no text field, does not.
extension View {
    func dsListKeyNavigation(selection: Binding<Int>, count: @escaping () -> Int) -> some View {
        modifier(DSListKeyNavigation(selection: selection, count: count))
    }
}

/// Where an arrow key lands in a grid, as a pure function of where you
/// were.
///
/// ALL THAT SURVIVES OF A KEY MONITOR. This was a ViewModifier holding a
/// global `NSEvent` monitor, which saw every keystroke in the application
/// and therefore had to work out by hand whether each one was its own —
/// a guard for the page being shown, another for no editor being open,
/// another for whether the human had used the keyboard yet. Every new
/// question added a condition, and three bugs hid among them in a single
/// day.
///
/// A view that only receives keys WHEN IT HAS FOCUS does not have to ask
/// any of that, so the guards are gone and the platform answers instead
/// (`.focusable`, `.onMoveCommand`, `.onKeyPress`). The arithmetic is the
/// one part that was never the monitor's business, so it stays — and it
/// stays tested.
enum GridCursor {

    /// ENTERING THE GRID IS NOT MOVING WITHIN IT. `selection` is -1 before
    /// the first arrow, meaning "not navigating", and applying a stride to
    /// that put ↓ on the LAST card of row one. Right looked correct only
    /// by coincidence — its stride is 1, and -1 + 1 is 0.
    /// Where the cursor is: which stacked grid, and where inside it.
    struct Position: Equatable {
        var section: Int
        var item: Int
    }

    /// The same movement across SEVERAL grids stacked vertically.
    ///
    /// A FLAT INDEX ACROSS THEM IS WRONG, which is the trap worth naming:
    /// with four columns and a groups grid holding two, ↓ from the first
    /// group would step four places and land on the third HOST — while the
    /// thing directly below it on screen is the first. Crossing a boundary
    /// keeps the COLUMN, not the offset.
    ///
    /// Left and right stay inside their section, because a row belongs to
    /// one grid; up and down cross, because the grids are stacked.
    static func next(from position: Position?, direction: MoveCommandDirection,
                     sections: [Int], columns: Int) -> Position? {
        let live = sections.enumerated().filter { $0.element > 0 }.map(\.offset)
        guard let firstLive = live.first else { return nil }
        guard let position, sections.indices.contains(position.section),
              sections[position.section] > 0
        else { return Position(section: firstLive, item: 0) }

        let c = max(1, columns)
        let count = sections[position.section]
        let item = min(position.item, count - 1)
        let column = item % c

        switch direction {
        case .right:
            return Position(section: position.section, item: min(item + 1, count - 1))
        case .left:
            return Position(section: position.section, item: max(item - 1, 0))
        case .down:
            if item + c < count {
                return Position(section: position.section, item: item + c)
            }
            guard let next = live.first(where: { $0 > position.section }) else {
                // The last row of the last section: go to its end rather
                // than refusing, so ↓ always means "further down".
                return Position(section: position.section, item: count - 1)
            }
            return Position(section: next, item: min(column, sections[next] - 1))
        case .up:
            if item - c >= 0 {
                return Position(section: position.section, item: item - c)
            }
            guard let previous = live.last(where: { $0 < position.section }) else {
                return Position(section: position.section, item: 0)
            }
            // The SAME COLUMN of that section's last row, which is what
            // sits directly above.
            let above = sections[previous]
            let lastRowStart = ((above - 1) / c) * c
            return Position(section: previous, item: min(lastRowStart + column, above - 1))
        @unknown default:
            return position
        }
    }

    static func next(from selection: Int, direction: MoveCommandDirection,
                     count: Int, columns: Int) -> Int {
        guard count > 0 else { return selection }
        guard selection >= 0 else { return 0 }
        let here = min(selection, count - 1)
        let row = max(1, columns)
        switch direction {
        case .right: return min(here + 1, count - 1)
        case .left: return max(here - 1, 0)
        case .down: return min(here + row, count - 1)
        case .up: return max(here - row, 0)
        @unknown default: return selection
        }
    }
}

// MARK: - Input field chrome

/// Unified text-input chrome — the same field language as DSDropdown and
/// the search field: rounded hover fill, hairline border, accent border
/// while focused (WI-2026-08-08-090 pass 2). Replaces the default
/// NSTextField `.roundedBorder` look:
///     TextField("Label", text: $x).dsField()
struct DSInputChrome: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .dsFieldShape(
                border: isFocused ? DS.selectionAccent : DS.border,
                lineWidth: isFocused ? 1.5 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

extension View {
    /// THE FIELD SHAPE, once: the padding, the rounded hover fill and the
    /// hairline around it.
    ///
    /// [[DSInputChrome]]'s own doc called this "the same field language as
    /// DSDropdown and the search field" while DSDropdown, ThemePicker and
    /// FontFamilyPicker each wrote it out again — four copies of a shape
    /// whose whole purpose is that fields look alike
    /// ([[WI-2026-08-28-020]]). What a focused field adds is the border,
    /// which is why that is the parameter.
    func dsFieldShape(border: Color = DS.border, lineWidth: CGFloat = 1) -> some View {
        self
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(DS.hover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .strokeBorder(border, lineWidth: lineWidth)
            )
    }

    /// Design-system input chrome for TextField / SecureField
    /// (see DSInputChrome).
    func dsField() -> some View { modifier(DSInputChrome()) }
}

// MARK: - Tag chip

/// Unified tag/filter chip (WI-2026-08-08-090 pass 2): `.accent` for tags
/// and active filters, `.neutral` for unselected suggestions. Optional
/// remove button.
struct DSTag: View {
    enum Style { case accent, neutral }
    let text: String
    var style: Style = .accent
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text(text)
                .font(DS.Typography.captionStrong)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(text)")
            }
        }
        .foregroundStyle(style == .accent ? DS.accent : DS.textSecondary)
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 2)
        .background(style == .accent ? DS.accentSoft : DS.hover, in: Capsule())
    }
}

// MARK: - Card chrome (interactive blocks)

extension View {
    /// Interactive card chrome shared by host/group/identity blocks:
    /// elevated surface, continuous corners, hover shadow, selection
    /// stroke (WI-2026-08-08-090 pass 2). One definition — cards cannot
    /// drift apart again.
    func dsCardChrome(isHovered: Bool, isSelected: Bool = false) -> some View {
        modifier(DSCardChrome(isHovered: isHovered, isSelected: isSelected))
    }
}

/// A HAIRLINE IS ONE PHYSICAL PIXEL ([[WI-2026-08-15-007]]).
///
/// `lineWidth: 1` is one POINT, which is two pixels on a Retina display —
/// twice the weight of every system separator beside it. Measured on a
/// card edge at native resolution: 2px of border where AppKit draws 1.
/// It matters more since the colour became `separatorColor`, which is
/// tuned for a single-pixel line and reads heavy at double the width.
///
/// Read from the environment rather than from `NSScreen.main`, so a
/// window dragged between a Retina and a non-Retina display redraws at
/// that display's hairline instead of the one it launched on.
struct DSCardChrome: ViewModifier {
    let isHovered: Bool
    let isSelected: Bool
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(DS.surface)
                    // 0.04/2pt measured as ONE level of separation on a
                    // real display — a shadow nobody can see is paint cost
                    // with no product ([[WI-2026-08-15-006]], 2026-09-01).
                    .shadow(
                        color: .black.opacity(isHovered ? 0.12 : 0.07),
                        radius: isHovered ? 5 : 3, x: 0, y: 1.5
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isSelected ? DS.selectionAccent : DS.border,
                        // A SELECTED edge stays a full point: it is a
                        // deliberate mark, not a separator, and a hairline
                        // in the accent colour reads as an artefact.
                        lineWidth: isSelected ? 1.5 : 1 / displayScale
                    )
            )
    }
}

// MARK: - Dropdown (unified menu picker)

/// Unified dropdown — replaces raw `.pickerStyle(.menu)` (default
/// NSPopUpButton chrome) so every dropdown matches the ThemePicker /
/// FontFamilyPicker trigger: rounded hover-filled field, hairline border,
/// small chevron (WI-2026-08-08-090). Options open in a native Menu with
/// a checkmark on the current value.
struct DSDropdown<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    /// Trigger label when `selection` matches no option.
    var placeholder: String = "None"
    /// Fixed trigger width; nil = stretch to the available row width.
    var width: CGFloat? = nil

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? placeholder
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: DS.Space.sm) {
                Text(currentLabel)
                    .font(DS.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.textTertiary)
            }
            .dsFieldShape()
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // .button + .plain keeps the custom label chrome; .borderlessButton
        // replaces it with the system pull-down look (accent text +
        // leading chevron) on macOS 26.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Form field (label above control)

/// How dense the surface is, which is the only thing that decides how big
/// its type should be.
///
/// A LABEL AND ITS CONTROL ARE THE SAME SIZE. This is the rule Apple's own
/// applications keep and the one this project was breaking: System Settings
/// puts a 13pt label beside a 13pt value; Xcode's inspector puts an 11pt
/// label above an 11pt one. The densities differ, and NEITHER mixes them —
/// but this project took the inspector's 11pt label and set it above a
/// native control rendering at 13, so every row in Settings read as a small
/// label pressed under a bigger value.
///
/// The hierarchy between them was never the size's job. Colour already does
/// it: the label is secondary, the value is not.
enum DSDensity {
    /// A full page: Settings, Hosts. Native controls render at 13 here, so
    /// the label does too.
    case page
    /// An inspector: the right-hand panel, sheets with `.controlSize(.small)`
    /// controls, which render at 11.
    case inspector

    var labelFont: Font {
        switch self {
        case .page: return DS.Typography.body
        case .inspector: return DS.Typography.caption
        }
    }
}

/// Labeled form field — label above the control, the stacked form idiom
/// (WI-2026-08-08-090). Replaces placeholder-only fields, which lose their
/// meaning once filled.
struct DSFormField<Content: View>: View {
    let label: String
    /// Inspector by default: this component was born in the right-hand
    /// panel and most of its callers are still there, so the density that
    /// needs no argument is the one most of them want.
    var density: DSDensity = .inspector
    @ViewBuilder var content: Content

    init(_ label: String, density: DSDensity = .inspector, @ViewBuilder content: () -> Content) {
        self.label = label
        self.density = density
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(density.labelFont)
                .foregroundStyle(DS.textSecondary)
            content
        }
    }
}

// MARK: - Icon button (borderless, hover fill)

/// Toolbar-style icon button: borderless at rest, soft fill on hover —
/// the native macOS toolbar-button behavior. Replaces the ad-hoc mix of
/// always-filled circles and rounded rects (WI-2026-08-08-090).
/// THE "MORE ACTIONS" MENU, once.
///
/// It was written out at four call sites — the same glyph, the same two
/// styles, the same suppressed indicator, the same tooltip — differing
/// only in which actions it offered ([[WI-2026-08-28-020]]). A control
/// that appears four times and is described four times is four places the
/// fifth appearance can differ from.
/// THE FOOT OF AN EDITING SHEET, once: a rule, Cancel, and the button
/// that commits.
///
/// Three sheets wrote it out — the host editor, the identity editor and
/// the group editor — and what they had to agree on was not the layout
/// but the BEHAVIOUR: which button Return reaches, which one Escape
/// reaches, and that the committing one is disabled until the form is
/// valid. Three copies agreeing by inspection ([[WI-2026-08-28-020]]).
///
/// [[DSSheetHeader]] is its other end and has always been one thing.
struct DSSheetFooter: View {
    let confirm: String
    let canConfirm: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DSHairline()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
                    .buttonStyle(.borderedProminent)
            }
            .padding(DS.Space.lg)
        }
    }
}

struct DSOverflowMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(DS.Icon.control)
                .foregroundStyle(DS.textSecondary)
        }
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }
}

struct DSIconButton: View {
    let icon: String
    let help: String
    var size: CGFloat = 24
    var role: ButtonRole? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? DS.textPrimary : DS.textSecondary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(isHovered ? DS.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        // The tooltip doubles as the VoiceOver label — icon-only buttons
        // are otherwise unlabeled (WI-2026-08-09-020) — less the chord,
        // which VoiceOver would read out as punctuation.
        .accessibilityLabel(Self.spokenLabel(help))
        .onHover { hovering in isHovered = hovering }
    }

    /// The tooltip without a trailing parenthesised chord: "Copy (⌘C)" is
    /// read as "Copy".
    static func spokenLabel(_ help: String) -> String {
        guard help.hasSuffix(")"), let open = help.lastIndex(of: "(") else { return help }
        let spoken = help[..<open].trimmingCharacters(in: .whitespaces)
        return spoken.isEmpty ? help : spoken
    }
}
