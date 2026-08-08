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

    /// Load-once cache (WI-2026-08-08-026): enumerating every installed
    /// family instantiates several hundred NSFonts — re-running it per
    /// Settings/panel open hitched the UI every time. The lock makes the
    /// one-time enumeration safe to trigger from the background warm-up
    /// and a racing first view.
    private static var cached: [Family]?
    private static let loadLock = NSLock()

    /// Synchronous, cached enumeration. The first call performs the
    /// (one-time) enumeration; every later call is a cache hit.
    /// Uses the thread-safe CoreText API — NSFontManager is not safe to
    /// touch off the main thread, and the warm-up runs on a background
    /// queue (WI-2026-08-08-026, WI-2026-08-08-033).
    static func load() -> [Family] {
        if let cached { return cached }
        loadLock.lock()
        defer { loadLock.unlock() }
        if let cached { return cached }
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        let families = names.map { name in
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            let traits = CTFontGetSymbolicTraits(font)
            // kCTFontTraitMonoSpace (1 << 10) — fixed-pitch glyphs.
            let isMono = traits.contains(.init(rawValue: 1 << 10))
            return Family(name: name, isMonospace: isMono)
        }
        cached = families
        return families
    }

    /// Warm the cache off the main thread at launch so the first picker
    /// open never hitches (WI-2026-08-08-026). Call once at app start.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = load()
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
