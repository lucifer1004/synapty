import XCTest
@testable import Synapty

/// Unit tests for TunnelManager's command building and credential
/// resolution — the fixed positional-argument contract of connectCommand
/// is exactly the kind of thing that drifts (WI-2026-08-08-021).
@MainActor
final class TunnelManagerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try setUpHostStoreStorage()
    }

    override func tearDownWithError() throws {
        restoreStorageOverrides(tempDir)
    }

    private func makeManager() -> TunnelManager {
        let m = TunnelManager()
        m.hostStore = HostStore()
        return m
    }

    // MARK: - shellEscape

    func testShellEscapePlain() {
        let m = makeManager()
        XCTAssertEqual(m.shellEscape("hello"), "'hello'")
    }

    func testShellEscapeEmbeddedQuote() {
        let m = makeManager()
        XCTAssertEqual(m.shellEscape("it's"), "'it'\\''s'")
    }

    func testShellEscapeEmpty() {
        let m = makeManager()
        XCTAssertEqual(m.shellEscape(""), "''")
    }

    func testShellEscapeSpecialCharsStayInsideQuotes() {
        let m = makeManager()
        // A label containing shell metacharacters must not be able to
        // Shell metacharacters must end up INSIDE the single-quoted unit —
        // single quotes make them literal, so no injection is possible.
        XCTAssertEqual(m.shellEscape("x; rm -rf /"), "'x; rm -rf /'")
        XCTAssertEqual(m.shellEscape("$(danger)"), "'$(danger)'")
        XCTAssertEqual(m.shellEscape("a b"), "'a b'")
    }

    // MARK: - connectCommand positional layout

    /// The connect script parses argv positionally:
    /// bash <script> <agentID> <address> <port> <username> <tunnelPort>
    ///      <hubPort> <key|''> <jump|''> [forwards...]
    func testConnectCommandPositionalLayout() {
        let m = makeManager()
        let host = HostEntry(label: "GPU", address: "10.0.1.5", port: 2222, username: "ml", sshKeyPath: "/keys/gpu")
        let result = m.connectCommand(for: host)
        let tokens = result.command.split(separator: " ").map(String.init)

        XCTAssertEqual(tokens[0], "bash")
        // The script path may be bundled (absolute) or repo-relative.
        XCTAssertTrue(tokens[1].hasPrefix("'"))
        XCTAssertTrue(tokens[1].hasSuffix("connect.sh'"))
        XCTAssertEqual(tokens[2], "'\(result.agentID)'")
        XCTAssertEqual(tokens[3], "'10.0.1.5'")
        XCTAssertEqual(tokens[4], "2222")
        XCTAssertEqual(tokens[5], "'ml'")
        XCTAssertEqual(tokens[6], "9000") // tunnelPort
        XCTAssertEqual(tokens[7], "9000") // hubPort
        XCTAssertEqual(tokens[8], "'/keys/gpu'")
        XCTAssertEqual(tokens[9], "''") // no jump
        XCTAssertEqual(tokens.count, 10) // no forwardings
    }

    func testConnectCommandEmptyKeyAndJumpArePlaceholders() {
        let m = makeManager()
        let host = HostEntry(label: "Min", address: "localhost", username: "u")
        let result = m.connectCommand(for: host)
        let tokens = result.command.split(separator: " ").map(String.init)
        XCTAssertEqual(tokens[8], "''")
        XCTAssertEqual(tokens[9], "''")
    }

    func testConnectCommandForwardingsAppended() {
        let m = makeManager()
        var host = HostEntry(label: "Fwd", address: "10.0.1.6", username: "u")
        host.forwardings = [PortForward(kind: .local, listenPort: 8080, targetHost: "localhost", targetPort: 80)]
        let result = m.connectCommand(for: host)
        let tokens = result.command.split(separator: " ").map(String.init)
        XCTAssertEqual(tokens.count, 14)
        XCTAssertEqual(tokens[10], "local")
        XCTAssertEqual(tokens[11], "8080")
        XCTAssertEqual(tokens[12], "'localhost'")
        XCTAssertEqual(tokens[13], "80")
    }

    // MARK: - effective* resolution (host → identity → group chain)

    func testEffectiveResolutionFromHostFields() {
        let m = makeManager()
        let host = HostEntry(label: "H", address: "1.1.1.1", port: 2222, username: "direct", sshKeyPath: "/k")
        XCTAssertEqual(m.effectiveUsername(for: host), "direct")
        XCTAssertEqual(m.effectivePort(for: host), 2222)
        XCTAssertEqual(m.effectiveKeyPath(for: host), "/k")
    }

    func testEffectiveResolutionFromIdentity() {
        let store = HostStore()
        let identity = Identity(id: UUID(), label: "ml", username: "ml-user", sshKeyPath: "~/.ssh/ml_key")
        store.identities.append(identity)
        let m = TunnelManager()
        m.hostStore = store

        var host = HostEntry(label: "H", address: "1.1.1.1", username: "")
        host.identityID = identity.id
        XCTAssertEqual(m.effectiveUsername(for: host), "ml-user")
        XCTAssertEqual(m.effectiveKeyPath(for: host), "~/.ssh/ml_key")
    }

    func testEffectiveResolutionFromGroupChain() {
        let store = HostStore()
        let group = HostGroup(id: UUID(), label: "Lab", parentID: nil)
        store.groups.append(group)
        let m = TunnelManager()
        m.hostStore = store

        // Group carries a port; the host defers to it (host port 22 = default).
        var host = HostEntry(label: "H", address: "1.1.1.1", username: "u")
        host.groupID = group.id
        var withPort = group
        withPort.port = 5555
        store.updateGroup(withPort)
        XCTAssertEqual(m.effectivePort(for: host), 5555)
    }

    // MARK: - localCommand

    func testLocalCommandShape() {
        let m = makeManager()
        let result = m.localCommand()
        XCTAssertTrue(result.agentID.hasPrefix("local-"))
        XCTAssertTrue(result.command.contains("run --id"))
        XCTAssertTrue(result.command.contains("--hub 127.0.0.1:9000"))
    }
}
