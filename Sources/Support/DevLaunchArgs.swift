import Foundation

/// Dev/test launch arguments — the screenshot-driven visual-iteration
/// toolkit (WI-2026-08-09-014). Every dev arg parses HERE; feature code
/// reads the typed properties instead of scanning ProcessInfo, so this
/// table is the complete inventory:
///
///     open Synapty.app --args --page hosts --hosts-pane forwarding
///
/// | Argument                  | Effect                                                  |
/// |---------------------------|---------------------------------------------------------|
/// | --page <name>             | Land on a page: terminal / hosts / tasks / settings.    |
/// |                           | Retired names hub/activity degrade to tasks (WI-…-007). |
/// | --hosts-pane <tab>        | Hosts workbench tab: hosts / identities / forwarding.   |
/// | --hosts-inspector <panel> | Open an editor: new-host / new-group / new-identity.    |
/// | --quick-connect           | Open the ⌘K quick-connect palette.                      |
/// | --hub-popover             | Open the status-bar Hub popover (3s delay — presenting  |
/// |                           | during first layout detaches the popover).              |
/// | --toast                   | Post one of each outcome, to look at the stack.         |
/// | --panel <view>            | Open the right panel (appearance is its one occupant).  |
/// | --pane <kind>             | Open a pane at launch: terminal / files / services /    |
/// |                           | browser.                                               |
/// | --panel-host <uuid>       | Point the panel at a host.                              |
/// | --expose <port>           | Expose a remote port through the real forward path,     |
/// |                           | so the web view has a page to render (3s delay — the    |
/// |                           | ControlMaster must be up first).                        |
/// | --tabs <N>                | Open N-1 extra tabs in the first session.               |
/// | --pane-command <cmd>      | The command a `--pane terminal` runs instead of the     |
/// |                           | shell — the only way to PUT CONTENT IN A TERMINAL       |
/// |                           | without accessibility, which any scrollback/search/     |
/// |                           | render verification needs.                              |
/// | --find <needle>           | Open the find bar on the focused pane with the needle   |
/// |                           | already searched (5s delay — the pane and its output    |
/// |                           | must exist first). The bar itself opens only on ⌘F.     |
/// | --layout <preset>         | Build a 3-leaf split, then apply the preset:            |
/// |                           | columns / rows / grid / mainStack.                      |
/// | --quick-connect-query <q> | With --quick-connect: the palette opens with q typed.   |
/// | --broadcast               | With --layout: arm broadcast on the visible panes (the  |
/// |                           | tab marks and the top-bar switch are what a screenshot  |
/// |                           | checks).                                                |
/// | --zoom                    | With --layout: zoom the focused position once the       |
/// |                           | arrangement is applied (the zoom mark and the           |
/// |                           | full-area frame are what a screenshot checks).          |
///
/// Values stay raw Strings; call sites map them onto their own enums
/// (AppPage, HostsPane, LayoutPreset) so this file has no UI imports.
///
/// WHAT EARNS A ROW HERE, because without a rule this table only grows —
/// every one of these is product surface that ships, and nothing ever
/// removes an argument that once helped somebody:
///
///   1. The state is reachable ONLY by a pointer, so no screenshot and no
///      test can otherwise see it.
///   2. The surface is still changing, so it will be looked at again.
///
/// An argument that fails (2) is scaffolding: it earned its keep once and
/// is now a line in a table nobody can judge. `--goto` was removed under
/// this rule — it existed to prove that navigating collapses an expanded
/// panel, and that behaviour is now pinned by a unit test, leaving the
/// argument with nothing only it can do.
///
/// DRIVE THE REAL PATH. `--expose` calls the forward service rather than
/// fabricating an exposure: an argument that manufactures state proves the
/// renderer works on data nothing produced.
enum DevLaunchArgs {
    private static let args = ProcessInfo.processInfo.arguments

    /// The value following a `--flag`, if present.
    private static func value(after flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    /// `--page <name>` — initial page.
    static let page: String? = value(after: "--page")

    /// `--hosts-pane <tab>` — initial Hosts workbench tab (one-shot).
    static let hostsPane: String? = value(after: "--hosts-pane")

    /// `--settings-pane <pane>` — which Settings pane to open
    /// (terminal|keys|agents|network|github). The pane is view state with
    /// no persisted key, so a screenshot of anything but the first one is
    /// otherwise unreachable without accessibility.
    static let settingsPane: String? = value(after: "--settings-pane")

    /// `--hosts-inspector <panel>` — open a create-editor at launch.
    static let hostsInspector: String? = value(after: "--hosts-inspector")

    /// `--pane-command <cmd>` — what a `--pane terminal` runs.
    static let paneCommand: String? = value(after: "--pane-command")

    /// `--find <needle>` — open the find bar pre-searched.
    static let find: String? = value(after: "--find")

    /// `--quick-connect` — open the ⌘K palette at launch.
    static let quickConnect: Bool = args.contains("--quick-connect")

    /// `--quick-connect-query <text>` — the palette opens with this typed,
    /// so a screenshot can show the rows a query produces (pane rows,
    /// [[WI-2026-09-02-007]]) without a keyboard.
    static let quickConnectQuery: String? = value(after: "--quick-connect-query")

    /// `--hub-popover` — open the status-bar Hub popover at launch.
    static let hubPopover: Bool = args.contains("--hub-popover")

    /// `--enrol-sheet` — open the ADR-0009 "Authorize a Mac" sheet on the
    /// first host card at launch. It is otherwise reachable only by a
    /// mouse click, which makes it unverifiable from a screenshot.
    static let enrolSheet: Bool = args.contains("--enrol-sheet")

    /// `--toast` — post one of each outcome at launch.
    ///
    /// The stack is otherwise reachable only by completing a real
    /// transfer, which needs a drag or a remote agent — so its layout,
    /// the thing most likely to be wrong, could not be looked at.
    static let toast: Bool = args.contains("--toast")

    /// `--panel <view>` — open the right panel.
    static let panel: String? = value(after: "--panel")

    /// `--pane <kind>` — open a pane of this kind at launch
    /// ([[RFC-0015]] C-CONTENT).
    ///
    /// The kinds that are not terminals are reachable only through a
    /// press-and-hold menu, which needs accessibility this machine does
    /// not grant — so without this there is no way to SEE one rendered,
    /// and "it compiles and the model is tested" is not the same claim.
    static let pane: String? = value(after: "--pane")

    /// `--panel-host <uuid>` — point the panel at a host.
    static let panelHost: String? = value(after: "--panel-host")

    /// `--expose <port>` — expose that remote port on the panel's host at
    /// launch, through the real forward path.
    ///
    /// The web view's one job is to RENDER A PAGE, and until this existed
    /// nothing could make it do so without a click: a page appears there
    /// only after an agent on a remote host runs `synapty expose`. The
    /// forward mechanism and the CLI hop were each verified alone, and the
    /// join — a page actually on screen — was verified by nothing. Same
    /// reason as `--enrol-sheet`.
    ///
    /// It calls `PortForwardService.expose` rather than appending an
    /// exposure: a hook that fabricated one would prove the renderer works
    /// on a URL nothing produced.
    static let expose: Int? = value(after: "--expose").flatMap(Int.init)

    /// `--tabs <N>` — extra tabs in the first session.
    static let tabs: Int? = value(after: "--tabs").flatMap(Int.init)

    /// `--layout <preset>` — split + arrange demo.
    static let layout: String? = value(after: "--layout")

    /// `--zoom` — zoom the focused position after `--layout` lands.
    static let zoom: Bool = args.contains("--zoom")

    /// `--broadcast` — arm every visible pane after `--layout` lands.
    static let broadcast: Bool = args.contains("--broadcast")

    /// `--hint-level session|tab|pane` — pin the modifier-hold hint badges
    /// on for screenshots (WI-2026-08-09-015).
    static let hintLevel: String? = value(after: "--hint-level")

    /// `--attention` — mark a background leaf as needing attention
    /// (WI-2026-08-09-021 cascade screenshots).
    static let attention: Bool = args.contains("--attention")

    /// `--sync-preflight` — ask CloudKit whether it is reachable, print
    /// the answer, and exit. Exists so the sandbox question (does CloudKit
    /// on macOS require App Sandbox?) is answered by a signed, notarized
    /// build in one launch, rather than after a sync engine is written
    /// against an assumption.
    static let syncPreflight: Bool = args.contains("--sync-preflight")
}
