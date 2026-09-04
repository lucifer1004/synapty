import Foundation

/// The durable session a remote agent lives in.
///
/// IT IS NAMED BY THE AGENT ID and nothing else, which is what lets a
/// client that has lost all its own state come back to it: `connect`
/// starts a holder under that name and attaches to it, and this ends it
/// by the same name ([[RFC-0014]] C-SCOPE, C-END).
///
/// This was a tmux session until [[ADR-0012]] moved durability into the
/// wrapper this project already deploys. NOTHING HERE SPEAKS TO THAT
/// MECHANISM ANY MORE ([[WI-2026-08-24-004]]): a retired mechanism still
/// spoken by the tool that retired it has not been retired, and a
/// product that has never shipped has nothing to be compatible with
/// ([[RFC-0015]] C-UNRELEASED).
///
/// [[ADR-0008]] stage 3a, [[WI-2026-08-16-001]], [[WI-2026-08-17-008]]
enum RemoteAgentSession {

    /// End it.
    ///
    /// A CLOSE IS A HUMAN SAYING THEY ARE DONE, and the holder is there to
    /// survive what the human did NOT choose — a network drop, a quit, a
    /// crash. Without this, closing a workspace left a detached session
    /// holding a `synapty run` and a shell that nothing would ever
    /// address again: found live on remotehost, 35 of them, the oldest
    /// four days old.
    ///
    /// Best effort and off the main actor. A host that has gone unreachable
    /// must not hold up closing a window, and a kill that does not land
    /// loses to the same disconnect that made it unreachable.
    /// WHETHER IT ENDED. This forced its own exit status with `; true`
    /// and then discarded it with `_ =`, so an `end` the far side refused
    /// — no such session, a holder that would not die — was reported to
    /// the caller as a success it could not distinguish from any other
    /// ([[WI-2026-09-03-010]]). `runQuiet` already nulls the streams; the
    /// redirect and the `true` were both belt on a belt.
    @discardableResult
    nonisolated static func kill(connection: RemoteConnection, agentID: String,
                                 timeout: TimeInterval = 10) -> Bool {
        SubprocessRunner.runQuiet(
            executable: "/usr/bin/ssh",
            arguments: connection.sshOptions + [
                connection.userAtHost,
                ".synapty/bin/synapty end --id \(Shell.quote(agentID))",
            ],
            timeout: timeout)
    }
}
