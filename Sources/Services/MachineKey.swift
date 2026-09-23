import Foundation

/// This Mac's own SSH key, and the public halves of every Mac the human
/// has ([[ADR-0009]]: sync the authorization, not the secret).
///
/// The private half never leaves this machine and is never placed in a
/// syncing store. The public half is published into the shared config
/// directory because a public key is not a secret, and because that is
/// what lets an already-authorized Mac enrol a new one without either
/// machine handling the other's private material.
///
/// A DEDICATED key rather than the human's existing one. Reusing
/// ~/.ssh/id_ed25519 would make "revoke Synapty's access from that Mac"
/// mean "revoke their personal key", and per-machine revocation is one of
/// the two reasons ADR-0009 chose this shape.
enum MachineKey {

    /// Comment written into the public key and therefore into every
    /// authorized_keys line. FOR HUMANS: an entry nobody can attribute is
    /// an entry nobody will dare remove. Matching is done on key MATERIAL,
    /// so this drifting (a peer-id re-mint) costs readability, not
    /// correctness.
    static func comment(for peerID: String) -> String { "synapty:\(peerID)" }

    /// Test seam: ~/.ssh is the human's real key directory, and a test
    /// that generated or looked for keys there would be reading and
    /// writing their actual credentials.
    nonisolated(unsafe) static var sshDirOverride: URL?

    static var sshDir: URL {
        if let sshDirOverride { return sshDirOverride }
        // A TEST HOST NEVER REACHES THE HUMAN'S REAL KEYS
        // ([[WI-2026-08-14-010]]). ~/.ssh is where their actual
        // credentials live, and a suite that generated or read keys there
        // would be operating on them.
        if TestHost.isActive { return TestHost.configRoot.appendingPathComponent("ssh") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    static func privateKeyURL(peerID: String) -> URL {
        sshDir.appendingPathComponent("synapty_\(peerID)")
    }

    static func publicKeyURL(peerID: String) -> URL {
        sshDir.appendingPathComponent("synapty_\(peerID).pub")
    }

    /// Where the public half is published so other Macs can see it. Inside
    /// the sync domain on purpose; the private half is not, and a test
    /// pins that.
    static var publishedDir: URL {
        ConfigPaths.shared.appendingPathComponent("machines")
    }

    static func publishedURL(peerID: String) -> URL {
        publishedDir.appendingPathComponent("\(peerID).pub")
    }

    /// This machine's peer id, as minted and persisted by its hub
    /// ([[RFC-0010]]). Reused rather than inventing a second machine
    /// identity: that one already has minting, persistence, collision
    /// handling and a re-mint story.
    static func localPeerID() -> String? {
        guard let data = try? Data(contentsOf: ConfigPaths.identity),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["peer_id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    /// Make this Mac offerable: generate its key if absent and publish the
    /// public half. Idempotent, and silent when the hub has not minted a
    /// peer id yet — a normal state at launch, not a failure; the next
    /// launch picks it up.
    @MainActor
    static func publishLocal() {
        guard let peerID = localPeerID(), !peerID.isEmpty else { return }
        // FIRST RUN ON A NEW MAC GENERATES A KEY, and ssh-keygen ran on the
        // main actor at launch — up to thirty seconds of frozen window
        // ([[WI-2026-09-02-022]]). Generate off the main thread; publish
        // back on it. A key already on disk takes the short path.
        let priv = privateKeyURL(peerID: peerID)
        if FileManager.default.fileExists(atPath: priv.path) {
            ensureLocalKey(peerID: peerID)
            return
        }
        try? FileManager.default.createDirectory(
            at: sshDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let note = comment(for: peerID)
        Task.detached(priority: .userInitiated) {
            _ = runKeygen(priv, note)
            await MainActor.run { ensureLocalKey(peerID: peerID) }
        }
    }

    /// Ensure this Mac has a key and that its public half is published.
    /// Idempotent: generating twice would invalidate every enrolment
    /// already made for this machine.
    @discardableResult
    @MainActor
    static func ensureLocalKey(
        peerID: String,
        keygen: (URL, String) -> Bool = MachineKey.runKeygen
    ) -> String? {
        let priv = privateKeyURL(peerID: peerID)
        if !FileManager.default.fileExists(atPath: priv.path) {
            try? FileManager.default.createDirectory(
                at: sshDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard keygen(priv, comment(for: peerID)) else {
                AppLog.sync.error(
                    "could not generate this machine's SSH key — it cannot be enrolled on any host until this succeeds")
                return nil
            }
        }
        guard let pub = try? String(contentsOf: publicKeyURL(peerID: peerID), encoding: .utf8)
        else { return nil }
        publish(publicKey: pub, peerID: peerID)
        return pub.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    static func publish(publicKey: String, peerID: String) {
        do {
            try FileManager.default.createDirectory(
                at: publishedDir, withIntermediateDirectories: true)
            let trimmed = publicKey.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            let url = publishedURL(peerID: peerID)
            // Only write on change: rewriting identical bytes would offer
            // the record to sync on every launch for nothing.
            if let existing = try? String(contentsOf: url, encoding: .utf8), existing == trimmed {
                return
            }
            try trimmed.write(to: url, atomically: true, encoding: .utf8)
            SyncEngine.shared.noteLocalChange(path: "machines/\(peerID).pub")
        } catch {
            AppLog.sync.error(
                "could not publish this machine's public key: \(error.localizedDescription, privacy: .public) — other Macs will not be able to enrol it")
        }
    }

    private static func runKeygen(_ path: URL, _ comment: String) -> Bool {
        SubprocessRunner.runQuiet(
            executable: "/usr/bin/ssh-keygen",
            arguments: ["-t", "ed25519", "-N", "", "-C", comment, "-f", path.path],
            timeout: 30)
    }

    // MARK: - The other machines

    struct Machine: Identifiable, Equatable {
        var id: String { peerID }
        let peerID: String
        /// The full authorized_keys line, verbatim.
        let publicKey: String
        let isThisMachine: Bool
    }

    /// Every Mac whose public key has reached this one, including this
    /// one. Read from the synced directory, so a machine appears here as
    /// soon as sync carries its key.
    static func knownMachines(localPeerID: String?) -> [Machine] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: publishedDir.path)
        else { return [] }
        return names.compactMap { name -> Machine? in
            guard name.hasSuffix(".pub") else { return nil }
            let peerID = String(name.dropLast(4))
            guard let key = try? String(
                contentsOf: publishedDir.appendingPathComponent(name), encoding: .utf8)
            else { return nil }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("ssh-") else { return nil }
            return Machine(peerID: peerID, publicKey: trimmed, isThisMachine: peerID == localPeerID)
        }.sorted { $0.peerID < $1.peerID }
    }
}
