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

    /// Supported deploy platforms and their corresponding build output directories.
    /// Maps (uname -s, uname -m) -> build output directory name.
    static let platformMap: [(os: String, arch: String, dir: String)] = [
        ("Linux",  "aarch64",  "linux-aarch64"),
        ("Linux",  "x86_64",   "linux-x86_64"),
        ("Linux",  "riscv64",  "linux-riscv64"),
        ("Darwin", "arm64",    "macos-aarch64"),
        ("Darwin", "x86_64",   "macos-x86_64"),
    ]

    /// Resolve a (uname -s, uname -m) pair to a deploy directory name.
    static func resolveDeployDir(os: String, arch: String) -> String? {
        return platformMap.first(where: { $0.os == os && $0.arch == arch })?.dir
    }

    /// Constructs a shell script that:
    /// 1. Detects the remote platform via `uname -sm`
    /// 2. Selects the matching local binary from zig-out/<platform>/synapty
    /// 3. scp's it to the remote host
    /// 4. SSH's in with a reverse tunnel and runs synapty
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

        // Build the platform detection case statement from platformMap
        let cases = DeployManager.platformMap.map { entry in
            "    \"\(entry.os) \(entry.arch)\") DEPLOY_DIR=\"\(entry.dir)\" ;;"
        }.joined(separator: "\n")

        return """
        echo "Detecting remote platform..." && \
        REMOTE_PLATFORM=$(ssh \(sshFlags) \(dest) "uname -sm") && \
        case "$REMOTE_PLATFORM" in
        \(cases)
            *) echo "Error: Unsupported remote platform: $REMOTE_PLATFORM" && \
               echo "Supported: \(DeployManager.platformMap.map { "\($0.os)/\($0.arch)" }.joined(separator: ", "))" && \
               exit 1 ;;
        esac && \
        LOCAL_BIN="zig-out/${DEPLOY_DIR}/synapty" && \
        if [ ! -f "$LOCAL_BIN" ]; then
            echo "Binary not found at $LOCAL_BIN — run: zig build deploy-${DEPLOY_DIR}" && exit 1
        fi && \
        echo "Deploying synapty ($DEPLOY_DIR) to \(host.address)..." && \
        ssh \(sshFlags) \(dest) "mkdir -p ~/.synapty/bin" && \
        scp \(scpFlags) "$LOCAL_BIN" \(dest):~/.synapty/bin/synapty && \
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
