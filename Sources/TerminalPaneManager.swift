import Foundation

/// Manages a three-level hierarchy: Sessions (sidebar) → Panes (tabs) → Splits (tree).
/// Each session is connected to a host. Each pane has a split tree of terminal surfaces.
class TerminalPaneManager: ObservableObject {

    struct Pane: Identifiable {
        let id: UUID
        let label: String
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

    struct Session: Identifiable {
        let id: UUID
        let label: String
        /// The host entry for remote sessions, nil for local.
        let hostEntry: HostEntry?
        var panes: [Pane]
        var activePaneID: UUID?

        var activePane: Pane? {
            guard let id = activePaneID else { return panes.first }
            return panes.first { $0.id == id }
        }

        var isLocal: Bool { hostEntry == nil }

        init(label: String, hostEntry: HostEntry? = nil, initialCommand: String? = nil) {
            self.id = UUID()
            self.label = label
            self.hostEntry = hostEntry
            let pane = Pane(label: "Shell", command: initialCommand)
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

    /// The active pane in the active session.
    var activePane: Pane? {
        activeSession?.activePane
    }

    /// All leaf IDs across all sessions — used for the ZStack.
    var allLeaves: [SplitNode.LeafData] {
        sessions.flatMap { session in
            session.panes.flatMap { pane in
                pane.splitRoot.leaves
            }
        }
    }

    /// The currently visible/focused leaf ID.
    var visibleLeafID: UUID? {
        activePane?.focusedLeafID
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

    func addRemoteSession(label: String, hostEntry: HostEntry, command: String) {
        let session = Session(label: label, hostEntry: hostEntry, initialCommand: command)
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

    // MARK: - Pane management

    func addPaneToActiveSession() {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        let session = sessions[sIdx]
        // For remote sessions, generate a new connect command with unique agent ID.
        let command: String?
        if let hostEntry = session.hostEntry {
            command = TunnelManager.shared?.connectCommand(for: hostEntry)
        } else {
            command = nil // local
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

        // For remote sessions, generate a new connect command with unique agent ID.
        let command: String?
        if let hostEntry = sessions[sIdx].hostEntry {
            command = TunnelManager.shared?.connectCommand(for: hostEntry)
        } else {
            command = nil
        }
        let newRoot = sessions[sIdx].panes[pIdx].splitRoot.splitLeaf(
            focusedID,
            direction: direction,
            newLeafCommand: command
        )
        sessions[sIdx].panes[pIdx].splitRoot = newRoot

        // Focus the new leaf (second child of the new split)
        if case .split(let data) = newRoot {
            // The new leaf is somewhere in the tree — find the leaf that wasn't there before
            let oldLeaves = Set(sessions[sIdx].panes[pIdx].splitRoot.leafIDs)
            // Actually, find it from the new root
            let newLeaves = newRoot.leafIDs
            let newLeafID = newLeaves.first { !sessions[sIdx].panes[pIdx].splitRoot.leafIDs.contains($0) }
            // The splitLeaf method adds the new leaf as second child. Find it by traversal.
            _ = data // suppress unused warning
        }
        // Simpler: the new root has one more leaf than before. Find it.
        sessions[sIdx].panes[pIdx].splitRoot = newRoot
        let allLeafIDs = newRoot.leafIDs
        // The new leaf is the last one added (second child is appended at end in leafIDs)
        if let newLeafID = allLeafIDs.last, newLeafID != focusedID {
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
