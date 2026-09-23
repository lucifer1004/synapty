import SwiftUI

/// THE REFERENCE SHEET, READ FROM THE TABLE ([[RFC-0016]] C-DISCOVERY).
///
/// IT USED TO BE TYPED OUT BY HAND, which is the shape that clause exists
/// to forbid: a chord written into a surface is a claim about behaviour
/// that nothing keeps true, and it stays on screen looking authoritative
/// for as long as it takes someone to notice. This one had already gone
/// stale twice over — it listed "Rename (sidebar) — Enter" after that
/// handler was removed, and said nothing about ⌘K at all.
///
/// EVERY COMMAND, INCLUDING THOSE HOLDING NOTHING, and the EFFECTIVE chord
/// rather than the default — a human who has rebound something is exactly
/// the human who opens this sheet.
struct KeyboardShortcutsView: View {
    @Binding var isPresented: Bool
    var dispatcher = KeyDispatcher.shared

    var body: some View {
        VStack(spacing: 0) {
            DSSheetHeader(title: "Keyboard Shortcuts", icon: "keyboard", isPresented: $isPresented)

            DSHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    // BINDINGS ARE SHOWN HERE TOO, so what the load dropped
                    // or took away is shown here too ([[RFC-0016]]
                    // C-CONFLICT).
                    if let notice = dispatcher.keymap.loadNotice {
                        KeymapLoadNotice(text: notice)
                    }
                    ForEach(KeyCommandTable.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: DS.Space.sm) {
                            DSSectionLabel(text: group.title)
                            ForEach(group.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                .padding(DS.Space.xl)
            }

            DSHairline()

            // WHERE THEY ARE CHANGED. A reference sheet that does not say
            // this leaves the human believing the list is the platform's
            // rather than theirs.
            HStack {
                Text("Change any of these in Settings ▸ Keys.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.md)
        }
        .frame(width: DS.scaled(460), height: DS.scaled(520))
        .background(DS.background)
    }

    @ViewBuilder
    private func row(_ entry: KeyCommandTable.Entry) -> some View {
        // A FAMILY IS SHOWN AS ITSELF — its name and its range — because
        // nine members are one act.
        switch entry {
        case .family(let family):
            HStack(spacing: DS.Space.md) {
                Text(family.name)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                Spacer()
                if let range = family.rangeDisplay(dispatcher.keymap) {
                    DSKeycap(range)
                } else {
                    Text("mixed")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textTertiary)
                }
            }
        case .command(let command):
        HStack(spacing: DS.Space.md) {
            Text(command.name)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
            Spacer()
            if dispatcher.keymap.differsFromDefault(command) {
                Text("changed")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
            if let chord = dispatcher.keymap.chord(of: command.id) {
                DSKeycap(chord.display)
            } else {
                // A COMMAND WITH NO CHORD IS STILL LISTED ([[RFC-0016]]
                // C-UNBOUND), and what it says is where to reach it —
                // which is the question a human with no shortcut has.
                Text(command.nonKeyboardPathDescription)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textTertiary)
            }
        }
        }
    }

}

extension KeyCommandTable {
    /// A ROW OF ANY SURFACE THAT LISTS THE TABLE — one command, or one
    /// family standing for its nine ([[RFC-0016]] C-TABLE).
    enum Entry: Identifiable {
        case command(KeyCommand)
        case family(Family)

        var id: String {
            switch self {
            case .command(let c): return c.id
            case .family(let f): return f.id
            }
        }
    }

    /// HOW THE TABLE IS GROUPED FOR A HUMAN, in ONE place — consumed by
    /// the reference sheet and by the editing panel, so the two cannot
    /// drift into different arrangements of the same commands. Which is
    /// the defect this whole work item is about, met one level up.
    static var groups: [(title: String, entries: [Entry])] {
        let all = commands
        func plain(_ predicate: (KeyCommand) -> Bool) -> [Entry] {
            all.filter { $0.family == nil && predicate($0) }.map(Entry.command)
        }
        return [
            ("Workspaces, Slots & Panes", plain {
                $0.id.hasPrefix("workspace.") || $0.id.hasPrefix("pane.")
                    || $0.id.hasPrefix("slot.")
            }),
            ("Terminal", plain { $0.domain == .terminal }),
            ("Go to", plain { $0.id.hasPrefix("page.") || $0.id.hasPrefix("palette.") }
                + families.map(Entry.family)),
            ("The Workbench", plain {
                $0.id.hasPrefix("layout.") || $0.id.hasPrefix("sidebar.")
                    || $0.id.hasPrefix("settings.") || $0.id.hasPrefix("help.")
                    || $0.id.hasPrefix("files.")
            }),
        ]
    }
}
