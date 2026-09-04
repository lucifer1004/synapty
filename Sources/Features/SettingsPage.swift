import SwiftUI

/// Application settings page — one pane per concern: Terminal, Keys,
/// Agents, Network, GitHub (`SettingsPane`).
struct SettingsPage: View {
    var settings: SynaptySettings
    var taskMonitor: TaskMonitor
    /// Optional so every existing construction site keeps compiling; the
    /// arming section simply does not render without it.
    var execController: ExecController? = nil
    /// Likewise for the standing transfer grants and the machine names
    /// they are written in.
    var transferAuthority: TransferAuthority? = nil
    var hostStore: HostStore? = nil

    /// FOUR PANES, because three were carrying six subjects. "Terminal"
    /// had become the pane everything landed in — agent authority and log
    /// levels sat beside cursor style — while Network held one block that
    /// was about agents and not about the network at all. The weight came
    /// out uneven because the SORTING was wrong, not because the content
    /// is: 188 lines against 30 and 64.
    enum SettingsPane: Hashable {
        case terminal
        /// Every chord the workbench answers to, and the only place they
        /// are changed ([[RFC-0016]] C-REBIND, C-DISCOVERY).
        case keys
        /// How much an agent may do here. Its own pane because it keeps
        /// growing — a toggle, a transfer limit, a resume policy — and
        /// because "what have I given them" should be one place to look.
        case agents
        case network
        case github
    }

    @State private var pane: SettingsPane = .terminal

    /// Dev-only, for screenshots ([[DevLaunchArgs]]).
    private static func launchPane() -> SettingsPane? {
        switch DevLaunchArgs.settingsPane {
        case "terminal": return .terminal
        case "keys": return .keys
        case "agents": return .agents
        case "network": return .network
        case "github": return .github
        default: return nil
        }
    }

    /// Installed font families, loaded lazily when the page appears.
    @State private var fontFamilies: [FontCatalog.Family] = []

    /// Fonts this configuration names that are not installed here.
    /// Empty is the normal state and renders nothing — a capability that
    /// works is invisible by working.
    private var fontGaps: [SettingsReadiness.Gap] {
        SettingsReadiness.evaluate(
            fontFamily: settings.fontFamily,
            fallbackFamilies: settings.fontFallbackFamilies,
            installed: Set(fontFamilies.map(\.name)))
    }

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("Settings")

            DSHairline()

            // Sub-navigation (WI-2026-08-08-052): Scrolling + Clipboard live
            // inside the Terminal pane. Native segmented control
            // (WI-2026-08-08-090).
            HStack {
                DSSegmented(selection: $pane, options: [
                    (SettingsPane.terminal, "Terminal"),
                    (.keys, "Keys"),
                    (.agents, "Agents"),
                    (.network, "Network"),
                    (.github, "GitHub"),
                ])
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.md)

            ScrollView {
                // THE CARDS FLOW INTO AS MANY CAPPED COLUMNS AS FIT
                // ([[ReadingColumns]]). A single column bounded at a
                // readable width left the right half of a wide window
                // empty; widening the column instead would put a label at
                // one end of the page and its switch at the other.
                ReadingColumns(maxColumnWidth: DS.scaled(700),
                               spacing: DS.Space.xl) {
                    switch pane {
                    case .terminal: terminalSection
                    case .keys: KeysSettingsView()
                    case .agents: agentsSection
                    case .network: networkSection
                    case .github: githubSection
                    }
                }
                .padding(DS.Space.xl)
                // ONE LEFT EDGE FOR THE WHOLE PAGE. The reading column is
                // still bounded — System Settings constrains content width
                // rather than stretching controls (WI-2026-08-08-090) —
                // but it is bounded from the SAME edge the page title and
                // the pane picker start at, not centred in whatever is
                // left over.
                //
                // Centred, the title sat at one x and the content at
                // another, with a few hundred points of nothing between
                // them; the wider the window, the wider the gap. Two left
                // edges on one page is the kind of thing that reads as
                // "unfinished" without the eye being able to say why.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        .onAppear {
            if let launch = Self.launchPane() { pane = launch }
            if fontFamilies.isEmpty {
                fontFamilies = FontCatalog.load()
            }
        }
    }

    // MARK: - Terminal (appearance + behavior)

    /// Complete terminal surface (WI-2026-08-08-052): the quick panel and
    /// this pane share the control components; fallback fonts, scrolling
    /// and clipboard are Settings-page-only.
    @ViewBuilder
    private var terminalSection: some View {
            DSSectionBlock(
                title: "Theme",
                help: "Each theme applies to its appearance mode (Settings → Appearance). Terminal colors switch live with the mode."
            ) {
                SettingsThemeControls(settings: settings)
            }

            DSSectionBlock(title: "Font") {
                SettingsFontControls(settings: settings, families: fontFamilies)

                // Fallback fonts for codepoints missing from the primary
                // (unicode symbols, Nerd Font icons, etc.). Form-field
                // label grammar — DSSectionLabel is reserved for labels
                // OUTSIDE cards (WI-2026-08-09-005 detail audit).
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack(spacing: DS.Space.xs) {
                        Text("Fallback fonts")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textSecondary)
                        DSHelpButton(text: "Used for glyphs missing from the primary font (e.g. Nerd Font icons, box drawing).")
                    }
                    ForEach(settings.fontFallbackFamilies, id: \.self) { family in
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: "textformat")
                                .font(DS.Typography.detail)
                                .foregroundStyle(DS.textTertiary)
                            Text(family)
                                .font(DS.Typography.detail)
                            Spacer()
                            Button {
                                settings.fontFallbackFamilies.removeAll { $0 == family }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(DS.Icon.control)
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

                    // A synced setting can name a font this Mac does not
                    // have ([[WI-2026-08-13-005]] carries appearance
                    // across Macs). Ghostty then substitutes silently, and
                    // the human sees different type with nothing anywhere
                    // explaining it. Said here, where they would go to fix
                    // it, rather than left to be noticed.
                    ForEach(fontGaps, id: \.summary) { gap in
                        HStack(alignment: .top, spacing: DS.Space.xs) {
                            Image(systemName: "textformat.size")
                                .font(DS.Typography.detail)
                                .foregroundStyle(DS.warning)
                            Text(gap.summary)
                                .font(DS.Typography.detail)
                                .foregroundStyle(DS.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(gap.summary)
                    }
                }
            }



            DSSectionBlock(title: "Background") {
                SettingsBackgroundOpacityControl(value: opacityBinding)
            }

            DSSectionBlock(title: "Cursor") {
                SettingsCursorControl(settings: settings)
            }

            DSSectionBlock(
                title: "Scrollback",
                help: "Scroll position is preserved — keystrokes and new output never snap to the bottom."
            ) {
                DSFormField("Limit", density: .page) {
                    DSDropdown(
                        selection: scrollbackBinding,
                        options: [
                            (Int?.none, "Default (10,000)"),
                            (Int?.some(1000), "1,000"),
                            (Int?.some(10_000), "10,000"),
                            (Int?.some(100_000), "100,000"),
                            (Int?.some(1_000_000), "1,000,000"),
                        ],
                        width: DS.scaled(220)
                    )
                }
            }

            DSSectionBlock(
                title: "Clipboard",
                help: "Lets terminal programs (e.g. vim, tmux, agent tools) read or write the system clipboard."
            ) {
                // Switches in a right-aligned COLUMN — the System Settings
                // toggle-row layout (WI-2026-08-09-005 detail audit).
                toggleRow("Copy on select", copyOnSelectBinding)
                DSHairline()
                toggleRow("Allow apps to read clipboard", clipboardReadBinding)
                DSHairline()
                toggleRow("Allow apps to write clipboard", clipboardWriteBinding)
            }
    }

    /// WHAT THE HUMAN ACTUALLY SAID YES TO, and the only place to take it
    /// back.
    ///
    /// The two controls above are POLICY — dials set once, in advance, for
    /// agents in general. A grant is a different kind of thing: standing
    /// state a human created by answering a question about one route, on
    /// one day. `revoke` and `grants` were written for this, doc-commented
    /// "a capability nobody can enumerate is one nobody can withdraw", and
    /// had no caller — so the only way to take back a route was to quit.
    ///
    /// [[RFC-0013]] C-BROKER rests its whole argument for preferring a
    /// relay to a key in authorized_keys on the ability being "scoped,
    /// gated, recorded and withdrawn, where a key in authorized_keys is
    /// account-wide, permanent and silently retained". Two of those four
    /// were only true here in the sense that quitting the app is a form of
    /// withdrawal.
    @ViewBuilder
    private var grantsBlock: some View {
        if let authority = transferAuthority {
            DSSectionBlock(
                title: "Routes you have allowed",
                help: "When an agent asks to send a file between two machines, you answer once "
                    + "and the answer covers that route — one direction, any file — until you "
                    + "quit.\n\nWithdrawing stops new transfers along the route and cancels any "
                    + "the agent has asked for that have not started. A copy already running "
                    + "finishes: the bytes are in an scp there is no way to call back."
            ) {
                if authority.grants.isEmpty {
                    Text("Nothing allowed. Agents ask before sending between machines.")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textSecondary)
                } else {
                    ForEach(Array(authority.grants.enumerated()), id: \.element) { index, pair in
                        if index > 0 { DSHairline().padding(.vertical, DS.Space.xs) }
                        HStack(spacing: DS.Space.sm) {
                            // THE SAME SENTENCE THE SHEET ASKED IN. A grant
                            // a human withdraws must read as it did when
                            // they made it, or they are matching a row
                            // against a memory of different words.
                            Text("\(machineName(pair.from)) → \(machineName(pair.to))")
                                .font(DS.Typography.body)
                            Spacer(minLength: DS.Space.sm)
                            Button("Withdraw") { authority.revoke(pair) }
                                .controlSize(.small)
                        }
                    }
                }
            }

            // THE OTHER ANSWER, LISTED FOR THE SAME REASON. A no that the
            // human cannot see is a no they cannot take back, and until
            // Deny recorded anything the agent simply asked again.
            if !authority.refusals.isEmpty {
                DSSectionBlock(
                    title: "Routes you have refused",
                    help: "An agent that asks about one of these is told no without "
                        + "reaching you.\n\nUndoing does NOT allow the route — it lets "
                        + "the agent put the question in front of you again."
                ) {
                    ForEach(Array(authority.refusals.enumerated()), id: \.element) { index, pair in
                        if index > 0 { DSHairline().padding(.vertical, DS.Space.xs) }
                        HStack(spacing: DS.Space.sm) {
                            Text("\(machineName(pair.from)) → \(machineName(pair.to))")
                                .font(DS.Typography.body)
                            Spacer(minLength: DS.Space.sm)
                            Button("Undo") { authority.allowAsking(pair) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func machineName(_ hostID: UUID?) -> String {
        hostStore?.displayName(of: hostID) ?? "a machine"
    }

    // MARK: - Network (Synapty)

    /// Everything an agent is allowed to do on this workbench.
    ///
    /// Two of these came from the Terminal pane and one from Network, where
    /// none of them were about a terminal or about a network. Together they
    /// answer one question — what have I given them — and that is a
    /// question a human should be able to answer by looking in one place.
    @ViewBuilder
    private var agentsSection: some View {
            DSSectionBlock(
                title: "Agent exec panes",
                help: "Agents can open scratch panes and run shell commands as you. "
                    + "Off by default; disarming stops new runs and cancels waits. While armed, "
                    + "the status bar says so and clicking it disarms.\n\n"
                    + "The transfer limit bounds what an agent can ask for unattended — your own "
                    + "drags are not limited. Every byte crosses this Mac twice and shares the "
                    + "connection carrying your keystrokes. Exceeding it is refused by name, never "
                    + "truncated. Both settings sync to your other Macs."
            ) {
                // Moved out of the hub popover. An arming switch is a
                // standing grant to run shell commands as the human, and
                // a popover dismisses when you look away — the wrong
                // container for a decision that persists. The ARMED state
                // now lives in the status bar where [[RFC-0007]]
                // C-EXEC-AUTHORITY requires it, and doubles as the
                // one-click disarm.
                if let exec = execController {
                    Toggle(isOn: Binding(get: { exec.armed }, set: { exec.setArmed($0) })) {
                        Text("Let registered agents open scratch panes")
                            .font(DS.Typography.bodyStrong)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                DSHairline().padding(.vertical, DS.Space.sm)

                // THE OTHER HALF OF THE SAME QUESTION as the toggle above:
                // how much authority an agent has here. Keeping both in one
                // place is what lets a human answer "what have I given
                // them" by looking once.
                DSFormField("Most an agent may transfer at once", density: .page) {
                    HStack(spacing: DS.Space.sm) {
                        TextField("", value: Binding(
                            get: { settings.agentTransferLimitMB },
                            set: { settings.agentTransferLimitMB = max(1, $0) }
                        ), format: .number)
                        .frame(width: DS.scaled(80))
                        .multilineTextAlignment(.trailing)
                        Text("MB")
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            grantsBlock
            // [[RFC-0014]] C-SCOPE, C-OPT-OUT: refusable on this machine
            // on the same terms as any host, and AS REACHABLE — a setting
            // with no control is not a choice the human has.
            DSSectionBlock(
                title: "Keep This Mac's Panes Running",
                help: "A pane on this Mac keeps its shell alive when you close the window, "
                    + "and returns to it when you reopen — the same way a pane on a host does. "
                    + "Turn this off and a pane ends with the window. "
                    + "What is running keeps running either way until you end it: "
                    + "`synapty sessions` lists them and `synapty end` closes one."
            ) {
                Toggle(isOn: Binding(
                    get: { settings.localDurableSessions },
                    set: { settings.localDurableSessions = $0 }
                )) {
                    Text("Panes outlive the window")
                        .font(DS.Typography.body)
                }
                .toggleStyle(.switch)
            }
    }

    @ViewBuilder
    private var networkSection: some View {
            DSSectionBlock(
                title: "Diagnostics",
                help: "Applies to this app and to every hub this workbench operates, including "
                    + "remote ones — without restarting them."
            ) {
                Picker("Log level", selection: Binding(
                    get: { settings.logLevel },
                    set: { settings.logLevel = $0 }
                )) {
                    ForEach(HubLogLevel.levels, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Log level for this app and every hub it operates")

                // THE CAVEATS STAY VISIBLE while the explanation above them
                // moved behind the "?" — the two are not the same kind of
                // text. An explanation is for whoever wants it; a statement
                // of what this control CANNOT do is for whoever does not
                // ask, because they are exactly the person who would
                // otherwise set a level and believe it took effect
                // everywhere ([[RFC-0012]] C-LEVEL-CONTROL: what the
                // application cannot control MUST NOT be presented as
                // controlled).
                ForEach(HubLogLevel.caveats, id: \.self) { caveat in
                    Text(caveat)
                        .font(DS.Typography.detail)
                        .foregroundStyle(DS.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            DSSectionBlock(
                title: "Ports",
                help: "Applied on the next tunnel connection. The hub port is automatic (9000 with fallback; SYNAPTY_HUB_PORT overrides). SSH connection robustness is automatic — fail-fast timeouts, keepalive probes and auto-reconnect."
            ) {
                HStack(alignment: .top, spacing: DS.Space.lg) {
                    DSFormField("Tunnel port", density: .page) {
                        TextField("9000", value: tunnelPortBinding, format: .number)
                            .dsField()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: DS.scaled(380))
            }
    }

    // MARK: - Helpers

    // MARK: - Bindings

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { settings.backgroundOpacity ?? 1.0 },
            set: { settings.backgroundOpacity = $0 }
        )
    }

    private var scrollbackBinding: Binding<Int?> {
        Binding(get: { settings.scrollbackLimit }, set: { settings.scrollbackLimit = $0 })
    }

    /// System Settings toggle-row: label left, switch in a right column.
    private func toggleRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(DS.Typography.body)
            Spacer()
            Toggle(label, isOn: binding)
                .toggleStyle(.switch)
                .labelsHidden()
        }
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
        DSSectionBlock(title: "GitHub") {
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
    }

    private var tunnelPortBinding: Binding<Int> {
        Binding(
            get: { settings.tunnelPort },
            set: { settings.tunnelPort = max(1, min($0, 65535)) }
        )
    }
}
