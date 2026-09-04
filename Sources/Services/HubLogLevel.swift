import Foundation

/// Push the log level to every hub this workbench operates
/// ([[RFC-0012]] C-LEVEL-CONTROL).
///
/// EVERY HUB IT OPERATES means this machine's and each peer hub the
/// workbench holds a direct connection to — the same connections the
/// merged multi-hub view already uses, which exist because the workbench
/// established the tunnel. Deliberately NOT the relay link: RFC-0009
/// C-BOUNDARIES scopes relay to identities and mail, and a control frame
/// is neither. The workbench's relationship to a peer hub here is
/// operator, not peer.
///
/// A dedicated frame rather than a field on `hub_info`, because a frame
/// named for asking must not also set — the next reader could not tell
/// which calls are safe to repeat.
enum HubLogLevel {

    static let levels = ["err", "warn", "info", "debug"]

    /// Ports this workbench currently operates: its own hub, plus every
    /// peer's loopback end. Read at call time rather than cached — a peer
    /// linked after the last change must still receive the level.
    @MainActor
    static func operatedPorts() -> [Int] {
        guard let tm = TunnelManager.shared else { return [] }
        // This machine's hub, plus every peer that has actually answered.
        // A peer that has never reported itself has no hub to tell.
        var ports: [Int] = [tm.hubPort]
        ports.append(contentsOf: tm.peerSummaries.filter { $0.linked }.map { $0.loopbackPort })
        return Array(Set(ports)).sorted()
    }

    @MainActor
    static func applyEverywhere(_ level: String) {
        guard accepted(level) else { return }
        for port in operatedPorts() { apply(level, port: port) }
    }

    /// A HUB THIS WORKBENCH HAS JUST REACHED IS TOLD WHAT THE HUMAN SET.
    ///
    /// THE OTHER HALF OF [[RFC-0012]] C-LEVEL-CONTROL, and it was written
    /// down twice and implemented nowhere: `operatedPorts`' comment says a
    /// peer linked later "must still receive the level", and `apply`'s
    /// says failures are not retried because "the level is re-sent
    /// whenever a hub is (re)connected". Nothing re-sent it. The only
    /// caller was `logLevel.didSet`, which `isLoading` suppresses at
    /// launch — so a human who set debug, quit and relaunched had a hub
    /// that deliberately outlived the workbench ([[ADR-0008]]) sitting at
    /// its default forever, and every peer linked afterwards too
    /// ([[WI-2026-08-30-008]]).
    ///
    /// ONE PORT AND NOT A RE-BROADCAST: the moment is a hub JOINING, so
    /// telling the others again is noise that grows with the fleet.
    @MainActor
    static func applyCurrent(port: Int) {
        let level = SynaptySettings.shared.logLevel
        guard accepted(level) else { return }
        apply(level, port: port)
    }

    /// The one gate on what may be sent, so a level neither entry point
    /// can put an unknown word on the wire.
    private static func accepted(_ level: String) -> Bool {
        guard levels.contains(level) else {
            AppLog.settings.error("refusing an unknown log level \(level, privacy: .public)")
            return false
        }
        return true
    }

    /// Send to one hub. Failures are logged and not retried: the level is
    /// re-sent whenever it changes and whenever a hub is (re)connected, so
    /// a hub that missed one gets the next. A retry loop here would be
    /// machinery for a problem that resolves itself.
    static func apply(_ level: String, port: Int) {
        DispatchQueue.global(qos: .utility).async {
            guard let sock = HubEventClient.connectLoopback(port: port) else { return }
            defer { close(sock) }
            let envelope: [String: Any] = [
                "type": "set_log_level", "id": "set-log-level",
                "source": "workbench", "target": "",
                "payload": ["level": level],
            ]
            guard let bytes = try? JSONSerialization.data(withJSONObject: envelope),
                  HubEventClient.writeAll(sock, Array(bytes) + [0x0A])
            else { return }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var resp = [UInt8](repeating: 0, count: 512)
            _ = read(sock, &resp, resp.count)
        }
    }

    /// What the interface must say alongside the control, because both
    /// are limits the app cannot lift and presenting them as covered
    /// would be the overstatement RFC-0012 exists to remove.
    static let caveats = [
        "A hub started before this workbench reached it runs at its default until then — including one that restarted itself after a reboot.",
        "Raising to debug also needs a system-level change this app cannot make: log config --mode 'level:debug' --subsystem com.synapty.app",
    ]
}
