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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.hover))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.textTertiary)
                    TextField("Search fonts…", text: $search)
                        .textFieldStyle(.plain)
                        .font(DS.Typography.body)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(DS.Space.md)

                Divider()

                List {
                    if mode == .select {
                        Button {
                            selection = nil
                            showPopover = false
                        } label: {
                            HStack {
                                Text("Default (system monospace)")
                                    .font(DS.Typography.body)
                                    .foregroundStyle(selection == nil ? DS.textPrimary : DS.textSecondary)
                                Spacer()
                                if selection == nil {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10))
                                        .foregroundStyle(DS.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if filtered.isEmpty {
                        Text("No fonts match “\(search)”")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                    } else {
                        Section("Monospace") {
                            pickerRows(filtered.filter(\.isMonospace))
                        }
                        Section("All Fonts") {
                            pickerRows(filtered.filter { !$0.isMonospace })
                        }
                    }
                }
                .listStyle(.plain)
            }
            .frame(width: 340, height: 380)
        }
    }

    private func pickerRows(_ items: [FontCatalog.Family]) -> some View {
        ForEach(items) { family in
            let isAdded = mode == .add && alreadyAdded.contains(family.name)
            Button {
                guard !isAdded else { return }
                if mode == .select {
                    selection = family.name
                    showPopover = false
                } else {
                    onAdd?(family.name)
                }
            } label: {
                HStack(spacing: DS.Space.sm) {
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
                            .font(.system(size: 10))
                            .foregroundStyle(DS.accent)
                    } else if isAdded {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isAdded)
        }
    }
}
