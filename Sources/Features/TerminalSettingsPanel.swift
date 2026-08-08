import SwiftUI

/// Collapsible right-hand panel with terminal-affecting settings
/// (WI-2026-08-07-002). Binds the same SynaptySettings as the Settings
/// page, so every change applies live through the existing reload chain.
/// Docks on the Terminal page; floats on other pages.
struct TerminalSettingsPanel: View {
    @ObservedObject var settings: SynaptySettings
    var onClose: () -> Void = {}

    @State private var fontFamilies: [FontCatalog.Family] = []
    /// Local opacity while dragging; debounced write to settings.
    @State private var localOpacity: Double = 1.0
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Panel header
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.accent)
                Text("Terminal")
                    .font(DS.Typography.title)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.textTertiary)
                        .frame(width: 20, height: 20)
                        .background(DS.hover, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close panel (⌘⌥P)")
                .accessibilityLabel("Close panel")
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    Text("Changes apply live to the terminal")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                        .padding(.top, DS.Space.sm)

                    // Appearance
                    section("Appearance") {
                        Picker("Appearance", selection: appearanceBinding) {
                            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    // Theme — light/dark pair side by side
                    section("Theme") {
                        HStack(spacing: DS.Space.md) {
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                Text("Light")
                                    .font(DS.Typography.captionStrong)
                                    .foregroundStyle(DS.textSecondary)
                                ThemePicker(selection: lightThemeBinding, themes: SynaptySettings.builtinThemeNames, width: 118)
                            }
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                Text("Dark")
                                    .font(DS.Typography.captionStrong)
                                    .foregroundStyle(DS.textSecondary)
                                ThemePicker(selection: darkThemeBinding, themes: SynaptySettings.builtinThemeNames, width: 118)
                            }
                        }
                        Text("Follows the Appearance mode above")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                    }

                    // Font
                    section("Font") {
                        FontFamilyPicker(selection: fontFamilyBinding, families: fontFamilies)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: DS.Space.md) {
                            Stepper("Size", value: fontSizeBinding, in: 6...48, step: 1)
                            if let size = settings.fontSize {
                                Text("\(Int(size)) pt")
                                    .font(DS.Typography.monoCaption)
                                    .foregroundStyle(DS.textSecondary)
                            }
                        }
                    }

                    // Background opacity — debounced while dragging
                    section("Background") {
                        HStack(spacing: DS.Space.md) {
                            Slider(value: $localOpacity, in: 0.1...1.0)
                            Text("\(Int(localOpacity * 100))%")
                                .font(DS.Typography.monoCaption)
                                .foregroundStyle(DS.textSecondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .onChange(of: localOpacity) { _, newValue in
                            scheduleOpacityWrite(newValue)
                        }
                    }

                    // Cursor
                    section("Cursor") {
                        Picker("Cursor", selection: cursorStyleBinding) {
                            Text("Default").tag(String?.none)
                            ForEach(SynaptySettings.cursorStyleOptions, id: \.0) { value, label in
                                Text(label).tag(String?.some(value))
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.lg)
            }
        }
        .frame(width: 300)
        .background(DS.surface)
        .onAppear {
            if fontFamilies.isEmpty {
                fontFamilies = FontCatalog.load()
            }
            localOpacity = settings.backgroundOpacity ?? 1.0
        }
        .onDisappear {
            // Persist the pending value instead of dropping it
            // (WI-2026-08-08-033). The slider binding keeps localOpacity
            // current, so flushing it is always the right final write.
            flushOpacityWrite(localOpacity)
        }
    }

    // MARK: - Sections

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionLabel(text: title)
            content()
        }
    }

    // MARK: - Debounced opacity

    private func scheduleOpacityWrite(_ value: Double) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            settings.backgroundOpacity = value
        }
    }

    /// Flush any pending debounced write — closing the panel within the
    /// debounce window used to DROP the last slider change (it snapped
    /// back on reopen; WI-2026-08-08-033).
    private func flushOpacityWrite(_ value: Double) {
        debounceTask?.cancel()
        debounceTask = nil
        settings.backgroundOpacity = value
    }

    // MARK: - Bindings

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(get: { settings.appearanceMode }, set: { settings.appearanceMode = $0 })
    }

    private var lightThemeBinding: Binding<String?> {
        Binding(get: { settings.lightThemeName }, set: { settings.lightThemeName = $0 })
    }

    private var darkThemeBinding: Binding<String?> {
        Binding(get: { settings.darkThemeName }, set: { settings.darkThemeName = $0 })
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

    private var cursorStyleBinding: Binding<String?> {
        Binding(get: { settings.cursorStyle }, set: { settings.cursorStyle = $0 })
    }
}
