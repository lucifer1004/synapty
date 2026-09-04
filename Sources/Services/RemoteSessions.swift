import Foundation

/// WHAT A HOST IS HOLDING, ASKED OF THE HOST.
///
/// [[RFC-0014]] C-END requires every holder on a host to be enumerable on
/// that host, and the far side already answers: `synapty sessions` lists
/// them and sweeps the records of the ones that are gone. Nothing on this
/// side had ever asked. The two remote calls this workbench made —
/// [[RemoteAgentSession]] to end one, [[RemotePwd]] to ask where one is —
/// both take a name, so a holder no workspace named was invisible from
/// here while running perfectly well over there.
///
/// FOUND IN ITS DOZENS, TWICE: 35 on remotehost with the oldest four days
/// old ([[RemoteAgentSession]] records it), and five on this Mac against
/// one open pane. The clause's own summary is the reason to close it —
/// "a holder that nothing can see is the failure the previous mechanism
/// produced".
///
/// AND IT MATTERS MORE FROM NOW ON. Closing a remote pane used to end its
/// agent, so a remote holder outlived only a crash or a quit;
/// [[RFC-0015]] C-PANE-ARCHIVE stopped that, deliberately, which means remote
/// holders now accumulate the way local ones did.
enum RemoteSessions {

    /// One row of the far side's listing.
    struct Session: Equatable, Identifiable {
        let name: String
        let attached: Bool
        let everAttached: Bool
        let childExited: Bool
        /// Seconds since anybody was attached. C-END names this and
        /// "whether the child has exited" as what a human decides on.
        let unattached: Int
        /// The foreground command, or nil where the host would not say.
        let command: String?
        /// WHERE IT IS, WHICH IS WHAT TELLS TWO OF THEM APART. Every
        /// session is named `local-XXXX` — the namespace [[RFC-0008]]
        /// C-IDENTITY reserves, and deliberately not the host's label,
        /// because that spelling put remote panes in a third namespace and
        /// broke [[RFC-0009]] C-IDENTITY-SCOPE. So the name distinguishes
        /// nothing a human can act on and the directory is what does.
        ///
        /// THE SHELL'S, NOT THE FOREGROUND GROUP'S: they differ whenever
        /// the session is running anything that has `cd`d, and what
        /// identifies a session to a human is where they are working
        /// rather than where a build script went ([[RemotePwd]] carries
        /// the measurement).
        let directory: String?
        /// RUNNING AND UNREACHABLE AT ONCE. Its socket is not answering,
        /// so it can be ended but not attached — different offers, which
        /// C-END requires to be told apart.
        let unreachable: Bool
        /// Who sits in the seat, as the client said ([[RFC-0014]]
        /// C-CLIENT-LABEL): `gui@deskmac:41`. Nil when nobody, or when the
        /// far side predates the column.
        var attachedBy: String? = nil
        /// The human's name for it ([[RFC-0014]] C-SESSION-NAME), nil when
        /// none was given.
        var humanName: String? = nil

        var id: String { name }
    }

    /// One round trip over the master that is already open.
    ///
    /// A HOST THAT CANNOT BE ASKED HAS NOT ANSWERED "NOTHING". The caller
    /// gets no rows either way, and must not present that as a host with
    /// nothing on it — see the call site, which keeps the previous answer
    /// rather than blanking the list.
    /// nil WHEN THE HOST COULD NOT BE ASKED, which is not the same
    /// answer as a host that holds nothing — and used to be the same
    /// VALUE ([[WI-2026-09-03-012]]). A caller handed `[]` for both had
    /// no choice but to distrust every empty listing, so a host's last
    /// row could never leave the sidebar.
    nonisolated static func query(connection: RemoteConnection,
                                  timeout: TimeInterval = 10) -> [Session]? {
        let out = SubprocessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: connection.sshOptions + [
                connection.userAtHost,
                ".synapty/bin/synapty sessions",
            ],
            timeout: timeout)
        return parse(stdout: out.stdout, exitCode: out.exitCode)
    }

    /// The host writes "-" where it could not say.
    private static func pick(_ column: Substring) -> String? {
        column == "-" || column.isEmpty ? nil : String(column)
    }

    /// Columns, as the far side writes them: name, attached, ever
    /// attached, child state, seconds unattached, the foreground group's
    /// directory, its command, the shell's directory.
    ///
    /// IN THE ORDER THE HOST GAVE THEM. It has already decided; a second
    /// ordering here would be a second answer to a question that has one.
    /// nil for a call that did not complete; a list — possibly empty —
    /// for one that did ([[query]]).
    static func parse(stdout: String, exitCode: Int32?) -> [Session]? {
        guard exitCode == 0 else { return nil }
        return stdout.split(separator: "\n").compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count >= 8 else { return nil }
            let name = String(c[0])
            // THE POLICY SENTENCE IS NOT A SESSION. C-END requires the
            // listing to carry it; reading it as a row would put a
            // session called "policy" in front of the human.
            guard name != "policy" else { return nil }
            let state = String(c[1])
            return Session(
                name: name,
                attached: state == "attached",
                everAttached: String(c[2]) == "seen",
                childExited: String(c[3]) == "child-exited",
                unattached: Int(c[4]) ?? 0,
                command: c[6] == "-" ? nil : String(c[6]),
                directory: pick(c[7]) ?? pick(c[5]),
                unreachable: state == "unreachable",
                // Two trailing columns a newer far side writes; an older
                // one stops at eight and these stay nil.
                attachedBy: c.count > 8 ? pick(c[8]) : nil,
                humanName: c.count > 9 ? pick(c[9]) : nil)
        }
    }
}
