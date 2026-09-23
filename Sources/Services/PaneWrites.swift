import Foundation

/// WHAT A FILE PANE MAY DO TO ITS MACHINE, and what it must ask first
/// ([[RFC-0015]] C-PANE-WRITES).
///
/// THE RULES ARE HERE AND NOT IN THE VIEW. Each of them is a sentence in
/// the clause that a dialog can quietly fail to honour — a confirmation
/// skipped, a machine unnamed, a collision resolved by overwriting — and
/// none of those failures look like anything on screen. Written as values
/// a test can put a case to, they cannot be skipped by drawing the wrong
/// button.
enum PaneWrites {

    /// WHERE A DELETION GOES, which is the whole of the split C-PANE-WRITES
    /// draws.
    enum Disposal: Equatable {
        /// The platform can take it back. Local only.
        case trash
        /// It is gone. Every other connection.
        case unrecoverable
    }

    /// A DESKTOP TRASH THE WORKBENCH CANNOT RESTORE FROM IS NOT AN UNDO IT
    /// CAN OFFER.
    ///
    /// The clause forbids exempting a remote machine on the grounds that
    /// it has a trash of its own — and that prohibition is the point:
    /// the rule would otherwise skip the confirmation on exactly the
    /// machines that need it, since a modern Linux desktop does have a
    /// `~/.local/share/Trash` and this application can neither see into it
    /// nor put anything back.
    static func disposal(isLocal: Bool) -> Disposal {
        guard isLocal else { return .unrecoverable }
        return .trash
    }

    /// WHETHER TO ASK. A confirmation on a reversible act is what teaches a
    /// human to dismiss the one that matters, so the local Trash path is
    /// NOT confirmed — deliberately, and not as an oversight to be
    /// tightened later.
    static func confirms(_ disposal: Disposal) -> Bool {
        disposal == .unrecoverable
    }

    /// WHAT THE QUESTION SAYS.
    ///
    /// "Delete 3 items?" tells a human with file leaves open on three
    /// machines nothing at all. The machine is named, and the absence of a
    /// recoverable copy is STATED rather than implied by the presence of a
    /// dialog — a human who has learnt that dialogs are noise reads the
    /// words or nothing.
    static func deletionQuestion(count: Int, machine: String) -> String {
        let subject = count == 1 ? "this item" : "these \(count) items"
        return "Delete \(subject) on \(machine)?"
    }

    static func deletionDetail(machine: String) -> String {
        "There is no Trash on \(machine) that Synapty can restore from. "
            + "This cannot be undone."
    }

    /// A WRITE THAT WOULD REPLACE SOMETHING IS A DESTRUCTION.
    ///
    /// Renaming onto an existing name destroys what was there, and so does
    /// creating over it. Neither is a transfer, so [[RFC-0013]]
    /// C-AUTHORIZATION's replacement rules do not reach them — which is
    /// why the question is asked here.
    static func replacementQuestion(name: String, machine: String) -> String {
        "\"\(name)\" already exists on \(machine). Replace it?"
    }

    static func replacementDetail(disposal: Disposal, machine: String) -> String {
        switch disposal {
        case .trash:
            // The recoverable copy is kept because the platform can keep
            // it; the question is still asked because a replacement is not
            // obviously a deletion.
            return "The existing \"\(machine)\" copy moves to the Trash."
        case .unrecoverable:
            return "The bytes that are there now are gone. This cannot be undone."
        }
    }

    /// ONE PRIMITIVE THIS MAC UNDERSTANDS, for a rename in the file pane.
    ///
    /// `moveItem` THROWS WHEN THE DESTINATION EXISTS, so "Replace it?"
    /// answered yes has to dispose of what is there first — and the sheet
    /// has already told the human where it goes. Written as steps so the
    /// decision can be asserted without putting anything in a human's
    /// Trash on every suite run ([[WI-2026-08-28-008]]).
    enum LocalStep: Equatable {
        case trash(String)
        case move(from: String, to: String)
    }

    static func renameSteps(from: String, to: String, replacing: Bool) -> [LocalStep] {
        (replacing ? [.trash(to)] : []) + [.move(from: from, to: to)]
    }

    /// A FAILED LISTING NAMES THE MACHINE IT FAILED ON.
    ///
    /// [[RFC-0015]] C-DERIVED requires a taken action that fails to say so
    /// and to name the machine — a pane opened from a path an agent
    /// printed can land on a directory that is not there, and "cannot read
    /// this folder" without a machine leaves the human checking the wrong
    /// computer. The local case says nothing extra, because there is only
    /// one answer to which machine it was.
    static func listingFailureTitle(machine: String?) -> String {
        guard let machine else { return "Cannot read this folder" }
        return "Cannot read this folder on \(machine)"
    }

    /// THE SAFE OUTCOME IS THE DEFAULT. A dialog whose default button
    /// destroys something is a dialog that destroys things whenever a
    /// human presses Return out of habit.
    static let safeAnswer = "Cancel"
    static let destructiveAnswer = "Replace"
    static let deleteAnswer = "Delete"
}
