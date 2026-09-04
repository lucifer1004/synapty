import XCTest
@testable import Synapty

/// [[WI-2026-08-15-011]]. Two tools print listening sockets in two shapes,
/// and this project reaches both kinds of host. A parser that handles one
/// silently reports "nothing is listening" on the other, which reads as a
/// quiet host rather than as a parser that gave up.
final class PortDiscoveryTests: XCTestCase {

    /// Linux's `ss -tlnH`: no header, local address in the fourth field.
    func testLinuxSsOutputIsParsed() {
        let out = """
        LISTEN 0      4096   127.0.0.1:8931       0.0.0.0:*
        LISTEN 0      128      0.0.0.0:22          0.0.0.0:*
        LISTEN 0      511    127.0.0.1:3000       0.0.0.0:*
        """
        XCTAssertEqual(PortDiscovery.parse(out), [22, 3000, 8931])
    }

    /// BSD netstat, which is what a macOS host answers with. It separates
    /// the port with a DOT rather than a colon — a parser that split on ":"
    /// alone would find nothing here and say the host was quiet.
    func testBsdNetstatOutputIsParsed() {
        let out = """
        tcp4       0      0  127.0.0.1.8931         *.*                    LISTEN
        tcp4       0      0  *.22                   *.*                    LISTEN
        tcp46      0      0  *.3000                 *.*                    LISTEN
        """
        XCTAssertEqual(PortDiscovery.parse(out), [22, 3000, 8931])
    }

    /// IPv6 IS FULL OF COLONS, and the two tools disagree about what
    /// separates the port from it.
    ///
    /// The BSD form was MISSED by the first parser and found by running the
    /// command on a real macOS host: `::1.18789` has colons, so a rule of
    /// "split on a colon if the field has one" reads it as `1.18789` and
    /// drops the listener silently. Nothing offline had that shape.
    func testBothIPv6FormsAreParsed() {
        XCTAssertEqual(PortDiscovery.parse("LISTEN 0 4096 [::1]:8931 [::]:*"), [8931])
        XCTAssertEqual(PortDiscovery.port(from: "::1.18789"), 18789)
        XCTAssertEqual(
            PortDiscovery.parse("tcp6       0      0  ::1.18789              *.*        LISTEN"),
            [18789])
    }

    /// The four shapes, side by side, so a future change has to keep all of
    /// them rather than the three that are easy.
    func testEveryAddressShapeYieldsItsPort() {
        XCTAssertEqual(PortDiscovery.port(from: "127.0.0.1:8931"), 8931)   // ss IPv4
        XCTAssertEqual(PortDiscovery.port(from: "[::1]:8931"), 8931)       // ss IPv6
        XCTAssertEqual(PortDiscovery.port(from: "127.0.0.1.8931"), 8931)   // netstat IPv4
        XCTAssertEqual(PortDiscovery.port(from: "::1.18789"), 18789)       // netstat IPv6
    }

    func testAWildcardAddressStillYieldsItsPort() {
        XCTAssertEqual(PortDiscovery.port(from: "*:8080"), 8080)
        XCTAssertEqual(PortDiscovery.port(from: "0.0.0.0:8080"), 8080)
    }

    /// A peer column of `*.*` or `0.0.0.0:*` carries no port and must not
    /// invent one.
    func testAPeerColumnContributesNothing() {
        XCTAssertNil(PortDiscovery.port(from: "*.*"))
        XCTAssertNil(PortDiscovery.port(from: "0.0.0.0:*"))
        XCTAssertNil(PortDiscovery.port(from: "[::]:*"))
    }

    /// Nonsense in, nothing out — never a crash and never a fabricated
    /// port, because this text comes from another machine.
    func testGarbageYieldsNothing() {
        XCTAssertEqual(PortDiscovery.parse("bash: ss: command not found"), [])
        XCTAssertEqual(PortDiscovery.parse(""), [])
        XCTAssertNil(PortDiscovery.port(from: "127.0.0.1:99999"), "not a port number")
        XCTAssertNil(PortDiscovery.port(from: "127.0.0.1:0"))
    }

    // MARK: - What is worth offering

    /// PRIVILEGED PORTS ARE INFRASTRUCTURE, NOT SOMETHING TO LOOK AT. sshd
    /// above all: it is how we got here, and offering to view it would be
    /// offering to point a web view at the connection carrying the request.
    func testPrivilegedPortsAreNotOffered() {
        let offered = PortDiscovery.offerable([22, 80, 443, 1023, 1024, 3000], alreadyExposed: [])
        XCTAssertEqual(offered, [1024, 3000])
    }

    /// A port an agent already exposed is not offered again: the same
    /// service under two labels, one named by its agent and one a bare
    /// number, reads as two things.
    func testAnAlreadyExposedPortIsNotOfferedTwice() {
        XCTAssertEqual(
            PortDiscovery.offerable([3000, 8931], alreadyExposed: [8931]),
            [3000])
    }

    /// The command has to work on both kinds of host, so it asks whether
    /// the Linux tool exists rather than assuming either.
    func testTheCommandDoesNotAssumeWhichToolExists() {
        XCTAssertTrue(PortDiscovery.command.contains("command -v ss"))
        XCTAssertTrue(PortDiscovery.command.contains("netstat"))
    }
}
