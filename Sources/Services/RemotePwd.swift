import Foundation

/// Where a REMOTE pane is standing, asked of the host that knows.
///
/// [[ProcessCwd]] answers this for a local pane by reading the kernel, and
/// cannot answer it for a remote one: a pane running ssh has a foreground
/// process on this Mac, so it would report a local path for a remote shell
/// — confidently, and wrongly. OSC 7 would answer, but a plain login does
/// not emit it, which is the whole reason the destination read "working
/// directory unknown".
///
/// THE HOLDER IS THE SHELL'S PARENT, so it can be asked ([[RFC-0014]]
/// C-PWD). It answers for the FOREGROUND PROCESS GROUP rather than for
/// the child it started: the child is a shell, and what the human is
/// looking at may be an editor three levels down whose directory is the
/// one a drop should land in.
///
/// This used to be `tmux display-message -p '#{pane_current_path}'`, and
/// moved when durability stopped going through a multiplexer
/// ([[ADR-0012]]). Nothing has to be installed either way, no dotfile
/// edited, and no `SetEnv` marker smuggled past an sshd that would have
/// refused it (`AcceptEnv` does not list ours).
///
/// [[WI-2026-08-16-001]], [[WI-2026-08-17-008]]
enum RemotePwd {

    /// One round trip over the master that is already open, or nil.
    ///
    /// A SESSION THAT IS NOT DURABLE ANSWERS NOTHING, and that is the
    /// honest result: there is no holder to ask, and a destination this
    /// cannot learn must stay visibly unknown rather than become a guess
    /// at home.
    nonisolated static func query(connection: RemoteConnection, agentID: String,
                                  timeout: TimeInterval = 8) -> String? {
        let out = SubprocessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: connection.sshOptions + [
                connection.userAtHost,
                // `sessions`, WHICH IS WHAT THE CLI HAS. A rename sweep
                // edited this string to `workspaces` and nothing failed at
                // build time, because a subcommand name in a shell
                // argument is invisible to the compiler. Every remote
                // working-directory query has answered `unknown subcommand`
                // since — so a drag onto a remote pane said "working
                // directory unknown" and fell back to home, which is the
                // defect [[WI-2026-08-16-001]] existed to fix.
                ".synapty/bin/synapty sessions --id \(Shell.quote(agentID))",
            ],
            timeout: timeout)
        return parse(stdout: out.stdout, exitCode: out.exitCode)
    }

    /// WHERE THE SHELL IS STANDING, and only when it is an ABSOLUTE path.
    /// A holder that could not determine a directory writes "-", and a
    /// destination built from that would be a directory nobody asked for.
    ///
    /// Columns: name, attached state, child state, the FOREGROUND group's
    /// working directory, its command, the SHELL's working directory.
    ///
    /// THE SIXTH, AND NOT THE FOURTH AS A FALLBACK ([[WI-2026-08-18-004]]).
    /// The two differ whenever the session is running anything that has
    /// `cd`d, and this answer is used to place things: `jenv rehash` runs
    /// from a great many `.zshrc` files and spends its life in
    /// `~/.jenv/shims`, and the fourth column reports that as the
    /// session's directory.
    ///
    /// A HOLDER OLD ENOUGH TO WRITE FIVE COLUMNS ANSWERS NOTHING, which
    /// is deliberate. It outlives a deploy by design, so the skew is real
    /// — and reading its fourth column would be quietly keeping the
    /// wrong answer this exists to remove, in the one place nothing marks
    /// it. Unknown is a state the drag hint already says out loud, and
    /// carrying a second shape for a transient window is what
    /// [[RFC-0015]] C-UNRELEASED is a standing rule against.
    static func parse(stdout: String, exitCode: Int32?) -> String? {
        guard exitCode == 0 else { return nil }
        let line = stdout.split(separator: "\n").first.map(String.init) ?? ""
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count > 5 else { return nil }
        let path = String(columns[5]).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? path : nil
    }
}
