import XCTest
@testable import Synapty

/// WHAT A KEY MEANS ONCE THE INPUT SYSTEM HAS HAD IT.
///
/// These cannot be driven from a synthesised NSEvent: what makes the
/// interesting case interesting is the INPUT METHOD's behaviour — it
/// consumes a key, changes its own preedit, and hands nothing back — and
/// no event this test could build would provoke that. So the rule is a
/// pure function and this drives it directly.
final class TerminalInputTests: XCTestCase {

    typealias D = GhosttyNSView.KeyDisposition

    /// AN ORDINARY KEY. No composition anywhere near it.
    func testAPlainKeyIsSentWithWhateverTextTheInputSystemMade() {
        XCTAssertEqual(
            GhosttyNSView.disposition(wasComposing: false, isComposing: false, committed: "a"),
            D.send(text: "a"))
        // And a key that produced no text — an arrow, a function key — is
        // still sent, so Ghostty can encode it from the keycode.
        XCTAssertEqual(
            GhosttyNSView.disposition(wasComposing: false, isComposing: false, committed: nil),
            D.send(text: nil))
    }

    /// MID-COMPOSITION. Each keystroke changes the candidate and reaches
    /// the terminal as nothing; the preedit is drawn from the preedit API.
    func testAKeyThatOnlyMovesTheCandidateReachesTheTerminalAsNothing() {
        XCTAssertEqual(
            GhosttyNSView.disposition(wasComposing: true, isComposing: true, committed: nil),
            D.composing)
        // Including the first keystroke of a composition, where nothing
        // was composing until this key started it.
        XCTAssertEqual(
            GhosttyNSView.disposition(wasComposing: false, isComposing: true, committed: nil),
            D.composing)
    }

    /// THE REPORTED BUG. Composing, then backspace until the candidate is
    /// empty: on that last press the IME consumes the key and clears its
    /// own preedit, so a check made AFTER the input system sees no marked
    /// text — and the key was encoded, and the terminal deleted a
    /// character the human had already committed.
    func testCancellingTheLastCandidateCharacterDoesNotReachTheTerminal() {
        XCTAssertEqual(
            GhosttyNSView.disposition(wasComposing: true, isComposing: false, committed: nil),
            D.composing,
            "the backspace that emptied the candidate deleted committed text")
    }

    /// AND THE REPAIR MUST NOT EAT THE COMMIT. Choosing a candidate also
    /// ends the composition, so treating "was composing" as composing
    /// outright would suppress the text as well — and Chinese input would
    /// stop producing anything at all.
    func testChoosingACandidateStillTypesIt() {
        XCTAssertEqual(
            GhosttyNSView.disposition(wasComposing: true, isComposing: false, committed: "你好"),
            D.send(text: "你好"))
    }

    /// A COMMIT THAT LEAVES A NEW COMPOSITION BEHIND, which some input
    /// methods do: the text is what matters, and it is sent.
    func testTextCommittedWhileACandidateRemainsIsStillSent() {
        XCTAssertEqual(
            GhosttyNSView.disposition(wasComposing: true, isComposing: true, committed: "你"),
            D.send(text: "你"))
    }
}
