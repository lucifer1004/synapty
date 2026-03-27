import Foundation

/// Manages a three-level hierarchy: Sessions (sidebar) → Panes (tabs).
/// Each session is connected to a host and contains 1+ terminal panes.
class TerminalPaneManager: ObservableObject {

    struct Pane: Identifiable {
        let id: UUID
        let label: String
        /// nil = default shell; non-nil = command string passed to the surface
        let command: String?

        init(label: String, command: String? = nil) {
            self.id = UUID()
            self.label = label
            self.command = command
        }
    }

    struct Session: Identifiable {
        let id: UUID
        let label: String
        /// The deploy command template for this host, nil for local.
        let hostCommand: String?
        var panes: [Pane]
        var activePaneID: UUID?

        var activePane: Pane? {
            guard let id = activePaneID else { return panes.first }
            return panes.first { $0.id == id }
        }

        /// All panes across all sessions (for ZStack rendering).
        var isLocal: Bool { hostCommand == nil }

        init(label: String, hostCommand: String? = nil) {
            self.id = UUID()
            self.label = label
            self.hostCommand = hostCommand
            // Start with one pane
            let pane = Pane(label: "Shell", command: hostCommand)
            self.panes = [pane]
            self.activePaneID = pane.id
        }
    }

    @Published var sessions: [Session] = []
    @Published var activeSessionID: UUID?

    var activeSession: Session? {
        guard let id = activeSessionID else { return sessions.first }
        return sessions.first { $0.id == id }
    }

    /// All panes across all sessions — used for the ZStack that keeps surfaces alive.
    var allPanes: [Pane] {
        sessions.flatMap { $0.panes }
    }

    /// The currently visible pane (active pane in active session).
    var visiblePaneID: UUID? {
        activeSession?.activePaneID
    }

    init() {
        addLocalSession()
    }

    // MARK: - Session management

    func addLocalSession() {
        let session = Session(label: "Local")
        sessions.append(session)
        activeSessionID = session.id
    }

    func addRemoteSession(label: String, command: String) {
        let session = Session(label: label, hostCommand: command)
        sessions.append(session)
        activeSessionID = session.id
    }

    func removeSession(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.last?.id
        }
    }

    func activateSession(_ session: Session) {
        activeSessionID = session.id
    }

    // MARK: - Pane management (within active session)

    func addPaneToActiveSession() {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        let session = sessions[idx]
        let pane = Pane(label: "Shell \(session.panes.count + 1)", command: session.hostCommand)
        sessions[idx].panes.append(pane)
        sessions[idx].activePaneID = pane.id
    }

    func removePane(_ pane: Pane) {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[idx].panes.removeAll { $0.id == pane.id }
        if sessions[idx].activePaneID == pane.id {
            sessions[idx].activePaneID = sessions[idx].panes.last?.id
        }
        // Remove session if no panes left
        if sessions[idx].panes.isEmpty {
            let session = sessions[idx]
            removeSession(session)
        }
    }

    func activatePane(_ pane: Pane) {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[idx].activePaneID = pane.id
    }

    // MARK: - Legacy compatibility

    /// Flat list of all panes — used by old code paths.
    var panes: [Pane] { allPanes }
    var activePaneID: UUID? {
        get { visiblePaneID }
        set {
            // Find which session contains this pane and activate both
            guard let newID = newValue else { return }
            for i in sessions.indices {
                if sessions[i].panes.contains(where: { $0.id == newID }) {
                    activeSessionID = sessions[i].id
                    sessions[i].activePaneID = newID
                    return
                }
            }
        }
    }
}
