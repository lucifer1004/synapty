import Foundation

/// Authorize another Mac on a host, or take that authorization away.
///
/// [[ADR-0009]]: what syncs is the authorization, not the secret. An
/// already-authorized Mac appends another Mac's PUBLIC key to a host's
/// authorized_keys, and no private material moves anywhere.
///
/// ALWAYS A HUMAN'S EXPLICIT ACT. Writing to someone's authorized_keys is
/// a grant of standing access, and a workbench that did it as a
/// consequence of adding a host or turning sync on would be making a
/// security decision on their behalf.
enum Enrolment {

    /// The remote command that adds a key.
    ///
    /// Three properties, each load-bearing:
    ///
    /// APPEND ONLY. It never rewrites the file. Every other line in there
    /// was put there by someone else for reasons we know nothing about,
    /// and "I do not have it" is not "it should not exist" — the rule
    /// per-record host storage rests on too ([[WI-2026-08-13-004]]).
    ///
    /// IDEMPOTENT. `grep -qxF` matches the whole line literally, so
    /// enrolling twice adds nothing and a human can re-run it without
    /// thinking about whether they already did.
    ///
    /// `umask 077` AND an explicit mkdir. sshd ignores authorized_keys
    /// ENTIRELY — logging nothing the human will ever read — when ~/.ssh
    /// is not 700 or the file is not 600. The write then succeeds, the
    /// content is visibly correct, and the key does not work. Two tokens
    /// remove the whole class.
    static func addCommand(publicKey: String) -> String {
        let key = Shell.quote(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        return """
            umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; \
            grep -qxF \(key) ~/.ssh/authorized_keys || echo \(key) >> ~/.ssh/authorized_keys
            """
    }

    /// The remote command that removes a key.
    ///
    /// Matches on KEY MATERIAL rather than on the comment. The comment is
    /// for humans reading the file and may drift — a peer-id re-mint
    /// changes it — while the key itself is what actually grants access.
    /// Matching the comment would leave a working key behind whenever the
    /// label had moved, which is the worst possible direction for a
    /// revocation to fail in.
    ///
    /// The rewrite is confined to lines we can identify, and the file's
    /// mode is restored explicitly rather than inherited from whatever
    /// the redirect created.
    static func removeCommand(publicKey: String) -> String {
        let material = Shell.quote(keyMaterial(of: publicKey))
        return """
            umask 077; [ -f ~/.ssh/authorized_keys ] || exit 0; \
            grep -vF \(material) ~/.ssh/authorized_keys > ~/.ssh/.authorized_keys.synapty && \
            mv ~/.ssh/.authorized_keys.synapty ~/.ssh/authorized_keys && \
            chmod 600 ~/.ssh/authorized_keys
            """
    }

    /// The `type base64` part, without the trailing comment. This is what
    /// identifies a key; the comment is decoration.
    static func keyMaterial(of publicKey: String) -> String {
        let parts = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return publicKey }
        return "\(parts[0]) \(parts[1])"
    }
}
