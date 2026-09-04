import SwiftUI

/// Searchable popover theme picker (WI-2026-08-07-006).
///
/// Replaces the 592-item `.menu` Picker, whose eager NSMenu construction
/// made the Settings page's render and menu opens slow. A lazy List in a
/// popover renders instantly and gives search.
struct ThemePicker: View {
    @Binding var selection: String?
    let themes: [String]
    /// Fixed picker width; nil = stretch to the available row width
    /// (WI-2026-08-08-083).
    var width: CGFloat? = 150

    @State private var showPopover = false
    @State private var search = ""
    /// Keyboard-selected row (WI-2026-08-09-004).
    @State private var selIndex = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return themes }
        return themes.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: DS.Space.sm) {
                Text(selection ?? "Default")
                    .font(DS.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selection == nil ? DS.textSecondary : DS.textPrimary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(DS.Icon.control)
                    .foregroundStyle(DS.textTertiary)
            }
            .dsFieldShape()
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            // Palette-style keyboard-first list (WI-2026-08-09-004):
            // type to filter, arrows + Enter, hover follows the pointer.
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textTertiary)
                    TextField("Search themes…", text: $search)
                        .textFieldStyle(.plain)
                        .font(DS.Typography.body)
                        .focused($searchFocused)
                        .onSubmit { choose(at: selIndex) }
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(DS.Icon.control)
                                .foregroundStyle(DS.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    DSKeycap("↩")
                }
                .padding(DS.Space.md)
                DSHairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: DS.Space.xxs) {
                            ForEach(Array(options.enumerated()), id: \.offset) { index, name in
                                themeRow(name, index: index)
                                    .id(index)
                            }
                            if filtered.isEmpty {
                                Text("No themes match “\(search)”")
                                    .font(DS.Typography.caption)
                                    .foregroundStyle(DS.textTertiary)
                                    .padding(DS.Space.md)
                            }
                        }
                        .padding(DS.Space.sm)
                    }
                    .onAppear {
                        // Open scrolled to the current selection.
                        selIndex = options.firstIndex(where: { $0 == selection }) ?? 0
                        proxy.scrollTo(selIndex, anchor: .center)
                        searchFocused = true
                    }
                    .onChange(of: selIndex) { _, newValue in
                        proxy.scrollTo(newValue)
                    }
                }
            }
            .frame(width: DS.scaled(300), height: DS.scaled(360))
            .dsListKeyNavigation(selection: $selIndex, count: { options.count })
            .onChange(of: search) { _, _ in selIndex = 0 }
        }
    }

    // MARK: - Keyboard-first list (WI-2026-08-09-004)

    /// Selectable options: Default (nil) + filtered themes.
    private var options: [String?] {
        [nil] + filtered.map { Optional($0) }
    }

    private func choose(at index: Int) {
        guard options.indices.contains(index) else { return }
        selection = options[index]
        showPopover = false
    }

    @ViewBuilder
    private func themeRow(_ name: String?, index: Int) -> some View {
        HStack {
            Text(name ?? "Default")
                .font(DS.Typography.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(DS.textPrimary)
            Spacer()
            if selection == name {
                Image(systemName: "checkmark")
                    .font(DS.Icon.control)
                    .foregroundStyle(DS.selectionAccent)
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(index == selIndex ? DS.selection : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(at: index) }
        .onTapGesture { choose(at: index) }
        .onHover { hovering in
            if hovering { selIndex = index }
        }
    }
}
