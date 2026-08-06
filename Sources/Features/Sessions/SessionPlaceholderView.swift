import SwiftUI

/// Shown in the detail area when the active session has no terminal pane
/// yet — i.e. a remote placeholder while the SSH tunnel is being
/// established, or a failed connection. No ghostty surface is created in
/// these states, so a nil-command shell is never spawned
/// (WI-2026-03-31-003: "connecting to remote host does not open spurious
/// local session").
struct SessionPlaceholderView: View {
    let session: TerminalPaneManager.Session
    /// Re-run the tunnel setup after a failed connection (WI-2026-08-07-004).
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            switch session.state {
            case .connecting:
                ProgressView()
                    .controlSize(.large)
                    .tint(DS.accent)
                VStack(spacing: DS.Space.xs) {
                    Text("Connecting to \(session.label)")
                        .font(DS.Typography.title)
                        .foregroundStyle(DS.textPrimary)
                    Text("Establishing SSH tunnel…")
                        .font(DS.Typography.detail)
                        .foregroundStyle(DS.textSecondary)
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(DS.warning)
                VStack(spacing: DS.Space.xs) {
                    Text("Connection failed")
                        .font(DS.Typography.title)
                        .foregroundStyle(DS.textPrimary)
                    Text(message)
                        .font(DS.Typography.detail)
                        .foregroundStyle(DS.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                if let onRetry {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(DS.Typography.detailStrong)
                            .padding(.horizontal, DS.Space.lg)
                            .padding(.vertical, DS.Space.sm)
                            .background(DS.accent, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            case .connected:
                // Transient: connectSession replaces the placeholder with a
                // real session+pane immediately, so this should not render.
                EmptyView()
            }
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
    }
}
