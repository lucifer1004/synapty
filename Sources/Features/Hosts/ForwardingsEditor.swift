import SwiftUI

/// Editable SSH port-forwarding rule list — shared by the host sheet and
/// the group settings sheet so both render identical UX
/// (WI-2026-08-08-060).
struct ForwardingsEditor: View {
    @Binding var forwardings: [PortForward]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if forwardings.isEmpty {
                Text("No forwarding rules. Add local (-L) or remote (-R) forwards, applied when the tunnel is established.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
            ForEach(forwardings.indices, id: \.self) { idx in
                HStack(spacing: DS.Space.sm) {
                    Picker("", selection: $forwardings[idx].kind) {
                        Text("Local (-L)").tag(PortForward.Kind.local)
                        Text("Remote (-R)").tag(PortForward.Kind.remote)
                    }
                    .labelsHidden()
                    .frame(width: DS.scaled(110))
                    TextField("Listen", text: Binding(
                        get: { "\(forwardings[idx].listenPort)" },
                        set: { forwardings[idx].listenPort = Int($0) ?? 0 }
                    ))
                    .frame(width: 55)
                    Text(":")
                    TextField("Target", text: $forwardings[idx].targetHost)
                    Text(":")
                    TextField("Port", text: Binding(
                        get: { "\(forwardings[idx].targetPort)" },
                        set: { forwardings[idx].targetPort = Int($0) ?? 0 }
                    ))
                    .frame(width: 55)
                    Button {
                        forwardings.remove(at: idx)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .font(DS.Typography.monoCaption)
            }
            Button {
                forwardings.append(PortForward())
            } label: {
                Label("Add Forward", systemImage: "plus")
                    .font(DS.Typography.detailStrong)
            }
        }
    }
}
