import Foundation

/// WHERE A FILE PANE IS, WHAT IS ON ITS SCREEN, AND WHAT IS BEING TYPED
/// INTO IT — as values, so the ways those three can disagree are not
/// expressible.
///
/// THIS EXISTS BECAUSE THEY DISAGREED, four times.
///
/// The view held five strings — where we are, where we are going, which
/// directory the rows came from, what is being typed, where the leaf says
/// we are — and every defect this pane has shipped was two of them drifting
/// apart:
///
/// - rows from the destination drawn while the pane still named the origin,
///   so clicking one asked for `<origin>/<name from destination>`;
/// - a rename computing its target from a different string than the row it
///   was renaming;
/// - a draft that outlived the navigation that left it behind;
/// - the same draft still on screen two seconds later, because it ended
///   when the pane ARRIVED rather than when it left.
///
/// None of those are visible to a test that can only ask the model what it
/// holds. Three of the four stop being possible here.

/// The rows on screen and the directory they came from: ONE value.
///
/// A ROW MEANS A CHILD OF THE DIRECTORY THE ROW CAME FROM. That sentence
/// is the whole reason these two are not separate properties — held apart,
/// they were assigned in five places and agreed in four of them.
struct Listing: Equatable {
    var path: String
    var files: [BrowsedFile] = []

    func child(_ name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }
}

/// Settled somewhere, or on the way there.
enum Whereabouts: Equatable {

    /// The rows came from this directory and the pane is in it.
    case at(Listing)

    /// In flight.
    ///
    /// `from` IS WHERE THE PANE STILL IS — a listing that fails moves
    /// nobody, and without this the failure had nowhere to fall back to.
    ///
    /// `preview` is the destination's rows out of the leaf's cache, put up
    /// immediately so that walking back through directories already visited
    /// is not a sequence of empty panes. It is the destination's rows, so
    /// while it is showing, the directory the rows belong to is `to` — and
    /// that is derived below rather than stored, which is what makes the
    /// mismatch unrepresentable.
    case going(to: String, from: Listing, preview: [BrowsedFile]?)

    /// WHAT IS ON SCREEN, AND WHERE IT CAME FROM. Everything a row does —
    /// opening it, dragging it, renaming it, deleting it — resolves against
    /// this and nothing else.
    var showing: Listing {
        switch self {
        case .at(let listing):
            return listing
        case .going(let to, let from, let preview):
            guard let preview else { return from }
            return Listing(path: to, files: preview)
        }
    }

    /// Where the pane still is, which is not always what it is showing.
    var origin: Listing {
        switch self {
        case .at(let listing): return listing
        case .going(_, let from, _): return from
        }
    }

    /// The destination, while there is one.
    var destination: String? {
        guard case .going(let to, _, _) = self else { return nil }
        return to
    }

    var isLoading: Bool { destination != nil }

    /// The directory a load should ask the machine for.
    var target: String { destination ?? origin.path }

    /// What the address bar says when nothing is being typed into it.
    ///
    /// THE DESTINATION WINS. A pane in flight is going somewhere, and an
    /// address bar that names the origin until the answer arrives is a bar
    /// that lags the click that moved it.
    var address: String { destination ?? showing.path }

    mutating func depart(for target: String, cached: [BrowsedFile]?) {
        self = .going(to: target, from: origin, preview: cached)
    }

    mutating func arrive(at canonical: String, files: [BrowsedFile]) {
        self = .at(Listing(path: canonical, files: files))
    }

    /// A DIRECTORY THAT COULD NOT BE READ MOVES NOBODY, and leaves nothing
    /// on screen that belongs anywhere.
    ///
    /// Both halves matter. The pane stays where it was, so the human has
    /// not been silently relocated by a typo; and the rows go, because a
    /// preview of a directory that turned out to be unreachable is a set of
    /// rows whose parent does not exist — clickable, and clickable onto
    /// nothing.
    mutating func fail() {
        self = .at(Listing(path: origin.path, files: []))
    }
}

/// The pane's whereabouts and the half-typed path together, because the one
/// rule that binds them is a rule about both.
struct FileBrowsing: Equatable {

    var here: Whereabouts = .at(Listing(path: "~"))

    /// The path the human is typing, while they are typing it. Not the
    /// leaf's business: an unsubmitted path names nowhere.
    var draft: String?

    var address: String { draft ?? here.address }

    /// A DRAFT ENDS AT DEPARTURE, NOT AT ARRIVAL.
    ///
    /// Ended on arrival, it outlived the whole round trip: back was
    /// pressed, the pane started moving, the rows changed — and the address
    /// bar went on showing the abandoned string for the two seconds the
    /// host took to answer. Leaving is already enough to know the draft is
    /// over, and it is the only moment both facts are in one place.
    mutating func navigate(to target: String, cached: [BrowsedFile]? = nil) {
        draft = nil
        here.depart(for: target, cached: cached)
    }
}
