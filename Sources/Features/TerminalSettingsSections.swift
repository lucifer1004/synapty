import SwiftUI

// ===========================================================================
// Shared terminal-setting control groups (WI-2026-08-08-052).
//
// The Terminal quick panel and the Settings → Terminal pane used to render
// the same controls with duplicated layout code. These components are the
// single rendering path; the panel is a quick subset, the Settings page is
// the complete surface (it adds fallback fonts, scrolling and clipboard).
// ===========================================================================

/// Theme light/dark pair.
struct SettingsThemeControls: View {
    let settings: SynaptySettings
    /// Compact width for the quick panel; nil = natural width (Settings page).
    var pickerWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: DS.Space.xl) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Light")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.textSecondary)
                ThemePicker(
                    selection: Binding(
                        get: { settings.lightThemeName },
                        set: { settings.lightThemeName = $0 }
                    ),
                    themes: SynaptySettings.builtinThemeNames,
                    width: pickerWidth ?? 150
                )
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Dark")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.textSecondary)
                ThemePicker(
                    selection: Binding(
                        get: { settings.darkThemeName },
                        set: { settings.darkThemeName = $0 }
                    ),
                    themes: SynaptySettings.builtinThemeNames,
                    width: pickerWidth ?? 150
                )
            }
        }
    }
}

/// Primary font family + size stepper.
struct SettingsFontControls: View {
    let settings: SynaptySettings
    let families: [FontCatalog.Family]

    var body: some View {
        FontFamilyPicker(
            selection: Binding(
                get: { settings.fontFamily },
                set: { settings.fontFamily = $0 }
            ),
            families: families
        )
        .frame(maxWidth: 380, alignment: .leading)

        HStack(spacing: DS.Space.md) {
            Stepper(
                "Size",
                value: Binding(
                    get: { settings.fontSize ?? 12 },
                    set: { settings.fontSize = $0 }
                ),
                in: 6...48,
                step: 1
            )
            .frame(width: 150)
            if let fontSize = settings.fontSize {
                Text("\(Int(fontSize)) pt")
                    .font(DS.Typography.monoCaption)
                    .foregroundStyle(DS.textSecondary)
            }
        }
    }
}

/// Background opacity slider (binding supplied by the caller — the quick
/// panel debounces while dragging, the Settings page writes directly).
struct SettingsBackgroundOpacityControl: View {
    let value: Binding<Double>

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Text("Opacity")
                .font(DS.Typography.detail)
            Slider(value: value, in: 0.1...1.0)
                .frame(maxWidth: 260)
            Text(String(format: "%.0f%%", (value.wrappedValue) * 100))
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// Cursor style segmented picker.
struct SettingsCursorControl: View {
    let settings: SynaptySettings

    var body: some View {
        Picker(
            "Style",
            selection: Binding(
                get: { settings.cursorStyle },
                set: { settings.cursorStyle = $0 }
            )
        ) {
            Text("Default").tag(String?.none)
            ForEach(SynaptySettings.cursorStyleOptions, id: \.0) { value, label in
                Text(label).tag(String?.some(value))
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
    }
}
