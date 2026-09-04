import Foundation
import XCTest
@testable import Synapty

/// Shared temp-storage harness for store-backed tests (WI-2026-08-08-037).
/// HostModelTests, TunnelManagerTests and SynaptySettingsTests all used to
/// hand-roll the same temp-directory creation/removal.
enum TestTempStorage {
    /// Create a fresh temp directory for this test case.
    static func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapty-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Remove the temp directory (best-effort).
    static func removeDir(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// XCTestCase helpers for the common "isolated storage" setUp/tearDown.
extension XCTestCase {
    /// Create a temp dir, install it as the HostStore storage override,
    /// and return it. Call `restoreStorageOverrides(url:)` in tearDown.
    @MainActor
    func setUpHostStoreStorage() throws -> URL {
        let url = try TestTempStorage.makeDir()
        HostStore.storageOverride = url
        return url
    }

    /// Create a temp dir, install it as the SynaptySettings storage
    /// override, and return it.
    @MainActor
    func setUpSettingsStorage() throws -> URL {
        let url = try TestTempStorage.makeDir()
        SynaptySettings.storageOverride = url
        return url
    }

    /// Remove a temp dir and clear the storage overrides.
    @MainActor
    func restoreStorageOverrides(_ url: URL) {
        HostStore.storageOverride = nil
        SynaptySettings.storageOverride = nil
        TestTempStorage.removeDir(url)
    }
}

extension XCTestCase {
    /// Wait for a condition an ASYNCHRONOUS chain will eventually satisfy,
    /// rather than guessing how long that chain takes.
    ///
    /// A flat `Task.sleep` is a wall-clock bet, and any number chosen is
    /// either wasteful on an idle machine or too short on a loaded one.
    /// One such bet — 1.2 seconds against a 500ms debounce, which reads
    /// like ample headroom — lost on a loaded machine and won on the next
    /// run. That is the worst way for a test to fail, because it teaches
    /// the reader that red means "run it again" rather than "look".
    ///
    /// Polls quickly, gives up slowly, and re-checks once at the deadline
    /// so a condition satisfied in the final interval is not missed.
    func eventually(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await MainActor.run(body: condition)
    }
}
