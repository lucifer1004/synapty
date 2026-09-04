import Foundation
import Observation

/// Shared GitHub bridge state, fetched via `synapty github status` — used by
/// both the Hub page and the Settings page so the binding model, refresh and
/// disconnect logic live in ONE place (WI-2026-08-08-056).
@MainActor @Observable final class GithubBridgeController {

    /// Bound hub-repo details from `synapty github status`.
    struct Binding: Equatable {
        var owner: String
        var repo: String
        var username: String?
        var hasToken: Bool
        var configured: Bool { hasToken }
    }

    /// Latest bridge binding; nil = status not fetched yet.
    var binding: Binding?
    var isDisconnecting = false

    /// Re-read `synapty github status` (off-main CLI call).
    func refresh() {
        guard let binary = SynaptyBinary.resolve() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = SubprocessRunner.run(
                executable: binary,
                arguments: ["github", "status"],
                timeout: 15
            )
            DispatchQueue.main.async {
                guard let self else { return }
                guard output.error == nil, !output.timedOut,
                      let data = output.stdout.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let configured = json["configured"] as? Bool
                else { return }
                // Keep owner/repo even when the token is missing (pre-fill
                // for Change/Connect).
                self.binding = Binding(
                    owner: json["owner"] as? String ?? "",
                    repo: json["repo"] as? String ?? "",
                    username: json["username"] as? String,
                    hasToken: configured
                )
            }
        }
    }

    /// Unbind via `synapty github logout` (WI-2026-08-08-043). The caller is
    /// responsible for refreshing dependent state (e.g. TaskMonitor tasks).
    func disconnect() {
        guard let binary = SynaptyBinary.resolve(), !isDisconnecting else { return }
        isDisconnecting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = SubprocessRunner.run(
                executable: binary,
                arguments: ["github", "logout"],
                timeout: 20
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDisconnecting = false
                self.binding = nil
                self.refresh()
            }
        }
    }
}
