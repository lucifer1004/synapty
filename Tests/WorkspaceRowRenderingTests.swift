import XCTest
import SwiftUI
@testable import Synapty

/// THE DOT SAYS STATE, AND A ROW MUST NOT BE ABLE TO TELL YOU WHICH
/// MACHINE IT IS ON ([[WI-2026-09-07-003]]).
///
/// NINE UNIT TESTS COULD NOT SEE THIS. `WorkspaceStatus` was referenced by
/// no test but its own, so putting `HostTint.color(for: host.label)` back
/// on the sidebar dot left every one of them green — and the defect that
/// actually happened was of exactly that shape: the precedence argument
/// rested on a channel a later change had removed, and no test went
/// through the row ([[WI-2026-09-07-007]]).
///
/// AND AN ACCESSIBILITY TEST CANNOT COVER IT EITHER, which is why this is
/// pixels. `WorkspaceStatus.spoken` is nil for both `.failed` and
/// `.quiet`, so a description test cannot tell a red dot from a grey one —
/// it would cover the `spoken`/`failureReason` wiring, which is worth
/// having, and be blind to the thing that went wrong.
///
/// AN INVARIANCE, NOT A COLOUR. Asserting "the dot is grey" would pin a
/// choice; asserting "two rows differing only in their machine render
/// identically" pins the RULE, and it fails the moment anything on the row
/// starts encoding which machine it is ([[WI-2026-09-08-012]]).
@MainActor
final class WorkspaceRowRenderingTests: XCTestCase {

    private var tunnelManager: TunnelManager!
    private var tmp: URL!
    private var hostStore: HostStore!

    override func setUpWithError() throws {
        tmp = try setUpHostStoreStorage()
        tunnelManager = TunnelManager()
        TunnelManager.shared = tunnelManager
        hostStore = HostStore()
    }

    override func tearDownWithError() throws {
        TunnelManager.shared = nil
        tunnelManager = nil
        hostStore = nil
        restoreStorageOverrides(tmp)
    }

    private func render(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(
            content: view.frame(width: 300, alignment: .leading).background(.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// A row on a host called `label`, with everything else held equal.
    private func row(onHostNamed label: String) throws -> AnyView {
        let manager = WorkspaceManager()
        manager.addRemoteWorkspace(
            label: "work",
            hostEntry: HostEntry(label: label, address: "10.0.0.1", username: "u"),
            command: "synapty connect --id a --host 10.0.0.1 --port 22 --user u")
        let workspace = try XCTUnwrap(manager.activeWorkspace)
        return AnyView(WorkspaceRow(
            session: workspace,
            paneManager: manager,
            hostStore: hostStore,
            editingWorkspaceID: .constant(nil),
            closing: .constant(nil),
            agent: nil,
            agentNeedsAttention: false,
            now: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    /// THE RIG CAN SEE A DIFFERENCE WHEN THERE IS ONE. Without this, a
    /// renderer that quietly produced two blank images would pass the
    /// assertion below and prove nothing — the lesson
    /// [[IdentifierRenderingTests]] already paid for.
    func testTheRigSeesADifferenceWhenThereIsOne() throws {
        let a = try render(Text("greencloud"))
        let b = try render(Text("redmachine"))
        XCTAssertNotEqual(a, b,
                          "if two different strings render alike, the comparison below "
                          + "cannot fail and proves nothing")
    }

    /// TWO MACHINES, ONE ROW. The workspace's own label is the same, its
    /// state is the same, and only the host differs — so nothing the row
    /// draws may differ either.
    ///
    /// The two names are chosen to hash far apart: `HostTint` is a djb2
    /// over the label, and a test whose two labels happened to collide
    /// would pass with the identity colour restored.
    func testARowDoesNotSayWhichMachineItIsOn() throws {
        let green = try render(try row(onHostNamed: "greencloud"))
        let red = try render(try row(onHostNamed: "redmachine"))

        XCTAssertNotEqual(HostTint.hue(for: "greencloud"), HostTint.hue(for: "redmachine"),
                          "precondition: these two must not hash to the same colour, "
                          + "or restoring the identity dot would leave this green")
        XCTAssertEqual(green, red,
                       "the row rendered differently for two machines, so something on it "
                       + "encodes which one — which is the leaf's question and not the "
                       + "container's ([[RFC-0015]] C-LEAF-BINDING)")
    }
}
