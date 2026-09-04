import AppKit
import SwiftUI

/// What the titlebar accessory needs to know and cannot ask for.
///
/// The page is `ContentView`'s own `@State`, and an AppKit accessory lives
/// outside that view's world entirely — so the one bit it needs is
/// published here rather than the accessory guessing or the page being
/// hoisted into a global.
@MainActor @Observable final class TitlebarChrome {
    var isTerminalPage = true
    init() {}
}

/// The workspace's own controls, in the TITLE BAR, on the row the window
/// buttons are on — the trailing twin of [[SidebarToggleAccessory]].
///
/// THEY HAD A BAND OF THEIR OWN AND DID NOT FILL IT. Arranging the
/// positions and opening a pane are workspace-level acts, so when the tab
/// bar moved down into the position that owns it ([[RFC-0015]] C-LAYOUT)
/// these two were left holding a full-width 34pt strip between the title
/// bar and the tabs, empty but for two glyphs at its right edge. Three
/// bands of chrome stood above the first line of terminal.
///
/// The title bar is a row no app content can occupy and it is already
/// there, so putting them in it costs nothing: a workspace showing one
/// pane now has NO chrome at all between the window buttons and the
/// shell.
///
/// THE APPEARANCE TOGGLE COMES WITH THEM. It sat in the status bar
/// because the version before that was a stray button floating in the
/// title-bar band (WI-2026-08-09-006) — floating being the fault, not the
/// band. As an accessory AppKit lays it out and keeps it there.
enum WorkspaceControlsAccessory {

    /// Install once per window. Idempotent, like its leading twin, so it
    /// is safe from a `WindowAccessor` that fires more than once.
    @MainActor
    static func install(in window: NSWindow,
                        paneManager: WorkspaceManager,
                        hostStore: HostStore,
                        chrome: TitlebarChrome,
                        onConnectHostHere: @escaping (HostEntry) -> Void) {
        let marker = "dev.synapty.workspace-controls"
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier?.rawValue == marker })
        else { return }

        let controller = NSTitlebarAccessoryViewController()
        controller.identifier = NSUserInterfaceItemIdentifier(marker)
        controller.layoutAttribute = .trailing
        let host = NSHostingView(rootView: WorkspaceControls(
            paneManager: paneManager, hostStore: hostStore,
            onConnectHostHere: onConnectHostHere, chrome: chrome))
        // Sized here rather than from intrinsic content, for the reason
        // the sidebar toggle is: the titlebar lays accessories out against
        // a fixed-height row and clips anything that asks for more.
        // WIDER THAN IT WAS, because the machine the next pane lands on is
        // stated rather than inferred and a name needs room.
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        controller.view = host
        window.addTitlebarAccessoryViewController(controller)
    }
}

private struct WorkspaceControls: View {
    var paneManager: WorkspaceManager
    var hostStore: HostStore
    /// Open a connection whose pane lands in THIS workspace ([[RFC-0015]]
    /// C-WORKSPACE: "A connection opened from inside a workspace SHOULD
    /// place its pane there").
    var onConnectHostHere: (HostEntry) -> Void = { _ in }
    var chrome: TitlebarChrome


    /// How many POSITIONS there are to arrange. One is nothing to arrange.
    private var slotCount: Int { paneManager.activeWorkspace?.slots.count ?? 0 }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if chrome.isTerminalPage {
                arrangeMenu
                newPaneControls
            }
            // EVERY PAGE, unlike the two beside it: a theme is judged
            // against whatever is on screen, and the panel is reachable
            // from all of them (WI-2026-08-08-052).
            DSIconButton(icon: "slider.horizontal.3",
                         help: CommandHint.help("Appearance panel", for: "settings.toggle-panel"),
                         size: 22) {
                NotificationCenter.default.post(name: .synaptyToggleSettingsPanel, object: nil)
            }
        }
        .padding(.trailing, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Layout presets (WI-2026-08-09-012) — one-click arrange of the
    /// workspace's POSITIONS. DSDropdown Menu pattern: .menuStyle(.button)
    /// + .buttonStyle(.plain), or macOS 26 replaces the custom label.
    private var arrangeMenu: some View {
        Menu {
            ForEach(SplitNode.LayoutPreset.allCases, id: \.self) { preset in
                Button {
                    paneManager.applyLayout(preset)
                } label: {
                    Label(preset.label, systemImage: preset.sfSymbol)
                }
            }
        } label: {
            Image(systemName: "rectangle.split.2x2")
                .font(DS.Icon.control)
                .foregroundStyle(slotCount > 1 ? Color.secondary : Color.secondary.opacity(0.4))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(slotCount < 2)
        .help(slotCount < 2
              ? "Split first (\(CommandHint.reach("pane.split-right"))) — "
                + "layouts arrange existing panes"
              : "Arrange splits")
    }

    /// OPENING A PANE IS TWO QUESTIONS, AND BOTH ARE VISIBLE.
    ///
    /// This was one `+` whose other kinds lived behind a press-and-hold,
    /// and press-and-hold has no affordance on this platform — a human
    /// looking at it cannot tell there is anything else there. The kinds
    /// are buttons now.
    ///
    /// AND THE SECOND QUESTION IS "ON WHICH MACHINE". It was answered
    /// implicitly, from whichever pane happened to hold focus, and never
    /// shown. That is tolerable while a workspace holds one machine and
    /// wrong the moment it holds several — which is the arrangement leaf
    /// binding exists to permit ([[RFC-0015]] C-LEAF-BINDING), so it is
    /// the case to design for rather than the exception.
    ///
    /// The chip below states the answer rather than changing it: it is a
    /// pure function of focus, exactly what `+` already did, made
    /// visible. Picking a machine from it MOVES FOCUS to a pane on that
    /// machine rather than setting a second piece of state — two states
    /// that can disagree about "where does the next pane go" is the
    /// defect this is fixing, not one to introduce.
    @ViewBuilder
    private var newPaneControls: some View {
        if let workspace = paneManager.activeWorkspace?.id {
            DSIconButton(icon: "terminal", help: "New terminal", size: 22) {
                paneManager.addPane(content: .terminal(command: nil), toWorkspace: workspace)
            }
            DSIconButton(icon: "folder", help: "New file browser", size: 22) {
                paneManager.addPane(content: .files(directory: nil), toWorkspace: workspace)
            }
            DSIconButton(icon: "antenna.radiowaves.left.and.right",
                         help: "New view of exposed services", size: 22) {
                paneManager.addPane(content: .services, toWorkspace: workspace)
            }
            DSIconButton(icon: "globe", help: "New browser", size: 22) {
                paneManager.addPane(content: .browser(address: nil), toWorkspace: workspace)
            }
            machineChip
        }
    }

    /// WHERE THE NEXT PANE LANDS. Follows focus, because that is what
    /// decides it.
    private var machineChip: some View {
        Menu {
            // The machines already here. Picking one goes to it, and the
            // chip follows — there is no second answer to disagree with.
            ForEach(machinesHere, id: \.id) { entry in
                Button(entry.name) { paneManager.focusLeaf(entry.leafID) }
            }
            Divider()
            // THE PALETTE, NOT A SECOND LIST OF MACHINES. A flat menu of
            // every host is unusable past a handful — fifteen of them
            // filled a column — and building a searchable one here would
            // be a second machine picker to keep in step with the one
            // ⌘K already is. It lands its pane in THIS workspace.
            //
            // THE SAME NAME THE EMPTY STATE USES, because it is the same
            // command: one act should not answer to two names depending
            // on which surface asked for it. The items above are a
            // different act — they go to a pane that already exists —
            // which is what the divider is for.
            Button("Open a Pane…") {
                NotificationCenter.default.post(name: .synaptyQuickConnect, object: true)
            }
        } label: {
            HStack(spacing: DS.Space.xxs) {
                Image(systemName: focusedMachineIsLocal ? "laptopcomputer" : "server.rack")
                    .font(DS.Icon.control)
                Text(focusedMachineName)
                    .font(DS.Typography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, DS.Space.xs)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("The next pane opens on this machine")
        .fixedSize()
    }

    /// One entry per machine present in this workspace, each naming a leaf
    /// on it to focus.
    private var machinesHere: [(id: String, name: String, leafID: UUID)] {
        guard let workspace = paneManager.activeWorkspace else { return [] }
        var seen: Set<String> = []
        return workspace.panes.compactMap { pane in
            let host = paneManager.host(ofLeaf: pane.id)
            let key = host?.id.uuidString ?? "local"
            guard seen.insert(key).inserted else { return nil }
            let name = host.map { $0.label.isEmpty ? $0.address : $0.label } ?? "This Mac"
            return (id: key, name: name, leafID: pane.id)
        }
    }

    private var focusedMachineIsLocal: Bool {
        guard let focused = paneManager.activeWorkspace?.focusedPaneID else { return true }
        return paneManager.host(ofLeaf: focused) == nil
    }

    private var focusedMachineName: String {
        guard let focused = paneManager.activeWorkspace?.focusedPaneID,
              let host = paneManager.host(ofLeaf: focused) else { return "This Mac" }
        return host.label.isEmpty ? host.address : host.label
    }

}
