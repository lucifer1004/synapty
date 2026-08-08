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
    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Brand

    /// Brand accent — teal. Used for focus indicators, active tabs, links.
    static let accent = dynamicColor(
        light: NSColor(red: 0.02, green: 0.45, blue: 0.48, alpha: 1),
        dark: NSColor(red: 0.25, green: 0.68, blue: 0.72, alpha: 1)
    )

    /// Softer accent for fills (badges, hovers).
    static let accentSoft = dynamicColor(
        light: NSColor(red: 0.02, green: 0.45, blue: 0.48, alpha: 0.12),
        dark: NSColor(red: 0.25, green: 0.68, blue: 0.72, alpha: 0.18)
    )

    // MARK: - Surfaces

    /// Main window background.
    static let background = dynamicColor(
        light: NSColor.windowBackgroundColor,
        dark: NSColor.windowBackgroundColor
    )

    /// Elevated surface (sheets, cards, find bar).
    static let surface = dynamicColor(
        light: NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1),
        dark: NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
    )

    /// Sidebar background (slightly distinct from the terminal area).
    static let sidebar = dynamicColor(
        light: NSColor(calibratedWhite: 0.97, alpha: 1),
        dark: NSColor(calibratedWhite: 0.11, alpha: 1)
    )

    /// Hover highlight for rows/cells.
    static let hover = dynamicColor(
        light: NSColor(calibratedWhite: 0, alpha: 0.05),
        dark: NSColor(calibratedWhite: 1, alpha: 0.07)
    )

    /// Selected row highlight.
    static let selection = dynamicColor(
        light: NSColor(calibratedWhite: 0, alpha: 0.08),
        dark: NSColor(calibratedWhite: 1, alpha: 0.12)
    )

    // MARK: - Borders & separators

    static let border = dynamicColor(
        light: NSColor(calibratedWhite: 0, alpha: 0.10),
        dark: NSColor(calibratedWhite: 1, alpha: 0.14)
    )

    static let separator = dynamicColor(
        light: NSColor.separatorColor,
        dark: NSColor.separatorColor
    )

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

    /// Global UI font scale — kept in sync with SynaptySettings.uiFontScale
    /// (WI-2026-08-08-070). Typography below reads it on every access, so a
    /// change repaints whatever recomputes its body.
    static var uiFontScale: CGFloat = 1.0

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
        /// 14pt — primary labels, session names.
        static var title: Font { .system(size: 14 * DS.uiFontScale, weight: .medium) }
        /// 16pt semibold — sheet titles.
        static var titleLarge: Font { .system(size: 16 * DS.uiFontScale, weight: .semibold) }
        /// Monospaced — IDs, addresses, logs, key caps.
        static var mono: Font { .system(size: 12 * DS.uiFontScale, design: .monospaced) }
        /// Monospaced caption — tiny IDs/timestamps.
        static var monoCaption: Font { .system(size: 11 * DS.uiFontScale, design: .monospaced) }
    }

    // MARK: - Spacing

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
    }

    // MARK: - Radii

    enum Radius {
        static let sm: CGFloat = 5
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let pill: CGFloat = 999
    }

    // MARK: - Layout metrics

    enum Layout {
        /// Bottom context bar height.
        static let statusBarHeight: CGFloat = 30
        /// Pane tab bar height.
        static let tabBarHeight: CGFloat = 34
        /// Sidebar width range.
        static let sidebarMinWidth: CGFloat = 180
        static let sidebarIdealWidth: CGFloat = 220
    }
}

// ===========================================================================
// Shared components
// ===========================================================================

// MARK: - Sheet header (title + close)

/// Uniform sheet header: leading icon + title, trailing close button.
struct DSSheetHeader: View {
    let title: String
    var icon: String? = nil
    @Binding var isPresented: Bool

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
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(DS.hover, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.lg)
    }
}

// MARK: - Section label

/// Uppercase section heading used in sidebars and sheets.
struct DSSectionLabel: View {
    let text: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text(text.uppercased())
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.textSecondary)
                .kerning(0.6)
            if let count {
                Text("\(count)")
                    .font(DS.Typography.monoCaption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
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
}

// MARK: - Badge

/// Small capsule badge (project counts, tags).
struct DSBadge: View {
    let text: String
    var color: Color = DS.textSecondary
    var highlighted: Bool = false

    var body: some View {
        Text(text)
            .font(DS.Typography.captionStrong)
            .foregroundStyle(highlighted ? color : DS.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                highlighted ? color.opacity(0.16) : DS.hover,
                in: Capsule()
            )
    }
}

// MARK: - Row hover background

/// Adds a subtle rounded hover/selection background to list rows.
struct DSRowBackground: ViewModifier {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = DS.Radius.md

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isSelected ? DS.selection : DS.hover)
            )
    }
}

// MARK: - Card

/// Elevated rounded surface for grouped content.
struct DSCard<Content: View>: View {
    var padding: CGFloat = DS.Space.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .stroke(DS.border, lineWidth: 1)
            )
    }
}

// MARK: - Divider style

extension Divider {
    /// Design-system separator (hairline, adaptive).
    static var ds: some View {
        Divider().overlay(DS.separator)
    }
}
