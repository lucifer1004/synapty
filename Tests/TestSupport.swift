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
