import SwiftUI

/// WHERE THE HUMAN CHANGES A BINDING ([[RFC-0016]] C-REBIND) and where
/// every binding is shown ([[RFC-0016]] C-DISCOVERY).
///
/// EVERY COMMAND IN THE TABLE IS LISTED, INCLUDING THOSE HOLDING NOTHING.
/// Hiding a cleared command would make clearing a chord irreversible
/// through the very interface that performed it.
struct KeysSettingsView: View {
    var dispatcher = KeyDispatcher.shared

    /// Which command's row is listening. At most one, and while one is,
    /// nothing is dispatched — row 1 of [[RFC-0016]] C-DISPATCH's function.
    @State private var recording: String?
    /// The account of the last act, shown until the next one. A
    /// displacement MUST be named at the moment it happens, and a
    /// rejection MUST say which rule it failed.
    @State private var account: Account?
    /// Whether anything is overridden — read from disk on appear and
    /// after each commit, not decoded from keys.json on every body
    /// ([[WI-2026-09-02-026]]).
    @State private var hasOverrides = false

    private struct Account: Equatable {
        enum Tone { case plain, warning }
        let text: String
        let tone: Tone
    }

    var body: some View {
        Group {
            header
            // THE ACCOUNT OF THE LAST ACT. Required rather than
            // decorative: a displacement MUST name the command that lost
            // the chord AT THAT MOMENT ([[RFC-0016]] C-CONFLICT), and a
            // rejected keystroke MUST say which rule it failed
            // ([[RFC-0016]] C-REBIND). Computing both and showing neither
            // is the same as not having them.
            if let account {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: account.tone == .warning
                          ? "exclamationmark.triangle" : "checkmark.circle")
                    Text(account.text)
                    Spacer()
                }
                .font(DS.Typography.caption)
                .foregroundStyle(account.tone == .warning ? DS.danger : DS.textSecondary)
                .padding(DS.Space.sm)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(DS.surfaceRaised)
                )
            }
            // WHAT THE LOAD DROPPED OR TOOK AWAY, which [[RFC-0016]]
            // C-CONFLICT requires to be visible "where bindings are
            // shown". It was computed and shown nowhere, so a store with a
            // line this build cannot apply — a command that no longer
            // exists, a chord this workbench refuses — was silently
            // ignored, and a command left holding nothing by a collision
            // in the file was silently left that way
            // ([[Keymap.loadNotice]]).
            //
            // BESIDE THE ACCOUNT AND NOT INSTEAD OF IT: that one is about
            // the human's last act, this one about the file they arrived
            // with.
            if let notice = dispatcher.keymap.loadNotice {
                KeymapLoadNotice(text: notice)
            }
            // THE SAME CARD EVERY OTHER SETTINGS PANE USES. This pane
            // began as naked rows on the page background, which left the
            // name and its chord five hundred points apart with nothing
            // between them for the eye to follow — and made one pane of
            // one page disagree with the rest about what a settings group
            // looks like.
            ForEach(KeyCommandTable.groups, id: \.title) { group in
                DSSectionBlock(title: group.title) {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { DSHairline() }
                        rowView(entry)
                    }
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Keys")
                    .font(DS.Typography.bodyStrong)
                    .foregroundStyle(DS.textPrimary)
                // WHAT THE WORKBENCH MAY SAY, and no more ([[RFC-0016]]
                // C-HONESTY): a chord another application registered
                // system-wide never reaches this process, and nothing here
                // can tell that from a key nobody pressed. So the copy
                // offers the remedy rather than a diagnosis.
                Text("If a shortcut does nothing, another app may have taken it. Pick another one.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            Spacer()
            Button("Reset All") {
                var overrides = KeymapStore.load()
                KeymapEditor.recoverAllDefaults(in: &overrides)
                commit(overrides, saying: .init(text: "Every shortcut is back to its default.",
                                                tone: .plain))
            }
            .controlSize(.small)
            .disabled(!hasOverrides)
        }
        .onAppear { hasOverrides = !KeymapStore.load().isEmpty }
    }

    // MARK: - One row

    /// A ROW IS EITHER A COMMAND OR A FAMILY OF THEM.
    ///
    /// THREE FAMILIES OF NINE WERE TWENTY-SEVEN ROWS, listed interleaved
    /// by number — Workspace 1, Tab 1, Pane 1, Workspace 2 — because that
    /// is the order the table generates them in. Read top to bottom it is
    /// an alphabet soup, and it buried the dozen commands a human came
    /// here to change. A family collapses to one row showing the range it
    /// holds, and opens when asked.


    @ViewBuilder
    private func rowView(_ entry: KeyCommandTable.Entry) -> some View {
        switch entry {
        case .command(let command):
            row(command, indented: false)
        case .family(let family):
            familyRow(family)
            if expanded.contains(family.id) {
                ForEach(family.members, id: \.id) { command in
                    DSHairline()
                    memberRow(command)
                }
            }
        }
    }

    /// A FAMILY IS REBOUND AS A WHOLE, BY ITS MODIFIER ([[RFC-0016]]
    /// C-TABLE). The nine members are shown so the human can see which
    /// chords the modifier produces, and shown WITHOUT the controls that
    /// would rebind one of them — a family whose members carried different
    /// modifiers would be a set of bindings nobody could describe.
    @ViewBuilder
    private func familyRow(_ family: KeyCommandTable.Family) -> some View {
        let isOpen = expanded.contains(family.id)
        let isRecording = recording == family.id
        HStack(spacing: DS.Space.sm) {
            Button {
                if isOpen { expanded.remove(family.id) } else { expanded.insert(family.id) }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                        .frame(width: DS.scaled(12))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(family.name)
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.textPrimary)
                        Text("nine shortcuts, one modifier")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                isRecording ? stopRecording() : startRecordingFamily(family)
            } label: {
                if isRecording {
                    Text("Press a modifier + any number… esc to cancel")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.accent)
                } else if let range = family.rangeDisplay(dispatcher.keymap) {
                    DSKeycap(range)
                } else {
                    Text("mixed")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .frame(minWidth: DS.scaled(120), alignment: .trailing)
            Menu {
                Button("Reset to Default") {
                    var overrides = KeymapStore.load()
                    _ = KeymapEditor.recoverFamily(family.id, in: &overrides,
                                                   commands: KeyCommandTable.commands)
                    commit(overrides, saying: .init(text: "\(family.name) is back to its default.",
                                                    tone: .plain))
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(DS.textTertiary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, DS.Space.xxs)
    }

    private func startRecordingFamily(_ family: KeyCommandTable.Family) {
        recording = family.id
        account = nil
        dispatcher.beginRecording { chord in
            if chord.key == .named(.escape), chord.modifiers.isEmpty {
                stopRecording()
                return
            }
            var overrides = KeymapStore.load()
            switch KeymapEditor.recordFamily(chord.modifiers, family: family.id,
                                             in: &overrides,
                                             commands: KeyCommandTable.commands,
                                             effective: dispatcher.keymap) {
            case .notAChord:
                account = .init(text: "A shortcut needs ⌘, ⌃ or ⌥. Try again.", tone: .warning)
            case .refused:
                account = .init(text: "That belongs to the system here. Try another.", tone: .warning)
            default:
                commit(overrides, saying: .init(
                    text: "\(family.name) moved together.", tone: .plain))
                stopRecording()
            }
        }
    }

    /// SHOWN, NOT EDITABLE — [[RFC-0016]] C-TABLE: a family's members are
    /// listed so the human can see the nine chords, without the controls
    /// that would move one of them out of step with the rest.
    @ViewBuilder
    private func memberRow(_ command: KeyCommand) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text(command.name)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textSecondary)
            Spacer()
            if let chord = dispatcher.keymap.chord(of: command.id) {
                DSKeycap(chord.display)
            }
        }
        .padding(.leading, DS.Space.lg)
        .padding(.vertical, DS.Space.xxs)
    }

    @ViewBuilder
    private func row(_ command: KeyCommand, indented: Bool) -> some View {
        let isRecording = recording == command.id
        HStack(spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 0) {
                Text(command.name)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                // WHERE IT IS REACHED WITHOUT A KEYBOARD ([[RFC-0016]]
                // C-UNBOUND), shown where that is the question the human
                // has — which is a command holding nothing. Printed under
                // all thirty rows it doubled the height of the list and
                // made the one case that needs it invisible.
                if dispatcher.keymap.holdsNothing(command.id) {
                    Text(command.nonKeyboardPathDescription)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                }
            }
            Spacer()
            if dispatcher.keymap.differsFromDefault(command) {
                // VISIBLE WHERE BINDINGS ARE EDITED ([[RFC-0016]]
                // C-DISCOVERY), so a human can tell what they changed from
                // what shipped.
                Text("changed")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
            chordButton(command, isRecording: isRecording)
            // ON HOVER, AND STILL OCCUPYING ITS PLACE WHEN NOT. Two dozen
            // rows each carrying a permanent ⋯ was a column of noise beside
            // a column of content; hiding it by OPACITY rather than by
            // taking it out keeps every chord on one vertical line as the
            // pointer moves down the list.
            //
            // THE SAME ITEMS ARE ON THE ROW'S CONTEXT MENU, because a
            // control that exists only under a pointer is one a human
            // working any other way cannot reach.
            Menu {
                rowMenuItems(command)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(DS.textTertiary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovered == command.id ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = command.id }
            else if hovered == command.id { hovered = nil }
        }
        .contextMenu { rowMenuItems(command) }
        .padding(.leading, indented ? DS.Space.lg : 0)
        .padding(.vertical, DS.Space.xxs)
    }

    @ViewBuilder
    private func rowMenuItems(_ command: KeyCommand) -> some View {
        Button("Clear") {
            var overrides = KeymapStore.load()
            _ = KeymapEditor.clear(command.id, in: &overrides)
            commit(overrides, saying: .init(
                text: "\(command.name) has no shortcut. Reach it at \(command.nonKeyboardPathDescription).",
                tone: .plain))
        }
        .disabled(dispatcher.keymap.holdsNothing(command.id))
        Button("Reset to Default") { recover(command) }
            .disabled(!dispatcher.keymap.differsFromDefault(command))
    }

    /// The row the pointer is over — the only one showing its menu.
    @State private var hovered: String?


    /// Which families are open. Empty is the resting state: a human comes
    /// here for the dozen commands they use, not for the twenty-seven.
    @State private var expanded: Set<String> = []

    @ViewBuilder
    private func chordButton(_ command: KeyCommand, isRecording: Bool) -> some View {
        Button {
            isRecording ? stopRecording() : startRecording(command)
        } label: {
            if isRecording {
                // ESCAPE LEAVES WITH NOTHING CHANGED ([[RFC-0016]]
                // C-REBIND) — the surface's own way out, which is why
                // Escape cannot be recorded here.
                Text("Press a shortcut… esc to cancel")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.accent)
            } else if let chord = dispatcher.keymap.chord(of: command.id) {
                DSKeycap(chord.display)
            } else {
                Text("none")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: DS.scaled(120), alignment: .trailing)
    }

    // MARK: - The acts

    private func startRecording(_ command: KeyCommand) {
        recording = command.id
        account = nil
        // THE DISPATCHER IS THE ONLY READER of a keystroke while this is
        // listening ([[RFC-0016]] C-DISPATCH row 1), so the panel hands it
        // a place to put one rather than trying to read the keyboard from
        // inside a view the platform would also offer to the menus.
        dispatcher.beginRecording { chord in
            // ESCAPE LEAVES WITH NOTHING CHANGED, and is therefore not
            // recordable here ([[RFC-0016]] C-REBIND).
            if chord.key == .named(.escape), chord.modifiers.isEmpty {
                stopRecording()
                return
            }
            record(chord, for: command)
        }
    }

    private func stopRecording() {
        recording = nil
        dispatcher.endRecording()
    }

    private func record(_ chord: Chord, for command: KeyCommand) {
        var overrides = KeymapStore.load()
        switch KeymapEditor.record(chord, for: command.id,
                                   in: &overrides, effective: dispatcher.keymap) {
        case .notAChord:
            // REJECTION IS NOT THE END OF RECORDING: a human reaching for
            // a chord and pressing something that does not qualify has
            // made a typo, not a decision.
            account = .init(text: "A shortcut needs ⌘, ⌃ or ⌥. Try again.", tone: .warning)
        case .refused:
            account = .init(text: "\(chord.display) belongs to the system here. Try another.",
                            tone: .warning)
        case .recorded(let displaced):
            let name = displaced.map { KeyCommandTable.name(of: $0) }
            commit(overrides, saying: .init(
                text: name.map { "\($0) held \(chord.display); it now has no shortcut." }
                    ?? "\(command.name) is \(chord.display).",
                tone: name == nil ? .plain : .warning))
            stopRecording()
        default:
            break
        }
    }

    private func recover(_ command: KeyCommand) {
        var overrides = KeymapStore.load()
        switch KeymapEditor.recoverDefault(of: command.id, in: &overrides,
                                           commands: KeyCommandTable.commands,
                                           effective: dispatcher.keymap) {
        case .defaultHeldBy(let holder):
            // NAMED, because it is the one fact that lets the human act.
            account = .init(
                text: "\(KeyCommandTable.name(of: holder)) holds that shortcut. Change it first.",
                tone: .warning)
        default:
            commit(overrides, saying: .init(text: "\(command.name) is back to its default.",
                                            tone: .plain))
        }
    }

    /// WRITE, THEN REBUILD. The effective table is always built from the
    /// defaults and the current override set ([[RFC-0016]] C-CONFLICT), so
    /// a change takes effect on the next keystroke without a relaunch.
    private func commit(_ overrides: [String: Override], saying account: Account) {
        try? KeymapStore.save(overrides)
        dispatcher.reload()
        hasOverrides = !overrides.isEmpty
        self.account = account
    }



}

/// WHAT A KEYMAP LOAD DROPPED OR TOOK AWAY, drawn the same way on every
/// surface that lists bindings ([[RFC-0016]] C-CONFLICT, C-DISCOVERY).
///
/// A view rather than two copies of the same `HStack`: the reference sheet
/// lists bindings too, and a human who opens that one instead must be told
/// the same thing.
struct KeymapLoadNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.xs) {
            Image(systemName: "exclamationmark.triangle")
            Text(text)
            Spacer(minLength: 0)
        }
        .font(DS.Typography.caption)
        .foregroundStyle(DS.warning)
        .padding(DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DS.surfaceRaised)
        )
        .accessibilityElement(children: .combine)
    }
}
