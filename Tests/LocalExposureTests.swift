import XCTest
@testable import Synapty

/// AN EXPOSE ON THIS MAC IS AN EXPOSE ([[RFC-0013]] C-PRIMITIVES:
/// "on the local connection nothing is unreachable and no forward is
/// opened, and the offer is the naming and the attribution rather than the
/// reach").
///
/// It was REFUSED — "this agent is on this Mac, its port is already
/// reachable at 127.0.0.1" — which mistook the mechanism for the primitive.
/// The human was told nothing, and the services pane on the connection
/// most humans are in could never hold anything at all
/// ([[WI-2026-08-19-001]]).
@MainActor
final class LocalExposureTests: XCTestCase {

    func testALocalAgentsExposeIsRecordedAndOpensNoForward() async {
        let forwards = PortForwardService()

        guard case .ok(let exposure) = await forwards.expose(
            hostID: nil, remotePort: 3000, agent: "claude", title: "the docs site")
        else { return XCTFail("a local expose was refused") }

        XCTAssertNil(exposure.hostID, "this Mac is a machine, not the absence of one")
        XCTAssertEqual(exposure.remotePort, 3000)
        XCTAssertEqual(exposure.localPort, 3000,
                       "no forward is opened locally, so the service is at the port it listens on")
        XCTAssertEqual(exposure.agent, "claude", "the offer IS the attribution")
        XCTAssertEqual(exposure.url.absoluteString, "http://127.0.0.1:3000/")
    }

    /// The offer is what a services leaf on this Mac shows, so it has to
    /// be findable by the machine it is on.
    func testALocalExposureIsFoundByTheLocalLeaf() async {
        let forwards = PortForwardService()
        _ = await forwards.expose(hostID: nil, remotePort: 8080, agent: "codex", title: nil)

        let local = forwards.exposures.filter { $0.hostID == nil }
        XCTAssertEqual(local.count, 1)
    }

    /// ONE LOOPBACK PORT IS ONE WEB ORIGIN, and "this Mac" is as much a
    /// party to that as any host. A port that carried a remote host's
    /// service would hand a local one that host's cookies.
    func testALocalExposureCannotTakeAPortAHostHasUsed() async {
        let forwards = PortForwardService()
        let host = UUID()
        guard let taken = forwards.allocatePort(for: .host(host)) else {
            return XCTFail("no port could be allocated")
        }

        guard case .refused(let why) = await forwards.expose(
            hostID: nil, remotePort: taken, agent: "claude", title: nil)
        else { return XCTFail("a local service took a port that has served a host") }
        XCTAssertTrue(why.contains("one site"), "the refusal must say why: \(why)")
    }

    /// And the reverse: a port this Mac's own service is on is not handed
    /// to a host either.
    func testAHostIsNotGivenAPortALocalServiceOwns() async {
        let forwards = PortForwardService()
        // Reach into the range the allocator uses, so the collision is
        // possible at all.
        guard case .ok(let local) = await forwards.expose(
            hostID: nil, remotePort: 39_000, agent: "claude", title: nil)
        else { return XCTFail("the local expose was refused") }

        let allocated = forwards.allocatePort(for: .host(UUID()))
        XCTAssertNotEqual(allocated, local.localPort,
                          "a host was handed the port a local service is on")
    }

    /// Withdrawing a local offer withdraws the offer, and there is nothing
    /// else to undo.
    func testWithdrawingALocalExposureRemovesIt() async {
        let forwards = PortForwardService()
        guard case .ok(let exposure) = await forwards.expose(
            hostID: nil, remotePort: 4321, agent: "claude", title: nil)
        else { return XCTFail() }

        await forwards.withdraw(exposure.id)

        XCTAssertTrue(forwards.exposures.isEmpty)
    }
}
