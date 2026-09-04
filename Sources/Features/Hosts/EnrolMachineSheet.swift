import SwiftUI

/// Authorize another Mac on one host, or take that authorization away
/// ([[ADR-0009]], [[WI-2026-08-14-001]]).
///
/// ALWAYS A HUMAN'S EXPLICIT ACT. Writing to someone's authorized_keys is
/// a grant of standing access, so it happens here — behind a menu item, a
/// sheet and a button — and never as a consequence of adding a host,
/// connecting to one, or turning sync on.
///
/// NO AUTHORIZED/NOT-AUTHORIZED COLUMN, deliberately. Knowing would mean
/// reading the host's authorized_keys on every open, which is a connection
/// and a file read the human did not ask for, and the answer would be
/// stale the moment anything else edited that file. Both actions are
/// idempotent, so the honest interface offers them and reports what
/// happened rather than predicting it.
struct EnrolMachineSheet: View {

    let host: HostEntry
    var tunnelManager: TunnelManager?
    var onClose: () -> Void

    @State private var machines: [MachineKey.Machine] = []
    /// Whether THIS Mac has published its own key. Separates "no other Mac
    /// yet", the ordinary wait for a second machine, from "nothing has
    /// published at all", which means this Mac failed to and nothing here
    /// can work.
    @State private var localPublished = false
    @State private var busy: String?
    @State private var outcome: Outcome?
    @State private var isPresented = true

    private struct Outcome {
        let message: String
        let ok: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            DSSheetHeader(
                title: "Authorize a Mac on \(host.label)",
                icon: "key.horizontal",
                isPresented: $isPresented)

            DSHairline()

            // EACH STATE SIZES ITSELF. A fixed height gives the empty
            // state the room it needs and leaves a dead gap under a short
            // list; the list hugs its rows and starts scrolling only when
            // there are enough to need it.
            if machines.isEmpty {
                emptyState.frame(height: DS.scaled(190))
            } else {
                machineList.frame(maxHeight: DS.scaled(280))
            }

            DSHairline()

            footer
        }
        .frame(width: DS.scaled(440))
        .onChange(of: isPresented) { _, shown in if !shown { onClose() } }
        .onAppear {
            // THIS MAC IS EXCLUDED from the list: it is the one doing the
            // authorizing and already reaches the host, so offering to
            // grant it access is noise. That it has published still
            // matters, which is what `localPublished` carries.
            let all = MachineKey.knownMachines(localPeerID: MachineKey.localPeerID())
            localPublished = all.contains { $0.isThisMachine }
            machines = all.filter { !$0.isThisMachine }
        }
    }

    // MARK: - States

    /// The two empty states mean OPPOSITE things and must not share copy:
    /// one is the ordinary wait for a second machine, the other says this
    /// Mac never published and nothing here can work.
    @ViewBuilder
    private var emptyState: some View {
        if localPublished {
            DSEmptyState(
                icon: "laptopcomputer",
                title: "No other Mac yet",
                message: "Each Mac publishes its key the first time it runs, "
                    + "and appears here once sync carries it.")
        } else {
            DSEmptyState(
                icon: "exclamationmark.triangle",
                title: "This Mac has not published its key",
                message: "It publishes on the first launch after its hub starts. "
                    + "Until then no Mac can be authorized from here.")
        }
    }

    private var machineList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                DSSectionLabel(text: "Machines", count: machines.count)
                VStack(spacing: 0) {
                    ForEach(machines) { machine in
                        row(machine)
                        if machine.id != machines.last?.id {
                            DSHairline().padding(.leading, DS.Space.xl)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(DS.surface))
            }
            .padding(DS.Space.lg)
        }
    }

    @ViewBuilder
    private func row(_ machine: MachineKey.Machine) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "laptopcomputer")
                .font(DS.Typography.body)
                .foregroundStyle(DS.textTertiary)
                .frame(width: DS.scaled(16))
            Text(machine.peerID)
                .font(DS.Typography.body)
                .lineLimit(1)
            Spacer(minLength: DS.Space.md)
            if busy == machine.peerID {
                ProgressView().controlSize(.small)
            } else {
                Button("Revoke") {
                    run(Enrolment.removeCommand(publicKey: machine.publicKey),
                        on: machine, verb: "revoked")
                }
                .controlSize(.small)
                Button("Authorize") {
                    run(Enrolment.addCommand(publicKey: machine.publicKey),
                        on: machine, verb: "authorized")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .accessibilityElement(children: .combine)
    }

    /// ONE line of chrome. The mechanism sentence sits here rather than
    /// under the title: what a human wants before pressing Authorize is
    /// that nothing secret moves, and that reassurance belongs beside the
    /// button, not stacked against the heading where it competes with it.
    /// A result replaces it, because once something has happened the
    /// explanation is no longer the most useful thing in the row.
    private var footer: some View {
        HStack(spacing: DS.Space.sm) {
            if let outcome {
                DSStatusDot(color: outcome.ok ? DS.success : DS.danger, size: 7)
                Text(outcome.message)
                    .font(DS.Typography.caption)
                    .foregroundStyle(outcome.ok ? DS.textSecondary : DS.danger)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !machines.isEmpty {
                Text("No private key leaves any machine.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
            Spacer(minLength: DS.Space.md)
            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(DS.Space.lg)
    }

    private func run(_ command: String, on machine: MachineKey.Machine, verb: String) {
        guard let tunnelManager else {
            outcome = Outcome(message: "No SSH manager is available.", ok: false)
            return
        }
        busy = machine.peerID
        outcome = nil
        tunnelManager.runOnHost(host, command: command) { result in
            busy = nil
            switch result {
            case .ok:
                // The enrolling Mac reports only that it WROTE. Whether the
                // key works is the target Mac's own connection to answer,
                // and it is the one party that can — verification needs the
                // private half, which never came here.
                outcome = Outcome(message: "\(machine.peerID) \(verb).", ok: true)
            case .failed(let why):
                outcome = Outcome(message: "\(host.label): \(why)", ok: false)
            }
        }
    }
}
