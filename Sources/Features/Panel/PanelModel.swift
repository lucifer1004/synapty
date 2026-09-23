import Foundation
import Observation

/// What the right panel is showing.
///
/// THE PANEL'S SUBJECT IS SOMETHING THE HUMAN IS NOT TYPING INTO — a
/// remote host, or the application's own appearance. That is what makes it
/// the right home for a second host's files while the middle of the window
/// stays on the session being worked in, and it is the admission rule:
/// anything that changes when the active session changes belongs in the
/// session, not here ([[ADR-0010]]).
///
/// ONE OCCUPANT, and it is the one the panel was built for. This carried
/// three — appearance, a host's files, and its exposed web services —
/// which meant three unrelated subjects competing for one strip of chrome
/// and a segmented control to arbitrate between them.
///
/// Files and web are panes now ([[RFC-0015]] C-CONTENT): they are ABOUT a
/// machine, so they belong in the layout where they can be split, moved,
/// and set beside the terminal writing what they show.
///
/// Appearance stays because it is about the APPLICATION rather than any
/// machine — it has no connection to bind to, so it cannot be a pane —
/// and because judging a theme, a font and an opacity means seeing them
/// against a live terminal while you change them. Settings would take the
/// one workflow it has.
///
/// The type survives its own collapse to one case so the panel keeps its
/// persisted width and open state, and so a second occupant that is
/// genuinely application-scoped has somewhere to go.
enum PanelOccupant: String, CaseIterable, Identifiable, Sendable {
    case appearance

    var id: String { rawValue }
    var title: String { "Appearance" }
    var icon: String { "slider.horizontal.3" }
}

/// The panel's own state, persisted.
///
/// ONE WIDTH FOR THE PANEL, not one per view. Per-view widths made the
/// panel jump every time the human switched tabs, because a width clamped
/// to what THIS view wanted moved the whole edge when the next view wanted
/// something else. Width belongs to the furniture; the content caps its
/// own column and leaves the rest as margin.
///
/// Its own type rather than `@AppStorage` because "which view was open, and
/// how wide" is exactly the kind of state this application has already lost
/// once by keeping it somewhere that forgot.
@MainActor @Observable final class PanelModel {

    /// nil means closed.
    private(set) var occupant: PanelOccupant?

    private let defaults: UserDefaults
    private var storedWidth: Double?

    /// Wide enough for the roomiest occupant's minimum, so every view is
    /// usable at every width the human can choose. A shared range is the
    /// point: a range that changed with the content is what made the edge
    /// move.
    static let minWidth: Double = 300
    static let defaultWidth: Double = 360

    /// Appearance is a column of controls, not a canvas: past this it is
    /// stretched labels and nothing gained. It caps itself and leaves the
    /// rest as margin, so widening the panel does not deform it.
    static let appearanceContentWidth: Double = 320

    /// What a terminal still needs to be a terminal.
    ///
    /// THE CEILING EXISTS TO PROTECT THE TERMINAL, NOT THE PANEL. Narrowing
    /// a pane is not "smaller" — it is a SIGWINCH and a reflow, which
    /// rewraps scrollback and rearranges whatever TUI is running in it. So
    /// the drag stops where the terminal stops being usable, and the human
    /// who wants more than that gets it by covering the terminal rather
    /// than by crushing it (`isExpanded`).
    static let minTerminalWidth: Double = 360

    /// A CEILING IN POINTS WAS ARBITRARY. It was 640, which is a number and
    /// not an argument: a file list is fine there and a web page is not.
    /// What can actually be justified is how much room the thing NEXT to
    /// the panel needs, so the limit follows the window.
    static func maxWidth(in available: Double) -> Double {
        max(minWidth, available - minTerminalWidth)
    }

    private static let occupantKey = "synapty.panelOccupant"
    private static let widthKey = "synapty.panelWidth"
    private static let expandedKey = "synapty.panelExpanded"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Self.occupantKey) {
            occupant = PanelOccupant(rawValue: raw)
        }

        isExpanded = defaults.bool(forKey: Self.expandedKey)
        storedWidth = defaults.object(forKey: Self.widthKey) as? Double
    }

    var isOpen: Bool { occupant != nil }

    func show(_ next: PanelOccupant) {
        occupant = next
        persistOccupant()
    }

    func close() {
        occupant = nil
        persistOccupant()
    }

    /// Pressing the same occupant that is already showing closes the panel;
    /// pressing a different one switches to it without closing. A toggle
    /// that always closed would make switching views a two-step.
    func toggle(_ next: PanelOccupant) {
        if occupant == next { close() } else { show(next) }
    }

    /// COVERS THE TERMINAL, DOES NOT SQUEEZE IT. A panel that took the
    /// whole width by growing would resize the pane beside it to nothing
    /// and reflow it; drawn on top, the terminal keeps the size it had and
    /// never learns anything happened.
    private(set) var isExpanded = false

    func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    /// NAVIGATING SOMEWHERE COLLAPSES IT. An expanded panel covers the
    /// content column, so a human who clicks Hosts while it is up gets no
    /// answer at all — the page they asked for is drawn underneath and
    /// nothing tells them why. Taking the panel down is what makes the
    /// click mean what it says.
    ///
    /// It does not come back on the way to the terminal. Restoring it
    /// would make the panel reappear over a pane they navigated to, which
    /// is the same dead end arriving a second time.
    func collapse() {
        guard isExpanded else { return }
        setExpanded(false)
    }

    private func setExpanded(_ value: Bool) {
        isExpanded = value
        defaults.set(value, forKey: Self.expandedKey)
    }

    /// The panel's width. The same number whatever is showing, so switching
    /// views never moves the edge.
    ///
    /// `available` is the room the panel and its neighbour share. It is a
    /// parameter rather than state because the window can be resized while
    /// nothing here is touched, and a width clamped against a stale figure
    /// is the same class of bug as the two coordinate systems in
    /// [[WI-2026-08-15-009]].
    func width(in available: Double) -> Double {
        clamp(storedWidth ?? Self.defaultWidth, in: available)
    }

    func setWidth(_ value: Double, in available: Double) {
        let clamped = clamp(value, in: available)
        storedWidth = clamped
        // STORED UNCLAMPED-BY-WINDOW would be better still, but the value
        // the human dragged to IS what they chose at this window size;
        // widening the window later reopens the room, and the stored
        // number is only ever re-clamped upward.
        defaults.set(clamped, forKey: Self.widthKey)
    }

    private func clamp(_ value: Double, in available: Double) -> Double {
        min(max(value, Self.minWidth), Self.maxWidth(in: available))
    }

    private func persistOccupant() {
        if let occupant {
            defaults.set(occupant.rawValue, forKey: Self.occupantKey)
        } else {
            // Never chosen and closed are the same state — `init` reads a
            // missing key as no occupant — so closing removes the key.
            defaults.removeObject(forKey: Self.occupantKey)
        }
    }
}
