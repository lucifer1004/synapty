import XCTest
@testable import Synapty

final class FontCatalogTests: XCTestCase {

    private func family(_ name: String, mono: Bool) -> FontCatalog.Family {
        FontCatalog.Family(name: name, isMonospace: mono)
    }

    // MARK: - Ordering

    func testMonospaceFamiliesSortFirst() {
        let families = [
            family("Zapf Dingbats", mono: false),
            family("Menlo", mono: true),
            family("Courier New", mono: true),
        ]
        let result = FontCatalog.sorted(families, search: "")
        XCTAssertEqual(result.map(\.name), ["Courier New", "Menlo", "Zapf Dingbats"])
    }

    func testEmptyCatalogStaysEmpty() {
        XCTAssertTrue(FontCatalog.sorted([], search: "").isEmpty)
    }

    // MARK: - Search

    func testSearchFiltersByName() {
        let families = [
            family("JetBrains Mono", mono: true),
            family("SF Mono", mono: true),
            family("Apple Color Emoji", mono: false),
        ]
        let result = FontCatalog.sorted(families, search: "mono")
        XCTAssertEqual(result.map(\.name), ["JetBrains Mono", "SF Mono"])
    }

    func testSearchIsCaseInsensitive() {
        let families = [
            family("Menlo", mono: true),
            family("Helvetica", mono: false),
        ]
        XCTAssertEqual(FontCatalog.sorted(families, search: "MENLO").map(\.name), ["Menlo"])
        XCTAssertEqual(FontCatalog.sorted(families, search: "helvetica").map(\.name), ["Helvetica"])
    }

    func testSearchPreservesMonospaceFirstWithinMatches() {
        let families = [
            family("Baskerville", mono: false),
            family("Fira Code", mono: true),
            family("Courier", mono: true),
            family("Copperplate", mono: false),
        ]
        let result = FontCatalog.sorted(families, search: "co")
        XCTAssertEqual(result.map(\.name), ["Courier", "Fira Code", "Copperplate"])
    }

    func testSearchIgnoresSurroundingWhitespace() {
        let families = [family("Menlo", mono: true)]
        XCTAssertEqual(FontCatalog.sorted(families, search: "  menlo  ").map(\.name), ["Menlo"])
    }

    // MARK: - Load

    func testLoadReturnsInstalledFamilies() {
        let families = FontCatalog.load()
        XCTAssertFalse(families.isEmpty)
        // Known macOS monospace families should be tagged.
        let menlo = families.first { $0.name == "Menlo" }
        XCTAssertEqual(menlo?.isMonospace, true)
    }
}
