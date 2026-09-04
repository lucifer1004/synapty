import Foundation

/// Config paths classified by LIFETIME — WI-2026-08-13-003, mirroring
/// `src/paths.zig` so both halves of the product agree about which files
/// may be replicated across a human's machines.
///
/// SHARED is the human's intent and is identical everywhere they work:
/// hosts, the task-centre repo, appearance. MACHINE is this box and
/// nothing else: its minted peer id, its hub's discovery entry and durable
/// state, its window layout.
///
/// The split exists because the natural sync operation is "sync the config
/// directory", and under the old flat layout that replicated identity.json
/// — which [[RFC-0010]] C-COLLISION names as one of exactly two ways two
/// machines end up holding one peer id, remedied only by a manual re-mint
/// and symptomatic as every message between them being misrouted. The
/// point is not that files moved; it is that `shared` is now a complete,
/// portable unit that CANNOT reach `machine`, so nobody has to remember
/// which file is which.
enum ConfigPaths {

    enum Kind {
        /// Replicable across a human's machines.
        case shared
        /// This machine only. Copying it is a defect, not a convenience.
        case machine
    }

    /// Test seam: redirect the whole root so a test never writes the real
    /// one.
    static var rootOverride: URL?

    /// THE ROOT MAY BE REDIRECTED BY THE ENVIRONMENT, so a real build can
    /// be driven — dev launch args, screenshots, a throwaway layout —
    /// without writing the config the operator actually uses.
    ///
    /// WHY IT EXISTS: `--tabs` and `--layout` ADD to the restored layout
    /// rather than replacing it, so every screenshot relaunch permanently
    /// grew the operator's own session file. Six of them turned a couple
    /// of panes into twelve before it was noticed, and the only reason it
    /// was noticed is that the panes were visible — the same accident in
    /// `hosts.json` would have been silent.
    static let environmentKey = "SYNAPTY_CONFIG_ROOT"

    /// AN ABSOLUTE PATH OR NOTHING. A relative one resolves against the
    /// process's working directory, and a bundled application's is `/` —
    /// so a typo would not fail, it would quietly build a config tree at
    /// the root of the disk and the application would come up looking as
    /// though every host had been lost. A path that cannot be honoured is
    /// therefore ignored rather than guessed at.
    ///
    /// Pure, so what it decides can be measured without setting a variable
    /// in this process and hoping to unset it again.
    static func resolveRoot(override: URL?, isTestHost: Bool,
                            environment: [String: String], home: URL) -> URL {
        if let override { return override }
        if isTestHost { return TestHost.configRoot }
        let real = home.appendingPathComponent(".config/synapty")
        guard let raw = environment[environmentKey] else { return real }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return real }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    /// Whether this process is running on a config root that is not the
    /// operator's. SAID OUT LOUD IN THE UI, because an application quietly
    /// showing an empty workspace and no hosts is indistinguishable from
    /// one that has lost them.
    static var isRedirected: Bool {
        rootOverride == nil && !TestHost.isActive && root != realRoot
    }

    static var realRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/synapty")
    }

    /// A TEST HOST NEVER RESOLVES TO THE OPERATOR'S CONFIG, whether or not
    /// the test remembered a seam ([[WI-2026-08-14-010]]). The suite runs
    /// hosted in the app, so app code with no idea it is under test reads
    /// and writes these paths; per-test overrides cannot cover that.
    static var root: URL {
        resolveRoot(override: rootOverride,
                    isTestHost: TestHost.isActive,
                    environment: ProcessInfo.processInfo.environment,
                    home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The directory a sync layer may replicate WHOLESALE.
    static var shared: URL { root.appendingPathComponent("shared") }
    static var machine: URL { root.appendingPathComponent("machine") }

    static func dir(_ kind: Kind) -> URL {
        switch kind {
        case .shared: return shared
        case .machine: return machine
        }
    }

    static func url(_ kind: Kind, _ name: String) -> URL {
        dir(kind).appendingPathComponent(name)
    }

    /// THE CLASSIFICATION ITSELF, AND ONLY HERE.
    ///
    /// A CASE PER FILE, not a pair of lists. The named accessors and the
    /// list the guard reads were written out separately, so an entry could
    /// be classified and unguarded at once — and one was: the per-record
    /// stores, the whole point of the shared half, were absent from the
    /// list while the guard reported on everything else
    /// ([[WI-2026-08-13-004]], [[WI-2026-08-30-003]]). An enumeration
    /// cannot be added to without both switches below answering for it.
    enum Entry: CaseIterable {
        case settings, ghosttyConfig, githubConfig
        /// The keymap ([[RFC-0016]] C-REBIND): taste before it is anything
        /// else, and taste belongs to the person rather than to the desk
        /// they are sitting at.
        case keymap
        /// The per-record stores ([[WI-2026-08-13-004]]).
        case hosts, groups, identities
        case session, identity, discovery, hubState
        /// The directory holding one record and one socket per durable
        /// session ([[paths.sessionsDir]] on the Zig side).
        case sessions
        /// A log is evidence about THIS machine; replicating it would
        /// present one machine's failures as another's
        /// ([[WI-2026-08-13-010]]).
        case hubLog
        case detect, lifecycle

        var kind: Kind {
            switch self {
            case .settings, .githubConfig, .keymap,
                 .hosts, .groups, .identities:
                return .shared
            // THE FRAGMENT IS DERIVED, AND PARTLY FROM THIS MACHINE. Every
            // line of ghostty.conf is computed from settings.json plus the
            // local $SHELL (shell-integration); nothing in it is the
            // human's own edit. Synced as a record it was a second copy
            // of the same intent that could disagree with the first — and
            // did: a fresh machine wrote its default fragment before sync
            // fetched, the remote copy then lost to "keep ours" for a
            // non-JSON file, and the terminal ignored the synced theme
            // ([[WI-2026-09-02-005]]). Regenerated here, from the record
            // that IS synced.
            case .ghosttyConfig,
                 .session, .sessions, .identity, .discovery, .hubState, .hubLog,
                 .detect, .lifecycle:
                return .machine
            }
        }

        var name: String {
            switch self {
            case .settings: return "settings.json"
            case .ghosttyConfig: return "ghostty.conf"
            case .githubConfig: return "config.toml"
            case .keymap: return "keys.json"
            case .hosts: return "hosts"
            case .groups: return "groups"
            case .identities: return "identities"
            case .session: return "session.json"
            case .sessions: return "sessions"
            case .identity: return "identity.json"
            case .discovery: return "hub.json"
            case .hubState: return "hub-state.json"
            case .hubLog: return "hub.log"
            case .detect: return "detect"
            case .lifecycle: return "lifecycle"
            }
        }
    }

    static func url(_ entry: Entry) -> URL { url(entry.kind, entry.name) }

    static var settings: URL { url(.settings) }
    static var ghosttyConfig: URL { url(.ghosttyConfig) }
    static var githubConfig: URL { url(.githubConfig) }
    static var keymap: URL { url(.keymap) }

    static var session: URL { url(.session) }
    static var identity: URL { url(.identity) }
    static var discovery: URL { url(.discovery) }
    static var hubState: URL { url(.hubState) }
    static var sessions: URL { url(.sessions) }
    static var detect: URL { url(.detect) }
    static var lifecycle: URL { url(.lifecycle) }

    /// Everything classified, for the guard test and migration. Derived,
    /// so it cannot fall behind what is classified.
    static var allEntries: [(kind: Kind, name: String)] {
        Entry.allCases.map { ($0.kind, $0.name) }
    }

    /// Create both roots and MOVE anything still at the old flat paths.
    /// A move and never a copy: a copy would leave identity.json readable
    /// at the old location, which is the one file whose duplication this
    /// split exists to prevent. Idempotent.
    static func migrate() {
        let fm = FileManager.default
        for d in [shared, machine] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        for entry in allEntries {
            let legacy = root.appendingPathComponent(entry.name)
            let destination = url(entry.kind, entry.name)
            guard fm.fileExists(atPath: legacy.path) else { continue }
            if fm.fileExists(atPath: destination.path) {
                // The destination is what everything reads, so the legacy
                // copy is SUPERSEDED. Remove it rather than leaving it —
                // a stale identity.json at the old flat path is exactly
                // the artefact this split exists to keep out of any future
                // replication, and it happens for real when an older build
                // runs once after a migration.
                try? fm.removeItem(at: legacy)
                continue
            }
            try? fm.moveItem(at: legacy, to: destination)
        }
    }
}
