import SwiftUI

/// The right panel: a context the human is NOT typing into.
///
/// ITS SUBJECT IS A HOST, and that is what makes the whole thing work
/// without touching the session model. The middle of the window stays on
/// the session being worked in; the panel stays on whichever host it was
/// pointed at. Switching workspaces does not move it, which is precisely the
/// property that lets a file be dragged from one machine into another's
/// terminal ([[ADR-0010]], [[WI-2026-08-15-009]]).
///
/// Appearance is the exception and is treated as one: it belongs to the
/// application rather than to a host, so it shows no host picker. Rather
/// than inventing a subject it does not have, the switcher simply hides
/// the row.
struct HostContextPanel: View {

    let model: PanelModel
    let hostStore: HostStore
    let tunnelManager: TunnelManager
    let transfers: TransferService
    let forwards: PortForwardService
    let artifacts: ArtifactService
    let settings: SynaptySettings
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The panel surface runs to the window top, but its controls
            // must clear the hidden title bar.
            Color.clear.frame(height: DS.Layout.titlebarInset)

            header

            // NO HOST ROW. It existed to say which machine the files and
            // web views were about; appearance is about the application
            // and has no machine to name.
            DSHairline()

            content

            if !transfers.inFlight.isEmpty {
                DSHairline()
                TransferStrip(transfers: transfers, hostStore: hostStore)
            }
        }
        .background(DSChromeBackground())
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            // NO SEGMENTED CONTROL. The panel held three unrelated
            // subjects competing for one strip; two of them are panes now
            // ([[RFC-0015]] C-CONTENT) and this is the appearance panel it
            // started as.
            Text("Appearance")
                .font(DS.Typography.detailStrong)
                .foregroundStyle(DS.textSecondary)
            Spacer(minLength: DS.Space.sm)
            // The arrows point at what the action DOES to the edge, which
            // is the only thing that changes — the terminal beside it is
            // covered, not resized.
            DSIconButton(
                icon: model.isExpanded
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: model.isExpanded ? "Shrink panel" : "Expand panel over the terminal",
                size: 22
            ) { model.toggleExpanded() }
            DSIconButton(icon: "xmark",
                         help: CommandHint.help("Close panel", for: "settings.toggle-panel"),
                         size: 22) { onClose() }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }


    /// Appearance caps its own column and leaves the rest as margin,
    /// rather than the panel resizing around it.
    private var content: some View {
        TerminalSettingsPanel(settings: settings, chromeless: true) { onClose() }
            .frame(maxWidth: DS.scaled(PanelModel.appearanceContentWidth))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// Transfers in flight, at the foot of the panel.
///
/// ALSO SHOWN OUTSIDE THE PANEL, because this row cannot be the only place:
/// the panel can be switched to another view or closed entirely while a
/// file is still moving, and a transfer nobody can see is one nobody can
/// cancel ([[RFC-0013]] C-CONTROL-PLANE).
struct TransferStrip: View {
    let transfers: TransferService
    let hostStore: HostStore

    var body: some View {
        VStack(spacing: 0) {
            ForEach(transfers.inFlight) { transfer in
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "arrow.right")
                        .font(DS.Icon.mark)
                        .foregroundStyle(DS.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transfer.fileName)
                            .font(DS.Typography.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(destinationLabel(transfer))
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.sm)
                    // A determinate bar only when a size is actually known;
                    // a bar sitting at zero and a bar that does not know are
                    // different claims.
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction).controlSize(.small).frame(width: DS.scaled(56))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    DSIconButton(icon: "xmark", help: "Cancel transfer", size: 18) {
                        transfers.cancel(transfer.id)
                    }
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.sm)
            }
        }
    }

    private func destinationLabel(_ transfer: TransferService.Transfer) -> String {
        guard let id = transfer.destination.hostID,
              let host = hostStore.hosts.first(where: { $0.id == id })
        else { return "to this Mac" }
        return "to \(host.label.isEmpty ? host.address : host.label)"
    }
}
