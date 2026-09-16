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
        XCTAssertEqual(HostTint.hue(for: "remotehost"), 0.8194444444444444, accuracy: 1e-12)
        XCTAssertEqual(HostTint.hue(for: "otherhost"), 0.8361111111111111, accuracy: 1e-12)
        XCTAssertEqual(HostTint.hue(for: "deskmac"), 0.9694444444444444, accuracy: 1e-12)
        XCTAssertEqual(HostTint.hue(for: ""), 0.9472222222222222, accuracy: 1e-12)
    }

    /// The pair this workbench actually shows side by side.
    func testDifferentNamesAreDifferentHues() {
        XCTAssertNotEqual(HostTint.hue(for: "remotehost"), HostTint.hue(for: "otherhost"))
        XCTAssertNotEqual(HostTint.hue(for: "deskmac"), HostTint.hue(for: "Deskmac"),
                          "case is part of the name the human typed")
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
