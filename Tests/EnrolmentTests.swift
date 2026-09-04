import XCTest
@testable import Synapty

/// [[ADR-0009]] / [[WI-2026-08-14-001]]: sync the authorization, not the
/// secret. These pin the properties that make that claim true — the ones
/// whose failure is silent.
final class EnrolmentTests: XCTestCase {

    private let samplePublic =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialHere synapty:deskmac-2630"

    // MARK: - The secret does not sync

    /// THE PRIVATE HALF MUST BE OUTSIDE THE SYNC DOMAIN.
    ///
    /// The whole point of ADR-0009 is that a private key never reaches a
    /// store that replicates. Nothing else in the system would notice if
    /// it did: the key would work, sync would succeed, and every machine
    /// would quietly hold every other machine's secret.
    func testThePrivateKeyLivesOutsideAnythingThatSyncs() {
        let peer = "deskmac-2630"
        let shared = ConfigPaths.shared.standardizedFileURL.path
        let priv = MachineKey.privateKeyURL(peerID: peer).standardizedFileURL.path

        // SCOPED TO THE SYNCED DIRECTORY, not to $HOME: under test the
        // whole config root AND ~/.ssh are redirected into one sandbox
        // ([[WI-2026-08-14-010]]), so "is it under the home directory" is
        // not a question this can ask. What replication actually copies is
        // `shared`, and that is the boundary that must hold.
        XCTAssertFalse(
            priv.hasPrefix(shared),
            "the private key must not resolve inside the directory sync replicates")
        XCTAssertTrue(
            MachineKey.publishedURL(peerID: peer).standardizedFileURL.path.hasPrefix(shared),
            "while the public half must, or no other Mac can enrol this one")
    }

    /// The PUBLIC half is published where other Macs can see it — a public
    /// key is not a secret, and publishing it is what lets an authorized
    /// Mac enrol another without either handling private material.
    func testThePublicHalfIsPublishedIntoTheSharedDirectory() {
        let published = MachineKey.publishedURL(peerID: "deskmac-2630").standardizedFileURL.path
        XCTAssertTrue(published.hasPrefix(ConfigPaths.shared.standardizedFileURL.path))
        XCTAssertTrue(published.hasSuffix(".pub"), "the format other tools already read")
    }

    // MARK: - The remote write

    /// sshd ignores authorized_keys ENTIRELY — logging nothing a human
    /// will read — when ~/.ssh is not 700 or the file is not 600. The
    /// write succeeds, the content looks right, and the key does not work.
    func testTheAddCommandCannotProduceAFileSshdWillIgnore() {
        let cmd = Enrolment.addCommand(publicKey: samplePublic)
        XCTAssertTrue(cmd.contains("umask 077"), "modes must not be inherited from the remote shell")
        XCTAssertTrue(cmd.contains("mkdir -p ~/.ssh"), "a missing ~/.ssh must not be a silent failure")
    }

    /// APPEND ONLY, and idempotent. Every other line in that file was put
    /// there by someone else for reasons we know nothing about.
    func testTheAddCommandAppendsAndNeverRewrites() {
        let cmd = Enrolment.addCommand(publicKey: samplePublic)
        XCTAssertTrue(cmd.contains(">> ~/.ssh/authorized_keys"), "append, never truncate")
        // A TRUNCATING redirect, i.e. a single `>` — note that ">>" also
        // contains ">", so the needle has to carry the preceding space.
        XCTAssertFalse(cmd.contains(" > ~/.ssh/authorized_keys"),
                       "a truncating redirect would replace the human's file")
        XCTAssertTrue(cmd.contains("grep -qxF"),
                      "whole-line literal match, so re-running adds nothing")
    }

    /// REVOCATION MATCHES KEY MATERIAL, NOT THE COMMENT. The comment
    /// drifts — a peer-id re-mint changes it — and matching it would leave
    /// a WORKING key behind whenever the label had moved, which is the
    /// worst direction for a revocation to fail in.
    func testRevocationMatchesTheKeyNotItsLabel() {
        let renamed =
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialHere synapty:deskmac-9999"
        XCTAssertEqual(
            Enrolment.keyMaterial(of: samplePublic),
            Enrolment.keyMaterial(of: renamed),
            "the same key under a different comment is the same key")

        let cmd = Enrolment.removeCommand(publicKey: samplePublic)
        XCTAssertFalse(cmd.contains("deskmac-2630"), "the comment must not be the matcher")
        XCTAssertTrue(cmd.contains("AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialHere"))
        XCTAssertTrue(cmd.contains("chmod 600"), "the mode is restored, not inherited from the redirect")
    }

    /// Absent file is success, not failure: revoking a key that was never
    /// there leaves the human authorized as they already were.
    func testRevokingFromAHostThatWasNeverEnrolledSucceeds() {
        XCTAssertTrue(Enrolment.removeCommand(publicKey: samplePublic).contains("exit 0"))
    }

    // MARK: - Quoting

    /// The comment is free-form and the human's to write, so it reaches a
    /// remote shell as data. A quote in it must not end the argument.
    func testAQuoteInTheCommentCannotEscapeTheArgument() {
        let nasty = "ssh-ed25519 AAAAB3 don't; rm -rf ~"
        let quoted = Shell.quote(nasty)
        XCTAssertTrue(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
        XCTAssertTrue(quoted.contains("'\\''"), "the embedded quote is closed, escaped and reopened")
        // Nothing between the wrapping quotes may terminate the string.
        let inner = String(quoted.dropFirst().dropLast())
        XCTAssertFalse(inner.contains("'") && !inner.contains("'\\''"))
    }

    func testKeyMaterialSurvivesAKeyWithNoComment() {
        let bare = "ssh-ed25519 AAAAB3"
        XCTAssertEqual(Enrolment.keyMaterial(of: bare), bare)
    }

    // MARK: - Which key this machine actually presents

    /// ENROLMENT IS POINTLESS UNLESS THE KEY GETS PRESENTED.
    ///
    /// Host records SYNC and `sshKeyPath` is a machine-local PATH, so a
    /// record that works on the Mac it was written on can name a file the
    /// next Mac does not have. Authorizing this machine's dedicated key
    /// only means something if the connection falls back to it — which is
    /// the gap [[ADR-0009]] exists to close.
    @MainActor
    func testAMacWithoutTheConfiguredKeyFallsBackToItsOwn() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }

        let ssh = tmp.appendingPathComponent("ssh-seam")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        MachineKey.sshDirOverride = ssh
        defer { MachineKey.sshDirOverride = nil }

        // A hub that has minted this machine's id, and the key named after it.
        try FileManager.default.createDirectory(
            at: ConfigPaths.machine, withIntermediateDirectories: true)
        try #"{"peer_id":"deskmac-2630"}"#.write(
            to: ConfigPaths.identity, atomically: true, encoding: .utf8)
        let own = MachineKey.privateKeyURL(peerID: "deskmac-2630")
        try "PRIVATE".write(to: own, atomically: true, encoding: .utf8)

        let store = HostStore()
        let tm = TunnelManager()
        tm.hostStore = store
        var host = HostEntry(label: "remotehost", address: "remotehost", username: "operator")
        // A path written on ANOTHER Mac, which does not exist here.
        host.sshKeyPath = "/Users/someone-else/.ssh/id_ed25519"

        XCTAssertEqual(
            tm.effectiveKeyPath(for: host), own.path,
            "a key the record names but this Mac does not have must fall back to this Mac's own")
        XCTAssertEqual(
            store.effectiveKeyPath(for: host), "/Users/someone-else/.ssh/id_ed25519",
            "what the RECORD says is a separate question, and is unchanged")
    }

    /// A Mac that HAS the configured key keeps using it — the fallback
    /// must not quietly re-authenticate working setups with a new key.
    @MainActor
    func testAMacThatHasTheConfiguredKeyKeepsUsingIt() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }

        let real = tmp.appendingPathComponent("id_ed25519")
        try "PRIVATE".write(to: real, atomically: true, encoding: .utf8)

        let tm = TunnelManager()
        tm.hostStore = HostStore()
        var host = HostEntry(label: "remotehost", address: "remotehost", username: "operator")
        host.sshKeyPath = real.path

        XCTAssertEqual(tm.effectiveKeyPath(for: host), real.path)
    }

    /// Neither on disk: hand back what was configured, so the failure
    /// names the file the human expected rather than saying nothing.
    @MainActor
    func testWithNoKeyAnywhereTheConfiguredPathIsStillReported() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }
        MachineKey.sshDirOverride = tmp.appendingPathComponent("empty-ssh")
        defer { MachineKey.sshDirOverride = nil }

        let tm = TunnelManager()
        tm.hostStore = HostStore()
        var host = HostEntry(label: "remotehost", address: "remotehost", username: "operator")
        host.sshKeyPath = "/nonexistent/id_ed25519"
        XCTAssertEqual(tm.effectiveKeyPath(for: host), "/nonexistent/id_ed25519")
    }

    /// A HOST WITH NO KEY NAMED MUST GET NO `-i` AT ALL.
    ///
    /// This is the ordinary setup for anyone on ssh-agent or
    /// ~/.ssh/config, and it is 13 of this operator's 14 hosts. Offering
    /// this machine's dedicated key there presents an identity no host has
    /// authorised: measured against a live host, the same command succeeds
    /// without `-i` and returns "Permission denied" with it
    /// ([[WI-2026-08-15-008]]).
    @MainActor
    func testAHostThatNamesNoKeyIsGivenNoIdentity() throws {
        let tmp = try setUpHostStoreStorage()
        defer { restoreStorageOverrides(tmp) }

        let ssh = tmp.appendingPathComponent("ssh-seam")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        MachineKey.sshDirOverride = ssh
        defer { MachineKey.sshDirOverride = nil }
        try FileManager.default.createDirectory(
            at: ConfigPaths.machine, withIntermediateDirectories: true)
        try #"{"peer_id":"deskmac-2630"}"#.write(
            to: ConfigPaths.identity, atomically: true, encoding: .utf8)
        try "PRIVATE".write(
            to: MachineKey.privateKeyURL(peerID: "deskmac-2630"),
            atomically: true, encoding: .utf8)

        let tm = TunnelManager()
        tm.hostStore = HostStore()
        // No sshKeyPath, no identity, no group — the common case.
        let host = HostEntry(label: "operator", address: "operator.example",
                             username: "operator")

        XCTAssertNil(
            tm.effectiveKeyPath(for: host),
            "a host that names no key must be left to ssh's own agent and config")
    }
}
