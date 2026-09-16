import XCTest
@testable import Synapty

/// [[WI-2026-08-15-011]], [[WI-2026-09-07-001]]. Two tools print listening
/// sockets in two shapes, and this project reaches both kinds of host. A
/// parser that handles one silently reports "nothing is listening" on the
/// other, which reads as a quiet host rather than as a parser that gave up.
///
/// THE CAPTURES BELOW ARE REAL and are marked where they are, because the
/// invented ones have twice missed a form a real machine prints — the BSD
/// IPv6 address first, and then `netstat -v`'s process column, which every
/// offline example lacked and which parses as a port if nothing stops it.
final class PortDiscoveryTests: XCTestCase {

    private func ports(_ output: String) -> [Int] {
        PortDiscovery.parse(output).map(\.port)
    }

    private func listener(_ output: String, port: Int) -> PortDiscovery.Listener? {
        PortDiscovery.parse(output).first { $0.port == port }
    }

    /// Linux's `ss -tlnH`: no header, local address in the fourth field.
    func testLinuxSsOutputIsParsed() {
        let out = """
        LISTEN 0      4096   127.0.0.1:8931       0.0.0.0:*
        LISTEN 0      128      0.0.0.0:22          0.0.0.0:*
        LISTEN 0      511    127.0.0.1:3000       0.0.0.0:*
        """
        XCTAssertEqual(ports(out), [22, 3000, 8931])
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
        XCTAssertEqual(ports(out), [22, 3000, 8931])
    }

    /// IPv6 IS FULL OF COLONS, and the two tools disagree about what
    /// separates the port from it.
    ///
    /// The BSD form was MISSED by the first parser and found by running the
    /// command on a real macOS host: `::1.18789` has colons, so a rule of
    /// "split on a colon if the field has one" reads it as `1.18789` and
    /// drops the listener silently. Nothing offline had that shape.
    func testBothIPv6FormsAreParsed() {
        XCTAssertEqual(ports("LISTEN 0 4096 [::1]:8931 [::]:*"), [8931])
        XCTAssertEqual(PortDiscovery.port(from: "::1.18789"), 18789)
        XCTAssertEqual(
            ports("tcp6       0      0  ::1.18789              *.*        LISTEN"),
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

    /// A ZONE ID IS PART OF THE ADDRESS, and it is an arbitrary word rather
    /// than anything address-shaped. Real, from greencloud: this is what
    /// systemd-resolved's stub listener looks like, and the rule that keeps
    /// process names from being read as ports must not take it out.
    func testAZoneSuffixedAddressStillYieldsItsPort() {
        XCTAssertEqual(PortDiscovery.port(from: "127.0.0.53%lo:53"), 53)
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
        XCTAssertEqual(ports("bash: ss: command not found"), [])
        XCTAssertEqual(ports(""), [])
        XCTAssertNil(PortDiscovery.port(from: "127.0.0.1:99999"), "not a port number")
        XCTAssertNil(PortDiscovery.port(from: "127.0.0.1:0"))
    }

    // MARK: - Who holds the port

    /// A REAL CAPTURE, `ss -tlnpH` on greencloud. Three things at once: a
    /// listener nobody named (port 53, another user's), two named ones, and
    /// a name the kernel cut at fifteen characters.
    func testALinuxHostNamesTheProcessHoldingEachPort() {
        let out = """
        LISTEN 0      4096                    127.0.0.54:53    0.0.0.0:*
        LISTEN 0      511                      127.0.0.1:24515 0.0.0.0:* users:(("openclaw-gatewa",pid=839,fd=21))
        LISTEN 0      128                      127.0.0.1:9000  0.0.0.0:* users:(("synapty",pid=1453940,fd=3))
        LISTEN 0      4096                       0.0.0.0:22    0.0.0.0:*
        \(PortDiscovery.marker)
            839 openclaw-gateway
        1453940 /home/operator/.synapty/bin/synapty hub --state-path default --peer-id gc
        """
        XCTAssertEqual(ports(out), [22, 53, 9000, 24515])

        let hub = listener(out, port: 9000)
        XCTAssertEqual(hub?.program, "synapty")
        XCTAssertEqual(hub?.pid, 1453940)
        XCTAssertEqual(hub?.command,
                       "/home/operator/.synapty/bin/synapty hub --state-path default --peer-id gc")

        // A port whose owner the host would not name is still offered, with
        // the number alone rather than a guess.
        XCTAssertNil(listener(out, port: 53)?.program)
        XCTAssertNil(listener(out, port: 53)?.pid)
    }

    /// A REAL CAPTURE, `netstat -anv -p tcp` on the operator's Mac.
    ///
    /// THE COLUMN THIS ADDS IS THE HAZARD IT ADDS. `Termius:16527` and
    /// `com.metacubex.Cl:33407` both end in a plausible port number after a
    /// separator, and the second contains dots as well — so every one of
    /// these lines would have yielded a second, fictional listener on the
    /// pid.
    func testAMacHostNamesTheProcessAndItsPidIsNotAPort() {
        let out = """
        tcp4       0      0  127.0.0.1.60941        *.*                    LISTEN                 0            0  131072  131072          Termius:16527  00100 00000106 000000000996dab0 00000001 00000800      1      0 000000
        tcp46      0      0  *.7890                 *.*                    LISTEN                 0            0  131072  131072 com.metacubex.Cl:33407  00180 00000006 0000000000021061 00000000 00000800      1      0 000000
        tcp4       0      0  *.22                   *.*                    LISTEN                 0            0  131072  131072          launchd:1      00180 00000006 0000000000000cda 00000000 00000800      1      0 000000
        """
        XCTAssertEqual(ports(out), [22, 7890, 60941],
                       "16527 and 33407 are pids, and neither is listening")

        // AND THE GUARD IS ASKED DIRECTLY, because the rows above do not
        // ask it. `port(in:)` returns on the FIRST field that parses, and
        // in every real capture the address column precedes the
        // `process:pid` one — so the assertion above was green with the
        // guard deleted, and pinned nothing about it ([[WI-2026-09-07-010]]).
        XCTAssertNil(PortDiscovery.port(from: "Termius:16527"))
        XCTAssertNil(PortDiscovery.port(from: "com.metacubex.Cl:33407"),
                     "a dotted program name is still not an address")
        XCTAssertNil(PortDiscovery.port(from: "launchd:1"))
        XCTAssertNil(PortDiscovery.port(from: "io.tailscale.ipn:26435"))
        XCTAssertEqual(listener(out, port: 60941)?.program, "Termius")
        XCTAssertEqual(listener(out, port: 60941)?.pid, 16527)
        XCTAssertEqual(listener(out, port: 22)?.program, "launchd")
    }

    /// BOTH TOOLS CUT THE NAME OFF, and a name cut mid-word reads as our
    /// defect rather than as the kernel's limit. Real: greencloud's comm is
    /// fifteen characters, and the executable on the same machine is not.
    ///
    /// ASKED OF THE EXECUTABLE, NOT GUESSED FROM THE ARGUMENTS. This used
    /// to search the command line for a token beginning with the truncated
    /// name, and both of the examples that justified it failed when they
    /// were finally run: the search found `openclaw-gateway-production.yml`
    /// and `com.metacubex.ClashX.config.yaml`, which are configuration
    /// files ([[WI-2026-09-08-016]]).
    func testATruncatedNameIsTakenFromTheExecutable() {
        let out = """
        LISTEN 0 511 127.0.0.1:24515 0.0.0.0:* users:(("openclaw-gatewa",pid=839,fd=21))
        \(PortDiscovery.marker)
            839 openclaw-gateway --config /etc/openclaw-gateway-production.yml
        \(PortDiscovery.pathMarker)
            839 /usr/local/bin/openclaw-gateway
        """
        XCTAssertEqual(listener(out, port: 24515)?.program, "openclaw-gateway")
    }

    /// A PROGRAM WHOSE NAME CONTAINS A SPACE SURVIVED AS A FRAGMENT.
    /// macOS separates the `process:pid` column from its neighbours with
    /// whitespace and lets the name contain it, so `Cursor Helper
    /// (P:38945` splits into three fields and the program read as `(P`.
    /// Compiled against this Mac's real listeners it produced `(` and
    /// `(P` for two of them ([[WI-2026-09-08-016]]).
    ///
    /// THE PID SURVIVES, being the digits after the last colon, so that is
    /// what the question is asked with.
    func testAProgramWhoseNameHasASpaceIsNamedWhole() {
        let out = """
        tcp4 0 0 127.0.0.1.46828 *.* LISTEN 0 0 131072 131072 Discord Helper (:46828 00100
        \(PortDiscovery.marker)
          46828 /Applications/Discord.app/Contents/MacOS/Discord Helper (Renderer) --type=renderer
        \(PortDiscovery.pathMarker)
          46828 /Applications/Discord.app/Contents/MacOS/Discord Helper (Renderer)
        """
        XCTAssertEqual(listener(out, port: 46828)?.program, "Discord Helper (Renderer)")
        XCTAssertEqual(listener(out, port: 46828)?.pid, 46828)
    }

    /// AND A HOST THAT NAMES NO EXECUTABLE FALLS BACK TO WHAT THE LISTENER
    /// COLUMN SAID, rather than to nothing. A truncated name is worse than
    /// a whole one and better than a bare number.
    func testWithoutAnExecutableTheColumnsNameIsStillUsed() {
        let out = """
        LISTEN 0 511 127.0.0.1:24515 0.0.0.0:* users:(("openclaw-gatewa",pid=839,fd=21))
        \(PortDiscovery.marker)
            839 openclaw-gateway --port 24515
        """
        XCTAssertEqual(listener(out, port: 24515)?.program, "openclaw-gatewa")
    }

    /// THE LENGTH GUARD IS WHAT MAKES COMPLETION SAFE. A name the host did
    /// not truncate must never be grown into something that merely starts
    /// with it — the row would then name a directory rather than a program.
    func testAShortNameIsNeverGrownIntoSomethingElse() {
        let out = """
        LISTEN 0 511 127.0.0.1:3000 0.0.0.0:* users:(("node",pid=77,fd=21))
        \(PortDiscovery.marker)
           77 /usr/bin/node /srv/app/node_modules/.bin/serve
        """
        XCTAssertEqual(listener(out, port: 3000)?.program, "node")
    }

    /// A COMMAND LINE CAN LOOK EXACTLY LIKE A LISTENER, which is why the
    /// two tables are separated by a marker rather than told apart by
    /// shape. Without it this output claims something answers on 8080.
    func testAProcessTableNeverContributesAPort() {
        let out = """
        LISTEN 0 511 127.0.0.1:3000 0.0.0.0:*
        \(PortDiscovery.marker)
          412 curl http://127.0.0.1:8080/health
        """
        XCTAssertEqual(ports(out), [3000])
    }

    /// A host that answers with a tool carrying no process column is not a
    /// failure: the ports are still the answer, and the parser says nothing
    /// it was not told.
    func testAHostThatNamesNothingStillYieldsItsPorts() {
        let out = """
        tcp4       0      0  127.0.0.1.8931         *.*                    LISTEN
        \(PortDiscovery.marker)
        """
        XCTAssertEqual(ports(out), [8931])
        XCTAssertNil(listener(out, port: 8931)?.program)
    }

    /// ONE ROW PER PORT, and it is the row that knows something. A listener
    /// appears once per address family and only one of the two carries the
    /// process on macOS.
    func testTheNamedRowWinsWhenAPortAppearsTwice() {
        let out = """
        tcp6       0      0  *.7890                 *.*                    LISTEN  0 0 131072 131072 *.* 00180
        tcp46      0      0  *.7890                 *.*                    LISTEN  0 0 131072 131072 com.metacubex.Cl:33407  00180
        """
        XCTAssertEqual(ports(out), [7890])
        XCTAssertEqual(listener(out, port: 7890)?.pid, 33407)
    }

    func testTheTitleLeadsWithTheProgramAndFallsBackToThePort() {
        XCTAssertEqual(PortDiscovery.Listener(port: 3000).title, "port 3000")
        XCTAssertEqual(
            PortDiscovery.Listener(port: 3000, pid: 7, program: "vite").title,
            "vite · port 3000")
    }

    // MARK: - What the row says

    /// THE ROW'S LINES ARE THE LISTENER'S TO DECIDE, and they are tested
    /// here rather than in the view because the view needs a forwarding
    /// service and a tunnel manager before it will render at all — which is
    /// exactly why the first version of this printed the port twice with
    /// nothing to catch it.
    func testANamedListenerLeadsWithItsProgramAndCarriesThePortBeneath() {
        let listener = PortDiscovery.Listener(
            port: 24515, pid: 839, program: "openclaw-gateway",
            command: "openclaw-gateway --port 24515")
        XCTAssertEqual(listener.name, "openclaw-gateway")
        XCTAssertEqual(listener.detail, "port 24515 · pid 839")
        XCTAssertEqual(listener.arguments, "openclaw-gateway --port 24515")
    }

    /// A listener the host would not name is a port and nothing else, and
    /// SAYS SO ONCE. `port 3000` above `port 3000` is the number twice and
    /// the answer never.
    func testAnUnnamedListenerSaysThePortOnceAndNoMore() {
        let listener = PortDiscovery.Listener(port: 3000)
        XCTAssertEqual(listener.name, "port 3000")
        XCTAssertNil(listener.detail)
        XCTAssertNil(listener.arguments)
    }

    /// A command line that is only the program's own name repeats the line
    /// above it, so it does not get one.
    func testACommandLineThatOnlyRepeatsTheNameIsNotShown() {
        XCTAssertNil(
            PortDiscovery.Listener(port: 3000, pid: 9, program: "sshd", command: "sshd")
                .arguments)
    }

    /// A pid the host declined to give is simply absent from the line
    /// rather than rendered as a blank or a zero.
    func testAProgramWithoutAPidStillSaysWhichPort() {
        XCTAssertEqual(
            PortDiscovery.Listener(port: 3000, program: "vite").detail, "port 3000")
    }

    /// A PORT AND A PID ARE IDENTIFIERS, NOT QUANTITIES: "9,090" connects
    /// to nothing.
    ///
    /// THIS CANNOT FAIL AND IS KEPT ANYWAY, WHICH NEEDS SAYING. These are
    /// plain `String` values, and `String` interpolation never
    /// group-separates — the hazard is `Text`'s LocalizedStringKey
    /// initialiser, which is reached only when a literal with
    /// interpolation is passed to `Text` directly. `ServicesView.row(_:)`
    /// passes these Strings, so the hazard is not on this path at all and
    /// the `String(pid)` inside `detail` is belt on top of braces.
    ///
    /// It stays as a statement of the intended SHAPE of these lines — a
    /// future edit that inlines them into `Text("port \(port)")` is what
    /// this is a tripwire for, and that edit would change these strings.
    /// It is not a test of the formatter, and the file must not pretend it
    /// is ([[WI-2026-09-07-010]]).
    func testThePortAndPidLinesHaveTheShapeTheyAreMeantTo() {
        let listener = PortDiscovery.Listener(port: 9090, pid: 16527, program: "Termius")
        XCTAssertEqual(listener.detail, "port 9090 · pid 16527")
        XCTAssertEqual(listener.title, "Termius · port 9090")
        XCTAssertEqual(PortDiscovery.Listener(port: 9090).name, "port 9090")
    }

    // MARK: - What is worth offering

    /// PRIVILEGED PORTS ARE INFRASTRUCTURE, NOT SOMETHING TO LOOK AT. sshd
    /// above all: it is how we got here, and offering to view it would be
    /// offering to point a web view at the connection carrying the request.
    func testPrivilegedPortsAreNotOffered() {
        let offered = PortDiscovery.offerable(
            [22, 80, 443, 1023, 1024, 3000].map { PortDiscovery.Listener(port: $0) },
            alreadyExposed: [])
        XCTAssertEqual(offered.map(\.port), [1024, 3000])
    }

    /// A port an agent already exposed is not offered again: the same
    /// service under two labels, one named by its agent and one a bare
    /// number, reads as two things.
    func testAnAlreadyExposedPortIsNotOfferedTwice() {
        XCTAssertEqual(
            PortDiscovery.offerable(
                [3000, 8931].map { PortDiscovery.Listener(port: $0) },
                alreadyExposed: [8931]
            ).map(\.port),
            [3000])
    }

    /// The command has to work on both kinds of host, so it asks whether
    /// the Linux tool exists rather than assuming either — and it asks each
    /// tool for the process, which is the whole point of the round trip.
    func testTheCommandAsksBothToolsForTheProcess() {
        XCTAssertTrue(PortDiscovery.command.contains("command -v ss"))
        XCTAssertTrue(PortDiscovery.command.contains("ss -tlnpH"))
        XCTAssertTrue(PortDiscovery.command.contains("netstat -anv"))
        XCTAssertTrue(PortDiscovery.command.contains("ps -eo pid=,args="))
        XCTAssertTrue(PortDiscovery.command.contains(PortDiscovery.marker))
    }
}
