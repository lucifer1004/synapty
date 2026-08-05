import AppKit

/// Installed font family catalog backing the settings font pickers.
/// `load()` enumerates the system via NSFontManager; `sorted(_:search:)`
/// is pure so the ordering/filtering rules are unit-testable.
enum FontCatalog {

    struct Family: Equatable, Identifiable {
        let name: String
        let isMonospace: Bool
        var id: String { name }
    }

    /// Enumerate every installed font family, tagging monospace families.
    static func load() -> [Family] {
        let names = NSFontManager.shared.availableFontFamilies
        return names.map { name in
            let isMono = NSFont(name: name, size: 12)?.isFixedPitch ?? false
            return Family(name: name, isMonospace: isMono)
        }
    }

    /// Case-insensitive search over family names; monospace families sort
    /// first, then the rest — both groups alphabetical (localizedCompare).
    static func sorted(_ families: [Family], search: String) -> [Family] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? families
            : families.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { lhs, rhs in
            if lhs.isMonospace != rhs.isMonospace { return lhs.isMonospace }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }
}
