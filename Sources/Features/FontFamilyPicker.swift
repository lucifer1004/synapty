import SwiftUI

/// Searchable popover picker over installed font families.
///
/// Two modes:
/// - `.select`: single selection; `selection == nil` means "Default"
///   (no `font-family` written to the ghostty fragment).
/// - `.add`: pick a family to append to a list (fallback fonts); the
///   selection binding is unused and `onAdd` is invoked instead.
///
/// Rows render the family name in the family's own typeface (falling back
/// silently for families SwiftUI cannot instantiate) and tag monospace
/// families. The monospace group sorts first (see FontCatalog.sorted).
struct FontFamilyPicker: View {
    enum Mode {
        case select
        case add
    }

    @Binding var selection: String?
    let families: [FontCatalog.Family]
    var mode: Mode = .select
    /// Families already in the target list (add mode): shown checked and disabled.
    var alreadyAdded: Set<String> = []
    var onAdd: ((String) -> Void)?

    @State private var showPopover = false
    @State private var search = ""
    /// Keyboard-selected row (WI-2026-08-09-004).
    @State private var selIndex = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [FontCatalog.Family] {
        FontCatalog.sorted(families, search: search)
    }

    private var title: String {
        mode == .add ? "Add Fallback…" : (selection ?? "Default")
    }

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: DS.Space.sm) {
                Text(title)
                    .font(mode == .add ? DS.Typography.detailStrong : .custom(title, size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(mode == .add || selection != nil ? DS.textPrimary : DS.textSecondary)
                Spacer()
                Image(systemName: mode == .add ? "plus" : "chevron.down")
                    .font(DS.Icon.control)
                    .foregroundStyle(DS.textTertiary)
            }
            .dsFieldShape()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            // Palette-style keyboard-first list (WI-2026-08-09-004):
            // type to filter, arrows + Enter, hover follows the pointer.
            // Sections are visual only — navigation runs on ONE flat
            // index space.
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textTertiary)
                    TextField("Search fonts…", text: $search)
                        .textFieldStyle(.plain)
                        .font(DS.Typography.body)
                        .focused($searchFocused)
                        .onSubmit { activate(at: selIndex) }
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
                        LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                            ForEach(Array(flatItems.enumerated()), id: \.offset) { index, item in
                                if index == monoStart && monoCount > 0 {
                                    sectionHeader("Monospace")
                                }
                                if index == othersStart && othersCount > 0 {
                                    sectionHeader("All Fonts")
                                }
                                fontRow(item, index: index)
                                    .id(index)
                            }
                            if filtered.isEmpty {
                                Text("No fonts match “\(search)”")
                                    .font(DS.Typography.caption)
                                    .foregroundStyle(DS.textTertiary)
                                    .padding(DS.Space.md)
                            }
                        }
                        .padding(DS.Space.sm)
                    }
                    .onAppear {
                        if mode == .select {
                            // Open scrolled to the current selection.
                            selIndex = flatItems.firstIndex(where: { $0?.name == selection }) ?? 0
                            proxy.scrollTo(selIndex, anchor: .center)
                        }
                        searchFocused = true
                    }
                    .onChange(of: selIndex) { _, newValue in
                        proxy.scrollTo(newValue)
                    }
                }
            }
            .frame(width: DS.scaled(340), height: DS.scaled(380))
            .dsListKeyNavigation(selection: $selIndex, count: { flatItems.count })
            .onChange(of: search) { _, _ in selIndex = 0 }
        }
    }

    // MARK: - Keyboard-first list (WI-2026-08-09-004)

    /// Flat selectable items — Default (select mode) + monospace families
    /// + the rest; one index space for keyboard navigation.
    private var flatItems: [FontCatalog.Family?] {
        let mono = filtered.filter(\.isMonospace)
        let others = filtered.filter { !$0.isMonospace }
        return (mode == .select ? [FontCatalog.Family?.none] : [])
            + mono.map(Optional.some)
            + others.map(Optional.some)
    }

    private var monoStart: Int { mode == .select ? 1 : 0 }
    private var monoCount: Int { filtered.filter(\.isMonospace).count }
    private var othersStart: Int { monoStart + monoCount }
    private var othersCount: Int { filtered.count - monoCount }

    private func activate(at index: Int) {
        guard flatItems.indices.contains(index) else { return }
        let item = flatItems[index]
        if mode == .select {
            selection = item?.name
            showPopover = false
        } else if let family = item, !alreadyAdded.contains(family.name) {
            // Add mode stays open for adding several fallbacks in a row.
            onAdd?(family.name)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        DSSectionLabel(text: title)
            .padding(.horizontal, DS.Space.md)
            .padding(.top, DS.Space.sm)
    }

    @ViewBuilder
    private func fontRow(_ item: FontCatalog.Family?, index: Int) -> some View {
        let isAdded = mode == .add && (item.map { alreadyAdded.contains($0.name) } ?? false)
        HStack(spacing: DS.Space.sm) {
            if let family = item {
                Text(family.name)
                    .font(.custom(family.name, size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isAdded ? DS.textTertiary : DS.textPrimary)
                if family.isMonospace {
                    Text("Mono")
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(DS.accent)
                        .padding(.horizontal, DS.Space.xs + 2)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.accentSoft)
                        )
                }
                Spacer()
                if mode == .select, selection == family.name {
                    Image(systemName: "checkmark")
                        .font(DS.Icon.control)
                        .foregroundStyle(DS.selectionAccent)
                } else if isAdded {
                    Image(systemName: "checkmark")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textTertiary)
                }
            } else {
                Text("Default (system monospace)")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                Spacer()
                if selection == nil {
                    Image(systemName: "checkmark")
                        .font(DS.Icon.control)
                        .foregroundStyle(DS.accent)
                }
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(index == selIndex ? DS.selection : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { activate(at: index) }
        .onHover { hovering in
            if hovering { selIndex = index }
        }
    }
}
