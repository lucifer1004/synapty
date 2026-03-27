import SwiftUI

/// Hub status sheet — shows running state, port, logs, and restart button.
struct HubStatusView: View {
    @ObservedObject var hubManager: HubManager
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Hub Status")
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Status info
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(hubManager.status.label)
                        .font(.body)
                    Spacer()
                    Text("Port \(hubManager.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    if case .running(let owned) = hubManager.status {
                        if owned {
                            Button("Restart") { hubManager.restartHub() }
                            Button("Stop") { hubManager.stopHub() }
                        }
                    } else if !hubManager.status.isRunning {
                        Button("Start") { hubManager.launchHub() }
                    }
                }
            }
            .padding()

            Divider()

            // Logs
            VStack(alignment: .leading, spacing: 4) {
                Text("Logs")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(hubManager.logs.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .id(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: hubManager.logs.count) { _ in
                        if let last = hubManager.logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
    }

    private var statusColor: Color {
        switch hubManager.status {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }
}
