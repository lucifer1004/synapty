import XCTest
@testable import Synapty

/// A listing read from a REAL sshd, over a REAL ControlMaster.
///
/// SKIPPED UNLESS ASKED FOR. It needs a live connection, so it cannot run
/// in an ordinary `just verify` — but the thing it checks is the thing the
/// offline codec tests structurally cannot: that the bytes this project
/// writes are the bytes OpenSSH's subsystem expects. A framing agreement
/// with a mock is an agreement with oneself.
///
///     SYNAPTY_LIVE_SOCKET=~/.synapty/sockets/'user@host:22' \
///     SYNAPTY_LIVE_USERHOST=user@host \
///     xcodebuild … -only-testing:SynaptyTests/RemoteFSLiveTests test
///
/// [[WI-2026-08-15-009]]
final class RemoteFSLiveTests: XCTestCase {

    private func liveConnection() throws -> RemoteConnection {
        let env = ProcessInfo.processInfo.environment
        let socket = try XCTUnwrap(env["SYNAPTY_LIVE_SOCKET"], "no live host configured")
        let userAtHost = try XCTUnwrap(env["SYNAPTY_LIVE_USERHOST"], "no live host configured")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: socket),
                          "no ControlMaster at \(socket)")
        return RemoteConnection(
            userAtHost: userAtHost,
            port: Int(env["SYNAPTY_LIVE_PORT"] ?? "22") ?? 22,
            controlPath: socket,
            identity: nil)
    }

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SYNAPTY_LIVE_SOCKET"] == nil,
                      "live host tests are opt-in")
    }

    /// The handshake, the canonicalisation and a real directory, end to end.
    func testAHomeDirectoryCanActuallyBeListed() throws {
        let connection = try liveConnection()
        switch RemoteFS.list(".", over: connection) {
        case .failure(let failure):
            XCTFail("listing failed: \(failure.message)")
        case .success(let listing):
            XCTAssertTrue(listing.canonicalPath.hasPrefix("/"),
                          "the host resolves '.' to an absolute path, we do not")
            XCTAssertFalse(listing.entries.isEmpty, "a home directory with nothing in it is suspicious")
            XCTAssertFalse(listing.entries.contains { $0.name == "." || $0.name == ".." },
                           "navigation entries are not content")
            // Directories sort first, which is only visible on real data.
            let firstFileIndex = listing.entries.firstIndex { !$0.attributes.isDirectory }
            if let firstFileIndex {
                let laterDirectory = listing.entries[firstFileIndex...].first { $0.attributes.isDirectory }
                XCTAssertNil(laterDirectory, "a directory sorted after a file")
            }
        }
    }

    /// A `~` PATH MUST STILL WORK, and only a live host can show that it
    /// does. SFTP has no tilde — expansion is a shell's job and there is no
    /// shell on this connection — so REALPATH("~") fails against real sshd
    /// while REALPATH(".") answers the home directory. Every offline test
    /// agreed with the codec about a `~` that OpenSSH rejects.
    func testATildePathResolvesEvenThoughTheProtocolHasNoTilde() throws {
        let connection = try liveConnection()
        guard case .success(let listing) = RemoteFS.list("~", over: connection) else {
            return XCTFail("listing ~ failed")
        }
        XCTAssertFalse(listing.canonicalPath.contains("~"))
        XCTAssertTrue(listing.canonicalPath.hasPrefix("/"))
    }

    /// A directory that is not there fails with the host's own reason,
    /// rather than as an empty listing that looks like an empty directory.
    func testAMissingDirectoryFailsRatherThanLookingEmpty() throws {
        let connection = try liveConnection()
        switch RemoteFS.list("/nonexistent-synapty-probe", over: connection) {
        case .success(let listing):
            XCTFail("expected a failure, got \(listing.entries.count) entries")
        case .failure(let failure):
            XCTAssertFalse(failure.message.isEmpty)
        }
    }
}
