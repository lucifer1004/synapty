import SwiftUI

/// Application settings page — grouped by user-facing concerns:
/// Appearance (app-level), Terminal, Scrolling, Clipboard, Network (Synapty).
struct SettingsPage: View {
    var settings: SynaptySettings
    var taskMonitor: TaskMonitor

    enum SettingsPane: Hashable {
        case appearance
        case terminal
        case scrolling
        case clipboard
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

            // Sub-navigation
            HStack(spacing: DS.Space.sm) {
                paneChip(.appearance, title: "Appearance", icon: "circle.lefthalf.filled")
                paneChip(.terminal, title: "Terminal", icon: "textformat")
                paneChip(.scrolling, title: "Scrolling", icon: "arrow.up.to.line")
                paneChip(.clipboard, title: "Clipboard", icon: "doc.on.doc")
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
                    case .scrolling: scrollingSection
                    case .clipboard: clipboardSection
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
        }
    }

    // MARK: - Terminal (appearance)

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            groupBlock("Theme") {
                HStack(spacing: DS.Space.xl) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Light")
                            .font(DS.Typography.captionStrong)
                            .foregroundStyle(DS.textSecondary)
                        ThemePicker(selection: lightThemeBinding, themes: SynaptySettings.builtinThemeNames)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Dark")
                            .font(DS.Typography.captionStrong)
                            .foregroundStyle(DS.textSecondary)
                        ThemePicker(selection: darkThemeBinding, themes: SynaptySettings.builtinThemeNames)
                    }
                }
                Text("Each theme applies to its appearance mode (Settings → Appearance). Terminal colors switch live with the mode.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
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

    // MARK: - GitHub bridge (WI-2026-08-08-043 round follow-up)

    /// Binding state shown in Settings: the current binding (from
    /// `synapty github status`) + the Connect/Disconnect sheet.
    @State private var binding: GithubBridgeInfo?
    @State private var showConnectSheet = false

    /// Parsed `synapty github status` output (mirrors HubStatusSheet).
    struct GithubBridgeInfo {
        var owner: String
        var repo: String
        var username: String?
        var hasToken: Bool
        var configured: Bool { hasToken }
    }

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if let binding {
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
                    Label(binding?.configured == true ? "Change" : "Connect GitHub", systemImage: "link.badge.plus")
                }
                .controlSize(.small)
                if binding?.owner.isEmpty == false {
                    Button {
                        disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "link.slash")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, DS.Space.md)
        .sheet(isPresented: $showConnectSheet) {
            GithubConnectSheet(
                isPresented: $showConnectSheet,
                onConnected: {
                    taskMonitor.refreshTasks()
                    refreshBinding()
                }
            )
        }
        .onAppear {
            refreshBinding()
        }
    }

    private func refreshBinding() {
        guard let binary = SynaptyBinary.resolve() else { return }
        DispatchQueue.global(qos: .utility).async {
            let output = SubprocessRunner.run(
                executable: binary,
                arguments: ["github", "status"],
                timeout: 15
            )
            DispatchQueue.main.async {
                guard output.error == nil, !output.timedOut,
                      let data = output.stdout.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let configured = json["configured"] as? Bool
                else { return }
                binding = GithubBridgeInfo(
                    owner: json["owner"] as? String ?? "",
                    repo: json["repo"] as? String ?? "",
                    username: json["username"] as? String,
                    hasToken: configured
                )
            }
        }
    }

    private func disconnect() {
        guard let binary = SynaptyBinary.resolve() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = SubprocessRunner.run(
                executable: binary,
                arguments: ["github", "logout"],
                timeout: 20
            )
            DispatchQueue.main.async {
                binding = nil
                taskMonitor.refreshTasks()
                refreshBinding()
            }
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
