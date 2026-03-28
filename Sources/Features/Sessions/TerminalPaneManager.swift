import Foundation

/// Manages a three-level hierarchy: Sessions (sidebar) → Panes (tabs) → Splits (tree).
/// Each session is connected to a host. Each pane has a split tree of terminal surfaces.
@MainActor final class TerminalPaneManager: ObservableObject, TerminalCoordinator {

    // MARK: - TerminalCoordinator

    func requestSplit(direction: SplitNode.SplitDirection) {
        splitFocusedLeaf(direction: direction)
    }

    func requestCloseSplit() {
        closeFocusedLeaf()
    }

    func requestFocusNextSplit() {
        focusNextLeaf()
    }

    func requestFocusPreviousSplit() {
        focusPreviousLeaf()
    }

    func leafDidFocus(_ leafID: UUID) {
        focusLeaf(leafID)
    }

    func leafDidClose(_ leafID: UUID) {
        closeLeaf(leafID)
    }

    struct Pane: Identifiable {
        let id: UUID
        var label: String
        /// The host command template, nil for local.
        let hostCommand: String?
        /// The split tree root. Starts as a single leaf.
        var splitRoot: SplitNode
        /// Which leaf surface is focused within this pane.
        var focusedLeafID: UUID?

        init(label: String, command: String? = nil) {
            self.id = UUID()
            self.label = label
            self.hostCommand = command
            let leaf = SplitNode.LeafData(command: command)
            self.splitRoot = .leaf(leaf)
            self.focusedLeafID = leaf.id
        }
    }

    /// Session connection state.
    enum SessionState: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    struct Session: Identifiable {
        let id: UUID
        var label: String
        /// The host entry for remote sessions, nil for local.
        let hostEntry: HostEntry?
        /// The synapty agent ID for this session (e.g., "local-37cb").
        let agentID: String?
        /// Connection state — connecting shows placeholder in sidebar.
        var state: SessionState
        var panes: [Pane]
        var activePaneID: UUID?

        var activePane: Pane? {
            guard let id = activePaneID else { return panes.first }
            return panes.first { $0.id == id }
        }

        var isLocal: Bool { hostEntry == nil }

        init(label: String, hostEntry: HostEntry? = nil, agentID: String? = nil, state: SessionState = .connected, initialCommand: String? = nil) {
            self.id = UUID()
            self.label = label
            self.hostEntry = hostEntry
            self.agentID = agentID
            self.state = state
            let pane = Pane(label: "Shell", command: initialCommand)
            self.panes = [pane]
            self.activePaneID = pane.id
        }
    }

    @Published var sessions: [Session] = []
    @Published var activeSessionID: UUID?
    /// Tracks session count per label prefix for auto-incrementing names.
    private var labelCounter: [String: Int] = [:]

    var activeSession: Session? {
        guard let id = activeSessionID else { return sessions.first }
        return sessions.first { $0.id == id }
    }

    var activePane: Pane? {
        activeSession?.activePane
    }

    var allLeaves: [SplitNode.LeafData] {
        sessions.flatMap { session in
            session.panes.flatMap { pane in
                pane.splitRoot.leaves
            }
        }
    }

    var visibleLeafID: UUID? {
        activePane?.focusedLeafID
    }

    init() {}

    // MARK: - Label generation

    /// Generate an auto-incrementing label: "Local", "Local 2", "Local 3", etc.
    private func nextLabel(for prefix: String) -> String {
        let count = (labelCounter[prefix] ?? 0) + 1
        labelCounter[prefix] = count
        return count == 1 ? prefix : "\(prefix) \(count)"
    }

    // MARK: - Session management

    func addLocalSession() {
        let result = TunnelManager.shared?.localCommand()
        let label = nextLabel(for: "Local")
        let session = Session(label: label, agentID: result?.agentID, initialCommand: result?.command)
        sessions.append(session)
        activeSessionID = session.id
    }

    /// Create a remote session immediately in .connecting state, then update when ready.
    func addRemoteSessionPlaceholder(label: String, hostEntry: HostEntry) -> UUID {
        let sessionLabel = nextLabel(for: label)
        let session = Session(label: sessionLabel, hostEntry: hostEntry, state: .connecting)
        sessions.append(session)
        activeSessionID = session.id
        return session.id
    }

    /// Update a connecting session to connected with the actual command and agent ID.
    func connectSession(id: UUID, command: String, agentID: String?) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].state = .connected
        sessions[idx] = Session(
            label: sessions[idx].label,
            hostEntry: sessions[idx].hostEntry,
            agentID: agentID,
            state: .connected,
            initialCommand: command
        )
        // Preserve the same ID by replacing inline — the UUID changes but that's OK
        // since we re-assign activeSessionID.
        activeSessionID = sessions[idx].id
    }

    /// Mark a connecting session as failed.
    func failSession(id: UUID, error: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].state = .failed(error)
    }

    func addRemoteSession(label: String, hostEntry: HostEntry, command: String, agentID: String? = nil) {
        let sessionLabel = nextLabel(for: label)
        let session = Session(label: sessionLabel, hostEntry: hostEntry, agentID: agentID, initialCommand: command)
        sessions.append(session)
        activeSessionID = session.id
    }

    // MARK: - Rename

    func renameSession(_ sessionID: UUID, to newLabel: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].label = newLabel
    }

    func renamePane(_ paneID: UUID, to newLabel: String) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }),
              let pIdx = sessions[sIdx].panes.firstIndex(where: { $0.id == paneID }) else { return }
        sessions[sIdx].panes[pIdx].label = newLabel
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

    // MARK: - Pane management

    func addPaneToActiveSession() {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        let session = sessions[sIdx]
        // Generate a new command with unique agent ID for every pane.
        let command: String?
        if let hostEntry = session.hostEntry {
            command = TunnelManager.shared?.connectCommand(for: hostEntry).command
        } else {
            command = TunnelManager.shared?.localCommand().command
        }
        let pane = Pane(label: "Shell \(session.panes.count + 1)", command: command)
        sessions[sIdx].panes.append(pane)
        sessions[sIdx].activePaneID = pane.id
    }

    func removePane(_ pane: Pane) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[sIdx].panes.removeAll { $0.id == pane.id }
        if sessions[sIdx].activePaneID == pane.id {
            sessions[sIdx].activePaneID = sessions[sIdx].panes.last?.id
        }
        if sessions[sIdx].panes.isEmpty {
            let session = sessions[sIdx]
            removeSession(session)
        }
    }

    func activatePane(_ pane: Pane) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[sIdx].activePaneID = pane.id
    }

    // MARK: - Split management

    /// Split the focused leaf in the active pane.
    func splitFocusedLeaf(direction: SplitNode.SplitDirection) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }),
              let pIdx = sessions[sIdx].panes.firstIndex(where: { $0.id == sessions[sIdx].activePaneID }),
              let focusedID = sessions[sIdx].panes[pIdx].focusedLeafID else { return }

        // Generate a new command with unique agent ID for every split.
        let command: String?
        if let hostEntry = sessions[sIdx].hostEntry {
            command = TunnelManager.shared?.connectCommand(for: hostEntry).command
        } else {
            command = TunnelManager.shared?.localCommand().command
        }
        let (newRoot, newLeafID) = sessions[sIdx].panes[pIdx].splitRoot.splitLeaf(
            focusedID,
            direction: direction,
            newLeafCommand: command
        )
        sessions[sIdx].panes[pIdx].splitRoot = newRoot
        if let newLeafID {
            sessions[sIdx].panes[pIdx].focusedLeafID = newLeafID
        }
    }

    /// Close the focused leaf in the active pane. If it's the last leaf, close the pane.
    func closeFocusedLeaf() {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }),
              let pIdx = sessions[sIdx].panes.firstIndex(where: { $0.id == sessions[sIdx].activePaneID }),
              let focusedID = sessions[sIdx].panes[pIdx].focusedLeafID else { return }

        let root = sessions[sIdx].panes[pIdx].splitRoot

        // If it's the only leaf, close the pane
        if case .leaf = root {
            let pane = sessions[sIdx].panes[pIdx]
            removePane(pane)
            return
        }

        // Remove the leaf and collapse the parent split
        if let newRoot = root.removeLeaf(focusedID) {
            sessions[sIdx].panes[pIdx].splitRoot = newRoot
            // Focus the first remaining leaf
            sessions[sIdx].panes[pIdx].focusedLeafID = newRoot.leaves.first?.id
        }
    }

    /// Close a specific leaf by ID (called when its process exits).
    func closeLeaf(_ leafID: UUID) {
        for sIdx in sessions.indices {
            for pIdx in sessions[sIdx].panes.indices {
                let root = sessions[sIdx].panes[pIdx].splitRoot
                if root.findLeaf(leafID) != nil {
                    // If it's the only leaf, close the pane
                    if case .leaf = root {
                        let pane = sessions[sIdx].panes[pIdx]
                        sessions[sIdx].panes.removeAll { $0.id == pane.id }
                        if sessions[sIdx].activePaneID == pane.id {
                            sessions[sIdx].activePaneID = sessions[sIdx].panes.last?.id
                        }
                        if sessions[sIdx].panes.isEmpty {
                            let session = sessions[sIdx]
                            sessions.removeAll { $0.id == session.id }
                            if activeSessionID == session.id {
                                activeSessionID = sessions.last?.id
                            }
                        }
                        return
                    }
                    // Remove the leaf and collapse
                    if let newRoot = root.removeLeaf(leafID) {
                        sessions[sIdx].panes[pIdx].splitRoot = newRoot
                        if sessions[sIdx].panes[pIdx].focusedLeafID == leafID {
                            sessions[sIdx].panes[pIdx].focusedLeafID = newRoot.leaves.first?.id
                        }
                    }
                    return
                }
            }
        }
    }

    /// Navigate focus to the next/previous split leaf.
    func focusNextLeaf() {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }),
              let pIdx = sessions[sIdx].panes.firstIndex(where: { $0.id == sessions[sIdx].activePaneID }),
              let focusedID = sessions[sIdx].panes[pIdx].focusedLeafID else { return }

        let root = sessions[sIdx].panes[pIdx].splitRoot
        if let nextID = root.nextLeaf(after: focusedID) {
            sessions[sIdx].panes[pIdx].focusedLeafID = nextID
        }
    }

    func focusPreviousLeaf() {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }),
              let pIdx = sessions[sIdx].panes.firstIndex(where: { $0.id == sessions[sIdx].activePaneID }),
              let focusedID = sessions[sIdx].panes[pIdx].focusedLeafID else { return }

        let root = sessions[sIdx].panes[pIdx].splitRoot
        if let prevID = root.previousLeaf(before: focusedID) {
            sessions[sIdx].panes[pIdx].focusedLeafID = prevID
        }
    }

    /// Update the split ratio for a split node.
    func resizeSplit(splitID: UUID, ratio: CGFloat) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }),
              let pIdx = sessions[sIdx].panes.firstIndex(where: { $0.id == sessions[sIdx].activePaneID }) else { return }
        sessions[sIdx].panes[pIdx].splitRoot.setRatio(splitID: splitID, ratio: ratio)
    }

    /// Set focus to a specific leaf (called from surface becomeFirstResponder).
    func focusLeaf(_ leafID: UUID) {
        for sIdx in sessions.indices {
            for pIdx in sessions[sIdx].panes.indices {
                if sessions[sIdx].panes[pIdx].splitRoot.findLeaf(leafID) != nil {
                    sessions[sIdx].panes[pIdx].focusedLeafID = leafID
                    sessions[sIdx].activePaneID = sessions[sIdx].panes[pIdx].id
                    activeSessionID = sessions[sIdx].id
                    return
                }
            }
        }
    }

    // MARK: - Legacy compatibility

    var panes: [Pane] {
        sessions.flatMap { $0.panes }
    }

    var activePaneID: UUID? {
        get { activeSession?.activePaneID }
        set {
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
