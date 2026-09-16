import XCTest
@testable import Synapty

/// WHERE THE TWO SIDES PUT A FILE, ASKED OF BOTH AT ONCE.
///
/// The config layout is stated twice and nothing made the two answer
/// together: `src/paths.zig` classifies each entry `shared` or `machine`
/// and migrates a flat-layout file into that half on every CLI
/// invocation, and `ConfigPaths` classifies the same entries for the app
/// that reads them. Each side had a thorough guard and each guard only
/// ever asked about its own tree, so `ghostty.conf` was `shared` in Zig
/// and `machine` in Swift — both green — and the migration filed it where
/// the workbench never looks ([[WI-2026-09-09-013]]).
///
/// THE ONLY HONEST QUESTION IS THE ONE THAT RUNS BOTH. This drives the
/// real binary's migration against a real config root and asks Swift
/// where it would then look. It is not a comparison of two sources; it is
/// the behaviour.
@MainActor
final class ConfigPathsCrossingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-crossing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ConfigPaths.rootOverride = root
    }

    override func tearDown() {
        ConfigPaths.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// The CLI, when this is a checkout that has built one.
    ///
    /// FOUND FROM THIS FILE, not from the working directory: a test
    /// runner's cwd is its own and skipping on that is a test that never
    /// runs while reporting that it did.
    private func binary() throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let dev = repo.appendingPathComponent("zig-out/bin/synapty").path
        guard FileManager.default.fileExists(atPath: dev) else {
            throw XCTSkip("no zig-out/bin/synapty — run `zig build`")
        }
        return dev
    }

    // AND IT IS WHATEVER WAS BUILT LAST. `just verify` builds the binary
    // before it runs this suite, so the gate compares the two current
    // answers; running the Swift suite alone after editing `paths.zig`
    // compares the new Swift one against a stale CLI. That is a property
    // of asking a second process rather than a flaw to guard against —
    // the alternative is not asking it, which is how the two drifted.

    /// ONE VARIABLE, ONE DESTINATION — ASKED OF BOTH SIDES.
    ///
    /// `SYNAPTY_CONFIG_ROOT` exists so a dev launch or a UI test writes
    /// somewhere other than the operator's own config. The workbench
    /// expanded a leading tilde and the CLI did not: it tested `raw[0] ==
    /// '/'` and fell back to the REAL root for anything else. So
    /// `SYNAPTY_CONFIG_ROOT=~/scratch` pointed the app at the scratch root
    /// and every `synapty` process it started at the operator's own
    /// config — the exact accident the variable exists to prevent, with
    /// the dangerous half silent ([[WI-2026-09-11-001]]).
    ///
    /// ASKED OF THE BINARY, because that is the half that was wrong and a
    /// Swift-only assertion could not have seen it.
    func testATildeRootSendsBothSidesToTheSamePlace() throws {
        let bin = try binary()
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let out = SubprocessRunner.run(
            executable: bin, arguments: ["identify"],
            environment: ["HOME": home.path, "SYNAPTY_CONFIG_ROOT": "~/scratch"],
            timeout: 20)
        XCTAssertNil(out.error, "the CLI did not run")

        // WHERE THE CLI WENT: the tilde root, not the fallback.
        let scratch = home.appendingPathComponent("scratch")
        let fallback = home.appendingPathComponent(".config/synapty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path),
                      "the CLI ignored the tilde and used \(fallback.path)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path),
                       "the CLI fell back to the real config root under a tilde")

        // AND WHERE SWIFT WOULD LOOK, from the same two inputs.
        let swiftSaid = ConfigPaths.resolveRoot(
            override: nil, isTestHost: false,
            environment: ["SYNAPTY_CONFIG_ROOT": "~/scratch"], home: home)
        XCTAssertEqual(swiftSaid.standardizedFileURL.path,
                       scratch.standardizedFileURL.path,
                       "the two sides read one variable and went to two places")
    }

    /// AND THE SAME SET IS REFUSED ON BOTH. A value that is neither
    /// absolute nor a leading tilde cannot be honoured, and both sides
    /// answer that by using the real root rather than guessing.
    func testARelativeRootIsRefusedRatherThanGuessedAt() throws {
        let bin = try binary()
        let home = root.appendingPathComponent("home-rel")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        _ = SubprocessRunner.run(
            executable: bin, arguments: ["identify"],
            environment: ["HOME": home.path, "SYNAPTY_CONFIG_ROOT": "scratch"],
            timeout: 20)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".config/synapty").path),
            "a relative root was honoured instead of ignored")

        let swiftSaid = ConfigPaths.resolveRoot(
            override: nil, isTestHost: false,
            environment: ["SYNAPTY_CONFIG_ROOT": "scratch"], home: home)
        XCTAssertEqual(swiftSaid.standardizedFileURL.path,
                       home.appendingPathComponent(".config/synapty").standardizedFileURL.path)
    }

    /// THE NAME THE HOLDER WRITES, ASKED OF THE HOLDER.
    ///
    /// `holder.canonical` folds A-Z to a-z before building the record,
    /// the socket and the lock, and says why: "a name that may not be a
    /// socket may not be a record either, and one that folds must fold
    /// identically or a session's three files stop being one session's."
    /// `SessionRecord` interpolated the raw string into all three.
    ///
    /// A CASE-INSENSITIVE VOLUME HIDES IT, which is exactly why it is
    /// worth a test that asks the binary rather than a mirror that asks
    /// itself: on a case-sensitive volume `isLive` answers false for a
    /// running session and the workbench tells the human their work is
    /// gone ([[WI-2026-09-11-015]]).
    ///
    /// THE FOLD IS BYTE-WISE, WHICH THIS SIDE LEARNED THE HARD WAY. It
    /// used `String.lowercased()` — full Unicode case mapping — where the
    /// holder maps bytes in 'A'...'Z'. Replacing that with a PER-CHARACTER
    /// ASCII fold was still wrong, and this test is what said so: a
    /// decomposed `Ü` is one Swift `Character` whose `isASCII` is false,
    /// while the holder folds its leading `U` BYTE. Non-ASCII names are
    /// refused outright now, so what is left to mirror is the ASCII fold
    /// ([[WI-2026-09-12-002]]).
    func testAMixedCaseSessionIsFoundWhereTheHolderPutIt() throws {
        let bin = try binary()
        let id = "MixedCase-Probe-\(UUID().uuidString.prefix(4))"

        let out = SubprocessRunner.run(
            executable: bin,
            // `--hub none`, BECAUSE THIS IS NOT ABOUT A HUB. `run --hold`
            // dials one before the holder binds anything, and with
            // nothing listening it gives up with "the session did not
            // come up" and exit 1 — measured, in five seconds, writing no
            // record. So this passed wherever something happened to be on
            // the resolved port, which on a developer's machine is their
            // own workbench hub and on CI is nothing
            // ([[WI-2026-09-15-003]]).
            arguments: ["run", "--hold", "--detach", "--id", id, "--hub", "none", "--",
                        "/bin/sh", "-c", "sleep 20"],
            environment: ["SYNAPTY_CONFIG_ROOT": root.path],
            timeout: 20)
        // THE STATUS, NOT THE LAUNCH. `Output.error` is a LAUNCH failure,
        // so a `run` that started and then exited 1 satisfied this and the
        // test went on to report the SYMPTOM — "the holder wrote no
        // record" — instead of the reason it was given. The same
        // confusion as [[WI-2026-09-10-001]], at a site that fix did not
        // reach.
        XCTAssertNil(out.error, "the holder could not be launched")
        XCTAssertEqual(out.exitCode, 0,
                       "the holder did not start: \(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        defer {
            _ = SubprocessRunner.run(
                executable: bin, arguments: ["end", "--id", id],
                environment: ["SYNAPTY_CONFIG_ROOT": root.path], timeout: 10)
        }

        // WHAT THE HOLDER ACTUALLY WROTE.
        let dir = root.appendingPathComponent("machine/sessions")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(written.contains(where: { $0.hasSuffix(".json") }),
                      "the holder wrote no record under \(dir.path): \(written)")

        // AND WHERE THIS SIDE WOULD LOOK, from the same id. Compared by
        // the bytes the two sides built, not by the strings a normalising
        // filesystem hands back: `contentsOfDirectory` can return a
        // different Unicode normalisation than the one written.
        let expected = SessionRecord.url(for: id).lastPathComponent
        XCTAssertTrue(
            written.contains(where: { $0.precomposedStringWithCanonicalMapping
                == expected.precomposedStringWithCanonicalMapping }),
            "the workbench looks for \(expected); the holder wrote \(written)")
    }

    /// THE ACCOUNT AS THE BINARY WRITES IT, PARSED BY THE SIDE THAT READS
    /// IT.
    ///
    /// `progress.say` writes `<13-digit ms> <kind> <text>`;
    /// `ConnectProgress` parses it; and two shell suites pin the shape
    /// against the binary — as a regex in one and positionally in the
    /// other. Nothing crossed the writer to the SWIFT reader, so the format
    /// was three statements each pinned to its own side
    /// ([[WI-2026-09-11-018]]).
    ///
    /// `synapty account` is the verb the connection itself uses, which is
    /// why it is what this drives: a line this test composed would only
    /// prove Swift can read what Swift wrote.
    func testTheAccountTheBinaryWritesIsTheAccountTheWorkbenchReads() throws {
        let bin = try binary()
        let log = root.appendingPathComponent("account.log")

        func say(_ args: [String]) {
            let out = SubprocessRunner.run(
                executable: bin, arguments: ["account"] + args,
                environment: ["SYNAPTY_CONNECT_LOG": log.path], timeout: 10)
            XCTAssertNil(out.error, "the binary could not write the account")
        }
        say(["note", "opening a connection to this host"])
        say(["lost", "the link died; dialling again"])
        say(["end", "no_session"])

        let text = try String(contentsOf: log, encoding: .utf8)

        // EVERY LINE IN THE SHAPE THE READER EXPECTS, asked of the file the
        // binary produced rather than of a fixture.
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2)
            XCTAssertGreaterThanOrEqual(f.count, 2, "not <ms> <kind> <text>: \(line)")
            XCTAssertEqual(f[0].count, 13, "the stamp is not milliseconds: \(line)")
            XCTAssertNotNil(UInt64(f[0]), "the stamp is not a number: \(line)")
        }

        // AND THE ENDING THE READER TAKES FROM IT. This is the decision the
        // format exists to carry: a session that is gone, told apart from
        // one that ended ordinarily.
        XCTAssertEqual(ConnectProgress.endReason(text), .noSession,
                       "the workbench could not read the ending the binary wrote")

        // A `stopped` end is the human leaving, and must not read as a
        // session that vanished.
        let second = root.appendingPathComponent("account2.log")
        _ = SubprocessRunner.run(
            executable: bin, arguments: ["account", "end", "stopped"],
            environment: ["SYNAPTY_CONNECT_LOG": second.path], timeout: 10)
        XCTAssertEqual(
            ConnectProgress.endReason(try String(contentsOf: second, encoding: .utf8)),
            .stopped)
    }

    /// EVERY ENTRY, UNDER BOTH ORDERS.
    ///
    /// THE TWO MIGRATIONS ARE SEPARATE AND BOTH REAL. The app runs
    /// `ConfigPaths.migrate()` at startup; the CLI runs `paths.migrate()`
    /// on every invocation, and a pane's CLI can easily run before the
    /// app's next start. So which of them reaches a flat-layout file
    /// first is not decidable, and the classifications have to agree for
    /// either order to be safe — a file the CLI files into the half the
    /// app does not read is a file the app then regenerates or does
    /// without, in the half that gets synced between machines.
    ///
    /// NOT A HAND-PICKED ENTRY: the defect this exists for was one entry
    /// classified differently, and a test naming its entries would have
    /// to be remembered when the next one is added.
    func testBothMigrationsFileEveryEntryWhereTheWorkbenchLooksForIt() throws {
        let bin = try binary()
        for cliFirst in [true, false] {
            try withFreshRoot { root in
                var planted: [ConfigPaths.Entry: URL] = [:]
                for entry in ConfigPaths.Entry.allCases {
                    // DIRECTORIES ARE MADE BY WHOEVER WRITES INTO THEM;
                    // only the single files travel, and a name with an
                    // extension is how this layout tells them apart.
                    guard entry.name.contains(".") else { continue }
                    let flat = root.appendingPathComponent(entry.name)
                    FileManager.default.createFile(
                        atPath: flat.path, contents: Data("\(entry.name)\n".utf8))
                    planted[entry] = flat
                }
                XCTAssertFalse(planted.isEmpty, "nothing was planted, so nothing is asserted")

                let runCLI = {
                    // Any verb runs the migration; `identify` touches
                    // nothing else.
                    let out = SubprocessRunner.run(
                        executable: bin, arguments: ["identify"],
                        environment: ["SYNAPTY_CONFIG_ROOT": root.path], timeout: 30)
                    XCTAssertNil(out.error, "the CLI could not be run: \(String(describing: out.error))")
                }
                if cliFirst { runCLI(); ConfigPaths.migrate() } else { ConfigPaths.migrate(); runCLI() }

                let order = cliFirst ? "CLI then app" : "app then CLI"
                for (entry, flat) in planted {
                    let expected = ConfigPaths.url(entry.kind, entry.name)
                    XCTAssertTrue(
                        FileManager.default.fileExists(atPath: expected.path),
                        "[\(order)] \(entry.name) is not where the workbench reads it: \(expected.path)")
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: flat.path),
                        "[\(order)] \(entry.name) was left at the flat path as well")
                }
            }
        }
    }

    private func withFreshRoot(_ body: (URL) throws -> Void) rethrows {
        let fresh = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-crossing-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        ConfigPaths.rootOverride = fresh
        defer {
            ConfigPaths.rootOverride = root
            try? FileManager.default.removeItem(at: fresh)
        }
        try body(fresh)
    }
}
