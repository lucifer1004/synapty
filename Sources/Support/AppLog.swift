import os

/// Central Logger namespace — one place for the service loggers
/// (WI-2026-08-08-036). Subsystem is the app bundle id; categories match
/// the service names.
///
/// SEVERITY POLICY. The same rule the Zig side follows (src/diag.zig), and
/// stated in both places on purpose: a convention that lives in one
/// language's source is a convention the other language does not have.
///
///   error   — a PROMISE WAS BROKEN, or a feature silently did not happen.
///             Something already reported as done is now untrue, or a
///             capability is gone and nothing else will say so. A host that
///             did not reach disk belongs here; so does a migration that
///             could not archive the document it just read.
///
///   warning — DEGRADED AND HANDLED, but what the user can expect has
///             changed. A retry is scheduled, a peer refused a link, one
///             connection lost a property the others keep. If nobody is
///             told and nothing retries, it is `error`.
///
///   info    — a STATE TRANSITION worth having in a timeline when someone
///             later asks what this machine was doing. Not per-event.
///
///   debug   — flow detail.
///
/// THE TEST, when it is unclear: assume nobody reads the line. If the
/// system still ends up correct — a retry fires, the caller got a failure
/// back — it is `warning`. If the only consequence is somebody confused
/// later by behaviour nothing explains, it is `error`.
///
/// TWO CHANNELS, TWO QUESTIONS — AND THEY MUST NOT CARRY THE SAME TEXT.
///
/// These lines answer WHY: cause and identifiers — the error, the path,
/// the host id, the code. Their reader is whoever is debugging, in
/// Console.app or `log stream --predicate 'subsystem ==
/// "com.synapty.app"'`, possibly hours later, possibly after the app is
/// gone. That last part is why this channel cannot be replaced by an
/// in-app view: a UI cannot report its own absence, and a crash or a hang
/// is exactly when someone needs the record. It is also the only channel
/// that interleaves with SSH, sandbox and network lines from the rest of
/// the system, which is where half this product's failures actually live.
/// The `privacy: .public` annotations exist for this reader; without them
/// the values are redacted and the line stops answering anything.
///
/// The UI answers WHAT: consequence and next step, on the object it
/// happened to, for the person using the app right now.
///
/// The same failure should produce BOTH, and the two strings must differ.
/// One string used in both places gives the two familiar bad outcomes — a
/// dialog reading `NSCocoaErrorDomain Code=513`, or a log line reading
/// "something went wrong" — each being the other audience's answer handed
/// to the wrong reader.
///
/// WHICH FAILURES EARN A UI: the `error` set above. A broken promise or a
/// feature that silently did not happen is what a human needs to see.
/// Same rule, different rendering.
///
/// WHERE THIS SIDE STANDS TODAY. The hub writes 79 lines across twelve
/// files; this side wrote eight across ten thousand, with thirteen of
/// fifteen services silent. The UI half is thinner still: `HostSidebar`
/// renders a failed tunnel correctly — danger chip, the reason inline, an
/// accessibility label — and that pattern is used for tunnels and nothing
/// else. Every `.alert` in the app is a confirmation dialog; not one
/// reports a failure. So the vocabulary is right and under-applied, which
/// is a wiring problem rather than a design one.
enum AppLog {
    static let agentMonitor = Logger(subsystem: "com.synapty.app", category: "AgentMonitor")
    static let taskMonitor = Logger(subsystem: "com.synapty.app", category: "TaskMonitor")
    static let tunnelManager = Logger(subsystem: "com.synapty.app", category: "TunnelManager")
    static let hostStore = Logger(subsystem: "com.synapty.app", category: "HostStore")
    static let hubManager = Logger(subsystem: "com.synapty.app", category: "HubManager")
    static let sessionStore = Logger(subsystem: "com.synapty.app", category: "WorkspaceStore")
    static let settings = Logger(subsystem: "com.synapty.app", category: "Settings")
    static let sync = Logger(subsystem: "com.synapty.app", category: "Sync")
    static let transfer = Logger(subsystem: "com.synapty.app", category: "Transfer")
    static let search = Logger(subsystem: "com.synapty.app", category: "Search")
    /// scenePhase transitions and what they triggered ([[WI-2026-09-02-032]]):
    /// the one record that says whether losing focus tears the world down.
    static let lifecycle = Logger(subsystem: "com.synapty.app", category: "Lifecycle")
}
