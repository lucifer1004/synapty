import SwiftUI

/// Shown in the detail area when the active session has no terminal pane
/// yet — i.e. a remote placeholder while the SSH tunnel is being
/// established, or a failed connection. No ghostty surface is created in
/// these states, so a nil-command shell is never spawned
/// (WI-2026-03-31-003: "connecting to remote host does not open spurious
/// local session").
struct SessionPlaceholderView: View {
    let session: TerminalPaneManager.Session

    var body: some View {
        VStack(spacing: 12) {
            switch session.state {
            case .connecting:
                ProgressView()
                    .controlSize(.large)
                Text("Connecting to \(session.label)…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text("Connection failed")
                    .font(.system(size: 14, weight: .medium))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            case .connected:
                // Transient: connectSession replaces the placeholder with a
                // real session+pane immediately, so this should not render.
                EmptyView()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
    }
}
