import XCTest
@testable import Synapty

/// Connecting to a host that wants a password ended with the pane closing
/// and nothing said. Synapty has no password path: setup runs in the
/// background with no terminal to prompt on, and the interactive session
/// runs behind `synapty attach`, whose stdin carries FRAMES — so the
/// human's keystrokes reach ssh wrapped in the holder protocol and are
/// read as a password made of frame bytes.
///
/// Until there is a password path, the failure at least has to say what
/// it was.
final class PasswordAuthTests: XCTestCase {
    func testRecognisesTheMethodsSSHSaysItWanted() {
        XCTAssertTrue(TunnelManager.wantsPassword(
            "user@box: Permission denied (publickey,password)."))
        XCTAssertTrue(TunnelManager.wantsPassword(
            "Permission denied (publickey,keyboard-interactive)."))
    }

    func testRecognisesAPromptNobodyCouldAnswer() {
        // The background run holds the prompt until its timeout, so there
        // is no "denied" line to read — only the prompt itself.
        XCTAssertTrue(TunnelManager.wantsPassword("user@10.0.0.5's password: "))
    }

    /// A KEY-ONLY REFUSAL IS NOT THIS. Saying "add a password" where the
    /// server refused the key would send the human after the wrong thing,
    /// which is the same failure as saying nothing.
    func testDoesNotClaimItOfAKeyOnlyRefusal() {
        XCTAssertFalse(TunnelManager.wantsPassword(
            "user@box: Permission denied (publickey)."))
        XCTAssertFalse(TunnelManager.wantsPassword(
            "ssh: connect to host box port 22: Connection refused"))
        XCTAssertFalse(TunnelManager.wantsPassword(""))
    }
}
