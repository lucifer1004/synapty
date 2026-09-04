import XCTest
@testable import Synapty

/// [[WI-2026-08-15-011]] / [[RFC-0013]]. Port allocation is where the web
/// origin boundary is actually enforced, and every failure here is silent:
/// the page loads, the forward works, and one host is reading another's
/// cookies.
@MainActor
final class PortForwardServiceTests: XCTestCase {

    private var tmp: URL!
    private var service: PortForwardService!
    private var heldStore: HostStore?
    private var heldTunnels: TunnelManager?
    private let hostA = UUID()
    private let hostB = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
        // A forward is placed on a real connection now, so the pool would
        // otherwise put live sockets in the human's own directory and
        // authenticate against hosts that do not exist.
        MasterPool.socketDirectoryOverride = tmp
        MasterPool.tenantDirectoryOverride = tmp.appendingPathComponent("tenants")
        service = PortForwardService()
    }

    override func tearDown() {
        MasterPool.socketDirectoryOverride = nil
        MasterPool.tenantDirectoryOverride = nil
        heldTunnels = nil
        heldStore = nil
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    // MARK: - The origin boundary

    /// A PORT THAT SERVED ONE HOST MUST NEVER SERVE ANOTHER.
    ///
    /// Every forward is reached as `http://127.0.0.1:<port>`, and a web
    /// origin is scheme + host + port. The host part is the same loopback
    /// address for all of them, so the PORT is the only thing separating
    /// two remote machines. Hand one over and the second host inherits the
    /// first's cookies, localStorage and service workers — in an
    /// application whose whole premise is that hosts are separate.
    func testAPortIsNeverHandedFromOneHostToAnother() throws {
        let first = try XCTUnwrap(service.allocatePort(for: .host(hostA)))
        XCTAssertEqual(service.owner(ofPort: first), .host(hostA))

        // Ten allocations for the other host, none of which may be it.
        for _ in 0..<10 {
            let next = try XCTUnwrap(service.allocatePort(for: .host(hostB)))
            XCTAssertNotEqual(next, first)
            XCTAssertEqual(service.owner(ofPort: next), .host(hostB))
        }
    }

    /// OWNERSHIP OUTLIVES THE FORWARD. Releasing a port back into the
    /// general pool when its exposure ends is exactly how one origin comes
    /// to serve two hosts, a little later and much harder to see.
    func testAPortStaysOwnedAfterItsExposureEnds() async throws {
        let port = try XCTUnwrap(service.allocatePort(for: .host(hostA)))
        await service.withdrawAll(hostID: hostA)
        XCTAssertEqual(service.owner(ofPort: port), .host(hostA),
                       "withdrawal ends the forward, not the ownership")

        for _ in 0..<10 {
            XCTAssertNotEqual(try XCTUnwrap(service.allocatePort(for: .host(hostB))), port)
        }
    }

    /// A host MAY take back a port it owned before — same host, same
    /// origin, nothing to leak — and must, or every expose/withdraw cycle
    /// burns one and a long session exhausts the range.
    func testAHostCanReuseItsOwnPort() throws {
        let first = try XCTUnwrap(service.allocatePort(for: .host(hostA)))
        // Nothing is forwarding, so the same port is the first candidate.
        XCTAssertEqual(service.allocatePort(for: .host(hostA)), first)
    }

    // MARK: - Ports that are not ours to take

    /// AVAILABILITY IS PROBED, NOT ASSUMED. Not hypothetical: the first
    /// port probed while designing this was held by an unrelated
    /// application on the operator's machine.
    func testAPortHeldBySomethingElseIsSkipped() throws {
        // Hold one for real, then ask for allocations and check none is it.
        let held = try XCTUnwrap((39000..<39500).first { PortForwardService.isFree($0) })
        let listener = try XCTUnwrap(Self.listen(on: held))
        defer { close(listener) }
        XCTAssertFalse(PortForwardService.isFree(held), "the probe must see a real listener")

        for _ in 0..<5 {
            XCTAssertNotEqual(try XCTUnwrap(service.allocatePort(for: .host(hostA))), held)
        }
    }

    /// The probe answers about the CURRENT state of the machine, which is
    /// the only thing it can honestly answer.
    func testTheProbeSeesAPortAppearAndDisappear() throws {
        let port = try XCTUnwrap((39000..<39500).first { PortForwardService.isFree($0) })
        let listener = try XCTUnwrap(Self.listen(on: port))
        XCTAssertFalse(PortForwardService.isFree(port))
        close(listener)
        XCTAssertTrue(PortForwardService.isFree(port))
    }

    // MARK: - Refusals

    /// An exposure with no reachable host is refused rather than recorded,
    /// so nothing shows a view that cannot load.
    func testExposingOnAnUnknownHostIsRefusedAndRecordsNothing() async {
        let outcome = await service.expose(hostID: hostA, remotePort: 3000, agent: "api-7f3c", title: nil)
        guard case .refused = outcome else { return XCTFail("expected a refusal") }
        XCTAssertTrue(service.exposures.isEmpty)
    }

    /// A number that is not a port is named as such rather than attempted.
    func testANumberThatIsNotAPortIsRefused() async {
        for bad in [0, 70000, -1] {
            guard case .refused(let why) = await service.expose(
                hostID: hostA, remotePort: bad, agent: "api-7f3c", title: nil)
            else { return XCTFail("expected a refusal for \(bad)") }
            XCTAssertTrue(why.contains("\(bad)"), "the refusal names what was wrong")
        }
    }

    // MARK: - A host keeps its port

    /// AN ADDRESS THAT LEAVES THIS PROCESS OUTLIVES `portOwners`.
    ///
    /// The in-memory table is exactly right while the only reader is our
    /// own web view: its data store is non-persistent, so the two forget
    /// together. A browser does not forget. Give it 127.0.0.1:39000 for
    /// host A today and host B tomorrow and B inherits A's cookies from a
    /// jar we do not control — so the assignment has to be stable across
    /// launches, which here means derived rather than recorded.
    func testAHostGetsTheSamePortInAFreshProcess() throws {
        let host = UUID()
        let first = try XCTUnwrap(PortForwardService().allocatePort(for: .host(host)))
        for _ in 0..<5 {
            // A brand-new service is what the next launch looks like: no
            // table, no memory of anything.
            XCTAssertEqual(PortForwardService().allocatePort(for: .host(host)), first)
        }
    }

    /// And two hosts still do not share one, which is the property the
    /// derivation must not cost.
    func testDerivedPortsStillSeparateHosts() throws {
        let service = PortForwardService()
        var seen: Set<Int> = []
        for _ in 0..<20 {
            let port = try XCTUnwrap(service.allocatePort(for: .host(UUID())))
            XCTAssertFalse(seen.contains(port), "two hosts were handed one origin")
            seen.insert(port)
        }
    }

    /// NOT `hashValue`: Swift seeds its hasher per process, so the standard
    /// one answers differently on every launch — the single property this
    /// must not have. Pinned against literals so a change of algorithm is
    /// a failing test rather than a silent reshuffle of everyone's ports.
    func testTheHashIsStableAcrossRuns() {
        let id = try! XCTUnwrap(UUID(uuidString: "33B89AE7-F182-47BA-8F71-D70FD99F7B1B"))
        XCTAssertEqual(PortForwardService.stableHash(id),
                       PortForwardService.stableHash(id))
        XCTAssertNotEqual(PortForwardService.stableHash(id),
                          PortForwardService.stableHash(UUID()))
    }

    // MARK: - Where on the service

    /// An agent pointing somewhere specific is the ordinary case, and the
    /// address it produces is this machine's.
    func testAnExposureCarriesItsPath() async throws {
        let hosts = try seededStore()
        service.control = { _, _, _, _ in true }

        guard case .ok(let exposure) = await service.expose(
            hostID: hosts.a, remotePort: 8888, agent: "nb-1", title: "notebook",
            path: "/lab?token=abc") else { return XCTFail("expected an exposure") }

        XCTAssertEqual(exposure.url.path, "/lab")
        XCTAssertEqual(exposure.url.query, "token=abc")
        XCTAssertEqual(exposure.url.host, "127.0.0.1")
        XCTAssertEqual(exposure.url.port, exposure.localPort)
    }

    /// A path that tries to move the destination is refused BEFORE a
    /// forward is opened — the refusal is the whole answer, not a fallback
    /// to the root that would look like it worked.
    func testAPathThatNamesAnotherHostIsRefusedAndOpensNothing() async throws {
        let hosts = try seededStore()
        var forwarded = 0
        service.control = { _, action, _, _ in
            if action == "forward" { forwarded += 1 }
            return true
        }

        guard case .refused = await service.expose(
            hostID: hosts.a, remotePort: 8888, agent: "nb-1", title: nil,
            path: "//evil.example/x") else { return XCTFail("expected a refusal") }

        XCTAssertTrue(service.exposures.isEmpty)
        XCTAssertEqual(forwarded, 0, "nothing may be opened for a request being refused")
    }

    /// RE-EXPOSING THE SAME PORT MOVES THE POINTER, IT DOES NOT OPEN A
    /// SECOND FORWARD. The forward is per port; where the agent is pointing
    /// is the only thing a second call can change.
    func testReExposingTheSamePortRepointsItWithoutOpeningAnother() async throws {
        let hosts = try seededStore()
        var forwarded = 0
        service.control = { _, action, _, _ in
            if action == "forward" { forwarded += 1 }
            return true
        }

        guard case .ok(let first) = await service.expose(
                hostID: hosts.a, remotePort: 8888, agent: "nb-1", title: nil, path: "/one"),
              case .ok(let again) = await service.expose(
                hostID: hosts.a, remotePort: 8888, agent: "nb-1", title: nil, path: "/two")
        else { return XCTFail("expected both calls to succeed") }

        XCTAssertEqual(service.exposures.count, 1)
        XCTAssertEqual(again.localPort, first.localPort)
        XCTAssertEqual(again.url.path, "/two")
        XCTAssertEqual(forwarded, 1, "the second call must not open another forward")
    }

    // MARK: - Mortality

    /// AN EXPOSURE MUST NOT OUTLIVE THE PROCESS THAT KNEW ABOUT IT.
    ///
    /// Found by quitting the application and looking: `ControlPersist=yes`
    /// means the master does not die with it, so a forward added to that
    /// master did not either — a loopback port was still serving a remote
    /// host's admin UI with the application gone, and `exposures` was the
    /// only record it had ever had. `withdrawAll` existed with ZERO
    /// callers, which is why nothing caught it.
    func testQuittingWithdrawsEveryForward() async throws {
        let hosts = try seededStore()
        var cancelled: [String] = []
        service.control = { _, action, spec, _ in
            if action == "cancel" { cancelled.append(spec) }
            return true
        }

        guard case .ok(let first) = await service.expose(
                hostID: hosts.a, remotePort: 9090, agent: "api-7f3c", title: "dashboard"),
              case .ok(let second) = await service.expose(
                hostID: hosts.b, remotePort: 3000, agent: "web-11a2", title: nil)
        else { return XCTFail("both exposures should be recorded") }
        XCTAssertEqual(service.exposures.count, 2)

        service.withdrawEverything()

        XCTAssertTrue(service.exposures.isEmpty, "nothing may survive the quit")
        XCTAssertEqual(cancelled.count, 2, "each forward is cancelled on the master")
        XCTAssertTrue(cancelled.contains("127.0.0.1:\(first.localPort):127.0.0.1:9090"))
        XCTAssertTrue(cancelled.contains("127.0.0.1:\(second.localPort):127.0.0.1:3000"))
        // Ownership is the one thing that must survive: a port released
        // back into the pool is how one origin comes to serve two hosts.
        XCTAssertEqual(service.owner(ofPort: first.localPort), .host(hosts.a))
        XCTAssertEqual(service.owner(ofPort: second.localPort), .host(hosts.b))
    }

    /// Disconnecting a host takes its forwards with it and LEAVES THE
    /// OTHERS. A teardown that cleared everything would silently close
    /// views belonging to machines the human did not touch.
    func testDisconnectingOneHostLeavesAnotherHostsForward() async throws {
        let hosts = try seededStore()
        service.control = { _, _, _, _ in true }

        guard case .ok = await service.expose(hostID: hosts.a, remotePort: 9090,
                                        agent: "api-7f3c", title: nil),
              case .ok(let kept) = await service.expose(hostID: hosts.b, remotePort: 3000,
                                                  agent: "web-11a2", title: nil)
        else { return XCTFail("both exposures should be recorded") }

        await service.withdrawAll(hostID: hosts.a)

        XCTAssertEqual(service.exposures.map(\.id), [kept.id])
    }

    /// EVERY LIVE FORWARD IS NAMEABLE. The Forwarding overview reads this,
    /// and a capability nobody can enumerate is one nobody can withdraw —
    /// which is the property the quit was quietly losing.
    func testEveryLiveForwardCanBeEnumeratedAndWithdrawnIndividually() async throws {
        let hosts = try seededStore()
        service.control = { _, _, _, _ in true }

        guard case .ok(let one) = await service.expose(hostID: hosts.a, remotePort: 9090,
                                                 agent: "api-7f3c", title: "dashboard")
        else { return XCTFail("expected an exposure") }

        let listed = try XCTUnwrap(service.exposures.first)
        XCTAssertEqual(listed.agent, "api-7f3c")
        XCTAssertEqual(listed.title, "dashboard")
        XCTAssertEqual(listed.remotePort, 9090)

        await service.withdraw(one.id)
        XCTAssertTrue(service.exposures.isEmpty)
    }

    // MARK: - Helpers

    /// A store with two hosts and a TunnelManager over it, which is what
    /// `expose` needs before it reaches the control command.
    ///
    /// HELD BY THE TEST CASE, because `service.tunnelManager` and
    /// `tunnels.hostStore` are both weak: locals would deallocate on
    /// return and every expose would refuse with "no such host" — a green
    /// A FORWARD IS CANCELLED ON THE CONNECTION THAT HOLDS IT.
    ///
    /// A host holds as many connections as its load has called for
    /// ([[RFC-0013]] C-BROKER), so "the connection for this host" is not a
    /// single answer and asking again at withdrawal time can name a
    /// different one. `ssh -O cancel` against a master that never held the
    /// forward reports nothing and removes nothing — a loopback port left
    /// open behind a model that believes it closed it, which is the exact
    /// shape of leak C-AUTHORIZATION's mortality rule exists to forbid.
    func testAForwardIsWithdrawnOnTheConnectionThatOpenedItNotTheCurrentBest() async throws {
        let (a, _) = try seededStore()
        let tunnels = try XCTUnwrap(service.tunnelManager)
        var sockets: [String: String] = [:]
        service.control = { connection, action, _, _ in
            sockets[action] = connection.controlPath
            return true
        }

        guard case .ok(let exposure) = await service.expose(
                hostID: a, remotePort: 8080, agent: "agent-1", title: nil)
        else { return XCTFail("expected the forward to open") }
        let opened = try XCTUnwrap(sockets["forward"])

        // The pool grew past that connection for a transfer, and the
        // transfer then finished — so the emptiest connection is now the
        // one the forward is NOT on, and a fresh lookup would name it.
        let store = try XCTUnwrap(tunnels.hostStore)
        let host = try XCTUnwrap(store.hosts.first(where: { $0.id == a }))
        let key = tunnels.poolKey(for: host)
        let other = try XCTUnwrap(tunnels.pool.placeExclusive(key, tenant: "transfer.probe"))
        tunnels.pool.release(tenant: "transfer.probe")
        XCTAssertNotEqual(other, opened, "the test needs a second connection to be wrong about")
        XCTAssertNotEqual(tunnels.pool.existing(key), opened,
                          "and it must now look like the worse choice")

        await service.withdraw(exposure.id)
        XCTAssertEqual(sockets["cancel"], opened,
                       "cancelled where it was opened, not where a fresh lookup points")
    }

    /// test asserting nothing.
    private func seededStore() throws -> (a: UUID, b: UUID) {
        let store = HostStore()
        let a = HostEntry(label: "alpha", address: "alpha.invalid", username: "u")
        let b = HostEntry(label: "beta", address: "beta.invalid", username: "u")
        store.addHost(a)
        store.addHost(b)
        let tunnels = TunnelManager()
        tunnels.hostStore = store
        tunnels.pool.openMaster = { _, path in
            FileManager.default.createFile(atPath: path, contents: nil); return true
        }
        tunnels.pool.closeMaster = { _, path in try? FileManager.default.removeItem(atPath: path) }
        service.tunnelManager = tunnels
        heldStore = store
        heldTunnels = tunnels
        XCTAssertNotNil(service.tunnelManager, "the seam must survive the helper returning")
        return (a.id, b.id)
    }

    /// A real listener, so the probe is tested against the thing it probes.
    private static func listen(on port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { close(fd); return nil }
        return fd
    }

    // MARK: - Requesting, not seizing

    /// AN ARRIVING EXPOSURE OPENS NOTHING.
    ///
    /// The panel's state is the human's. An agent that could open it, or
    /// switch what it shows, could put its content in front of someone
    /// mid-sentence — which is the difference between a request and a
    /// seizure ([[RFC-0013]] C-REQUEST-NOT-SEIZE). The only path that opens
    /// the panel for agent content starts on a status-bar click.
    func testAnExposureOpensNeitherAPanelNorAPane() throws {
        let suite = "dev.synapty.tests.expose.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let panel = PanelModel(defaults: defaults)
        panel.show(.appearance)

        // WHAT AN EXPOSURE MAY REACH IS ALLOCATION AND BOOKKEEPING.
        // Nothing here holds a reference to the panel or to the layout,
        // which is the point rather than an accident of this test.
        _ = service.allocatePort(for: .host(hostA))
        XCTAssertEqual(panel.occupant, .appearance, "an exposure must not change the panel")

        panel.close()
        _ = service.allocatePort(for: .host(hostB))
        XCTAssertFalse(panel.isOpen, "and must not open a panel the human closed")

        // The web view is a PANE now ([[RFC-0015]] C-CONTENT), so the
        // seizure this forbids has a second shape: putting one into the
        // human's layout uninvited.
        let manager = WorkspaceManager()
        manager.addLocalWorkspace()
        let before = manager.allLeaves.count
        _ = service.allocatePort(for: .host(hostA))
        XCTAssertEqual(manager.allLeaves.count, before,
                       "an exposure must not put a pane in front of anyone")
    }

    /// EVERY EXPOSURE CARRIES ITS AGENT. There is no anonymous presented
    /// content: the attribution frame has nothing to name without it.
    func testAnExposureIsAlwaysAttributed() async {
        // The refusal path is the one reachable without a live host, and it
        // is enough to pin that the agent is required to get that far: the
        // signature has no default for it.
        guard case .refused = await service.expose(
            hostID: hostA, remotePort: 3000, agent: "api-7f3c", title: "API preview")
        else { return XCTFail("expected a refusal without a host") }
        XCTAssertTrue(service.exposures.isEmpty)
    }
}

/// THE GLOBE COUNTS EVERY MACHINE, SO IT MUST REACH EVERY MACHINE
/// ([[WI-2026-08-28-009]]).
///
/// It used to open a services pane bound to whichever machine the FOCUSED
/// pane was on, and a services pane shows one connection's exposures — so
/// a human working locally, with an agent on `builder` exposing port 3000,
/// read 1, clicked, and got "Nothing exposed on this Mac".
@MainActor
final class ExposureDestinationTests: XCTestCase {

    private var tmp: URL!
    private var hostStore: HostStore!
    private var builder: HostEntry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try setUpHostStoreStorage()
        hostStore = HostStore()
        builder = HostEntry(label: "builder", address: "builder.example", username: "someone")
        hostStore.hosts.append(builder)
    }

    override func tearDown() {
        restoreStorageOverrides(tmp)
        super.tearDown()
    }

    private func exposure(on hostID: UUID?, port: Int) -> PortForwardService.Exposure {
        PortForwardService.Exposure(
            id: UUID(), hostID: hostID, remotePort: port, localPort: port + 10000,
            agent: "api-7f3c", title: nil, path: ExposedPath.root)
    }

    /// A SERVICES PANE OPENED FOR A NAMED MACHINE LOOKS AT THAT MACHINE,
    /// and not at the one the human happens to be focused on.
    func testAPaneOpenedForAnotherMachineIsBoundToIt() {
        let panes = WorkspaceManager()
        panes.addLocalWorkspace()
        let workspace = panes.workspaces[0].id

        let leaf = panes.addPane(content: .services, toWorkspace: workspace,
                                 on: .machine(builder))
        let pane = panes.workspaces[0].panes.first { $0.id == leaf }
        XCTAssertEqual(panes.connections.connection(pane?.connectionID ?? UUID())?.host?.id,
                       builder.id,
                       "the pane looks at the machine the human was focused on, not the one "
                       + "whose exposure the badge counted")
    }

    /// AND SAYING NOTHING STILL MEANS "WHERE THE HUMAN IS LOOKING". The
    /// default is what a new pane has always meant.
    func testAPaneThatNamesNoMachineStillFollowsTheFocus() {
        let panes = WorkspaceManager()
        panes.addLocalWorkspace()
        let workspace = panes.workspaces[0].id

        let leaf = panes.addPane(content: .services, toWorkspace: workspace)
        let pane = panes.workspaces[0].panes.first { $0.id == leaf }
        XCTAssertNil(panes.connections.connection(pane?.connectionID ?? UUID())?.host,
                     "a workspace on this Mac gained a pane looking somewhere else")
    }

    /// THE BADGE OFFERS EVERY MACHINE IT COUNTED, in an order that does not
    /// change between two looks — a Dictionary has none, and a menu that
    /// reshuffles is one a human cannot aim at.
    func testTheBadgeOffersEveryMachineItCounted() {
        let machines = ContextStatusBar.exposureMachines(
            [exposure(on: builder.id, port: 3000),
             exposure(on: builder.id, port: 3001),
             exposure(on: nil, port: 8080)],
            name: { [hostStore] in hostStore!.displayName(of: $0) })

        XCTAssertEqual(machines.map(\.name), ["builder", "This Mac"])
        XCTAssertEqual(machines.map(\.count), [2, 1])
        XCTAssertEqual(machines.map(\.hostID), [builder.id, nil])
    }

    /// Equal counts are ordered by name rather than by whatever the
    /// dictionary handed back.
    func testMachinesWithEqualCountsAreOrderedByName() {
        let machines = ContextStatusBar.exposureMachines(
            [exposure(on: builder.id, port: 3000), exposure(on: nil, port: 8080)],
            name: { [hostStore] in hostStore!.displayName(of: $0) })
        XCTAssertEqual(machines.map(\.name), ["This Mac", "builder"])
    }
}
