import Foundation

/// One row of a directory listing.
///
/// A MODEL AND NOT A VIEW DETAIL, which is why it lives here: the listing
/// is cached per leaf so a pane the human comes back to can show what it
/// last saw while it checks ([[WorkspaceManager.FileNavigation]]), and a
/// cache the manager cannot name is a cache that has to live in the view
/// it was supposed to outlive.
struct BrowsedFile: Identifiable, Equatable {
    var name: String
    var size: Int64?
    var modified: Date?
    var isDirectory: Bool
    /// A SYMLINK, and `isDirectory` already says what it POINTS AT
    /// ([[WI-2026-08-29-002]]). Carried separately because the two are
    /// different questions: whether the row can be entered, and whether
    /// what the human is looking at is the thing or a name for it.
    var isSymlink: Bool = false
    /// A link whose target is not there. The one case where nothing can
    /// say what kind of thing it was.
    var isBrokenLink: Bool = false
    var id: String { name }

    /// What to draw for this row.
    var kind: FileKind { FileKind.of(name: name, isDirectory: isDirectory) }
}
