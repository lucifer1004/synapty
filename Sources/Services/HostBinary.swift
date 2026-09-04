import Foundation

/// WHETHER A HOST IS RUNNING THE BINARY THIS BUILD DEPLOYS, and how to
/// make it so.
///
/// `setup-host.sh` compares md5 and uploads when they differ, and its own
/// header promises the check "ALWAYS runs — even when a ControlMaster is
/// already active. The master may outlive a rebuild". The CALLER does not
/// keep that promise: [[TunnelManager]]'s fast path opens a session on an
/// already-connected host without running the script at all, and
/// ControlPersist=yes keeps that master alive as long as the host is
/// peered. So a host stays on whatever binary it had when it was first
/// dialled, and nothing anywhere says so — the failure a human meets is a
/// feature that is simply absent over there, with no version named.
///
/// ASKED ONLY OF HOSTS THAT ARE CONNECTED. On a live master the question
/// is one round trip over a link that is already open; on a host that is
/// not connected it means dialling — an ssh, an authentication, a wait —
/// for a machine the human is not using. A probe that expensive would be
/// paid on every launch for every host ever configured.
enum HostBinary {

    enum Verdict: Equatable {
        /// The host runs what this build deploys.
        case current
        /// It runs something else, and the human can be offered the fix.
        case stale
        /// It did not say, or this app cannot say what it deploys. NOT
        /// stale: marking a host that may be perfectly current tells a
        /// human to fix nothing, and offering to upload over a link that
        /// just failed is worse than saying nothing.
        case unknown
    }

    static func verdict(remote: String?, local: String) -> Verdict {
        let theirs = remote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ours = local.trimmingCharacters(in: .whitespacesAndNewlines)
        // "unknown" is what `HubManager.expectedBuild` answers when it
        // cannot resolve its own binary. Compared against, it would call
        // every host stale.
        guard !theirs.isEmpty, !ours.isEmpty, ours != "unknown" else { return .unknown }
        return theirs == ours ? .current : .stale
    }

    /// The two conditions, named so the caller cannot spell them a third
    /// way: connected, and not already being asked.
    static func worthAsking(connected: Bool, alreadyAsking: Bool) -> Bool {
        connected && !alreadyAsking
    }

    static func parse(stdout: String, exitCode: Int32?) -> String? {
        guard exitCode == 0 else { return nil }
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// WHICH BUILD A MACHINE TAKES, from what it says it is.
    ///
    /// The same five `uname -sm` answers `setup-host.sh` maps, and named
    /// here rather than reimplemented in prose: an unsupported platform
    /// gets nil and is offered nothing, which is honest — there is no
    /// binary for it in the bundle either.
    static func deployTarget(unameSM: String) -> String? {
        switch unameSM.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Linux aarch64": return "linux-aarch64"
        case "Linux x86_64": return "linux-x86_64"
        case "Linux riscv64": return "linux-riscv64"
        case "Darwin arm64": return "macos-aarch64"
        case "Darwin x86_64": return "macos-x86_64"
        default: return nil
        }
    }

    /// The binary this build carries for that machine.
    static func bundled(target: String) -> String? {
        let url = Bundle.main.resourceURL?
            .appendingPathComponent("deploy/\(target)/synapty")
        guard let url, FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url.path
    }

    /// What a host says it is, over the master it already holds.
    nonisolated static func platform(connection: RemoteConnection,
                                     timeout: TimeInterval = 8) -> String? {
        let out = SubprocessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: connection.sshOptions + [connection.userAtHost, "uname -sm"],
            timeout: timeout)
        return parse(stdout: out.stdout, exitCode: out.exitCode)
    }

    /// What build a host is running, over the master it already holds.
    nonisolated static func query(connection: RemoteConnection,
                                  timeout: TimeInterval = 8) -> String? {
        let out = SubprocessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: connection.sshOptions + [
                connection.userAtHost,
                ".synapty/bin/synapty version",
            ],
            timeout: timeout)
        return parse(stdout: out.stdout, exitCode: out.exitCode)
    }

    /// PUT THE CURRENT BINARY THERE.
    ///
    /// UNLINKED FIRST, NOT OVERWRITTEN. Linux allows unlinking a running
    /// executable — it stays in memory — but writing to an active text
    /// segment fails with ETXTBSY, so a host with a session open would
    /// refuse the write. `setup-host.sh` does the same thing for the same
    /// reason.
    ///
    /// THE HOLDERS ALREADY RUNNING ARE NOT DISTURBED. They are their own
    /// processes with the old image mapped; replacing the file on disk
    /// changes what the NEXT one runs, which is the whole of what this
    /// act promises.
    nonisolated static func upload(local: String, connection: RemoteConnection,
                                   timeout: TimeInterval = 120) -> Bool {
        let removed = SubprocessRunner.runQuiet(
            executable: "/usr/bin/ssh",
            arguments: connection.sshOptions + [
                connection.userAtHost,
                "mkdir -p .synapty/bin && rm -f .synapty/bin/synapty",
            ],
            timeout: 20)
        guard removed else { return false }
        let sent = SubprocessRunner.runQuiet(
            executable: "/usr/bin/scp",
            arguments: connection.scpOptions
                + [local, "\(connection.userAtHost):.synapty/bin/synapty"],
            timeout: timeout)
        guard sent else { return false }
        return SubprocessRunner.runQuiet(
            executable: "/usr/bin/ssh",
            arguments: connection.sshOptions + [
                connection.userAtHost,
                "chmod +x .synapty/bin/synapty",
            ],
            timeout: 20)
    }
}
