import SwiftUI

/// THE MENU BAR, assembled from [[MenuLayout]].
///
/// EVERY ITEM IS A ROW OF THE TABLE ([[RFC-0016]] C-TABLE): its label, its
/// chord and what it does all come from [[KeyCommandTable]] by identifier,
/// so this file decides nothing about keys. WHICH MENU an item is in comes
/// from [[MenuLayout]], which is also where the Keys pane reads the path
/// it prints — so the two cannot disagree, and they had.
///
/// THE CHORDS SHOWN HERE NEVER FIRE. [[KeyDispatcher]]'s monitor consumes
/// the event before the window offers it to a menu, which is what makes
/// the table the sole authority; the equivalent survives because it is
/// what the human READS ([[RFC-0016]] C-DISCOVERY).
struct SynaptyCommands: Commands {
    var body: some Commands {
        // BOUND FROM THE TUPLE [[MenuLayout.sections]], whose arity is part
        // of its type: adding a section there and not here fails to build.
        // `@CommandsBuilder` admits no loop, so the bindings are still
        // written out — what changes is that the LIST is not.
        let (file, help, goTo, terminal, view) = MenuLayout.sections
        MenuSectionCommands(section: file)
        MenuSectionCommands(section: help)
        MenuSectionCommands(section: goTo)
        MenuSectionCommands(section: terminal)
        MenuSectionCommands(section: view)
    }
}

/// ONE SECTION OF [[MenuLayout]], attached where the section says.
struct MenuSectionCommands: Commands {
    let section: MenuSection

    var body: some Commands {
        if let placement = section.replacing {
            CommandGroup(replacing: placement) {
                MenuEntryItems(entries: section.entries)
            }
        } else {
            CommandMenu(section.title) {
                MenuEntryItems(entries: section.entries)
            }
        }
    }
}

/// The entries of a menu or submenu as menu items.
struct MenuEntryItems: View {
    let entries: [MenuEntry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            item(entry)
        }
    }

    @ViewBuilder
    private func item(_ entry: MenuEntry) -> some View {
        switch entry {
        case .command(let id):
            KeyCommandMenuItem(id: id)
        case .separator:
            DSHairline()
        case .submenu(let title, let nested):
            Menu(title) { MenuEntryItems(entries: nested) }
        }
    }
}

// MARK: - Notification names for menu → ContentView communication

extension Notification.Name {
    static let synaptyNewSession = Notification.Name("synaptyNewSession")
    static let synaptyShowShortcuts = Notification.Name("synaptyShowShortcuts")
    static let synaptyFind = Notification.Name("synaptyFind")
    static let synaptyTunnelFailed = Notification.Name("synaptyTunnelFailed")
    static let synaptySettingsChanged = Notification.Name("synaptySettingsChanged")
    static let synaptyAppearanceChanged = Notification.Name("synaptyAppearanceChanged")
    static let synaptyReloadRequested = Notification.Name("synaptyReloadRequested")
    static let synaptyToggleSettingsPanel = Notification.Name("synaptyToggleSettingsPanel")
    static let synaptyToggleHiddenFiles = Notification.Name("synaptyToggleHiddenFiles")
    /// The human went to look at what agents have exposed. Posted only by
    /// a human's click — never by an arriving exposure, which must not
    /// open anything ([[RFC-0013]] C-REQUEST-NOT-SEIZE).
    static let synaptyShowExposures = Notification.Name("synaptyShowExposures")
    /// The human went to answer what agents are waiting on. Posted only by
    /// their click — a request never opens its own sheet.
    static let synaptyShowApprovals = Notification.Name("synaptyShowApprovals")
    static let synaptyToggleSidebar = Notification.Name("synaptyToggleSidebar")
    /// Go-to menu / clickable badges → page switch; userInfo["page"] is the
    /// AppPage raw value (WI-2026-08-08-053).
    static let synaptyShowPage = Notification.Name("synaptyShowPage")
    /// App UI font scale changed — repaint chrome (WI-2026-08-08-070).
    /// GhosttyApp.shared was just assigned — the terminal placeholder must
    /// re-render (cold start, WI-2026-08-08-079).
    static let synaptyGhosttyReady = Notification.Name("synaptyGhosttyReady")
    /// Cmd+K quick-connect palette (WI-2026-08-09-003).
    static let synaptyQuickConnect = Notification.Name("synaptyQuickConnect")
    /// Open the host editor for an existing host; userInfo["id"] is the
    /// host UUID string ("Save as Host…" flow, WI-2026-08-09-003).
    static let synaptyEditHost = Notification.Name("synaptyEditHost")
}

/// WHICH MACHINE'S EXPOSURES THE HUMAN ASKED TO SEE.
///
/// A box rather than a bare `UUID?`, because `nil` inside it means THIS
/// MAC while a missing object would mean nothing was named — and the two
/// have to be told apart by whatever opens the pane
/// ([[WI-2026-08-28-009]]).
struct ExposureDestination {
    let hostID: UUID?
}
