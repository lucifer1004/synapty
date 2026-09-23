import SwiftUI

/// FIND IN SCROLLBACK, DOCKED TO THE PANE IT SEARCHES
/// ([[WI-2026-08-20-001]]).
///
/// Ghostty's core does the searching, counts the matches and decides which
/// one is selected; the embedder supplies the bar. Each keystroke issues
/// `search:<needle>`, the arrows issue `navigate_search`, and closing
/// issues `end_search`.
///
/// THE COUNT AND THE ARROWS ARE NOT DECORATION. Without them this is a
/// text field that highlights something — a human cannot tell whether
/// there are two matches or two hundred, and cannot reach the next one.
/// They are what makes a find bar a find bar, and ghostty had been
/// reporting both to an embedder that ignored them.
struct FindBarView: View {
    @Binding var text: String
    let onTextChange: (String) -> Void
    let onClose: () -> Void
    /// WHEN THIS FIELD ACTUALLY HAS FOCUS, which is what row 2 of
    /// [[RFC-0016]] C-DISPATCH is defined over — not merely whether the
    /// bar is on screen. Reported from the field's own `@FocusState`,
    /// because nothing outside it knows.
    var onFocusChange: (Bool) -> Void = { _ in }
    var results: GhosttyApp.SearchResults = .init()
    var onNavigate: (Bool) -> Void = { _ in }

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.textSecondary)
            TextField("Find", text: $text)
                .textFieldStyle(.plain)
                .font(DS.Typography.mono)
                .frame(width: DS.scaled(150))
                .focused($focused)
                .onChange(of: text) { _, newValue in
                    onTextChange(newValue)
                }
                // ENTER GOES TO THE NEXT MATCH, which is what it does in
                // every find bar on this platform — re-running the same
                // search would leave the human pressing it and watching
                // nothing move.
                .onSubmit { onNavigate(true) }

            count

            DSIconButton(icon: "chevron.up",
                         help: CommandHint.help("Previous match", for: "terminal.find-previous"),
                         size: 18) {
                onNavigate(false)
            }
            .disabled(results.isEmpty)
            DSIconButton(icon: "chevron.down",
                         help: CommandHint.help("Next match", for: "terminal.find-next"),
                         size: 18) {
                onNavigate(true)
            }
            .disabled(results.isEmpty)
            DSIconButton(icon: "xmark", help: "Close search (esc)", size: 18) {
                onClose()
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs)
        // Shared floating chrome — same surface as the Cmd+K palette
        // (WI-2026-08-09-004).
        .dsFloatingPanel()
        .onExitCommand {
            onClose()
        }
        // FOCUS ASKED FOR ON THE NEXT TURN OF THE LOOP, not during the
        // update that creates the view. Set inline it did not take: the
        // terminal beside it had just yielded first responder and the
        // window handed the keyboard to the sidebar instead, so every
        // letter of the search went somewhere else. Measured through the
        // accessibility tree, which showed the sidebar's button holding
        // keyboard focus while this field held none.
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
        // REPORTED ON A FOCUS CHANGE, never from `onAppear`. Mutating
        // shared state during a view update invalidates that update, which
        // re-runs it, which fires the callback again — the application
        // never goes idle and the window stops answering. Measured, not
        // feared: claiming this from `onAppear` hung the app every time
        // the palette opened over the bar.
        .onChange(of: focused) { _, hasFocus in
            onFocusChange(hasFocus)
        }
        .onDisappear { onFocusChange(false) }
    }

    /// `3 / 12`, or the honest absence of it.
    ///
    /// THREE STATES AND NOT TWO: nothing typed yet says nothing at all,
    /// a needle with no matches says so in the danger colour, and a needle
    /// with matches counts them. Showing `0 / 0` for an empty field would
    /// report a failed search the human never ran.
    @ViewBuilder
    private var count: some View {
        if text.isEmpty {
            EmptyView()
        } else if results.isEmpty {
            Text("none")
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.danger)
        } else {
            Text("\(results.ordinal ?? 0) / \(results.total)")
                .font(DS.Typography.monoCaption)
                .foregroundStyle(DS.textSecondary)
                .monospacedDigit()
        }
    }
}
