import SwiftUI

/// A HOST'S OWN COLOUR, derived from its name and nothing else
/// ([[WI-2026-09-02-011]], the UI review's P5).
///
/// The avatar coloured hosts by OS family, so every Linux box was the
/// same orange and the one thing the colour could have told the eye —
/// WHICH machine — it did not. A stable hue from the label makes the same
/// host the same colour on its avatar, on its workspace row and on the
/// tabs of its panes, and two hosts different colours without anyone
/// choosing them. Saturation and brightness are fixed so every hue reads
/// as a mark and none as a warning; the semantic colours (danger, warning,
/// accent) stay the only saturated ones with a meaning.
enum HostTint {

    static let saturation = 0.50
    static let brightness = 0.58

    /// djb2 over the label's scalars. Stable across launches and
    /// machines — the same name is the same colour everywhere, which is
    /// what lets the colour be recognised rather than looked up.
    static func hue(for label: String) -> Double {
        let hash = label.unicodeScalars.reduce(5381 as UInt32) { ($0 &* 33) &+ $1.value }
        return Double(hash % 360) / 360.0
    }

    static func color(for label: String) -> Color {
        Color(hue: hue(for: label), saturation: saturation, brightness: brightness)
    }
}
