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

    /// Constructs a shell script that:
    /// 1. Creates the remote bin directory
    /// 2. scp's the local synapty binary
    /// 3. SSH's in with a reverse tunnel and runs synapty on the remote
    func fullDeployCommand(for host: HostEntry) -> String {
        let dest = "\(host.username)@\(host.address)"
        let portFlagSSH = "-p \(host.port)"
        let portFlagSCP = "-P \(host.port)"
        let keyFlag: String
        if let keyPath = host.sshKeyPath, !keyPath.isEmpty {
            keyFlag = "-i \(keyPath)"
        } else {
            keyFlag = ""
        }

        // Inline helper: build flag string omitting blanks
        func flags(_ parts: String...) -> String {
            parts.filter { !$0.isEmpty }.joined(separator: " ")
        }

        let sshFlags = flags(keyFlag, portFlagSSH)
        let scpFlags = flags(keyFlag, portFlagSCP)

        let remoteCmd = "~/.synapty/bin/synapty run --id \(host.label) --hub 127.0.0.1:9000 -- bash -l"

        return """
        echo "Deploying synapty to \(host.address)..." && \
        ssh \(sshFlags) \(dest) "mkdir -p ~/.synapty/bin" && \
        scp \(scpFlags) $(which synapty 2>/dev/null || echo zig-out/bin/synapty) \(dest):~/.synapty/bin/synapty && \
        echo "Connecting..." && \
        ssh -R 9000:localhost:9000 \(sshFlags) \(dest) "\(remoteCmd)"
        """
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
