import SwiftUI

/// Searchable popover theme picker (WI-2026-08-07-006).
///
/// Replaces the 592-item `.menu` Picker, whose eager NSMenu construction
/// made the Settings page's render and menu opens slow. A lazy List in a
/// popover renders instantly and gives search.
struct ThemePicker: View {
    @Binding var selection: String?
    let themes: [String]
    /// Button width (the right panel is narrow — use a compact width there).
    var width: CGFloat = 150

    @State private var showPopover = false
    @State private var search = ""

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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.hover))
            .frame(width: width)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.textTertiary)
                    TextField("Search themes…", text: $search)
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
                    Button {
                        selection = nil
                        showPopover = false
                    } label: {
                        HStack {
                            Text("Default")
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

                    if filtered.isEmpty {
                        Text("No themes match “\(search)”")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textTertiary)
                    } else {
                        ForEach(filtered, id: \.self) { name in
                            Button {
                                selection = name
                                showPopover = false
                            } label: {
                                HStack {
                                    Text(name)
                                        .font(DS.Typography.body)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .foregroundStyle(selection == name ? DS.textPrimary : DS.textSecondary)
                                    Spacer()
                                    if selection == name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10))
                                            .foregroundStyle(DS.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .frame(width: 300, height: 360)
        }
    }
}
