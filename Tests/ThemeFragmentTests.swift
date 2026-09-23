import XCTest
@testable import Synapty

final class ThemeFragmentTests: XCTestCase {

    func testBothThemesProducesPair() {
        let line = SynaptySettings.themeLine(light: "GitHub Light", dark: "GitHub Dark")
        XCTAssertEqual(line, "theme = light:GitHub Light,dark:GitHub Dark")
    }

    func testOnlyLightProducesSingle() {
        let line = SynaptySettings.themeLine(light: "Rose Pine Dawn", dark: nil)
        XCTAssertEqual(line, "theme = Rose Pine Dawn")
    }

    func testOnlyDarkProducesSingle() {
        let line = SynaptySettings.themeLine(light: nil, dark: "Rose Pine")
        XCTAssertEqual(line, "theme = Rose Pine")
    }

    func testNoneProducesNil() {
        XCTAssertNil(SynaptySettings.themeLine(light: nil, dark: nil))
        XCTAssertNil(SynaptySettings.themeLine(light: "", dark: "  "))
    }

    func testWhitespaceTrimmed() {
        let line = SynaptySettings.themeLine(light: "  GitHub Light ", dark: " GitHub Dark ")
        XCTAssertEqual(line, "theme = light:GitHub Light,dark:GitHub Dark")
    }
}
