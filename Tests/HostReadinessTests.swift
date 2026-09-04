import XCTest
@testable import Synapty

/// A host row travels between Macs and the credential it names does not
/// ([[ADR-0009]]). Without this, syncing converts a connection failure
/// into a subtler one: a host that looks ready and is not.
@MainActor
final class HostReadinessTests: XCTestCase {

    private var tempDir: URL!
    private var store: HostStore!

    override func setUpWithError() throws {
        tempDir = try setUpHostStoreStorage()
        store = HostStore()
    }

    override func tearDownWithError() throws {
        restoreStorageOverrides(tempDir)
    }

    private func present(_ paths: Set<String>) -> (String) -> Bool {
        { paths.contains($0) }
    }

    /// THE CASE SYNC PRODUCES. A host arrives from another Mac naming
    /// /Users/other/.ssh/id_ed25519, which is not here.
    func testASyncedHostNamingAMissingKeyIsIncompleteForBoth() {
        let host = HostEntry(label: "remotehost", address: "gc.example",
                             username: "u", sshKeyPath: "/Users/other/.ssh/id_ed25519")
        let r = HostReadiness.evaluate(host: host, store: store, fileExists: present([]))

        XCTAssertFalse(r.isComplete)
        XCTAssertFalse(r.canOpenTerminal, "the human CHOSE this key; ssh will not silently substitute another")
        XCTAssertFalse(r.canDeploy)
        XCTAssertEqual(r.terminalGap, .keyFileMissing(path: "/Users/other/.ssh/id_ed25519"))
    }

    /// THE ASYMMETRY THAT IS THE WHOLE POINT. No key named at all: the
    /// human is fine — ssh falls back to the agent, ~/.ssh/config, or a
    /// password prompt in the pane, all of which work because a person is
    /// watching. The workbench is not fine: it scps and holds tunnels
    /// non-interactively, where the same prompt is fatal.
    func testNoKeyBlocksDeployButNotTheTerminal() {
        let host = HostEntry(label: "legacy", address: "old.example", username: "u")
        let r = HostReadiness.evaluate(host: host, store: store, fileExists: present([]))

        XCTAssertTrue(r.canOpenTerminal, "a password prompt in a PTY is not a failure")
        XCTAssertFalse(r.canDeploy)
        XCTAssertEqual(r.deployGap, .noKeyConfigured)
        // And it says WHICH, or the human sees a warning on a host they
        // can open perfectly well and stops trusting warnings.
        XCTAssertTrue(r.summary?.contains("Agents cannot be deployed") ?? false)
    }

    func testAPresentKeyIsSilent() {
        let key = "/Users/operator/.ssh/id_ed25519"
        let host = HostEntry(label: "ok", address: "ok.example", username: "u", sshKeyPath: key)
        let r = HostReadiness.evaluate(host: host, store: store, fileExists: present([key]))

        XCTAssertTrue(r.isComplete)
        // A capability that works is invisible by working — RFC-0010
        // C-DIAGNOSABILITY, applied to hosts.
        XCTAssertNil(r.summary)
        XCTAssertNil(r.accessibilityPhrase)
    }

    /// An identity reference that did not travel is not a missing key, it
    /// is a missing answer to "who am I on this host" — so it blocks both.
    func testAnUnresolvableIdentityBlocksBoth() {
        var host = HostEntry(label: "x", address: "x.example", username: "u")
        host.identityID = UUID()
        let r = HostReadiness.evaluate(host: host, store: store, fileExists: present([]))

        XCTAssertEqual(r.terminalGap, .identityMissing)
        XCTAssertEqual(r.deployGap, .identityMissing)
    }

    /// The identity resolved but ITS key is elsewhere — reported as the
    /// identity's problem, because that is where the human fixes it.
    func testAnIdentityWhoseKeyIsMissingSaysSo() {
        let identity = Identity(id: UUID(), label: "ml", username: "ml",
                                sshKeyPath: "/Users/other/.ssh/ml_key")
        store.identities.append(identity)
        var host = HostEntry(label: "gpu", address: "gpu.example", username: "ml")
        host.identityID = identity.id

        let r = HostReadiness.evaluate(host: host, store: store, fileExists: present([]))
        XCTAssertEqual(r.terminalGap, .identityKeyFileMissing(path: "/Users/other/.ssh/ml_key"))
        XCTAssertTrue(r.summary?.contains("identity's SSH key") ?? false)
    }

    /// Tilde paths are the common way a key is written, and a literal
    /// "~/.ssh/id_ed25519" exists on no filesystem.
    func testTildePathsAreExpandedBeforeAsking() {
        let expanded = ("~/.ssh/id_ed25519" as NSString).expandingTildeInPath
        let host = HostEntry(label: "t", address: "t.example", username: "u",
                             sshKeyPath: "~/.ssh/id_ed25519")
        let r = HostReadiness.evaluate(host: host, store: store, fileExists: present([expanded]))
        XCTAssertTrue(r.isComplete, "a tilde path must be resolved, not tested literally")
    }

    /// The human-facing string abbreviates the home directory rather than
    /// printing an absolute path nobody reads — and carries no diagnostic
    /// vocabulary (AppLog's two-channel rule).
    func testTheSummaryIsForAHumanNotForALog() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let host = HostEntry(label: "h", address: "h.example", username: "u",
                             sshKeyPath: "\(home)/.ssh/absent")
        let r = HostReadiness.evaluate(host: host, store: store, fileExists: present([]))
        let s = try! XCTUnwrap(r.summary)
        XCTAssertTrue(s.contains("~/.ssh/absent"))
        XCTAssertFalse(s.contains(home), "an absolute home path is noise to the person reading it")
    }
}

extension HostReadinessTests {

    /// THE GRID MARKS ONLY WHAT BLOCKS THE HUMAN'S OWN USE.
    ///
    /// This test previously required a deploy-only gap to carry a warning
    /// glyph, on the reasoning that two severities should be
    /// distinguishable. The severities were right and the premise was
    /// wrong: a host with no key path configured is the ORDINARY setup
    /// for anyone using ssh-agent or ~/.ssh/config, so that rule put an
    /// orange mark on every card in the grid, permanently. A mark that is
    /// on for the normal case carries nothing and spends the credibility
    /// of the marks that do ([[WI-2026-08-15-003]]).
    ///
    /// The deploy gap is still computed and still spoken by `describe`;
    /// it belongs where someone deploys, not on a card at rest.
    func testTheGridMarksOnlyWhatBlocksTheHuman() {
        let blocked = HostReadiness(terminalGap: .keyFileMissing(path: "/x"),
                                    deployGap: .keyFileMissing(path: "/x"))
        let deployOnly = HostReadiness(terminalGap: nil, deployGap: .noKeyConfigured)

        let b = try! XCTUnwrap(HostFailureMarks.readiness(blocked))
        XCTAssertEqual(b.1, DS.danger, "a host the human cannot open is a failure")
        XCTAssertNil(
            HostFailureMarks.readiness(deployOnly),
            "a host that opens fine must not wear a warning for an action nobody has taken")

        // Still said, just not drawn: the sentence survives for the
        // places that ask for it.
        XCTAssertNotNil(deployOnly.summary)
        XCTAssertNotNil(deployOnly.accessibilityPhrase)
    }

    /// A complete host shows nothing at all.
    func testACompleteHostHasNoMark() {
        XCTAssertNil(HostFailureMarks.readiness(HostReadiness(terminalGap: nil, deployGap: nil)))
    }

    /// The card and the list row are two views of one host switched by a
    /// toggle; a failure visible in one and not the other reads as the
    /// failure resolving itself when the human changes a view preference.
    func testBothPresentationsSpeakTheSameReadiness() {
        let host = HostEntry(label: "gc", address: "gc.example", username: "u",
                             sshKeyPath: "/Users/other/.ssh/id_ed25519")
        let r = HostReadiness(terminalGap: .keyFileMissing(path: "/Users/other/.ssh/id_ed25519"),
                              deployGap: .keyFileMissing(path: "/Users/other/.ssh/id_ed25519"))
        let spoken = HostFailureMarks.describe(
            host: host, connected: false, unsaved: false, peerState: .none, readiness: r)

        XCTAssertTrue(spoken.contains("SSH key not on this Mac"))
        // And the hover text is the same sentence, so the two carriers
        // cannot drift apart.
        XCTAssertEqual(HostFailureMarks.readiness(r)?.2, r.summary)
    }
}
