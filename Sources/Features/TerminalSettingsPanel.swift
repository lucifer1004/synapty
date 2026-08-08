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
                    // Quick subset note: the app-level Appearance mode lives
                    // on the Settings page only (WI-2026-08-08-052).
                    Text("Quick settings — apply live. Full set in Settings → Terminal.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                        .padding(.top, DS.Space.sm)

                    // Theme — light/dark pair side by side
                    section("Theme") {
                        SettingsThemeControls(settings: settings, pickerWidth: 118)
                    }

                    // Font
                    section("Font") {
                        SettingsFontControls(settings: settings, families: fontFamilies)
                    }

                    // Background opacity — debounced while dragging
                    section("Background") {
                        SettingsBackgroundOpacityControl(value: $localOpacity)
                            .onChange(of: localOpacity) { _, newValue in
                                scheduleOpacityWrite(newValue)
                            }
                    }

                    // Cursor
                    section("Cursor") {
                        SettingsCursorControl(settings: settings)
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
}
