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
                    PortField(label: "Listen", port: $forwardings[idx].listenPort)
                    Text(":")
                    TextField("Target", text: $forwardings[idx].targetHost)
                    Text(":")
                    PortField(label: "Port", port: $forwardings[idx].targetPort)
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

/// One port box.
///
/// A CLEARED BOX IS NOT PORT ZERO. Both boxes were computed Bindings whose
/// setter was `Int($0) ?? 0`, so deleting the contents wrote a 0 straight
/// into the rule — and `-L 0:host:0` is a forward ssh will happily accept
/// and place somewhere nobody can find. The CLI now refuses that spec, so
/// the same keystroke would cost the human the whole pane; the box holds
/// its own text instead and only commits a port that is one
/// ([[WI-2026-09-10-002]]).
private struct PortField: View {
    let label: String
    @Binding var port: Int
    @State private var text: String = ""

    private var valid: Bool { (1...65535).contains(Int(text) ?? 0) }

    var body: some View {
        TextField(label, text: $text)
            .frame(width: 55)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .stroke(DS.danger, lineWidth: valid ? 0 : 1)
            )
            .onAppear { text = "\(port)" }
            // The model is the other writer: a rule can arrive from a
            // group's defaults or a reload while this row is on screen.
            .onChange(of: port) { _, new in
                if Int(text) != new { text = "\(new)" }
            }
            .onChange(of: text) { _, new in
                if let n = Int(new), (1...65535).contains(n) { port = n }
            }
    }
}
