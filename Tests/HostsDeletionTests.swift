import XCTest
@testable import Synapty

/// [[HostsDeletion]] — one question at a time, by construction.
final class HostsDeletionTests: XCTestCase {

    /// THE SECOND QUESTION REPLACES THE FIRST. Held as three optionals,
    /// both could be set at once and the human would face two stacked
    /// alerts, the second asking about something the first had destroyed.
    func testOnlyOneThingCanBeAwaitingConfirmation() {
        let host = HostEntry(label: "buildbox", address: "10.0.0.9", username: "root")
        let group = HostGroup(label: "lab")

        var pending: HostsDeletion? = .host(host)
        pending = .group(group)

        XCTAssertEqual(pending, .group(group))
        if case .host = pending { XCTFail("two questions are outstanding at once") }
    }

    func testDismissingLeavesNothingOutstanding() {
        var pending: HostsDeletion? = .identity(Identity(label: "work key", username: "me", sshKeyPath: "/keys/id"))
        pending = nil
        XCTAssertNil(pending)
    }
}
