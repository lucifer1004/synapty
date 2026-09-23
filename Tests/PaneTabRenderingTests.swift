import XCTest
import SwiftUI
@testable import Synapty

/// A TAB SAYS WHICH MACHINE IT IS ON, AND SAYS IT IN THE MARGIN
/// ([[HostSpine]], [[WI-2026-09-17-001]]).
///
/// THIS IS PIXELS FOR THE REASON [[WorkspaceRowRenderingTests]] IS. The
/// thing that went wrong is WHERE a colour is drawn, and no description,
/// no accessibility label and no unit test on a geometry constant can tell
/// a hue in the label row from the same hue at the leading edge. Both
/// arrangements satisfy every non-pixel assertion that could be written
/// about them.
///
/// AN INVARIANCE, NOT A LAYOUT. Asserting "the spine is three points wide
/// at x=3" would pin this week's numbers. What the change actually claims
/// is that two tabs differing ONLY in their machine differ only in the
/// margin — which fails the moment identity leaks back into the row of
/// marks beside the title, whatever shape it comes back as.
@MainActor
final class PaneTabRenderingTests: XCTestCase {

    private var tunnelManager: TunnelManager!
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = try setUpHostStoreStorage()
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
        restoreStorageOverrides(tmp)
    }

    private static let tabWidth: CGFloat = 160

    private func bitmap(_ view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.background(.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    /// A tab on `hostLabel`, with everything else held equal. nil is a
    /// local pane.
    private func tab(onHostNamed hostLabel: String?) throws -> AnyView {
        let manager = WorkspaceManager()
        _ = manager.addRemoteWorkspace(
            label: "work",
            hostEntry: HostEntry(label: "fixed", address: "10.0.0.1", username: "u"))
        let workspace = try XCTUnwrap(manager.activeWorkspace)
        let pane = try XCTUnwrap(workspace.panes.first)
        return AnyView(PaneTab(
            pane: pane,
            width: Self.tabWidth,
            tooltip: "",
            isBusy: { false },
            displayLabel: "build.sh",
            isActive: false,
            hostLabel: hostLabel,
            editingPaneID: .constant(nil),
            onSelect: {},
            onClose: {},
            onRename: { _ in }))
    }

    /// Which columns two renders differ in, left to right.
    private func differingColumns(_ a: NSBitmapImageRep,
                                  _ b: NSBitmapImageRep) throws -> [Int] {
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh)
        var columns: [Int] = []
        for x in 0..<a.pixelsWide {
            for y in 0..<a.pixelsHigh where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                columns.append(x)
                break
            }
        }
        return columns
    }

    /// THE RIG CAN SEE A DIFFERENCE WHEN THERE IS ONE. Without this, a
    /// renderer quietly producing two blank images would pass everything
    /// below and prove nothing — the lesson [[WorkspaceRowRenderingTests]]
    /// already paid for.
    func testTheRigSeesADifferenceWhenThereIsOne() throws {
        let a = try bitmap(Text("greencloud"))
        let b = try bitmap(Text("redmachine"))
        XCTAssertNotEqual(a.tiffRepresentation, b.tiffRepresentation,
                          "if two different strings render alike, nothing below can fail")
    }

    /// IT STILL SAYS WHICH MACHINE. Moving the mark must not be a way of
    /// deleting it: the tab is the only surface that carries identity
    /// per-pane, which is why [[WI-2026-09-07-003]] left it here when it
    /// took the same colour off the workspace row.
    func testATabOnTwoDifferentMachinesDoesNotLookTheSame() throws {
        XCTAssertNotEqual(HostTint.hue(for: "greencloud"), HostTint.hue(for: "redmachine"),
                          "precondition: these two must not hash to one colour, or the "
                          + "assertion below could pass with the machine unsaid")
        let green = try bitmap(try tab(onHostNamed: "greencloud"))
        let red = try bitmap(try tab(onHostNamed: "redmachine"))
        XCTAssertFalse(try differingColumns(green, red).isEmpty,
                       "two tabs on different machines rendered identically — the tab no "
                       + "longer says which machine it is on at all")
    }

    /// AND ONLY IN THE MARGIN. This is the finding: the identity colour
    /// sat in the row of marks beside the title, one 6pt dot away from the
    /// attention pulse, and two adjacent dots — one meaning something and
    /// one not — teach the eye to discount both.
    func testATabSaysWhichMachineOnlyAtItsLeadingEdge() throws {
        let green = try bitmap(try tab(onHostNamed: "greencloud"))
        let red = try bitmap(try tab(onHostNamed: "redmachine"))
        let columns = try differingColumns(green, red)

        // A POINT OF SLACK FOR THE CAPSULE'S OWN ANTIALIASING, and no
        // more: the row of marks begins a full `DS.Space.lg` further in,
        // so nothing here is within reach of it by accident.
        let bound = Int(HostSpine.occupiedWidth.rounded(.up)) + 1
        let strays = columns.filter { $0 >= bound }
        XCTAssertTrue(strays.isEmpty,
                      "the machine is encoded at columns \(strays) as well as in the "
                      + "margin (< \(bound)) — identity is back among the marks that "
                      + "mean something")
    }

    /// A LOCAL PANE WEARS NOTHING. The spine answers "which of several
    /// machines", and there is no such question about this one.
    func testALocalTabHasNoSpine() throws {
        let local = try bitmap(try tab(onHostNamed: nil))
        let remote = try bitmap(try tab(onHostNamed: "greencloud"))
        let columns = try differingColumns(local, remote)
        XCTAssertFalse(columns.isEmpty, "a local tab and a remote one looked identical")
        XCTAssertTrue(columns.allSatisfy { $0 < Int(HostSpine.occupiedWidth.rounded(.up)) + 1 },
                      "a local tab differs from a remote one somewhere other than the "
                      + "margin, so something else is reporting on the host too")
    }
}
