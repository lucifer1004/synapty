import CloudKit
import Foundation
import Security

/// Can this app reach CloudKit at all, and if not, WHY.
///
/// This exists before the sync engine does, on purpose. The open question
/// was whether CloudKit on macOS requires App Sandbox — and Synapty spawns
/// arbitrary child processes, SSHes out and drives tmux, so sandboxing it
/// would not be a hardening step but a different product. If that
/// requirement is real the whole approach is dead, and the cheapest place
/// to find out is a single account lookup, not a finished sync engine.
///
/// It is also not throwaway. Every state below is one the shipped app has
/// to be able to explain to a human ([[WI-2026-08-13-005]]: sync failure
/// is VISIBLE AND TYPED, and a sync that is not running never renders as
/// one that is), so the diagnosis written here is the diagnosis the UI
/// will use.
enum SyncPreflight {

    /// Why sync is or is not available. Each case is something a human can
    /// act on, or be told to stop waiting for — which is the difference
    /// between this and a Bool.
    enum Status: Equatable {
        case available
        /// No iCloud account on this Mac. The human signs in; nothing here
        /// can fix it.
        case notSignedIn
        /// Signed in, but iCloud Drive / this app's access is off.
        case restricted
        /// Reachable account state unknown because the network is not.
        /// Distinct from `notSignedIn` because waiting fixes one and not
        /// the other.
        case networkUnavailable
        /// The container exists but the record types do not — the
        /// development schema was never promoted to production. Named
        /// because it is invisible in development and total in a shipped
        /// build.
        case schemaMissing
        /// The entitlement is not authorised: profile missing, container
        /// not assigned to the App ID, or an unsigned/dev build.
        case notEntitled(String)
        /// Anything else, carried verbatim rather than flattened.
        case failed(String)

        /// What the human is told. WHAT and what to do — the cause and the
        /// CKError code belong in the log (AppLog's two-channel rule).
        var humanDescription: String {
            switch self {
            case .available:
                return "Syncing with iCloud"
            case .notSignedIn:
                return "Not syncing — sign in to iCloud in System Settings"
            case .restricted:
                return "Not syncing — iCloud is turned off for this app in System Settings"
            case .networkUnavailable:
                return "Not syncing — no network. Changes are kept and sent when you are back online"
            case .schemaMissing:
                return "Not syncing — this build cannot find its iCloud records"
            case .notEntitled:
                return "Not syncing — this copy of Synapty is not set up for iCloud"
            case .failed:
                return "Not syncing — iCloud returned an error"
            }
        }

        /// `available` is the ONLY state that may render as working. Named
        /// as a property rather than left to each call site, because "not
        /// running looked like running" is the failure this WI exists to
        /// prevent and it happens one forgotten branch at a time.
        var isSyncing: Bool { self == .available }
    }

    static let containerID = "iCloud.com.synapty.app"

    /// Ask CloudKit for the account status. One request, no schema, no
    /// records — enough to distinguish every case above except
    /// `schemaMissing`, which only a real record operation can produce.
    static func check() async -> Status {
        // ASK BEFORE TOUCHING CLOUDKIT.
        //
        // CKContainer(identifier:) TRAPS in a process whose entitlements
        // do not carry that container — it does not throw, and it does not
        // return an error. The Debug build is ad-hoc signed with no
        // profile and therefore no iCloud entitlement, so the first
        // version of this crashed the app and the test host on launch.
        //
        // The guard is not just crash avoidance: "this copy is not set up
        // for iCloud" is a real, distinct state a human can be told, and
        // it is exactly what a development build, an unsigned build, or a
        // build whose profile lost its container all are.
        guard hasContainerEntitlement() else {
            return .notEntitled("no \(containerID) entitlement in this build")
        }
        let container = CKContainer(identifier: containerID)
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                return .available
            case .noAccount:
                return .notSignedIn
            case .restricted:
                return .restricted
            case .couldNotDetermine:
                // CloudKit reports this when it cannot reach the account,
                // which is usually the network rather than the account.
                return .networkUnavailable
            case .temporarilyUnavailable:
                return .networkUnavailable
            @unknown default:
                return .failed("unknown account status \(status.rawValue)")
            }
        } catch {
            return classify(error)
        }
    }

    /// Does THIS process carry the container entitlement?
    ///
    /// Read from the running process's own signature rather than assumed
    /// from the build configuration, because the two can disagree: a
    /// Release binary run from a stale copy, or a profile that no longer
    /// lists the container, both look like Release and are not entitled.
    static func hasContainerEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.icloud-container-identifiers" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        guard let ids = value as? [String] else { return false }
        return ids.contains(containerID)
    }

    /// Turn a CKError into something with a remedy attached.
    static func classify(_ error: Error) -> Status {
        guard let ck = error as? CKError else {
            let ns = error as NSError
            // The entitlement failure does not always arrive as a CKError.
            if ns.domain == "CKErrorDomain" || ns.localizedDescription.lowercased().contains("entitle") {
                return .notEntitled(ns.localizedDescription)
            }
            return .failed(ns.localizedDescription)
        }
        switch ck.code {
        case .notAuthenticated:
            return .notSignedIn
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return .networkUnavailable
        case .badContainer, .missingEntitlement:
            return .notEntitled(ck.localizedDescription)
        case .unknownItem, .invalidArguments:
            // `unknownItem` on a type-level operation is the shape a
            // missing production schema takes.
            return .schemaMissing
        case .managedAccountRestricted, .permissionFailure:
            return .restricted
        case .quotaExceeded:
            return .failed("iCloud storage is full")
        default:
            return .failed("\(ck.code.rawValue): \(ck.localizedDescription)")
        }
    }
}
