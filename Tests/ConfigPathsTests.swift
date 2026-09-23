import XCTest
@testable import Synapty

/// WI-2026-08-13-003. The guard that has to outlive the change that made
/// it true — the mistake this prevents is a FUTURE one, where somebody
/// writes "sync the shared directory" and a machine-scoped file happens to
/// be sitting inside it.
final class ConfigPathsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConfigPaths.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-paths-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root = ConfigPaths.rootOverride {
            try? FileManager.default.removeItem(at: root)
        }
        ConfigPaths.rootOverride = nil
        super.tearDown()
    }

    // MARK: - Driving a real build without writing the real config

    private let home = URL(fileURLWithPath: "/Users/someone")

    private func resolved(_ env: [String: String]) -> URL {
        ConfigPaths.resolveRoot(override: nil, isTestHost: false,
                                environment: env, home: home)
    }

    func testWithoutTheVariableTheRootIsTheOperatorsOwn() {
        XCTAssertEqual(resolved([:]).path, "/Users/someone/.config/synapty")
    }

    func testAnAbsolutePathRedirectsTheWholeRoot() {
        XCTAssertEqual(resolved([ConfigPaths.environmentKey: "/tmp/scratch"]).path,
                       "/tmp/scratch")
    }

    func testATildeIsTheHumansHomeAndNotADirectoryCalledTilde() {
        let out = resolved([ConfigPaths.environmentKey: "~/scratch"]).path
        XCTAssertFalse(out.contains("~"))
        XCTAssertTrue(out.hasSuffix("/scratch"), "got \(out)")
    }

    /// A RELATIVE PATH IS IGNORED, NOT RESOLVED. A bundled application's
    /// working directory is `/`, so honouring one would silently build a
    /// config tree at the root of the disk and come up looking as though
    /// every host had been lost — a typo has to fall back to the real
    /// config, not to a plausible-looking empty one.
    func testARelativePathIsRefusedAndTheRealRootStands() {
        XCTAssertEqual(resolved([ConfigPaths.environmentKey: "scratch"]).path,
                       "/Users/someone/.config/synapty")
        XCTAssertEqual(resolved([ConfigPaths.environmentKey: "../scratch"]).path,
                       "/Users/someone/.config/synapty")
        XCTAssertEqual(resolved([ConfigPaths.environmentKey: ""]).path,
                       "/Users/someone/.config/synapty")
    }

    /// The test host outranks it: a suite that happened to run with the
    /// variable set must still not write wherever it points.
    func testATestHostOutranksTheEnvironment() {
        let out = ConfigPaths.resolveRoot(override: nil, isTestHost: true,
                                          environment: [ConfigPaths.environmentKey: "/tmp/scratch"],
                                          home: home)
        XCTAssertEqual(out, TestHost.configRoot)
        XCTAssertNotEqual(out.path, "/tmp/scratch")
    }

    /// And an explicit override outranks everything, which is what the
    /// per-test seam relies on.
    func testAnExplicitOverrideOutranksBoth() {
        let mine = URL(fileURLWithPath: "/tmp/mine")
        XCTAssertEqual(ConfigPaths.resolveRoot(override: mine, isTestHost: true,
                                               environment: [ConfigPaths.environmentKey: "/tmp/scratch"],
                                               home: home), mine)
    }

    func testTheSharedDirectoryCannotReachAnythingMachineScoped() {
        let sharedPath = ConfigPaths.shared.path
        for entry in ConfigPaths.allEntries {
            let p = ConfigPaths.url(entry.kind, entry.name).path
            switch entry.kind {
            case .shared:
                XCTAssertTrue(p.hasPrefix(sharedPath), "\(entry.name) must live under shared/")
            case .machine:
                XCTAssertFalse(p.hasPrefix(sharedPath),
                               "\(entry.name) is machine-scoped and must NOT be reachable from shared/")
            }
        }
    }

    func testIdentityIsMachineScopedAndThatIsThePoint() {
        // The one whose misclassification has a named consequence:
        // RFC-0010 C-COLLISION — two machines holding one peer id, every
        // message between them misrouted, remedied only by a manual re-mint.
        XCTAssertFalse(ConfigPaths.identity.path.hasPrefix(ConfigPaths.shared.path))
        XCTAssertFalse(ConfigPaths.hubState.path.hasPrefix(ConfigPaths.shared.path))
        XCTAssertFalse(ConfigPaths.session.path.hasPrefix(ConfigPaths.shared.path))
        XCTAssertFalse(ConfigPaths.discovery.path.hasPrefix(ConfigPaths.shared.path))
    }

    func testMigrationMovesRatherThanCopies() throws {
        // A copy would leave identity.json readable at the old path — the
        // one file whose duplication this split exists to prevent. Half a
        // migration must not leave the landmine armed.
        let fm = FileManager.default
        let root = ConfigPaths.root
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("identity.json")
        try #"{"peer_id":"deskmac-2630"}"#.write(to: legacy, atomically: true, encoding: .utf8)

        ConfigPaths.migrate()

        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "the legacy copy must be GONE, not duplicated")
        XCTAssertTrue(fm.fileExists(atPath: ConfigPaths.identity.path))

        // Idempotent.
        ConfigPaths.migrate()
        XCTAssertTrue(fm.fileExists(atPath: ConfigPaths.identity.path))
    }

    func testMigrationDoesNotClobberAnExistingDestination() throws {
        // A destination that already exists means a previous run finished;
        // the legacy file is stale and guessing which is newer would be a
        // way to lose the current one.
        let fm = FileManager.default
        try fm.createDirectory(at: ConfigPaths.machine, withIntermediateDirectories: true)
        try #"{"peer_id":"current"}"#.write(to: ConfigPaths.identity, atomically: true, encoding: .utf8)
        let legacy = ConfigPaths.root.appendingPathComponent("identity.json")
        try #"{"peer_id":"stale"}"#.write(to: legacy, atomically: true, encoding: .utf8)

        ConfigPaths.migrate()

        let kept = try String(contentsOf: ConfigPaths.identity, encoding: .utf8)
        XCTAssertTrue(kept.contains("current"), "an existing identity must not be overwritten by a stale one")
    }
}

extension ConfigPathsTests {

    /// The guard the first version of this change NEEDED and did not have.
}

extension ConfigPathsTests {

    func testASupersededLegacyFileIsRemovedNotLeftBehind() throws {
        // Observed for real: an older build ran once after a migration and
        // recreated two files at the root. The destination is what
        // everything reads, so the root copy is superseded — and a stale
        // identity at the old flat path is precisely the artefact this
        // split exists to keep out of any future replication.
        let fm = FileManager.default
        try fm.createDirectory(at: ConfigPaths.machine, withIntermediateDirectories: true)
        try #"{"peer_id":"current-0001"}"#.write(to: ConfigPaths.identity, atomically: true, encoding: .utf8)
        let legacy = ConfigPaths.root.appendingPathComponent("identity.json")
        try #"{"peer_id":"stale-9999"}"#.write(to: legacy, atomically: true, encoding: .utf8)

        ConfigPaths.migrate()

        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "the superseded copy must be removed")
        let kept = try String(contentsOf: ConfigPaths.identity, encoding: .utf8)
        XCTAssertTrue(kept.contains("current-0001"), "and the current one must survive intact")
    }

    /// A test process must not resolve to the operator's real config.
    ///
    /// The suite runs hosted in the app, so app code that has never heard
    /// of a test seam reads and writes these paths. Per-test overrides
    /// only isolate the tests that remember them; this asserts the
    /// PROCESS-level boundary ([[WI-2026-08-14-010]]).
    func testATestHostNeverResolvesToTheRealConfigRoot() {
        let saved = ConfigPaths.rootOverride
        ConfigPaths.rootOverride = nil
        defer { ConfigPaths.rootOverride = saved }

        XCTAssertTrue(TestHost.isActive, "this assertion is meaningless outside a test host")
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/synapty")
        XCTAssertNotEqual(
            ConfigPaths.root.standardizedFileURL, real.standardizedFileURL,
            "a suite run must not be able to reach the operator's config")
        // And the shared half — the one that syncs — with it.
        XCTAssertFalse(
            ConfigPaths.settings.path.hasPrefix(real.path),
            "settings.json must not resolve under the real root")
    }
}

/// THE CLASSIFICATION IS ONE LIST, NOT TWO ([[WI-2026-08-30-003]]).
///
/// The named accessors and the list the guard reads were written out
/// separately, and one entry was in the first and not the second — the
/// per-record stores, which are the whole point of the shared half. The
/// list is derived from the enumeration now, so the two cannot disagree;
/// these say what that buys.
final class ConfigPathsClassificationTests: XCTestCase {

    func testEveryClassifiedEntryIsInTheListTheGuardReads() {
        let listed = Set(ConfigPaths.allEntries.map { "\($0.kind)/\($0.name)" })
        for entry in ConfigPaths.Entry.allCases {
            XCTAssertTrue(listed.contains("\(entry.kind)/\(entry.name)"),
                          "\(entry.name) is classified and not guarded")
        }
        XCTAssertEqual(listed.count, ConfigPaths.Entry.allCases.count)
    }

    /// A NAMED ACCESSOR RESOLVES WHERE ITS ENTRY SAYS. The accessors used
    /// to repeat the pair; if one drifted from its entry the guard would
    /// still pass while the file was written somewhere else.
    func testAnAccessorAgreesWithItsEntry() {
        XCTAssertEqual(ConfigPaths.settings, ConfigPaths.url(.settings))
        XCTAssertEqual(ConfigPaths.keymap, ConfigPaths.url(.keymap))
        XCTAssertEqual(ConfigPaths.hubState, ConfigPaths.url(.hubState))
        XCTAssertEqual(ConfigPaths.settings.lastPathComponent,
                       ConfigPaths.Entry.settings.name)
    }

    /// No two entries name the same file in the same half — a collision
    /// would have one silently overwrite the other's contents.
    func testNoTwoEntriesCollide() {
        let keys = ConfigPaths.Entry.allCases.map { "\($0.kind)/\($0.name)" }
        XCTAssertEqual(Set(keys).count, keys.count, "two entries resolve to one path")
    }

    /// WHICH HALF EACH FILE IS IN, pinned where a reason was given for it.
    ///
    /// Not a restatement of the switch: these are the decisions the split
    /// exists to make, and each was argued. A later tidy-up that moves one
    /// is exactly what this catches — moving `identity.json` into the
    /// shared half would replicate the one file whose duplication the
    /// split was created to prevent, and moving `hub.log` there would
    /// present one machine's failures as another's.
    func testTheHalvesEachFileIsInAreTheOnesThatWereArguedFor() {
        for entry in [ConfigPaths.Entry.identity, .hubLog, .hubState, .session, .discovery, .sessions] {
            XCTAssertEqual(entry.kind, .machine, "\(entry.name) is evidence about this machine")
        }
        // DERIVED, AND FROM THIS MACHINE'S SHELL AS MUCH AS FROM THE
        // PERSON'S SETTINGS: the fragment is regenerated wherever it lands
        // and was measured losing to a fresh machine's default when it
        // travelled as a record of its own ([[WI-2026-09-02-005]]).
        XCTAssertEqual(ConfigPaths.Entry.ghosttyConfig.kind, .machine,
                       "ghostty.conf is computed here, not carried here")
        for entry in [ConfigPaths.Entry.settings, .keymap,
                      .hosts, .groups, .identities] {
            XCTAssertEqual(entry.kind, .shared, "\(entry.name) belongs to the person, not the desk")
        }
    }
}

/// NOTHING BUILDS A SYNAPTY PATH FROM $HOME ([[WI-2026-08-30-004]]).
///
/// Three services did — the hub's discovery file, and the detect and
/// lifecycle override directories — so a redirected root moved the writer
/// and left those readers on the operator's real files. The UI suite
/// launches with SYNAPTY_CONFIG_ROOT pointed at a scratch directory
/// expressly to keep the operator's own app out of it, and the workbench
/// read their hub.json anyway and adopted their live hub.
final class ConfigRootRedirectTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = try TestTempStorage.makeDir()
        ConfigPaths.rootOverride = tmp
    }

    override func tearDown() {
        ConfigPaths.rootOverride = nil
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    /// THE TEST IS THAT THEY MOVE, not that they equal a path spelled out
    /// here — spelling it out would be the second copy over again.
    func testEveryClassifiedPathFollowsARedirectedRoot() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for entry in ConfigPaths.Entry.allCases {
            let path = ConfigPaths.url(entry).path
            XCTAssertTrue(path.hasPrefix(tmp.path),
                          "\(entry.name) resolved outside the redirected root")
            XCTAssertFalse(path.hasPrefix(home + "/.config/synapty"),
                           "\(entry.name) still resolves into the operator's own state")
        }
    }

    /// THE THREE THAT WERE BUILT BY HAND, asked of the production readers
    /// rather than of the accessors they were supposed to be using —
    /// asserting that `ConfigPaths.discovery` follows the root proves
    /// nothing about the site that never called it.
    func testTheHubIsDiscoveredInsideTheRedirectedRoot() throws {
        let dir = ConfigPaths.discovery.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"port":19731}"#.utf8).write(to: ConfigPaths.discovery)

        XCTAssertEqual(HubManager.discoveredPort(), 19731,
                       "the hub was discovered somewhere other than the redirected root")
    }

    /// A redirected root has no discovery file until something writes one,
    /// and finding a port anyway means the operator's own was read.
    func testAnEmptyRedirectedRootDiscoversNoHub() {
        XCTAssertNil(HubManager.discoveredPort(),
                     "a hub was discovered in an empty root — the operator's file was read")
    }

    func testTheManifestOverrideDirectoriesFollowTheRoot() {
        for url in [DetectManifestLoader.defaultOverrideDir, LifecycleSpecLoader.defaultOverrideDir] {
            XCTAssertTrue(url.path.hasPrefix(tmp.path),
                          "\(url.lastPathComponent) still points at the operator's own manifests")
        }
    }
}
