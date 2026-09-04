import Foundation

/// What a synced SETTING names that this machine does not have.
///
/// The same shape as HostReadiness, for the same reason: the shared
/// configuration domain carries references to LOCAL resources, and a
/// reference that travels is not a resource that travels. A host names an
/// SSH key path; appearance settings name a font family. Neither exists on
/// the other Mac merely because the setting reached it.
///
/// FONTS ARE WHERE THIS DIFFERS FROM TERMIUS, which ships its own font and
/// therefore has nothing to be missing. Synapty uses whatever is installed
/// — which is better, and it means a synced font setting can name
/// something absent. Ghostty then falls back to a default, silently, and
/// the human sees different type on their second Mac with nothing
/// anywhere explaining it.
///
/// Syncing the setting anyway, rather than making appearance
/// machine-scoped, is deliberate: both Macs having the same font is the
/// common case, and making everyone configure twice to defend against the
/// uncommon one is the worse trade. The defence is saying so, not
/// withholding the setting.
enum SettingsReadiness {

    enum Gap: Equatable {
        /// The terminal font this configuration names is not installed.
        case terminalFontMissing(String)
        /// A fallback family is missing. Less severe: fallbacks are a
        /// chain and the chain still works, just shorter.
        case fallbackFontMissing([String])

        var summary: String {
            switch self {
            case .terminalFontMissing(let name):
                return "The terminal font \"\(name)\" is not installed on this Mac — a substitute is being used"
            case .fallbackFontMissing(let names):
                let list = names.joined(separator: ", ")
                return "Fallback font\(names.count == 1 ? "" : "s") not installed here: \(list)"
            }
        }
    }

    /// Evaluate against what is actually installed.
    ///
    /// Pure in its inputs so it can be tested without touching the font
    /// system, which is also what keeps the test from depending on which
    /// fonts the developer happens to have.
    static func evaluate(
        fontFamily: String?,
        fallbackFamilies: [String],
        installed: Set<String>
    ) -> [Gap] {
        var gaps: [Gap] = []
        if let f = fontFamily, !f.isEmpty, !installed.contains(f) {
            gaps.append(.terminalFontMissing(f))
        }
        let missingFallbacks = fallbackFamilies.filter { !$0.isEmpty && !installed.contains($0) }
        if !missingFallbacks.isEmpty {
            gaps.append(.fallbackFontMissing(missingFallbacks))
        }
        return gaps
    }
}
