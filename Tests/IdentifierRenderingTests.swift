import XCTest
import SwiftUI
import AppKit
@testable import Synapty

/// AN IDENTIFIER DOES NOT CHANGE WHEN THE LOCALE DOES.
///
/// `Text("#\(anInt)")` resolves to the LocalizedStringKey initialiser,
/// which group-separates the number for the locale — so GitHub issue 1234
/// renders as "#1,234" in en_US and "#1.234" in de_DE, neither of which
/// is an issue anyone can look up. `portText` in ServicesView states the
/// rule; this is the test for it.
///
/// The assertion is made on PIXELS of the real row rather than on a string
/// a test re-types, because the defect IS the choice of initialiser: a
/// helper that returns the right string proves nothing if the view stops
/// calling it. Rendering the production view under two locales that
/// separate differently catches that, and needs no accessibility
/// permission from anyone.
///
/// [[WI-2026-08-28-012]]
@MainActor
final class IdentifierRenderingTests: XCTestCase {

    private func render(_ view: some View, locale: String) throws -> Data {
        let renderer = ImageRenderer(
            content: view
                .environment(\.locale, Locale(identifier: locale))
                .frame(width: 420, alignment: .leading)
                .background(.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private static let task = TaskItem(
        number: 1234, title: "Rename the holder", state: "open",
        url: "https://github.com/o/r/issues/1234", labels: [], assignee: nil)

    /// The rig can see grouping at all. Without this, a renderer that
    /// silently produced two blank images would pass the real assertion.
    func testTheRigSeesGroupingWhenItHappens() throws {
        let quantity = Text("\(1234)")
        XCTAssertNotEqual(try render(quantity, locale: "en_US"),
                          try render(quantity, locale: "de_DE"),
                          "a quantity separates differently per locale; if these match, "
                          + "the comparison below cannot fail and proves nothing")
    }

    func testAFourDigitIssueNumberRendersTheSameInEveryLocale() throws {
        let row = TaskRow(task: Self.task)
        XCTAssertEqual(try render(row, locale: "en_US"),
                       try render(row, locale: "de_DE"),
                       "issue #1234 rendered differently under en_US and de_DE, which "
                       + "means it went through a number formatter")
    }
}
