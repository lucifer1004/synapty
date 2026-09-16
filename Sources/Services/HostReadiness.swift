import Foundation

/// What a host can and cannot do ON THIS MACHINE, asked before anything is
/// attempted rather than discovered when it fails.
///
/// [[ADR-0009]] takes this on as an obligation of syncing configuration: a
/// host row travels between Macs, and the credential it names does not.
/// Without this, sync converts a connection failure into a subtler one — a
/// host that looks ready and is not.
///
/// TWO CONSUMERS, ASKED SEPARATELY, and that is the point rather than a
/// detail. The human's terminal pane is interactive: `ssh` runs in a PTY,
/// so a password prompt appears and gets typed, and a missing key is an
/// inconvenience. The workbench's own machinery is not: it scps a binary,
/// starts a hub and holds a ControlMaster and the forward that reaches
/// that hub ([[ADR-0008]]), all non-interactive, where the same prompt is
/// fatal.
/// Collapsing the two into one "ready" flag would either block a terminal
/// that would have worked, or promise a deploy that cannot.
struct HostReadiness: Equatable {

    /// Why a host is not usable for a given purpose. Each case names
    /// something the human can act on.
    enum Gap: Equatable {
        /// The row names a key path that does not exist here. The most
        /// common consequence of syncing a host from another Mac.
        case keyFileMissing(path: String)
        /// The row references a reusable identity that did not travel,
        /// or was deleted.
        case identityMissing
        /// The identity resolves but names a key path that is not here.
        case identityKeyFileMissing(path: String)
        /// No key at all. Fine for a human — ssh will ask, or an agent
        /// will answer — and fatal for anything non-interactive.
        case noKeyConfigured

        var summary: String {
            switch self {
            case .keyFileMissing(let p):
                return "SSH key not on this Mac: \(abbreviate(p))"
            case .identityMissing:
                return "The saved identity for this host is not on this Mac"
            case .identityKeyFileMissing(let p):
                return "The identity's SSH key is not on this Mac: \(abbreviate(p))"
            case .noKeyConfigured:
                return "No SSH key configured for this host"
            }
        }

        /// WHETHER THIS IS SETTLED OR MERELY LIKELY, which decides
        /// whether the workbench may REFUSE on it or has to go and find
        /// out.
        ///
        /// A NAMED KEY THAT IS NOT HERE IS SETTLED: the configuration
        /// points at a file this Mac does not have, and ssh will not
        /// substitute another. NO KEY NAMED AT ALL IS NOT: `ssh-agent`
        /// answers non-interactively, and so does an `IdentityFile` in
        /// `~/.ssh/config` — neither of which this can see. Refusing on
        /// that would block hosts that work today, which is the third
        /// outcome the header above did not name when it weighed
        /// "block a terminal that would have worked, or promise a deploy
        /// that cannot" ([[WI-2026-09-11-007]]).
        ///
        /// So the unsettled case stays a WARNING and is discovered where
        /// it always was — `TunnelManager.wantsPassword` reads it out of
        /// ssh's own output.
        var isSettled: Bool {
            switch self {
            case .keyFileMissing, .identityMissing, .identityKeyFileMissing:
                return true
            case .noKeyConfigured:
                return false
            }
        }

        private func abbreviate(_ path: String) -> String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        }
    }

    /// Can the human open a terminal here? A missing key is NOT
    /// disqualifying: ssh falls back to the agent, to ~/.ssh/config, or to
    /// asking for a password in the pane — all of which work because there
    /// is a person watching.
    let terminalGap: Gap?
    /// Can the workbench deploy an agent and hold a tunnel here? This one
    /// is strict, because nobody is present to answer a prompt.
    let deployGap: Gap?

    var canOpenTerminal: Bool { terminalGap == nil }
    var canDeploy: Bool { deployGap == nil }
    /// Nothing to say. A host that works is silent — the same rule
    /// [[RFC-0010]] C-DIAGNOSABILITY sets for peer capabilities.
    var isComplete: Bool { terminalGap == nil && deployGap == nil }

    /// WHY THE WORKBENCH MUST NOT EVEN TRY, or nil to go ahead.
    ///
    /// ASKED OF WHAT WILL ACTUALLY BE USED, which is not what the record
    /// says. `TunnelManager.effectiveKeyPath` substitutes this machine's
    /// ENROLLED key when the named one is not here, and its comment calls
    /// that "the case [[ADR-0009]] enrolment answers, and the only one
    /// where substituting our own key is right" — the same sync scenario
    /// this type's header cites as its reason for existing.
    ///
    /// So the first version of this refused precisely the case the
    /// workbench repairs: a host row from another Mac, on a host this Mac
    /// was enrolled with, connected before and was refused after. The
    /// caller passes the resolved key because the caller is the only party
    /// that knows it ([[WI-2026-09-11-019]]).
    ///
    /// AND THE OLD REASONING WAS WRONG ABOUT SSH AS WELL. `isSettled` said
    /// "ssh will not substitute another", which is not true of `ssh -i` on
    /// a path that does not exist — it warns and falls through to the
    /// agent and to `~/.ssh/config`. The substitution that matters here is
    /// the WORKBENCH'S, and the workbench knows whether it has one.
    ///
    /// THE CONSUMER THIS TYPE'S HEADER DESCRIBES AND NOBODY HAD WRITTEN.
    /// It argues the two-consumer split at length — the workbench "scps a
    /// binary, starts a hub and holds a ControlMaster ... all
    /// non-interactive, where the same prompt is fatal" — and only the
    /// terminal half was ever asked. `HostBlockView.readiness` even
    /// records where the other half belongs: the deploy warning came off
    /// the host grid because "it matters when someone deploys an agent to
    /// that host, and that is where it should be said." It was not said
    /// there either ([[WI-2026-09-11-007]]).
    ///
    /// So the failure was found at the far end instead, after up to sixty
    /// seconds of ssh, by reading a password prompt out of its output.
    /// This is the same answer, before the attempt — but only for the
    /// gaps that are SETTLED, because refusing on the rest would block
    /// hosts that an agent answers for perfectly well.
    func deployRefusal(resolvedKey: String?,
                       fileExists: (String) -> Bool = {
                           FileManager.default.fileExists(atPath: $0)
                       }) -> String? {
        guard !canDeploy, deployGap?.isSettled == true else { return nil }
        // A KEY THE WORKBENCH WILL ACTUALLY PASS, AND THAT IS HERE, ends
        // the matter: whatever the record names, this connection has a
        // credential.
        if let resolvedKey, !resolvedKey.isEmpty, fileExists(resolvedKey) { return nil }
        return summary
    }

    /// What the human is told, in one sentence, with the consequence
    /// first. WHAT and what to do; the path and the resolution belong in
    /// the log (AppLog's two-channel rule).
    var summary: String? {
        if let t = terminalGap { return t.summary }
        guard let d = deployGap else { return nil }
        // Terminal works, deploy does not — say which, or the human reads
        // a warning on a host they can open perfectly well and stops
        // trusting the warnings.
        return "Agents cannot be deployed here — \(d.summary.prefix(1).lowercased() + d.summary.dropFirst())"
    }

    var accessibilityPhrase: String? {
        guard let s = summary else { return nil }
        return canOpenTerminal ? "terminal available, \(s)" : s
    }

    /// Resolve for a host, against what is actually on this machine.
    ///
    /// A pure function of (host, store, filesystem) so the answer can be
    /// tested without a host, a network, or a key.
    @MainActor
    static func evaluate(
        host: HostEntry,
        store: HostStore,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> HostReadiness {
        // An identity reference that does not resolve is a gap for BOTH
        // consumers: it is not a missing key, it is a missing answer to
        // "who am I on this host".
        if let identityID = host.identityID {
            guard let identity = store.identities.first(where: { $0.id == identityID }) else {
                return HostReadiness(terminalGap: .identityMissing, deployGap: .identityMissing)
            }
            if let path = identity.sshKeyPath, !path.isEmpty {
                let expanded = (path as NSString).expandingTildeInPath
                if !fileExists(expanded) {
                    let gap = Gap.identityKeyFileMissing(path: expanded)
                    return HostReadiness(terminalGap: gap, deployGap: gap)
                }
                return HostReadiness(terminalGap: nil, deployGap: nil)
            }
            // Identity with no key: same asymmetry as a host with no key.
            return HostReadiness(terminalGap: nil, deployGap: .noKeyConfigured)
        }

        if let path = host.sshKeyPath, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            if !fileExists(expanded) {
                // A NAMED key that is absent is a gap for the human too:
                // they chose this key, and ssh will not silently substitute
                // another. This is the case syncing a host row produces.
                let gap = Gap.keyFileMissing(path: expanded)
                return HostReadiness(terminalGap: gap, deployGap: gap)
            }
            return HostReadiness(terminalGap: nil, deployGap: nil)
        }

        // No key named anywhere. The human is fine — agent, ssh config, or
        // a password prompt in the pane. The workbench is not.
        return HostReadiness(terminalGap: nil, deployGap: .noKeyConfigured)
    }
}
