import SwiftUI

/// Application settings page — grouped by user-facing concerns:
/// Appearance (app-level), Terminal, Scrolling, Clipboard, Network (Synapty).
struct SettingsPage: View {
    var settings: SynaptySettings
    var taskMonitor: TaskMonitor

    enum SettingsPane: Hashable {
        case appearance
        case terminal
        case network
        case github
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

            // Sub-navigation (WI-2026-08-08-052): Scrolling + Clipboard live
            // inside the Terminal pane — 4 balanced panes, not a 6-chip row.
            HStack(spacing: DS.Space.sm) {
                paneChip(.appearance, title: "Appearance", icon: "circle.lefthalf.filled")
                paneChip(.terminal, title: "Terminal", icon: "textformat")
                paneChip(.network, title: "Network", icon: "network")
                paneChip(.github, title: "GitHub", icon: "link")
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    switch pane {
                    case .appearance: appearanceSection
                    case .terminal: terminalSection
                    case .network: networkSection
                    case .github: githubSection
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

    // MARK: - Appearance (app-level)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            groupBlock("Mode") {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Text("Applies to the whole app — sidebar, settings and terminal chrome. In System mode Synapty follows macOS, including live changes.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }

            // App UI size (WI-2026-08-08-070): scales the app's own chrome.
            groupBlock("UI Size") {
                Picker("UI Size", selection: uiSizeBinding) {
                    Text("Small").tag(0.85)
                    Text("Standard").tag(1.0)
                    Text("Large").tag(1.15)
                    Text("Extra Large").tag(1.3)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Text("Scales the app's own interface (sidebar, lists, panels). The terminal font size is separate — see Terminal.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
    }

    // MARK: - Terminal (appearance + behavior)

    /// Complete terminal surface (WI-2026-08-08-052): the quick panel and
    /// this pane share the control components; fallback fonts, scrolling
    /// and clipboard are Settings-page-only.
    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            groupBlock("Theme") {
                SettingsThemeControls(settings: settings)
            }

            groupBlock("Font") {
                SettingsFontControls(settings: settings, families: fontFamilies)

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
                SettingsBackgroundOpacityControl(value: opacityBinding)
            }

            groupBlock("Cursor") {
                SettingsCursorControl(settings: settings)
            }

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
                Text("Scroll position is preserved (keystrokes and new output never snap to the bottom).")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }

            groupBlock("Clipboard") {
                Toggle("Copy on select", isOn: copyOnSelectBinding)
                    .toggleStyle(.switch)
                Text("Selecting text copies it to the clipboard immediately.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
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

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(get: { settings.appearanceMode }, set: { settings.appearanceMode = $0 })
    }

    private var uiSizeBinding: Binding<Double> {
        Binding(get: { settings.uiFontScale }, set: { settings.uiFontScale = $0 })
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { settings.backgroundOpacity ?? 1.0 },
            set: { settings.backgroundOpacity = $0 }
        )
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

    // MARK: - GitHub bridge (WI-2026-08-08-043 round follow-up)

    /// Shared GitHub bridge state (WI-2026-08-08-056) — one model +
    /// refresh/disconnect path for the Hub page and the Settings page.
    @State private var bridge = GithubBridgeController()
    @State private var showConnectSheet = false

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if let binding = bridge.binding {
                if binding.configured {
                    HStack(spacing: DS.Space.sm) {
                        DSStatusDot(color: DS.success, size: 8)
                        Text("\(binding.owner)/\(binding.repo)")
                            .font(DS.Typography.bodyStrong)
                        if let username = binding.username, !username.isEmpty {
                            Text("· \(username)")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.textSecondary)
                        }
                    }
                } else if binding.owner.isEmpty {
                    Text("Not connected — agents route task tools through this device once a hub repo is bound.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                } else {
                    Text("Credential missing for \(binding.owner)/\(binding.repo) — reconnect to restore it.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.warning)
                }
            } else {
                Text("Checking GitHub bridge…")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }

            HStack(spacing: DS.Space.sm) {
                Button {
                    showConnectSheet = true
                } label: {
                    Label(bridge.binding?.configured == true ? "Change" : "Connect GitHub", systemImage: "link.badge.plus")
                }
                .controlSize(.small)
                if bridge.binding?.owner.isEmpty == false {
                    Button {
                        bridge.disconnect()
                        taskMonitor.refreshTasks()
                    } label: {
                        Label(bridge.isDisconnecting ? "Disconnecting…" : "Disconnect", systemImage: "link.slash")
                    }
                    .controlSize(.small)
                    .disabled(bridge.isDisconnecting)
                }
            }
        }
        .padding(.vertical, DS.Space.md)
        .sheet(isPresented: $showConnectSheet) {
            GithubConnectSheet(
                isPresented: $showConnectSheet,
                onConnected: {
                    taskMonitor.refreshTasks()
                    bridge.refresh()
                }
            )
        }
        .onAppear {
            bridge.refresh()
        }
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
