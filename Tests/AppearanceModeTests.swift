import XCTest
import AppKit
@testable import Synapty

final class AppearanceModeTests: XCTestCase {

    func testCodableRoundTrip() throws {
        for mode in AppearanceMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(AppearanceMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    func testRawValuesStable() {
        XCTAssertEqual(AppearanceMode.system.rawValue, "system")
        XCTAssertEqual(AppearanceMode.light.rawValue, "light")
        XCTAssertEqual(AppearanceMode.dark.rawValue, "dark")
    }

    func testNSAppearanceMapping() {
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }

    func testLabels() {
        XCTAssertEqual(AppearanceMode.system.label, "System")
        XCTAssertEqual(AppearanceMode.light.label, "Light")
        XCTAssertEqual(AppearanceMode.dark.label, "Dark")
    }
}
