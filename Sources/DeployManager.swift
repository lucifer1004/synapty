import Foundation

/// Manages SSH deployment command construction for remote hosts.
class DeployManager: ObservableObject {

    @Published var deployStatus: DeployStatus = .idle

    enum DeployStatus {
        case idle
        case connecting
        case deploying
        case tunneling
        case running
        case failed(String)
    }

    /// Locate the deploy.sh script — bundled in .app or dev fallback.
    private func deployScriptPath() -> String {
        // Bundled as folder reference: Contents/Resources/scripts/deploy.sh
        if let bundled = Bundle.main.path(forResource: "deploy", ofType: "sh", inDirectory: "scripts") {
            return bundled
        }
        // Dev fallback: scripts/deploy.sh relative to working directory.
        return "scripts/deploy.sh"
    }

    /// Constructs a single-line command that invokes scripts/deploy.sh.
    /// Ghostty can pass this directly to the shell via -c without newline issues.
    func fullDeployCommand(for host: HostEntry) -> String {
        let script = deployScriptPath()
        var parts = ["bash", script, host.label, host.address, "\(host.port)", host.username]
        if let keyPath = host.sshKeyPath, !keyPath.isEmpty {
            parts.append(keyPath)
        }
        return parts.joined(separator: " ")
    }

    /// Constructs a plain SSH command (assumes synapty is already on the remote).
    func sshOnlyCommand(for host: HostEntry) -> String {
        var parts: [String] = ["ssh", "-R", "9000:localhost:9000"]
        if let keyPath = host.sshKeyPath, !keyPath.isEmpty {
            parts += ["-i", keyPath]
        }
        if host.port != 22 {
            parts += ["-p", "\(host.port)"]
        }
        parts.append("\(host.username)@\(host.address)")
        parts.append("\"~/.synapty/bin/synapty run --id \(host.label) --hub 127.0.0.1:9000 -- bash -l\"")
        return parts.joined(separator: " ")
    }
}
