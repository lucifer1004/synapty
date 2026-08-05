import SwiftUI

/// Application settings page — currently the terminal theme picker.
/// Kept as its own top-level page (toolbar gear icon), not nested under
/// Hosts.
struct SettingsPage: View {
    @ObservedObject var settings: SynaptySettings

    var body: some View {
        VStack(spacing: 0) {
            // Page header
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.accent)
                    .frame(width: 18)
                Text("Settings")
                    .font(DS.Typography.titleLarge)
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    // Terminal theme
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        DSSectionLabel(text: "Terminal Theme")
                        Text("Applies to all terminal panes. Picked from Ghostty's built-in themes (590+). Changes take effect on new panes.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)

                        Picker("Theme", selection: themeBinding) {
                            Text("Ghostty Default").tag(String?.none)
                            ForEach(SynaptySettings.builtinThemeNames(), id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 380)
                    }

                    // Managed config note
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        DSSectionLabel(text: "Managed Config")
                        Text("Synapty-managed settings are written to ~/.config/synapty/ghostty.conf (scroll-to-bottom, theme). Your personal Ghostty config is untouched.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
    }

    private var themeBinding: Binding<String?> {
        Binding(
            get: { settings.themeName },
            set: { settings.themeName = $0 }
        )
    }
}
