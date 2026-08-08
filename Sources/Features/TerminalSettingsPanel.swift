import SwiftUI

/// Collapsible right-hand panel with terminal-affecting settings
/// (WI-2026-08-07-002). Binds the same SynaptySettings as the Settings
/// page, so every change applies live through the existing reload chain.
/// Docks on the Terminal page; floats on other pages.
struct TerminalSettingsPanel: View {
    var settings: SynaptySettings
    var onClose: () -> Void = {}

    @State private var fontFamilies: [FontCatalog.Family] = []
    /// Local opacity while dragging; debounced write to settings.
    @State private var localOpacity: Double = 1.0
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Panel header
            HStack(spacing: DS.Space.sm) {
                Text("Terminal")
                    .font(DS.Typography.title)
                DSHelpButton(text: "Quick settings — apply live to the terminal. The full set lives in Settings → Terminal.")
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
                // Compact label+control rows (WI-2026-08-08-081).
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    row(icon: "sun.max", label: "Light theme") {
                        ThemePicker(
                            selection: Binding(
                                get: { settings.lightThemeName },
                                set: { settings.lightThemeName = $0 }
                            ),
                            themes: SynaptySettings.builtinThemeNames,
                            width: 150
                        )
                    }
                    row(icon: "moon", label: "Dark theme") {
                        ThemePicker(
                            selection: Binding(
                                get: { settings.darkThemeName },
                                set: { settings.darkThemeName = $0 }
                            ),
                            themes: SynaptySettings.builtinThemeNames,
                            width: 150
                        )
                    }
                    row(icon: "textformat", label: "Font family") {
                        FontFamilyPicker(
                            selection: Binding(
                                get: { settings.fontFamily },
                                set: { settings.fontFamily = $0 }
                            ),
                            families: fontFamilies
                        )
                    }
                    row(icon: "textformat.size", label: "Font size") {
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
                        if let size = settings.fontSize {
                            Text("\(Int(size)) pt")
                                .font(DS.Typography.monoCaption)
                                .foregroundStyle(DS.textSecondary)
                        }
                    }
                    row(icon: "opacity", label: "Background opacity") {
                        Slider(value: $localOpacity, in: 0.1...1.0)
                            .onChange(of: localOpacity) { _, newValue in
                                scheduleOpacityWrite(newValue)
                            }
                        Text("\(Int(localOpacity * 100))%")
                            .font(DS.Typography.monoCaption)
                            .foregroundStyle(DS.textSecondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    row(icon: "cursorarrow", label: "Cursor style") {
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
                        .labelsHidden()
                    }
                }
                .padding(DS.Space.lg)
            }
        }
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

    /// One compact row: fixed-width icon + control. Icons do not scale
    /// with the UI font, so rows never wrap at large UI sizes
    /// (WI-2026-08-08-082).
    private func row(icon: String, label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 18, alignment: .leading)
                .help(label)
                .accessibilityLabel(label)
            control()
            Spacer(minLength: 0)
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
}
