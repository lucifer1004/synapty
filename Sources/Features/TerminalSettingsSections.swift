import SwiftUI

// ===========================================================================
// Shared terminal-setting control groups (WI-2026-08-08-052).
//
// The single rendering path for controls that appear in two places: the
// Terminal quick panel shows a subset, the Settings → Terminal pane the
// complete surface (it adds fallback fonts, scrolling and clipboard).
//
// ONE form grammar everywhere (WI-2026-08-09-005 detail audit): every
// control carries a DSFormField label above it — no inline labels, no
// icon-only rows, no ragged intrinsic widths.
// ===========================================================================

/// Theme light/dark pair — two EQUAL columns.
struct SettingsThemeControls: View {
    let settings: SynaptySettings

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            DSFormField("Light theme") {
                ThemePicker(
                    selection: Binding(
                        get: { settings.lightThemeName },
                        set: { settings.lightThemeName = $0 }
                    ),
                    themes: SynaptySettings.builtinThemeNames,
                    width: nil
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DSFormField("Dark theme") {
                ThemePicker(
                    selection: Binding(
                        get: { settings.darkThemeName },
                        set: { settings.darkThemeName = $0 }
                    ),
                    themes: SynaptySettings.builtinThemeNames,
                    width: nil
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Primary font family + size stepper.
struct SettingsFontControls: View {
    let settings: SynaptySettings
    let families: [FontCatalog.Family]

    var body: some View {
        DSFormField("Family") {
            FontFamilyPicker(
                selection: Binding(
                    get: { settings.fontFamily },
                    set: { settings.fontFamily = $0 }
                ),
                families: families
            )
        }

        DSFormField("Size") {
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
                .labelsHidden()
                Text("\(Int(settings.fontSize ?? 12)) pt")
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
        DSFormField("Opacity") {
            HStack(spacing: DS.Space.md) {
                Slider(value: value, in: 0.1...1.0)
                Text(String(format: "%.0f%%", (value.wrappedValue) * 100))
                    .font(DS.Typography.monoCaption)
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: DS.scaled(40), alignment: .trailing)
            }
            .frame(maxWidth: DS.scaled(320), alignment: .leading)
        }
    }
}

/// Cursor style segmented picker.
struct SettingsCursorControl: View {
    let settings: SynaptySettings

    var body: some View {
        DSFormField("Style") {
            DSSegmented(
                selection: Binding(
                    get: { settings.cursorStyle },
                    set: { settings.cursorStyle = $0 }
                ),
                options: [(String?.none, "Default")]
                    + SynaptySettings.cursorStyleOptions.map { (String?.some($0.0), $0.1) }
            )
        }
    }
}
