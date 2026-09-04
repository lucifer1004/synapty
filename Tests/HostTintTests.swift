import XCTest
@testable import Synapty

/// [[HostTint]] — the colour a host wears is a function of its name.
final class HostTintTests: XCTestCase {

    func testTheSameNameIsTheSameHue() {
        XCTAssertEqual(HostTint.hue(for: "remotehost"), HostTint.hue(for: "remotehost"))
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
