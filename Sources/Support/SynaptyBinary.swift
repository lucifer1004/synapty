import Foundation

/// Resolves the bundled synapty CLI binary — the single source of truth
/// for the bundled-vs-dev lookup shared by HubManager, AgentMonitor and
/// TaskMonitor ([[WI-2026-08-08-036]]).
enum SynaptyBinary {
    /// Contents/Helpers/ under the REAL name "synapty". NOT MacOS/: APFS
    /// case-insensitivity makes a PATH lookup for "synapty" there match
    /// "Synapty" (the GUI executable) — in-pane `synapty` calls launched
    /// second GUI instances. NOT Resources/: unsealed copies are killed
    /// by ASP.
    private static let bundledPath = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/synapty").path

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
