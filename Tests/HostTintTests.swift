import XCTest
@testable import Synapty

/// [[HostTint]] — the colour a host wears is a function of its name.
final class HostTintTests: XCTestCase {

    /// THE SAME COLOUR EVERYWHERE, which is the whole claim: `HostTint`
    /// says its hash is "stable across launches and machines", so that a
    /// host can be RECOGNISED by its colour rather than looked up.
    ///
    /// Pinned against numbers computed outside this program. Calling the
    /// function twice and comparing it to itself agreed with any
    /// implementation, including a `hashValue` — which Swift seeds per
    /// process, so the very substitution this test names would have passed
    /// it and failed on the next launch ([[WI-2026-09-10-004]]).
    func testAKnownNameKeepsAKnownHue() {
        XCTAssertEqual(HostTint.hue(for: "remotehost"), 1.0 / 12, accuracy: 1e-12)
        XCTAssertEqual(HostTint.hue(for: "otherhost"), 7.0 / 12, accuracy: 1e-12)
        XCTAssertEqual(HostTint.hue(for: "deskmac"), 3.0 / 12, accuracy: 1e-12)
        XCTAssertEqual(HostTint.hue(for: ""), 1.0 / 12, accuracy: 1e-12)
    }

    /// The pair this workbench actually shows side by side.
    ///
    /// NO LONGER "DIFFERENT NAMES, DIFFERENT HUES", because that is not
    /// what a twelve-colour palette promises and asserting it would be
    /// asserting a bug. Two names may share a band; what they may not do
    /// is land close enough to look alike while the program treats them
    /// as distinct ([[WI-2026-09-17-001]], and the test below).
    func testTheTwoMachinesShownTogetherAreFarApart() {
        XCTAssertNotEqual(HostTint.hue(for: "remotehost"), HostTint.hue(for: "otherhost"))
    }

    /// THE DEFECT, PINNED. `HostTint` used djb2, whose low bits are
    /// dominated by a name's last characters — and machines are named
    /// with shared suffixes. Measured on the old hash: `build-01` 147°,
    /// `build-02` 148°, `cache.internal` 148°, `gpu-a` 351°, `gpu-b`
    /// 352°. Each of those pairs claimed to be a distinction and was not.
    ///
    /// EITHER APART OR IDENTICAL, NEVER NEARLY. A shared band is honest —
    /// it says the colour cannot tell these two apart. A one-degree gap
    /// is the lie.
    func testNamesSharingASuffixAreEitherFarApartOrTheSameColour() {
        let fleet = ["build-01", "build-02", "build-03", "cache.internal",
                     "db.internal", "web.internal", "gpu-a", "gpu-b",
                     "remotehost", "otherhost"]
        let step = 1.0 / Double(HostTint.bands)
        for a in fleet {
            for b in fleet where a < b {
                let gap = abs(HostTint.hue(for: a) - HostTint.hue(for: b))
                XCTAssertTrue(gap == 0 || gap >= step - 1e-12,
                              "\(a) and \(b) are \(gap * 360)° apart — close enough to "
                              + "look like one colour while being treated as two")
            }
        }
    }

    /// AND THE PALETTE IS THE PALETTE. Every hue is a band, so nothing
    /// can reintroduce a continuous one by a side door.
    func testEveryHueIsOneOfTheBands() {
        for name in ["", "a", "remotehost", "10.0.0.5", "ノード", "Deskmac"] {
            let index = HostTint.hue(for: name) * Double(HostTint.bands)
            XCTAssertEqual(index, index.rounded(), accuracy: 1e-12,
                           "\(name) landed between bands")
        }
    }

    func testHueIsAUnitFraction() {
        for name in ["", "a", "remotehost", "10.0.0.5", "ノード"] {
            let h = HostTint.hue(for: name)
            XCTAssertGreaterThanOrEqual(h, 0)
            XCTAssertLessThan(h, 1)
        }
    }

    /// A MARK, NOT A WARNING: below the saturation the semantic colours
    /// carry, so no host can be mistaken for a state.
    func testTheTintStaysUnderSemanticSaturation() {
        XCTAssertLessThanOrEqual(HostTint.saturation, 0.6)
        XCTAssertLessThan(HostTint.brightness, 0.7)
    }
}
