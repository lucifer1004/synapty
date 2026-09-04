import SwiftUI

/// WHAT A LEAF SHOWS WHILE ITS CONNECTION IS NOT UP ([[RFC-0015]] C-DIAL,
/// C-FAILURE).
///
/// This replaced a card drawn over the whole workspace. That card was the
/// old model showing through: a session WAS a connection, so a connecting
/// session had no pane and the container wore the state. Under
/// [[RFC-0015]] C-LEAF-BINDING a connection is named by a leaf, and
/// C-FAILURE says its state "MUST NOT be presented as a property of the
/// SLOT or the workspace containing that leaf" — so it is drawn here, in
/// the leaf's own place in the layout, at the size the layout gave it.
///
/// What that buys, concretely: a workspace holding a connected local pane
/// and a remote one still dialling shows both, and two hosts dialling at
/// once each account for themselves. Neither was expressible before.
///
/// DRAWN BY THE WORKBENCH, NOT WRITTEN INTO THE PANE ([[RFC-0015]]
/// C-FAILURE). The pane is the session's screen; progress and failure are
/// chrome over it and MUST NOT be emitted as bytes into it.
struct LeafConnectionView: View {
    let host: HostEntry?
    /// The account the connection is writing as it goes.
    var progress: ConnectProgress? = nil
    /// nil while dialling; the reason once it has failed.
    var failure: String? = nil
    /// Another client took this session ([[RFC-0014]] C-ONE-CLIENT).
    var taken = false
    /// Re-dial the shared connection this leaf names ([[RFC-0015]] C-DIAL).
    var onRetry: (() -> Void)? = nil

    private var hostLabel: String {
        guard let host else { return "this Mac" }
        return host.label.isEmpty ? host.address : host.label
    }

    var body: some View {
        VStack(spacing: DS.Space.md) {
            if taken {
                displaced
            } else if let failure {
                failed(failure)
            } else {
                dialling
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
    }

    private var dialling: some View {
        VStack(spacing: DS.Space.sm) {
            ProgressView().controlSize(.small)
            Text("Connecting to \(hostLabel)")
                .font(DS.Typography.bodyStrong)
                .foregroundStyle(DS.textPrimary)
            // THE ACCOUNT, WHERE THERE IS ONE. A dial that says only
            // "connecting" for eight seconds is indistinguishable from one
            // that has hung ([[WI-2026-08-17-016]]).
            if let latest = progress?.latest {
                Text(latest)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(DS.Space.lg)
    }

    /// WHAT THE HUMAN IS OWED WHEN THEIR SEAT IS TAKEN ([[RFC-0014]]
    /// C-ONE-CLIENT). The protocol tells the client, and the client wrote
    /// it — onto a screen that the same event destroys. So it is said
    /// here, where nothing is about to close, and the pane waits.
    ///
    /// AND THE WAY BACK SAYS WHAT IT COSTS. Returning displaces them in
    /// turn, which is the whole reason this notice exists; a button that
    /// did it without saying so would repeat the fault it is answering.
    private var displaced: some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: "person.fill.questionmark")
                .font(DS.Icon.feature)
                .foregroundStyle(DS.textSecondary)
            Text("Another client took this session")
                .font(DS.Typography.bodyStrong)
                .foregroundStyle(DS.textPrimary)
            Text("The session is still running on \(hostLabel) — somebody "
                 + "else is attached to it now. Nothing here was lost.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(4)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button("Take It Back", action: onRetry)
                    .controlSize(.small)
                    .padding(.top, DS.Space.xs)
                Text("This disconnects whoever is attached.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .padding(DS.Space.lg)
    }

    private func failed(_ reason: String) -> some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(DS.Icon.feature)
                .foregroundStyle(DS.danger)
            Text("Could not reach \(hostLabel)")
                .font(DS.Typography.bodyStrong)
                .foregroundStyle(DS.textPrimary)
            // THE REASON, AND IT PERSISTS ([[RFC-0015]] C-FAILURE): a
            // failure that clears itself leaves the human with a pane that
            // stopped working and no account of why.
            Text(reason)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(4)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let onRetry {
                Button("Try Again", action: onRetry)
                    .controlSize(.small)
                    .padding(.top, DS.Space.xs)
            }
        }
        .padding(DS.Space.lg)
    }
}
