import CloudKit
import Foundation
import Observation

/// Holds what sync is currently doing, so the answer is one thing every
/// surface reads rather than a question each surface asks separately.
///
/// The requirement this serves ([[WI-2026-08-13-005]]) is not "show an
/// error" — it is that a sync which is NOT running must never render as
/// one that is. Those fail differently: an error nobody shows is a bug you
/// find eventually, and a stopped sync that looks healthy is a human
/// trusting a host list that stopped updating months ago. The second is
/// the one this project has been removing everywhere else (RFC-0010
/// C-DIAGNOSABILITY), and it is the one CloudKit was chosen over
/// NSUbiquitousKeyValueStore to avoid.
@MainActor @Observable final class SyncMonitor {

    /// The app's one monitor. A second instance would ask CloudKit the
    /// same question on its own schedule and could answer differently,
    /// which is how two surfaces come to disagree about whether sync is
    /// running — the exact confusion this type exists to remove.
    @MainActor static let shared = SyncMonitor()

    /// Test seam: skip the real CloudKit call. Tests assert on the STATE
    /// MACHINE, not on Apple's servers.
    nonisolated(unsafe) static var statusOverride: SyncPreflight.Status?

    private(set) var status: SyncPreflight.Status = .networkUnavailable
    /// When the status was last established. A status with no timestamp
    /// is indistinguishable from a fresh one, which is the same shape of
    /// lie as a stale relayed presence being served as current.
    private(set) var lastChecked: Date?

    private var accountObserver: NSObjectProtocol?

    /// True only when sync is genuinely running. Read this rather than
    /// comparing against `.available` at each call site.
    var isSyncing: Bool { status.isSyncing }

    func start() {
        Task { await refresh() }
        // iCloud sign-in and sign-out happen while the app runs, and a
        // status established at launch is wrong from that moment on.
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        if let o = accountObserver { NotificationCenter.default.removeObserver(o) }
        accountObserver = nil
    }

    func refresh() async {
        // Not `??`: its right-hand side is an autoclosure, which cannot
        // be async.
        let next: SyncPreflight.Status
        if let forced = Self.statusOverride {
            next = forced
        } else {
            next = await SyncPreflight.check()
        }
        let changed = next != status
        status = next
        lastChecked = Date()
        guard changed else { return }
        // The log answers WHY (the typed case, verbatim); the UI answers
        // WHAT (humanDescription). Deliberately not the same string —
        // AppLog's two-channel rule.
        if next.isSyncing {
            AppLog.sync.info("sync available")
        } else {
            AppLog.sync.error("sync unavailable: \(String(describing: next), privacy: .public)")
        }
    }

    /// Short label for a compact surface. Empty when syncing, because a
    /// capability that works is invisible by working — the same rule
    /// [[RFC-0010]] C-DIAGNOSABILITY sets for peer capabilities.
    var compactLabel: String? {
        switch status {
        case .available: return nil
        case .notSignedIn: return "iCloud sign-in needed"
        case .restricted: return "iCloud off for Synapty"
        case .networkUnavailable: return "iCloud offline"
        case .schemaMissing: return "iCloud unavailable"
        case .notEntitled: return "iCloud not set up"
        case .failed: return "iCloud error"
        }
    }

    /// Spoken form, so a colour and a glyph are not the only carriers.
    var accessibilityLabel: String {
        status.isSyncing ? "Host list syncing with iCloud"
            : "Host list not syncing. \(status.humanDescription)"
    }
}
