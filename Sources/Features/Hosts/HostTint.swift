import SwiftUI

/// A HOST'S OWN COLOUR, derived from its name and nothing else
/// ([[WI-2026-09-02-011]], the UI review's P5).
///
/// The avatar coloured hosts by OS family, so every Linux box was the
/// same orange and the one thing the colour could have told the eye —
/// WHICH machine — it did not. A stable hue from the label makes the same
/// host the same colour on its avatar, on its workspace row and on the
/// leading edge of its panes' tabs ([[HostSpine]]), and two hosts
/// different colours without anyone choosing them. Saturation and
/// brightness are fixed so every hue reads as a mark and none as a
/// warning; the semantic colours (danger, warning, accent) stay the only
/// saturated ones with a meaning.
enum HostTint {

    static let saturation = 0.50
    static let brightness = 0.58

    /// HOW MANY COLOURS THERE ARE, and why there are not three hundred
    /// and sixty ([[WI-2026-09-17-001]]).
    ///
    /// A CONTINUOUS HUE SPACE PROMISES A DISTINCTION IT CANNOT KEEP. Two
    /// names landing six degrees apart are the same colour to the eye and
    /// a different colour to the program, so the mark says "these are
    /// different machines" in a way nobody can read. Quantised, two hosts
    /// either differ by thirty degrees — which is a difference — or share
    /// a band exactly, which reads as "the colour cannot tell these two
    /// apart" and is true.
    static let bands = 12

    /// WHICH BAND A NAME FALLS IN. FNV-1a, stable across launches and
    /// machines — the same name is the same colour everywhere, which is
    /// what lets the colour be recognised rather than looked up.
    ///
    /// NOT djb2, WHICH THIS WAS, AND THE REASON IS ARITHMETIC RATHER THAN
    /// TASTE. djb2 is `h*33 + c`, so a name's last characters dominate
    /// the low bits — and `33^4 mod 360` is 81, whose gcd with 360 is 9.
    /// Every set of names sharing a four-character suffix therefore had
    /// its prefixes folded into forty of the three hundred and sixty
    /// slots. Real machines are named with shared suffixes, and the
    /// fleet this was read on showed it: `remotehost` 295° against
    /// `otherhost` 301°, `build-01` 147° against `build-02` 148° against
    /// `cache.internal` 148°, `gpu-a` 351° against `gpu-b` 352°. Three
    /// pairs of "different" colours nobody could tell apart.
    ///
    /// FNV-1a is what [[AgentMonitor]] already reaches for when it needs
    /// a stable, distinguishable colour for a tool it does not know.
    static func band(for label: String) -> Int {
        var h: UInt32 = 2_166_136_261
        for byte in label.utf8 { h = (h ^ UInt32(byte)) &* 16_777_619 }
        return Int(h % UInt32(bands))
    }

    static func hue(for label: String) -> Double {
        Double(band(for: label)) / Double(bands)
    }

    static func color(for label: String) -> Color {
        Color(hue: hue(for: label), saturation: saturation, brightness: brightness)
    }
}
