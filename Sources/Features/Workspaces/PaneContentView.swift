import SwiftUI

/// What a non-terminal pane draws ([[RFC-0015]] C-CONTENT).
///
/// These two lived in a fixed right-hand panel, which meant they could not
/// be split, moved, or set beside the terminal writing the files they show.
/// They are panes now, and the only thing that distinguishes them from a
/// terminal pane is what is drawn inside the frame the layout gives them.
///
/// THE MACHINE COMES FROM THE LEAF, not from the workspace or the tab
/// ([[RFC-0015]] C-LEAF-BINDING). A file browser is a browser OF a machine,
/// so it answers the same question a terminal pane does, the same way.
struct PaneContentView: View {
    /// Whether this pane is the one in front. A web pane is now built
    /// while hidden so its page survives a tab switch, so it has to be
    /// told — the kinds that keep their state in the pane manager do not
    /// care and ignore it.
    var isVisible: Bool = true
    let content: SplitNode.PaneContent
    /// nil is this Mac.
    let host: HostEntry?
    var hostStore: HostStore?
    var tunnelManager: TunnelManager?
    var transfers: TransferService?
    var forwards: PortForwardService?
    var artifacts: ArtifactService?
    /// Where this file leaf ended up, so the LEAF can remember it
    /// ([[RFC-0015]] C-PERSIST).
    var onDirectoryChange: ((String) -> Void)?
    /// How this file leaf is being looked at — history, filter, sort. Held
    /// by the leaf because this view is destroyed on every tab switch
    /// ([[WI-2026-08-19-002]]).
    var navigation: WorkspaceManager.FileNavigation = .init()
    var openedFrom: String?
    var onFilter: ((String) -> Void)?
    var onListing: (([BrowsedFile], String) -> Void)?
    var onInvalidate: ((String) -> Void)?
    var onSort: ((WorkspaceManager.FileNavigation.Sort) -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    /// Which exposure this services leaf is showing, held by the LEAF for
    /// the same reason the file leaf's directory is: this view does not
    /// survive a tab switch ([[LeafFacts]] `viewing`).
    var viewing: UUID?
    var onViewing: ((UUID?) -> Void)?
    /// Where a browser leaf was pointed, held by the LEAF — the one thing
    /// [[RFC-0015]] C-PERSIST writes for that kind.
    var onAddress: ((String) -> Void)?

    var body: some View {
        switch content {
        case .files(let directory):
            if let hostStore, let tunnelManager, let transfers, let artifacts {
                RemoteFilesView(
                    host: host,
                    hostStore: hostStore,
                    tunnelManager: tunnelManager,
                    transfers: transfers,
                    artifacts: artifacts,
                    initialDirectory: directory,
                    onDirectoryChange: { onDirectoryChange?($0) },
                    navigation: navigation,
                    openedFrom: openedFrom,
                    onFilter: { onFilter?($0) },
                    onListing: { onListing?($0, $1) },
                    onInvalidate: { onInvalidate?($0) },
                    onSort: { onSort?($0) },
                    onBack: onBack,
                    onForward: onForward)
            } else {
                unavailable("Files")
            }
        case .browser(let address):
            BrowserView(address: address, onAddress: { onAddress?($0) },
                        isVisible: isVisible)
        case .services:
            if let tunnelManager, let forwards {
                ServicesView(isVisible: isVisible,
                             host: host, forwards: forwards, tunnelManager: tunnelManager,
                             viewing: viewing, onViewing: { onViewing?($0) })
            } else {
                unavailable("Services")
            }
        case .terminal:
            // Terminals are drawn by the surface stack, which keeps them
            // alive across tab switches because a pty must not die with a
            // view. Reaching here means a caller routed one wrongly.
            unavailable("Terminal")
        }
    }

    /// SAID RATHER THAN LEFT BLANK. A pane with no services behind it is a
    /// rectangle of nothing, and a human looking at one cannot tell it from
    /// a pane that is still loading.
    private func unavailable(_ what: String) -> some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: "questionmark.square.dashed")
                .font(DS.Icon.feature)
                .foregroundStyle(DS.textTertiary)
            Text("\(what) is not available here")
                .font(DS.Typography.detail)
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
    }
}
