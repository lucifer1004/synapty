import SwiftUI

/// Application settings page — grouped by user-facing concerns:
/// Terminal (appearance), Scrolling, Clipboard, Network (Synapty).
struct SettingsPage: View {
    @ObservedObject var settings: SynaptySettings

    enum SettingsPane: Hashable {
        case terminal
        case scrolling
        case clipboard
        case network
    }

    @State private var pane: SettingsPane = .terminal

    /// Installed font families, loaded lazily when the page appears.
    @State private var fontFamilies: [FontCatalog.Family] = []

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

            // Sub-navigation
            HStack(spacing: DS.Space.sm) {
                paneChip(.terminal, title: "Terminal", icon: "textformat")
                paneChip(.scrolling, title: "Scrolling", icon: "arrow.up.to.line")
                paneChip(.clipboard, title: "Clipboard", icon: "doc.on.doc")
                paneChip(.network, title: "Network", icon: "network")
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    switch pane {
                    case .terminal: terminalSection
                    case .scrolling: scrollingSection
                    case .clipboard: clipboardSection
                    case .network: networkSection
                    }
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        .onAppear {
            if fontFamilies.isEmpty {
                fontFamilies = FontCatalog.load()
            }
        }
    }

    // MARK: - Terminal (appearance)

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            groupBlock("Theme") {
                Picker("Theme", selection: themeBinding) {
                    Text("Ghostty Default").tag(String?.none)
                    ForEach(SynaptySettings.builtinThemeNames(), id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 380)
            }

            groupBlock("Font") {
                FontFamilyPicker(selection: fontFamilyBinding, families: fontFamilies)
                    .frame(maxWidth: 380)

                HStack(spacing: DS.Space.md) {
                    Stepper("Size", value: fontSizeBinding, in: 6...48, step: 1)
                        .frame(width: 150)
                    if let fontSize = settings.fontSize {
                        Text("\(Int(fontSize)) pt")
                            .font(DS.Typography.monoCaption)
                            .foregroundStyle(DS.textSecondary)
                    }
                }

                // Fallback fonts for codepoints missing from the primary
                // (unicode symbols, Nerd Font icons, etc.).
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    DSSectionLabel(text: "Fallback Fonts")
                    ForEach(settings.fontFallbackFamilies, id: \.self) { family in
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: "textformat")
                                .font(.system(size: 10))
                                .foregroundStyle(DS.textTertiary)
                            Text(family)
                                .font(DS.Typography.detail)
                            Spacer()
                            Button {
                                settings.fontFallbackFamilies.removeAll { $0 == family }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    FontFamilyPicker(
                        selection: .constant(nil),
                        families: fontFamilies,
                        mode: .add,
                        alreadyAdded: Set(settings.fontFallbackFamilies),
                        onAdd: { settings.fontFallbackFamilies.append($0) }
                    )
                    .disabled(settings.fontFamily == nil)
                    Text("Used for glyphs missing from the primary font (e.g. Nerd Font icons, box drawing).")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                }
            }

            groupBlock("Background") {
                HStack(spacing: DS.Space.md) {
                    Text("Opacity")
                        .font(DS.Typography.detail)
                    Slider(value: opacityBinding, in: 0.1...1.0)
                        .frame(maxWidth: 260)
                    Text(String(format: "%.0f%%", (settings.backgroundOpacity ?? 1.0) * 100))
                        .font(DS.Typography.monoCaption)
                        .foregroundStyle(DS.textSecondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            groupBlock("Cursor") {
                Picker("Style", selection: cursorStyleBinding) {
                    Text("Default").tag(String?.none)
                    ForEach(SynaptySettings.cursorStyleOptions, id: \.0) { value, label in
                        Text(label).tag(String?.some(value))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }
        }
    }

    // MARK: - Scrolling

    private var scrollingSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            groupBlock("Scrollback") {
                Picker("Limit", selection: scrollbackBinding) {
                    Text("Default (10,000)").tag(Int?.none)
                    Text("1,000").tag(Int?.some(1000))
                    Text("10,000").tag(Int?.some(10_000))
                    Text("100,000").tag(Int?.some(100_000))
                    Text("1,000,000").tag(Int?.some(1_000_000))
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 380)
            }
            groupBlock("Behavior") {
                Text("Scroll position is preserved (keystrokes and new output never snap to the bottom).")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
    }

    // MARK: - Clipboard

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            groupBlock("Selection") {
                Toggle("Copy on select", isOn: copyOnSelectBinding)
                    .toggleStyle(.switch)
                Text("Selecting text copies it to the clipboard immediately.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
            groupBlock("Applications (OSC 52)") {
                Toggle("Allow apps to read clipboard", isOn: clipboardReadBinding)
                    .toggleStyle(.switch)
                Toggle("Allow apps to write clipboard", isOn: clipboardWriteBinding)
                    .toggleStyle(.switch)
                Text("Lets terminal programs (e.g. vim, tmux, agent tools) read or write the system clipboard.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
    }

    // MARK: - Network (Synapty)

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            groupBlock("Ports") {
                HStack(spacing: DS.Space.md) {
                    Text("Hub port")
                        .font(DS.Typography.detail)
                        .frame(width: 90, alignment: .leading)
                    TextField("9000", value: hubPortBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                HStack(spacing: DS.Space.md) {
                    Text("Tunnel port")
                        .font(DS.Typography.detail)
                        .frame(width: 90, alignment: .leading)
                    TextField("9000", value: tunnelPortBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                Text("Applied on the next Hub start / tunnel connection.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
            groupBlock("SSH") {
                Text("Connection robustness is managed automatically: fail-fast timeouts, keepalive probes and auto-reconnect.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
    }

    // MARK: - Helpers

    private func groupBlock(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionLabel(text: title)
            content()
        }
    }

    private func paneChip(_ target: SettingsPane, title: String, icon: String) -> some View {
        let isActive = pane == target
        return Button {
            pane = target
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(DS.Typography.detailStrong)
            }
            .foregroundStyle(isActive ? DS.accent : DS.textSecondary)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.pill)
                    .fill(isActive ? DS.accentSoft : DS.hover)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bindings

    private var themeBinding: Binding<String?> {
        Binding(get: { settings.themeName }, set: { settings.themeName = $0 })
    }

    private var fontFamilyBinding: Binding<String?> {
        Binding(get: { settings.fontFamily }, set: { settings.fontFamily = $0 })
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { settings.fontSize ?? 12 },
            set: { settings.fontSize = $0 }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { settings.backgroundOpacity ?? 1.0 },
            set: { settings.backgroundOpacity = $0 }
        )
    }

    private var cursorStyleBinding: Binding<String?> {
        Binding(get: { settings.cursorStyle }, set: { settings.cursorStyle = $0 })
    }

    private var scrollbackBinding: Binding<Int?> {
        Binding(get: { settings.scrollbackLimit }, set: { settings.scrollbackLimit = $0 })
    }

    private var copyOnSelectBinding: Binding<Bool> {
        Binding(
            get: { settings.copyOnSelect ?? false },
            set: { settings.copyOnSelect = $0 }
        )
    }

    private var clipboardReadBinding: Binding<Bool> {
        Binding(
            get: { settings.clipboardRead ?? true },
            set: { settings.clipboardRead = $0 }
        )
    }

    private var clipboardWriteBinding: Binding<Bool> {
        Binding(
            get: { settings.clipboardWrite ?? true },
            set: { settings.clipboardWrite = $0 }
        )
    }

    private var hubPortBinding: Binding<Int> {
        Binding(
            get: { settings.hubPort },
            set: { settings.hubPort = max(1, min($0, 65535)) }
        )
    }

    private var tunnelPortBinding: Binding<Int> {
        Binding(
            get: { settings.tunnelPort },
            set: { settings.tunnelPort = max(1, min($0, 65535)) }
        )
    }
}
