import Foundation

/// Resolves the bundled synapty CLI binary — the single source of truth
/// for the Contents/MacOS vs dev-fallback lookup that HubManager,
/// AgentMonitor and TaskMonitor used to copy-paste (WI-2026-08-08-036).
enum SynaptyBinary {
    /// Contents/MacOS/ — Resources/ copies are killed by ASP (signature not
    /// sealed); MacOS/ is the standard nested-helper location.
    private static let bundledPath = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/synapty-cli").path

    /// Dev fallback (zig-out/bin next to the workspace).
    private static let devPath = "zig-out/bin/synapty"

    /// The CLI binary path, or nil when neither the bundled nor the dev
    /// copy exists.
    static func resolve() -> String? {
        if FileManager.default.fileExists(atPath: bundledPath) {
            return bundledPath
        }
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
    }
}
