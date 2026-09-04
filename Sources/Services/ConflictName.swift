import Foundation

/// A name that does not collide with one already there.
///
/// SILENT OVERWRITE IS THE WORST OF THE THREE OUTCOMES. A refused transfer
/// is visible; a renamed one is visible; a file replaced by another of the
/// same name is not, and the thing it destroyed is gone with no record
/// that it existed.
///
/// The agent inbox makes this ordinary rather than rare: it is ONE
/// directory shared by every agent on a machine, so two agents each
/// running `present ./report.html` collide by default, and the second
/// silently erased the first.
///
/// FINDER'S SHAPE, because the human already reads it: `report.html`
/// becomes `report 2.html`, then `report 3.html`. The extension is
/// preserved — a `.html` that became `report.html 2` stops opening in the
/// thing that opens html.
enum ConflictName {

    /// A DOTFILE HAS NO EXTENSION, it has a name that starts with a dot.
    /// `NSString.pathExtension` disagrees — it reads `.zshrc` as extension
    /// "zshrc" — and taking its word produces ` 2.zshrc`, a different file
    /// entirely rather than a second copy of this one.
    static func split(_ name: String) -> (base: String, ext: String) {
        if name.hasPrefix("."), !name.dropFirst().contains(".") {
            return (name, "")
        }
        return ((name as NSString).deletingPathExtension, (name as NSString).pathExtension)
    }

    /// The first name in the series that `isTaken` says is free.
    ///
    /// `isTaken` is a closure rather than a filesystem call because the
    /// destination may be on another machine, where "does this exist" is a
    /// round trip and not a stat — and because the rule itself is worth
    /// testing without either.
    ///
    /// `isTaken` may throw, and the throw is passed through: a probe that
    /// cannot answer is not a name that is free, and pretending otherwise
    /// is the silent overwrite this type exists to prevent.
    ///
    /// `nil` when the series is exhausted. Bounded: a directory holding a
    /// thousand collisions is a fault to report, not a loop to run — and
    /// the name it must not report is the original, which is taken.
    static func available(for name: String, isTaken: (String) throws -> Bool) rethrows -> String? {
        guard try isTaken(name) else { return name }
        let (base, ext) = split(name)
        for n in 2...1000 {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if try !isTaken(candidate) { return candidate }
        }
        return nil
    }

}
