import Foundation

/// GO TO PANE ([[WI-2026-09-02-007]]): what the ⌘K palette knows about an
/// open pane, and how a query is held against it.
///
/// WITH A DOZEN PANES ACROSS HOSTS THE EYE CANNOT FIND ONE. The palette
/// already ranks hosts; a pane is the other thing a human reaches for by
/// name, and everything a row needs is already in the workspace model —
/// the label the tab shows, the live title the tooltip carries, the host
/// the pane is on, the agent registered in it. This type is the pure
/// half: candidates in, ranked matches out, so the ranking is testable
/// without a view or a manager.
enum PaneSearch {

    struct Candidate: Equatable, Identifiable {
        let id: UUID
        /// What the tab shows ([[WorkspaceManager.displayLabel]]).
        var label: String
        /// The half the tab is not showing — the live title, or the stored
        /// default for a renamed pane ([[WorkspaceManager.tabTooltip]]).
        var title: String = ""
        var host: String = ""
        var agent: String = ""
        var workspace: String = ""
    }

    /// A LABEL THAT STARTS WITH THE QUERY OUTRANKS ONE THAT CONTAINS IT,
    /// and either outranks a match found only in the title, host or agent
    /// — the label is what the human sees on the tab and is likeliest to
    /// be typing. Ties keep the caller's order, which is the workspaces'
    /// own. Nil means no match anywhere; a whitespace-only query matches
    /// nothing, since the empty palette lists hosts, not panes.
    static func score(_ query: String, against c: Candidate) -> Int? {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }
        let label = c.label.lowercased()
        if label.hasPrefix(needle) { return 3 }
        if label.contains(needle) { return 2 }
        for field in [c.title, c.host, c.agent, c.workspace] where field.lowercased().contains(needle) {
            return 1
        }
        return nil
    }

    static func rank(_ query: String, in candidates: [Candidate]) -> [Candidate] {
        candidates.compactMap { c in score(query, against: c).map { (c, $0) } }
            .enumerated()
            .sorted { a, b in
                a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
            }
            .map(\.element.0)
    }
}
