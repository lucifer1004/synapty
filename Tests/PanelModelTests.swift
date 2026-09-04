import XCTest
import SwiftUI
@testable import Synapty

/// [[WI-2026-08-15-009]]. The panel stopped being one hard-coded occupant
/// and became a host context with views. What these pin is the state that
/// vanishes quietly when it is wrong: a width that resets, a panel that
/// closes itself, an occupant that comes back after being dismissed.
@MainActor
final class PanelModelTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // A private suite, never `.standard` — this test writes panel state,
        // and the real one belongs to a running application.
        suiteName = "dev.synapty.tests.panel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A generous window, so the tests about the STORED width are not
    /// silently also testing the ceiling.
    private let room: Double = 1600

    // MARK: - Width belongs to the panel, not to the view

    /// SWITCHING VIEWS MUST NOT MOVE THE EDGE.
    ///
    /// Width was per view once, on the reasoning that a file list wants more
    /// room than a column of controls. That reasoning was about CONTENT and
    /// got applied to FURNITURE: every tab switch re-clamped the panel to
    /// what the new view wanted, so the whole edge jumped and the content
    /// area reflowed. A view that does not want the full width caps its own
    /// column instead (`appearanceContentWidth`).
    /// The panel carried three occupants and now carries one; the width
    /// belonging to the furniture rather than the content is what let it
    /// survive that without the edge moving.
    func testTheWidthBelongsToThePanelNotItsContent() {
        let model = PanelModel(defaults: defaults)
        model.setWidth(520, in: room)
        let before = model.width(in: room)

        model.show(.appearance)
        XCTAssertEqual(model.width(in: room), before)
        model.close()
        model.show(.appearance)
        XCTAssertEqual(model.width(in: room), before, "reopening does not renegotiate the width")
    }

    /// Every view has to be usable at every width the human can reach, which
    /// is what makes one shared range possible in the first place.
    func testTheSharedRangeFitsTheRoomiestViewsMinimum() {
        let model = PanelModel(defaults: defaults)
        model.setWidth(10, in: room)
        XCTAssertEqual(model.width(in: room), PanelModel.minWidth)
        model.setWidth(4000, in: room)
        XCTAssertEqual(model.width(in: room), PanelModel.maxWidth(in: room))
        XCTAssertGreaterThanOrEqual(PanelModel.minWidth, 300,
                                    "narrower than this and the file list cannot show a size")
    }

    /// A width the human chose survives a relaunch. The panel width was
    /// already lost once by living somewhere that forgot.
    func testAWidthTheHumanChoseSurvivesARelaunch() {
        PanelModel(defaults: defaults).setWidth(500, in: room)
        XCTAssertEqual(PanelModel(defaults: defaults).width(in: room), 500)
    }

    /// WIDTHS ARE DESIGN POINTS, NOT POINTS ON THE GLASS.
    ///
    /// The divider drags in scaled points and clamps against scaled bounds.
    /// If the model clamped the same number against unscaled ones, the range
    /// the human could reach and the range the panel would keep were
    /// different ranges at any UI size but 100% — drag past the maximum, let
    /// go, watch it jump back.
    func testAStoredWidthIsIndependentOfTheUiScale() {
        let model = PanelModel(defaults: defaults)
        let scale = DS.uiFontScale
        defer { DS.uiFontScale = scale }

        model.setWidth(500, in: room)
        DS.uiFontScale = 1.4
        XCTAssertEqual(model.width(in: room), 500,
                       "the stored value is what the human chose, not what it measured on screen")
        XCTAssertEqual(DS.scaled(model.width(in: room)), 700, "and the view is the one that scales it")
    }

    // MARK: - The ceiling protects the terminal

    /// THE LIMIT IS ABOUT THE THING NEXT TO THE PANEL. It was 640 points,
    /// which is a number rather than an argument — fine for a file list,
    /// not for a web page. What can be justified is how much room a
    /// terminal still needs to be one, so the ceiling follows the window.
    func testTheCeilingLeavesTheTerminalEnoughToBeATerminal() {
        for window in [900.0, 1600.0, 3000.0] {
            let ceiling = PanelModel.maxWidth(in: window)
            XCTAssertEqual(window - ceiling, PanelModel.minTerminalWidth,
                           "whatever the window, the terminal keeps its floor")
        }
    }

    /// A wider window means a wider panel is reachable — the point of
    /// measuring rather than picking a constant.
    func testAWiderWindowRaisesTheCeiling() {
        XCTAssertGreaterThan(PanelModel.maxWidth(in: 3000), PanelModel.maxWidth(in: 1200))
    }

    /// A WINDOW TOO SMALL FOR BOTH STILL YIELDS A USABLE PANEL rather than
    /// a negative one. The panel's own minimum wins, and the terminal is
    /// the one that gives — it can be scrolled and the panel cannot be
    /// laid out at all below its floor.
    func testATinyWindowFallsBackToThePanelsOwnMinimum() {
        XCTAssertEqual(PanelModel.maxWidth(in: 200), PanelModel.minWidth)
        let model = PanelModel(defaults: defaults)
        model.setWidth(500, in: 200)
        XCTAssertEqual(model.width(in: 200), PanelModel.minWidth)
    }

    /// A width the human chose is not DESTROYED by a narrow moment. It is
    /// clamped for display, and the stored figure comes back when the room
    /// does — otherwise dragging a window narrow would silently rewrite a
    /// preference the human set once.
    func testARoomyWidthSurvivesAWindowThatWasBrieflyNarrow() {
        let model = PanelModel(defaults: defaults)
        model.setWidth(900, in: 2000)
        XCTAssertEqual(model.width(in: 700), PanelModel.maxWidth(in: 700))
        XCTAssertEqual(model.width(in: 2000), 900, "the choice returns with the room")
    }

    /// EXPANDING IS A MODE, NOT A WIDTH. It covers the terminal rather than
    /// growing into it, so it must not touch the stored width at all — a
    /// human who expands and collapses gets back the edge they set.
    func testExpandingDoesNotDisturbTheStoredWidth() {
        let model = PanelModel(defaults: defaults)
        model.setWidth(480, in: room)
        XCTAssertFalse(model.isExpanded)

        model.toggleExpanded()
        XCTAssertTrue(model.isExpanded)
        XCTAssertEqual(model.width(in: room), 480)

        model.toggleExpanded()
        XCTAssertFalse(model.isExpanded)
        XCTAssertEqual(model.width(in: room), 480)
    }

    /// And it survives a relaunch, like every other thing about the panel
    /// this application has already lost once.
    func testExpandedSurvivesARelaunch() {
        PanelModel(defaults: defaults).toggleExpanded()
        XCTAssertTrue(PanelModel(defaults: defaults).isExpanded)
    }

    /// NAVIGATING SOMEWHERE MUST TAKE IT DOWN. An expanded panel covers
    /// the content column, so a human who asks for Hosts while it is up
    /// gets the page drawn underneath and no explanation — the click
    /// silently does nothing.
    func testCollapsingIsWhatMakesNavigationMeanSomething() {
        let model = PanelModel(defaults: defaults)
        model.toggleExpanded()
        XCTAssertTrue(model.isExpanded)

        model.collapse()
        XCTAssertFalse(model.isExpanded)
        // And it stays down across the relaunch, rather than reappearing
        // over whatever they navigated to.
        XCTAssertFalse(PanelModel(defaults: defaults).isExpanded)
    }

    /// Collapsing what is already down changes nothing — navigation
    /// happens constantly and must not be a write per click.
    func testCollapsingWhenAlreadyDownIsANoOp() {
        let model = PanelModel(defaults: defaults)
        model.collapse()
        XCTAssertFalse(model.isExpanded)
        model.show(.appearance)
        model.collapse()
        XCTAssertEqual(model.occupant, .appearance, "collapsing is not closing")
    }

    // MARK: - Which view is showing

    /// Pressing the view that is already open closes the panel.
    func testPressingTheOpenViewCloses() {
        let model = PanelModel(defaults: defaults)
        XCTAssertFalse(model.isOpen)

        model.toggle(.appearance)
        XCTAssertEqual(model.occupant, .appearance)

        model.toggle(.appearance)
        XCTAssertFalse(model.isOpen)
    }


    // MARK: - The change must not cost the human their state



}

/// [[WI-2026-08-16-001]]. Three bugs lived in this arithmetic in one day
/// and the suite saw none of them, because it sat inside an event-monitor
/// closure. It is a pure function now, and these are the three.
final class GridKeyNavigationTests: XCTestCase {

    private let right = MoveCommandDirection.right
    private let left = MoveCommandDirection.left
    private let down = MoveCommandDirection.down
    private let up = MoveCommandDirection.up

    /// ENTERING THE GRID IS NOT MOVING WITHIN IT. Before the first arrow
    /// the selection is -1, meaning "not navigating"; applying a stride to
    /// that put the first ↓ on the LAST card of row one. Right looked
    /// correct only by coincidence — its stride is 1, and -1 + 1 is 0.
    func testTheFirstArrowEntersAtTheBeginningWhicheverArrowItIs() {
        for key in [right, left, down, up] {
            XCTAssertEqual(
                GridCursor.next(from: -1, direction: key, count: 14, columns: 4), 0,
                "the first press enters the grid rather than stepping inside it")
        }
    }

    /// UP AND DOWN MOVE BY A ROW, which is the whole reason a grid looks
    /// like a grid. They used to move by one, so ↑ and ← did the same
    /// thing and the keys contradicted the picture.
    func testUpAndDownMoveByARow() {
        XCTAssertEqual(GridCursor.next(from: 0, direction: down, count: 14, columns: 4), 4)
        XCTAssertEqual(GridCursor.next(from: 7, direction: up, count: 14, columns: 4), 3)
        XCTAssertNotEqual(
            GridCursor.next(from: 5, direction: up, count: 14, columns: 4),
            GridCursor.next(from: 5, direction: left, count: 14, columns: 4),
            "up is not left")
    }

    /// THE EDGES HOLD rather than wrapping or running off. A grid whose
    /// last row is short must not let ↓ select something that is not there.
    func testTheEdgesHold() {
        XCTAssertEqual(GridCursor.next(from: 13, direction: down, count: 14, columns: 4), 13)
        XCTAssertEqual(GridCursor.next(from: 12, direction: down, count: 14, columns: 4), 13,
                       "a short last row lands on what exists")
        XCTAssertEqual(GridCursor.next(from: 0, direction: up, count: 14, columns: 4), 0)
        XCTAssertEqual(GridCursor.next(from: 0, direction: left, count: 14, columns: 4), 0)
    }

    /// A SINGLE COLUMN STILL WALKS ONE AT A TIME, which is what every
    /// caller that passes nothing relies on.
    func testOneColumnStepsByOne() {
        XCTAssertEqual(GridCursor.next(from: 2, direction: down, count: 9, columns: 1), 3)
        XCTAssertEqual(GridCursor.next(from: 2, direction: up, count: 9, columns: 1), 1)
    }

    /// An empty grid has nowhere to go, and must not answer as though it
    /// did — a selection into nothing is what Return would then activate.
    func testAnEmptyGridStaysPut() {
        XCTAssertEqual(GridCursor.next(from: -1, direction: down, count: 0, columns: 4), -1)
    }
}

/// [[WI-2026-08-16-001]]. Two grids stacked — groups above hosts — and the
/// arrows have to cross between them the way the eye does.
final class SectionedGridCursorTests: XCTestCase {

    private let down = MoveCommandDirection.down
    private let up = MoveCommandDirection.up
    private let right = MoveCommandDirection.right
    private let left = MoveCommandDirection.left

    /// A FLAT INDEX ACROSS SECTIONS IS WRONG, and this is the case that
    /// shows it: four columns, two groups, so ↓ from the first group must
    /// land on the first HOST — the card directly below it — and not four
    /// places along.
    func testCrossingKeepsTheColumnRatherThanTheOffset() {
        let at = GridCursor.Position(section: 0, item: 0)
        XCTAssertEqual(
            GridCursor.next(from: at, direction: down, sections: [2, 14], columns: 4),
            GridCursor.Position(section: 1, item: 0))

        let second = GridCursor.Position(section: 0, item: 1)
        XCTAssertEqual(
            GridCursor.next(from: second, direction: down, sections: [2, 14], columns: 4),
            GridCursor.Position(section: 1, item: 1))
    }

    /// UP LANDS ON THE LAST ROW OF THE SECTION ABOVE, in the same column —
    /// which is the card actually sitting there, not its first row.
    func testGoingUpEntersTheLastRowAbove() {
        let firstHost = GridCursor.Position(section: 1, item: 1)
        XCTAssertEqual(
            GridCursor.next(from: firstHost, direction: up, sections: [6, 14], columns: 4),
            GridCursor.Position(section: 0, item: 5),
            "six groups over four columns: the last row is items 4 and 5")
    }

    /// A SHORT LAST ROW ABOVE still catches the cursor rather than letting
    /// it point past the end.
    func testUpIntoAShortLastRow() {
        let host = GridCursor.Position(section: 1, item: 3)
        XCTAssertEqual(
            GridCursor.next(from: host, direction: up, sections: [5, 14], columns: 4),
            GridCursor.Position(section: 0, item: 4),
            "column 3 has nothing in the last row, so it clamps to what exists")
    }

    /// LEFT AND RIGHT STAY IN THEIR SECTION, because a row belongs to one
    /// grid — crossing sideways would jump the eye a whole section.
    func testSidewaysStaysInSection() {
        let firstGroup = GridCursor.Position(section: 0, item: 0)
        XCTAssertEqual(
            GridCursor.next(from: firstGroup, direction: left, sections: [2, 14], columns: 4),
            firstGroup)
        XCTAssertEqual(
            GridCursor.next(from: GridCursor.Position(section: 0, item: 1),
                            direction: right, sections: [2, 14], columns: 4),
            GridCursor.Position(section: 0, item: 1),
            "the last group has nothing to its right")
    }

    /// AN EMPTY SECTION IS SKIPPED rather than swallowing the cursor — with
    /// no groups, ↓ from a host must not land somewhere invisible.
    func testAnEmptySectionIsNotEntered() {
        XCTAssertEqual(
            GridCursor.next(from: nil, direction: down, sections: [0, 14], columns: 4),
            GridCursor.Position(section: 1, item: 0),
            "entering skips the empty grid entirely")
        let host = GridCursor.Position(section: 1, item: 2)
        XCTAssertEqual(
            GridCursor.next(from: host, direction: up, sections: [0, 14], columns: 4),
            GridCursor.Position(section: 1, item: 0),
            "there is nothing above, so it clamps inside its own section")
    }

    /// Nothing anywhere has nowhere to go, and must say so rather than
    /// answering with a position into an empty grid.
    func testEverythingEmpty() {
        XCTAssertNil(GridCursor.next(from: nil, direction: down, sections: [0, 0], columns: 4))
    }
}


/// [[HostEntry]]'s Codable is half synthesised and half written out, which
/// is a shape that loses data silently: a property added to the struct is
/// encoded from the shared `CodingKeys` and then dropped by the
/// hand-written `init(from:)`, so it survives a save and dies on the next
/// launch with nothing failing to compile.
///
/// These three together make that impossible to ship. Found while adding
/// `durableSessions`, which would have been exactly that bug.
final class HostEntryCodingTests: XCTestCase {

    /// A host with EVERY field set away from its default.
    private func populated() -> HostEntry {
        HostEntry(
            id: UUID(), label: "Builder", address: "10.0.0.9", port: 2222,
            username: "z", sshKeyPath: "/keys/id_ed25519", groupID: UUID(),
            tags: ["prod"], identityID: UUID(), proxyJump: "jump@edge:22",
            forwardings: [PortForward(kind: .local, listenPort: 8080,
                                      targetHost: "127.0.0.1", targetPort: 80)],
            osHint: "linux", lastConnectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durableSessions: false)
    }

    /// One key's value as canonical JSON. `String(describing:)` will not
    /// do — for an array or a dictionary it prints the object's ADDRESS,
    /// so two equal values compare unequal on every run.
    private func encoded(_ host: HostEntry) throws -> [String: String] {
        let data = try JSONEncoder().encode(host)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try object.mapValues { value in
            let wrapped = try JSONSerialization.data(withJSONObject: [value],
                                                     options: [.sortedKeys, .fragmentsAllowed])
            return String(decoding: wrapped, as: UTF8.self)
        }
    }

    /// EVERY STORED PROPERTY HAS A KEY. Adding one without a key means it
    /// is never persisted at all, and this is the only place that notices.
    func testEveryStoredPropertyIsCoded() {
        let mirrored = Mirror(reflecting: populated()).children.count
        XCTAssertEqual(HostEntry.CodingKeys.allCases.count, mirrored,
                       "a stored property was added without a CodingKey")
    }

    /// THE FIXTURE MUST EXERCISE EVERY KEY, or the round trip below cannot
    /// tell a preserved field from one that reverted to its default. This
    /// fails when a new field is added and left at its default here.
    func testTheFixtureDiffersFromADefaultHostInEveryKey() throws {
        let plain = try encoded(HostEntry(label: "", address: "", username: ""))
        let full = try encoded(populated())
        for key in HostEntry.CodingKeys.allCases.map(\.rawValue) {
            XCTAssertNotEqual(plain[key], full[key], "the fixture leaves \(key) at its default")
        }
    }

    /// AND EVERY KEY SURVIVES THE ROUND TRIP. A key the decoder drops comes
    /// back as its default and this compares unequal.
    func testEveryCodedKeySurvivesADecode() throws {
        // ONE instance, encoded once — `populated()` mints fresh UUIDs on
        // every call, so encoding it twice compares two different hosts.
        let host = populated()
        let data = try JSONEncoder().encode(host)
        let original = try encoded(host)
        let restored = try encoded(JSONDecoder().decode(HostEntry.self, from: data))
        for key in HostEntry.CodingKeys.allCases.map(\.rawValue) {
            XCTAssertEqual(original[key], restored[key], "init(from:) does not read \(key)")
        }
    }

    /// AND A HOST RECORDED BEFORE ANY OF THIS STILL LOADS, which is the
    /// whole reason the decoder is written out rather than synthesised.
    func testAHostFromAnOlderFileStillLoads() throws {
        let old = Data(#"{"label":"Old","address":"h","username":"z"}"#.utf8)
        let host = try JSONDecoder().decode(HostEntry.self, from: old)
        XCTAssertEqual(host.port, 22)
        XCTAssertTrue(host.durableSessions, "absent means on — it is what the code was doing")
    }
}
