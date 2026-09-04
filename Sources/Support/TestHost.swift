import Foundation

/// Is this process an XCTest host?
///
/// The Swift tests run HOSTED IN THE APP, so the app's own code — its
/// startup path, its singletons — runs inside the test process with the
/// operator's real machine underneath it. Everything machine-global is
/// therefore reachable from a test unless something stops it.
///
/// Read from XCTest's own environment rather than a build flag: the test
/// host is a Debug build of the same app the operator may also be running,
/// so a compile-time switch would disable the behaviour for ordinary Debug
/// use as well.
enum TestHost {

    static var isActive: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }

    /// A config root of this process's own, created once.
    ///
    /// ISOLATION THAT CANNOT BE FORGOTTEN. Per-test seams
    /// (`setUpSettingsStorage`, `HostStore.storageOverride`) only isolate
    /// the tests that remember to call them, and the app code a hosted
    /// test drags in never calls them at all — so a suite run wrote the
    /// operator's settings.json back to defaults, repeatedly, and the
    /// cause looked like a sync bug for most of a day.
    ///
    /// Per PROCESS, not per test: the point is that no code path has to
    /// know it is under test.
    static let configRoot: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-test-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
