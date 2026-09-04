import SwiftUI

/// Collapsible right-hand panel with terminal-affecting settings
/// (WI-2026-08-07-002). Binds the same SynaptySettings as the Settings
/// page, so every change applies live through the existing reload chain.
/// Docks on the Terminal page; floats on other pages.
struct TerminalSettingsPanel: View {
    /// The chrome material switch. Read here only to DISABLE the control
    /// when macOS has already answered — a switch that looks live while
    /// the system overrides it is worse than one that says why.
    @AppStorage("synapty.translucentChrome") private var translucentChrome = true
    @State private var systemReducesTransparency =
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    var settings: SynaptySettings
    /// Set when the panel host already draws the title bar inset, the view
    /// switcher and the close button. Two headers stacked is what happened
    /// the first time this was embedded ([[WI-2026-08-15-009]]).
    var chromeless = false
    var onClose: () -> Void = {}

    @State private var fontFamilies: [FontCatalog.Family] = []
    /// Local opacity while dragging; debounced write to settings.
    @State private var localOpacity: Double = 1.0
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if !chromeless {
                // Keep the header below the hidden-titlebar strip; the panel
                // surface itself still runs to the window top
                // (WI-2026-08-08-090).
                Color.clear
                    .frame(height: DS.Layout.titlebarInset)

                // Panel header
                DSPanelHeader(
                    title: "Appearance",
                    help: "Display settings — apply live. Mode and UI Size affect the whole app; the rest affect the terminal. The full terminal set lives in Settings → Terminal.",
                    closeHelp: CommandHint.help("Close panel", for: "settings.toggle-panel")
                ) { onClose() }

                DSHairline()
            }

            ScrollView {
                // ONE form grammar with the Settings page (labels above
                // controls, no cryptic icon rows — WI-2026-08-09-005
                // detail audit); shared control groups where the panel
                // and the page render the same thing.
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    DSFormField("Appearance") {
                        DSSegmented(
                            selection: Binding(
                                get: { settings.appearanceMode },
                                set: { settings.appearanceMode = $0 }
                            ),
                            options: AppearanceMode.allCases.map { ($0, $0.label) }
                        )
                    }
                    DSFormField("UI size") {
                        DSSegmented(
                            selection: Binding(
                                get: { settings.uiFontScale },
                                set: { settings.uiFontScale = $0 }
                            ),
                            sizeOptions: [
                                (0.85, "Small", 10),
                                (1.0, "Standard", 12),
                                (1.15, "Large", 14),
                                (1.3, "Extra Large", 16),
                            ]
                        )
                    }

                    DSFormField("Chrome") {
                        Toggle("Translucent", isOn: $translucentChrome)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help(systemReducesTransparency
                                  ? "Off while macOS is set to Reduce transparency."
                                  : "Frosted sidebar, inspector and status bar. "
                                    + "Turn off for a solid background — useful with a "
                                    + "translucent terminal.")
                            .disabled(systemReducesTransparency)
                    }

                    DSHairline()

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
                    DSFormField("Font family") {
                        FontFamilyPicker(
                            selection: Binding(
                                get: { settings.fontFamily },
                                set: { settings.fontFamily = $0 }
                            ),
                            families: fontFamilies
                        )
                    }
                    DSFormField("Font size") {
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

                    DSHairline()

                    SettingsBackgroundOpacityControl(value: $localOpacity)
                        .onChange(of: localOpacity) { _, newValue in
                            scheduleOpacityWrite(newValue)
                        }
                    SettingsCursorControl(settings: settings)
                }
                .padding(DS.Space.lg)
            }
        }
        // Chrome, not content — same surface as the sidebar it faces.
        .background(DSChromeBackground())
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

    // MARK: - Debounced opacity

    private func scheduleOpacityWrite(_ value: Double) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            settings.backgroundOpacity = value
        }
    }

    /// Flush any pending debounced write. Closing the panel inside the
    /// debounce window would otherwise discard the last slider change,
    /// which reappears as the old value on reopen ([[WI-2026-08-08-033]]).
    private func flushOpacityWrite(_ value: Double) {
        debounceTask?.cancel()
        debounceTask = nil
        settings.backgroundOpacity = value
    }
}
