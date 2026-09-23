import SwiftUI

/// AN ENTRY OF A MENU: a command, a rule between groups, or a submenu.
enum MenuEntry {
    case command(String)
    case separator
    case submenu(title: String, entries: [MenuEntry])
}

/// ONE MENU OF THE BAR.
struct MenuSection {
    /// The title as the human reads it in the bar. For a section that
    /// REPLACES one of the platform's groups this is the title macOS
    /// already gives that menu — carried here because it is the first
    /// word of the path a human is told to walk, and nothing else in the
    /// process knows it.
    let title: String
    /// The platform group this section replaces, or nil for a menu of our
    /// own.
    let replacing: CommandGroupPlacement?
    let entries: [MenuEntry]

    init(title: String, replacing: CommandGroupPlacement? = nil, entries: [MenuEntry]) {
        self.title = title
        self.replacing = replacing
        self.entries = entries
    }
}

/// WHERE EVERY MENU-BAR COMMAND IS, said once.
///
/// [[SynaptyCommands]] BUILDS the menus from this and the Keys pane READS
/// the path out of it ([[RFC-0016]] C-UNBOUND), so a command cannot
/// advertise a menu it is not in. It used to be able to, and did: the
/// table said "View ▸ Split Right" for two commands built into the File
/// menu, and told the human so in the moment they needed it right — the
/// Keys pane prints the path under a command whose chord is cleared.
///
/// A command's own label is NOT written here. The menu item's label is
/// `KeyCommandTable.name(of:)`, so the last segment of the path is the
/// row's `name` and appending it is the only way it stays that.
enum MenuLayout {

    static let file = MenuSection(
        title: "File", replacing: .newItem,
        entries: [
            .command("workspace.new"),
            .command("pane.new"),
            .separator,
            .command("pane.split-right"),
            .command("pane.split-down"),
            .separator,
            .command("workspace.close-pane"),
            .command("workspace.archive-pane"),
        ])

    static let help = MenuSection(
        title: "Help", replacing: .help,
        entries: [.command("help.shortcuts")])

    /// Every jump the workbench offers, which is also the only way to
    /// reach the two families that used to live in an event monitor with
    /// no menu item at all ([[RFC-0016]] C-UNBOUND).
    static let goTo = MenuSection(
        title: "Go to",
        entries: [
            .command("palette.quick-connect"),
            .separator,
            .command("slot.focus-next"),
            .command("slot.focus-previous"),
            .command("pane.next"),
            .command("pane.previous"),
            .separator,
        ]
        + AppPage.allCases.map { .command("page.\($0.rawValue)") }
        + [
            .separator,
            .submenu(title: "Workspace",
                     entries: (1..<10).map { .command("workspace.select-\($0)") }),
            .submenu(title: "Pane",
                     entries: (1..<10).map { .command("pane.select-\($0)") }),
            .submenu(title: "Slot",
                     entries: (1..<10).map { .command("slot.select-\($0)") }),
        ])

    /// THE TERMINAL'S OWN ACTS, in a menu of their own rather than in the
    /// platform's Edit menu. An Edit ▸ Copy carrying this table's chord
    /// would take ⌘C away from every text field the moment a human
    /// rebound terminal copy, which [[RFC-0016]] C-TABLE's OUT list
    /// forbids — so the platform's verbs stay where they are and these
    /// sit beside them.
    static let terminal = MenuSection(
        title: "Terminal",
        entries: [
            .command("terminal.copy"),
            .command("terminal.paste"),
            .separator,
            .command("terminal.find"),
            .command("terminal.find-next"),
            .command("terminal.find-previous"),
            .command("terminal.clear"),
            .separator,
            .command("terminal.font-increase"),
            .command("terminal.font-decrease"),
            .command("terminal.font-reset"),
        ])

    static let view = MenuSection(
        title: "View",
        entries: [
            .command("sidebar.toggle"),
            .separator,
        ]
        + SplitNode.LayoutPreset.allCases.map { .command("layout.\($0.rawValue)") }
        + [
            .command("layout.zoom"),
            .command("layout.equalize"),
            .command("layout.grow-left"),
            .command("layout.grow-right"),
            .command("layout.grow-up"),
            .command("layout.grow-down"),
            .separator,
            .command("layout.broadcast"),
            .separator,
            .command("settings.toggle-panel"),
            .command("files.show-hidden"),
        ])

    /// EVERY MENU THIS WORKBENCH HAS, as a tuple.
    ///
    /// A TUPLE BECAUSE ITS ARITY IS PART OF ITS TYPE. The list was written
    /// out twice — here, and again in [[SynaptyCommands]] where each
    /// section becomes an actual menu — so a section added to one and not
    /// the other exists in the path the Keys pane prints and in no menu a
    /// human can open ([[RFC-0016]] C-DISCOVERY, [[WI-2026-08-30-008]]).
    /// Destructuring a tuple fails to build when its arity changes, which
    /// is what makes the second site notice.
    ///
    /// WHAT THE COMPILER DOES NOT HOLD is the PAIRING: nothing here stops
    /// `body` binding the wrong element to the wrong menu. `MenuBarTests`
    /// is what holds that.
    static let sections = (file: file, help: help, goTo: goTo, terminal: terminal, view: view)

    /// The same menus as a list, derived so it cannot fall behind them.
    static let all: [MenuSection] = Mirror(reflecting: sections)
        .children.compactMap { $0.value as? MenuSection }

    /// The menus that lead to `id`, outermost first, WITHOUT the command's
    /// own label — or nil if nothing in the bar invokes it.
    static func chain(of id: String) -> [String]? {
        for section in all {
            if let rest = chain(of: id, in: section.entries) {
                return [section.title] + rest
            }
        }
        return nil
    }

    private static func chain(of id: String, in entries: [MenuEntry]) -> [String]? {
        for entry in entries {
            switch entry {
            case .command(let found) where found == id:
                return []
            case .submenu(let title, let nested):
                if let rest = chain(of: id, in: nested) { return [title] + rest }
            case .command, .separator:
                continue
            }
        }
        return nil
    }

    /// Every command identifier the bar invokes, in no particular order.
    static var placedCommandIDs: [String] {
        all.flatMap { ids(in: $0.entries) }
    }

    private static func ids(in entries: [MenuEntry]) -> [String] {
        entries.flatMap { entry -> [String] in
            switch entry {
            case .command(let id): return [id]
            case .separator: return []
            case .submenu(_, let nested): return ids(in: nested)
            }
        }
    }
}
