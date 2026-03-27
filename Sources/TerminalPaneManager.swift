import Foundation

/// Manages the set of active terminal panes for V1 multi-pane support.
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

    @Published var panes: [Pane] = []
    @Published var activePaneID: UUID?

    /// The currently displayed pane, or nil when the list is empty.
    var activePane: Pane? {
        guard let id = activePaneID else { return panes.first }
        return panes.first { $0.id == id }
    }

    init() {
        // Start with one local shell pane
        addLocalPane()
    }

    func addLocalPane() {
        let pane = Pane(label: "Local")
        panes.append(pane)
        activePaneID = pane.id
    }

    func addRemotePane(label: String, command: String) {
        let pane = Pane(label: label, command: command)
        panes.append(pane)
        activePaneID = pane.id
    }

    func removePane(_ pane: Pane) {
        panes.removeAll { $0.id == pane.id }
        if activePaneID == pane.id {
            activePaneID = panes.last?.id
        }
    }

    func activate(_ pane: Pane) {
        activePaneID = pane.id
    }
}
